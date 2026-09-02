import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum AttachmentStoreError: LocalizedError, Equatable {
    case unavailable
    case invalidFile(String)
    case fileTooLarge(String)
    case tooManyFiles
    case submissionTooLarge
    case storageFailure(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Attachment storage is unavailable."
        case .invalidFile(let name):
            return "\(name) is not a regular file. Directories and symbolic links cannot be attached."
        case .fileTooLarge(let name):
            return "\(name) exceeds the 10 MiB attachment limit."
        case .tooManyFiles:
            return "A run can include at most 8 attachments."
        case .submissionTooLarge:
            return "Attachments can total at most 40 MiB per run."
        case .storageFailure(let message):
            return "Could not store attachment: \(message)"
        }
    }
}

actor AttachmentStore {
    static let maximumFileBytes: Int64 = 10 * 1024 * 1024
    static let maximumAttachmentCount = 8
    static let maximumSubmissionBytes: Int64 = 40 * 1024 * 1024

    private enum Ownership: String, Codable {
        case draft
        case owned
    }

    private struct Metadata: Codable {
        let descriptor: AttachmentDescriptor
        let ownership: Ownership
    }

    let rootURL: URL
    private let fileManager = FileManager.default

    init(rootURL requestedRootURL: URL? = nil) throws {
        let requested: URL
        if let requestedRootURL {
            requested = requestedRootURL
        } else {
            requested = try Self.defaultRootURL()
        }
        do {
            try FileManager.default.createDirectory(
                at: requested,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: requested.path)
            let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard canonical.path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AttachmentStoreError.unavailable
            }
            rootURL = canonical
        } catch let error as AttachmentStoreError {
            throw error
        } catch {
            throw AttachmentStoreError.storageFailure("managed directory could not be prepared")
        }
    }

    func cleanAbandonedDrafts() throws {
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            guard isDirectoryWithoutFollowingLinks(child) else { continue }
            guard let metadata = try? readMetadata(in: child) else {
                try? fileManager.removeItem(at: child)
                continue
            }
            if metadata.ownership == .draft {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    func importFiles(_ sourceURLs: [URL], existing: [AttachmentDescriptor]) throws -> [AttachmentDescriptor] {
        guard existing.count + sourceURLs.count <= Self.maximumAttachmentCount else {
            throw AttachmentStoreError.tooManyFiles
        }
        var totalBytes = existing.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var imported: [AttachmentDescriptor] = []
        do {
            for sourceURL in sourceURLs {
                let descriptor = try importFile(sourceURL)
                imported.append(descriptor)
                totalBytes += descriptor.sizeBytes
                guard totalBytes <= Self.maximumSubmissionBytes else {
                    throw AttachmentStoreError.submissionTooLarge
                }
            }
            return imported
        } catch {
            for descriptor in imported { try? removeDraft(descriptor) }
            throw error
        }
    }

    func markOwned(_ descriptors: [AttachmentDescriptor]) throws {
        for descriptor in descriptors {
            let directory = directoryURL(for: descriptor)
            let metadata = try readMetadata(in: directory)
            guard metadata.descriptor == descriptor else {
                throw AttachmentStoreError.storageFailure("staged attachment metadata does not match")
            }
            if metadata.ownership != .owned {
                try writeMetadata(Metadata(descriptor: descriptor, ownership: .owned), in: directory)
            }
        }
    }

    func removeDraft(_ descriptor: AttachmentDescriptor) throws {
        try remove(descriptor, ownership: .draft)
    }

    func discardOwned(_ descriptors: [AttachmentDescriptor]) throws {
        for descriptor in descriptors { try remove(descriptor, ownership: .owned) }
    }

    private func remove(_ descriptor: AttachmentDescriptor, ownership: Ownership) throws {
        let directory = directoryURL(for: descriptor)
        guard isDirectoryWithoutFollowingLinks(directory) else { return }
        let metadata = try readMetadata(in: directory)
        guard metadata.descriptor == descriptor, metadata.ownership == ownership else { return }
        try fileManager.removeItem(at: directory)
    }

    private func importFile(_ sourceURL: URL) throws -> AttachmentDescriptor {
        let displayName = sourceURL.lastPathComponent.isEmpty ? "attachment" : sourceURL.lastPathComponent
        var sourceInfo = stat()
        guard lstat(sourceURL.path, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            throw AttachmentStoreError.invalidFile(displayName)
        }

        let sourceFD = open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw AttachmentStoreError.invalidFile(displayName) }
        defer { close(sourceFD) }
        guard fstat(sourceFD, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            throw AttachmentStoreError.invalidFile(displayName)
        }
        guard sourceInfo.st_size <= Self.maximumFileBytes else {
            throw AttachmentStoreError.fileTooLarge(displayName)
        }

        let attachmentID = UUID().uuidString.lowercased()
        let name = safeName(displayName)
        let directory = rootURL.appendingPathComponent(attachmentID, isDirectory: true)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let destinationFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destinationFD >= 0 else {
                throw AttachmentStoreError.storageFailure("could not create managed snapshot")
            }
            let descriptor: AttachmentDescriptor
            do {
                let result = try copyAndHash(sourceFD: sourceFD, destinationFD: destinationFD, name: displayName)
                guard fsync(destinationFD) == 0 else {
                    throw AttachmentStoreError.storageFailure("could not flush managed snapshot")
                }
                descriptor = AttachmentDescriptor(
                    attachmentId: attachmentID,
                    kind: "file",
                    stagedRelativePath: "\(attachmentID)/\(name)",
                    name: name,
                    mimeType: genericMIMEType(for: sourceURL),
                    sizeBytes: result.sizeBytes,
                    sha256: result.sha256
                )
            } catch {
                close(destinationFD)
                throw error
            }
            close(destinationFD)
            guard chmod(destination.path, 0o400) == 0 else {
                throw AttachmentStoreError.storageFailure("could not restrict managed snapshot permissions")
            }
            try writeMetadata(Metadata(descriptor: descriptor, ownership: .draft), in: directory)
            return descriptor
        } catch {
            try? fileManager.removeItem(at: directory)
            if let attachmentError = error as? AttachmentStoreError { throw attachmentError }
            throw AttachmentStoreError.storageFailure("managed snapshot could not be created")
        }
    }

    private func copyAndHash(sourceFD: Int32, destinationFD: Int32, name: String) throws -> (sizeBytes: Int64, sha256: String) {
        let source = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: false)
        let destination = FileHandle(fileDescriptor: destinationFD, closeOnDealloc: false)
        var hasher = SHA256()
        var size: Int64 = 0
        while let data = try source.read(upToCount: 64 * 1024), !data.isEmpty {
            size += Int64(data.count)
            guard size <= Self.maximumFileBytes else { throw AttachmentStoreError.fileTooLarge(name) }
            hasher.update(data: data)
            try destination.write(contentsOf: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (size, digest)
    }

    private func safeName(_ original: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var value = original.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        while value.first == "." { value.removeFirst() }
        while String(value).utf8.count > 180 { value.removeLast() }
        let result = String(value)
        return result.isEmpty || result == "." || result == ".." ? "attachment" : result
    }

    private func genericMIMEType(for url: URL) -> String {
        let detected = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        let supported = ["application/octet-stream", "application/pdf", "text/plain", "application/json"]
        return detected.flatMap { supported.contains($0) ? $0 : nil } ?? "application/octet-stream"
    }

    private func directoryURL(for descriptor: AttachmentDescriptor) -> URL {
        rootURL.appendingPathComponent(descriptor.attachmentId, isDirectory: true)
    }

    private func metadataURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".attachment-metadata.json", isDirectory: false)
    }

    private func writeMetadata(_ metadata: Metadata, in directory: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        let temporary = directory.appendingPathComponent(".attachment-metadata-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            let destination = metadataURL(in: directory)
            guard rename(temporary.path, destination.path) == 0 else {
                throw AttachmentStoreError.storageFailure("could not commit managed metadata")
            }
            let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0, fsync(directoryFD) == 0 else {
                if directoryFD >= 0 { close(directoryFD) }
                throw AttachmentStoreError.storageFailure("could not flush managed metadata")
            }
            close(directoryFD)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if let attachmentError = error as? AttachmentStoreError { throw attachmentError }
            throw AttachmentStoreError.storageFailure("could not commit managed metadata")
        }
    }

    private func readMetadata(in directory: URL) throws -> Metadata {
        let url = metadataURL(in: directory)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AttachmentStoreError.storageFailure("managed metadata is missing")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AttachmentStoreError.storageFailure("managed metadata is unreadable") }
        defer { close(fd) }
        do {
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
            return try JSONDecoder().decode(Metadata.self, from: data)
        } catch {
            throw AttachmentStoreError.storageFailure("managed metadata is invalid")
        }
    }

    private func isDirectoryWithoutFollowingLinks(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func defaultRootURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appIdentifier = Bundle.main.bundleIdentifier ?? "com.adaptiveagent.desktop"
        return applicationSupport
            .appendingPathComponent(appIdentifier, isDirectory: true)
            .appendingPathComponent("ManagedAttachments", isDirectory: true)
    }
}
