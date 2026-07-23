import Foundation
import Darwin

enum RuntimeClientError: LocalizedError, Equatable {
    case executableMissing
    case incompatibleRuntime(String?)
    case protocolViolation(String)
    case notInitialized(String)
    case remote(code: Int, protocolCode: String?, message: String)
    case terminated(Int32)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing: return "Bundled agent-runtime executable is missing."
        case .incompatibleRuntime(let advertisedVersion):
            let advertised = advertisedVersion.map { " (runtime advertised \($0))" } ?? ""
            return "Incompatible agent runtime: protocol \(ProtocolCodec.version) is required\(advertised)."
        case .protocolViolation(let message): return "Protocol error: \(message)"
        case .notInitialized(let component): return "\(component) is not initialized."
        case .remote(let code, let protocolCode, let message): return "\(protocolCode ?? String(code)): \(message)"
        case .terminated(let status): return "Runtime exited with status \(status)."
        case .timedOut(let operation): return "Timed out waiting for \(operation)."
        }
    }
}

struct NDJSONBuffer {
    private var data = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = Data(data[..<newline])
            data.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

actor RuntimeClient {
    typealias NotificationHandler = @Sendable (String, JSONValue) async -> Void
    typealias ErrorHandler = @Sendable (String) async -> Void
    typealias TerminationHandler = @Sendable (Int32) async -> Void

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let executableURLOverride: URL?
    private let readyTimeout: Duration
    private let responseTimeout: Duration
    private let shutdownResponseTimeout: Duration
    private var stdoutBuffer = NDJSONBuffer()
    private var stderrBuffer = NDJSONBuffer()
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var readyContinuation: CheckedContinuation<RuntimeReady, Error>?
    private var readyMessage: RuntimeReady?
    private var startupError: Error?
    private var notificationHandler: NotificationHandler?
    private var errorHandler: ErrorHandler?
    private var terminationHandler: TerminationHandler?
    private var didTerminate = false
    private var expectedTermination = false
    private var protocolInitialized = false
    private var runtimeInitialized = false
    private var runtimeInitializationInProgress = false
    private var isShuttingDown = false
    private var readyTimeoutTask: Task<Void, Never>?
    private var responseTimeoutTasks: [JSONRPCID: Task<Void, Never>] = [:]
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    init(
        executableURL: URL? = nil,
        readyTimeout: Duration = .seconds(10),
        responseTimeout: Duration = .seconds(30),
        shutdownResponseTimeout: Duration = .seconds(2)
    ) {
        self.executableURLOverride = executableURL
        self.readyTimeout = readyTimeout
        self.responseTimeout = responseTimeout
        self.shutdownResponseTimeout = shutdownResponseTimeout
        signal(SIGPIPE, SIG_IGN)
    }

    func start(
        notificationHandler: @escaping NotificationHandler,
        errorHandler: @escaping ErrorHandler,
        terminationHandler: @escaping TerminationHandler = { _ in }
    ) async throws {
        self.notificationHandler = notificationHandler
        self.errorHandler = errorHandler
        self.terminationHandler = terminationHandler
        let environmentRuntime = ProcessInfo.processInfo.environment["ADAPTIVE_AGENT_RUNTIME_PATH"].map {
            URL(fileURLWithPath: $0)
        }
        guard let executable = executableURLOverride
                ?? environmentRuntime
                ?? Bundle.main.url(forResource: "agent-runtime", withExtension: nil, subdirectory: "AgentRuntime") else {
            throw RuntimeClientError.executableMissing
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RuntimeClientError.executableMissing
        }
        process.executableURL = executable
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment
        process.terminationHandler = { [weak self] process in
            Task { await self?.terminated(status: process.terminationStatus) }
        }
        do {
            try process.run()
            startReaders()
            let ready = try await awaitReady()
            guard ready.protocolVersion == ProtocolCodec.version else {
                throw RuntimeClientError.incompatibleRuntime(ready.protocolVersion)
            }
            let result = try await request(
                method: "initialize",
                params: [
                    "protocolVersion": .string(ProtocolCodec.version),
                    "clientInfo": .object([
                        "name": .string("adaptive-agent-desktop"),
                        "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                    ]),
                    "capabilities": .object([:])
                ],
                id: .string("initialize")
            )
            guard result.objectValue?["protocolVersion"] == .string(ProtocolCodec.version) else {
                throw RuntimeClientError.incompatibleRuntime(result.objectValue?["protocolVersion"]?.stringValue)
            }
            protocolInitialized = true
        } catch {
            await stopProcess()
            throw error
        }
    }

    func initializeRuntime(params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard protocolInitialized else { throw RuntimeClientError.notInitialized("Bridge protocol") }
        guard !isShuttingDown else { throw RuntimeClientError.protocolViolation("runtime is shutting down") }
        guard !runtimeInitialized, !runtimeInitializationInProgress else {
            throw RuntimeClientError.protocolViolation("agent runtime is already initialized or initializing")
        }
        runtimeInitializationInProgress = true
        defer { runtimeInitializationInProgress = false }
        let result = try await request(method: "runtime/initialize", params: params)
        runtimeInitialized = true
        return result
    }

    func send(method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard protocolInitialized else { throw RuntimeClientError.notInitialized("Bridge protocol") }
        guard !isShuttingDown else { throw RuntimeClientError.protocolViolation("runtime is shutting down") }
        guard method != "initialize", method != "runtime/initialize", method != "runtime/shutdown" else {
            throw RuntimeClientError.protocolViolation("\(method) is managed by RuntimeClient")
        }
        if method.hasPrefix("agent/") || method.hasPrefix("run/") || method.hasPrefix("interaction/") {
            guard runtimeInitialized else { throw RuntimeClientError.notInitialized("Agent runtime") }
        }
        return try await request(method: method, params: params)
    }

    private func request(
        method: String,
        params: [String: JSONValue] = [:],
        id: JSONRPCID = .string(UUID().uuidString),
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        guard process.isRunning else { throw RuntimeClientError.terminated(process.terminationStatus) }
        let data = try ProtocolCodec.encodeRequest(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            responseTimeoutTasks[id] = Task { [weak self, responseTimeout] in
                try? await Task.sleep(for: timeout ?? responseTimeout)
                guard !Task.isCancelled else { return }
                await self?.responseTimedOut(id: id, method: method)
            }
            do { try stdinPipe.fileHandleForWriting.write(contentsOf: data) }
            catch {
                pending.removeValue(forKey: id)
                responseTimeoutTasks.removeValue(forKey: id)?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    func shutdown() async {
        guard process.isRunning else {
            cleanUp()
            return
        }
        isShuttingDown = true
        expectedTermination = true
        if protocolInitialized {
            do {
                _ = try await request(method: "runtime/shutdown", timeout: shutdownResponseTimeout)
            } catch {
                await errorHandler?(error.localizedDescription)
            }
        }
        stdinPipe.fileHandleForWriting.closeFile()
        await waitForExit()
        cleanUp()
    }

    private func awaitReady() async throws -> RuntimeReady {
        if let readyMessage { return readyMessage }
        if let startupError { throw startupError }
        let timeout = readyTimeout
        return try await withCheckedThrowingContinuation {
            readyContinuation = $0
            readyTimeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self.readyTimedOut()
            }
        }
    }

    private func startReaders() {
        let stdoutStream = AsyncStream<Data> { self.stdoutContinuation = $0 }
        let stderrStream = AsyncStream<Data> { self.stderrContinuation = $0 }
        let stdout = stdoutPipe.fileHandleForReading
        let stdoutSink = stdoutContinuation
        stdout.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { stdoutSink?.finish() }
            else { stdoutSink?.yield(data) }
        }
        let stderr = stderrPipe.fileHandleForReading
        let stderrSink = stderrContinuation
        stderr.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { stderrSink?.finish() }
            else { stderrSink?.yield(data) }
        }
        stdoutTask = Task { [weak self] in
            for await data in stdoutStream {
                guard let self else { return }
                await self.consumeStdout(data)
            }
        }
        stderrTask = Task { [weak self] in
            for await data in stderrStream {
                guard let self else { return }
                await self.consumeStderr(data)
            }
        }
    }

    private func stopReaders() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        stdoutContinuation = nil
        stderrContinuation = nil
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
    }

    private func consumeStdout(_ data: Data) async {
        for line in stdoutBuffer.append(data) {
            do { try await decodeLine(line) }
            catch {
                await failProtocol(error)
                return
            }
        }
    }

    private func consumeStderr(_ data: Data) async {
        for line in stderrBuffer.append(data) {
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                await errorHandler?(text)
            }
        }
    }

    private func decodeLine(_ data: Data) async throws {
        switch try ProtocolCodec.decodeMessage(data) {
        case .ready(let ready):
            guard readyMessage == nil, !protocolInitialized else {
                throw RuntimeClientError.protocolViolation("unexpected runtime/ready notification")
            }
            readyMessage = ready
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            readyContinuation?.resume(returning: ready)
            readyContinuation = nil
        case .notification(let method, let params):
            guard protocolInitialized else {
                throw RuntimeClientError.protocolViolation("\(method) notification arrived before protocol initialization")
            }
            guard method == "agent/event" || method == "cli/output" else {
                throw RuntimeClientError.protocolViolation("unsupported runtime notification \(method)")
            }
            await notificationHandler?(method, params)
        case .success(let id, let result):
            guard let continuation = pending.removeValue(forKey: id) else { return }
            responseTimeoutTasks.removeValue(forKey: id)?.cancel()
            if id == .string("initialize"),
               result.objectValue?["protocolVersion"] == .string(ProtocolCodec.version) {
                protocolInitialized = true
            }
            continuation.resume(returning: result)
        case .failure(let id, let error):
            guard let continuation = pending.removeValue(forKey: id) else { return }
            responseTimeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(throwing: RuntimeClientError.remote(
                code: error.code,
                protocolCode: error.protocolCode,
                message: error.message
            ))
        }
    }

    private func terminated(status: Int32) async {
        guard !didTerminate else { return }
        didTerminate = true
        let error = RuntimeClientError.terminated(status)
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        if startupError == nil { startupError = error }
        readyContinuation?.resume(throwing: startupError ?? error)
        readyContinuation = nil
        let continuations = pending.values
        pending.removeAll()
        responseTimeoutTasks.values.forEach { $0.cancel() }
        responseTimeoutTasks.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        if !expectedTermination {
            await errorHandler?(error.localizedDescription)
            await terminationHandler?(status)
        }
    }

    private func readyTimedOut() {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        readyTimeoutTask = nil
        let error = RuntimeClientError.timedOut("runtime/ready")
        startupError = error
        continuation.resume(throwing: error)
    }

    private func responseTimedOut(id: JSONRPCID, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        responseTimeoutTasks.removeValue(forKey: id)
        continuation.resume(throwing: RuntimeClientError.timedOut("\(method) response"))
    }

    private func failProtocol(_ error: Error) async {
        let reportedError: Error
        if readyMessage == nil {
            reportedError = RuntimeClientError.incompatibleRuntime(nil)
            startupError = reportedError
        } else {
            reportedError = error
        }
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        readyContinuation?.resume(throwing: reportedError)
        readyContinuation = nil
        let continuations = pending.values
        pending.removeAll()
        responseTimeoutTasks.values.forEach { $0.cancel() }
        responseTimeoutTasks.removeAll()
        continuations.forEach { $0.resume(throwing: reportedError) }
        expectedTermination = true
        if process.isRunning { process.terminate() }
        await errorHandler?(reportedError.localizedDescription)
    }

    private func stopProcess() async {
        expectedTermination = true
        if process.isRunning { process.terminate() }
        stdinPipe.fileHandleForWriting.closeFile()
        await waitForExit()
        cleanUp()
    }

    private func waitForExit() async {
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    private func cleanUp() {
        stopReaders()
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        responseTimeoutTasks.values.forEach { $0.cancel() }
        responseTimeoutTasks.removeAll()
        protocolInitialized = false
        runtimeInitialized = false
        runtimeInitializationInProgress = false
    }
}
