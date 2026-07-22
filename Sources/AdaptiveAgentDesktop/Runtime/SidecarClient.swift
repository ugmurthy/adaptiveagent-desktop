import Foundation
import Darwin

enum SidecarError: LocalizedError {
    case executableMissing
    case protocolViolation(String)
    case remote(String, String)
    case terminated(Int32)

    var errorDescription: String? {
        switch self {
        case .executableMissing: return "Bundled agent-runtime executable is missing."
        case .protocolViolation(let message): return "Protocol error: \(message)"
        case .remote(let code, let message): return "\(code): \(message)"
        case .terminated(let status): return "Runtime exited with status \(status)."
        }
    }
}

actor SidecarClient {
    typealias EventHandler = @Sendable (JSONValue) async -> Void
    typealias ErrorHandler = @Sendable (String) async -> Void

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var readyContinuation: CheckedContinuation<RuntimeReady, Error>?
    private var readyMessage: RuntimeReady?
    private var eventHandler: EventHandler?
    private var errorHandler: ErrorHandler?
    private var didTerminate = false
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    func start(eventHandler: @escaping EventHandler, errorHandler: @escaping ErrorHandler) async throws {
        self.eventHandler = eventHandler
        self.errorHandler = errorHandler
        let environmentRuntime = ProcessInfo.processInfo.environment["ADAPTIVE_AGENT_RUNTIME_PATH"].map {
            URL(fileURLWithPath: $0)
        }
        guard let executable = environmentRuntime
                ?? Bundle.main.url(forResource: "agent-runtime", withExtension: nil, subdirectory: "AgentRuntime") else {
            throw SidecarError.executableMissing
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SidecarError.executableMissing
        }
        process.executableURL = executable
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment
        process.terminationHandler = { [weak self] process in
            Task { await self?.terminated(status: process.terminationStatus) }
        }
        try process.run()
        startReaders()
        let ready = try await awaitReady()
        guard ready.version == 1, ready.protocolVersion == 1, ready.type == "runtime.ready" else {
            throw SidecarError.protocolViolation("runtime.ready did not advertise protocol v1")
        }
        let hello = try await send(type: "hello")
        guard hello.objectValue?["protocolVersion"] == .number(1) else {
            throw SidecarError.protocolViolation("hello did not confirm protocol v1")
        }
    }

    func send(type: String, fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard process.isRunning else { throw SidecarError.terminated(process.terminationStatus) }
        let id = UUID()
        let data = try ProtocolCodec.encodeCommand(id: id, type: type, fields: fields)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id.uuidString] = continuation
            do { try stdinPipe.fileHandleForWriting.write(contentsOf: data) }
            catch {
                pending.removeValue(forKey: id.uuidString)
                continuation.resume(throwing: error)
            }
        }
    }

    func shutdown() async {
        let graceful = process.isRunning ? Task { try? await self.send(type: "runtime.shutdown") } : nil
        try? await Task.sleep(for: .seconds(2))
        if process.isRunning { process.terminate() }
        try? await Task.sleep(for: .seconds(1))
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        _ = await graceful?.value
        stdinPipe.fileHandleForWriting.closeFile()
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
    }

    private func awaitReady() async throws -> RuntimeReady {
        if let readyMessage { return readyMessage }
        return try await withCheckedThrowingContinuation { readyContinuation = $0 }
    }

    private func startReaders() {
        let stdout = stdoutPipe.fileHandleForReading
        stdoutTask = Task { [weak self] in
            do {
                for try await byte in stdout.bytes { await self?.consumeStdoutByte(byte) }
            } catch {
                await self?.errorHandler?(error.localizedDescription)
            }
        }
        let stderr = stderrPipe.fileHandleForReading
        stderrTask = Task { [weak self] in
            do {
                for try await byte in stderr.bytes { await self?.consumeStderrByte(byte) }
            } catch {
                await self?.errorHandler?(error.localizedDescription)
            }
        }
    }

    private func consumeStdoutByte(_ byte: UInt8) async {
        guard byte == 0x0A else { stdoutBuffer.append(byte); return }
        let line = stdoutBuffer
        stdoutBuffer.removeAll(keepingCapacity: true)
        guard !line.isEmpty else { return }
        do { try await decodeLine(line) }
        catch { await errorHandler?(error.localizedDescription) }
    }

    private func decodeLine(_ data: Data) async throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = value.objectValue, let type = object["type"]?.stringValue else {
            throw SidecarError.protocolViolation("message is not an envelope")
        }
        switch type {
        case "runtime.ready":
            let ready = try JSONDecoder().decode(RuntimeReady.self, from: data)
            readyMessage = ready
            readyContinuation?.resume(returning: ready)
            readyContinuation = nil
        case "agent.event":
            let envelope = try JSONDecoder().decode(AgentEventEnvelope.self, from: data)
            guard envelope.version == 1 else { throw SidecarError.protocolViolation("agent.event version is not 1") }
            await eventHandler?(envelope.event)
        case "response":
            let response = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
            guard response.version == 1, let continuation = pending.removeValue(forKey: response.id) else { return }
            if response.ok { continuation.resume(returning: response.result ?? .null) }
            else { continuation.resume(throwing: SidecarError.remote(response.error?.code ?? "UNKNOWN", response.error?.message ?? "Unknown runtime error")) }
        default: throw SidecarError.protocolViolation("unknown envelope type \(type)")
        }
    }

    private func consumeStderrByte(_ byte: UInt8) async {
        guard byte == 0x0A else { stderrBuffer.append(byte); return }
        let line = stderrBuffer
        stderrBuffer.removeAll(keepingCapacity: true)
        if let text = String(data: line, encoding: .utf8), !text.isEmpty { await errorHandler?(text) }
    }

    private func terminated(status: Int32) async {
        guard !didTerminate else { return }
        didTerminate = true
        let error = SidecarError.terminated(status)
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        await errorHandler?(error.localizedDescription)
    }
}
