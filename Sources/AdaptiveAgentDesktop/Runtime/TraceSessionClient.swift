import Darwin
import Foundation

enum TraceSessionClientError: LocalizedError, Equatable {
    case executableMissing
    case invalidBackend(String)
    case incompatibleProtocol(String?)
    case protocolViolation(String)
    case notInitialized
    case remote(code: Int, protocolCode: String?, message: String)
    case terminated(Int32)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing: "Bundled trace-session-sidecar executable is missing."
        case .invalidBackend(let reason): "Invalid trace backend: \(reason)"
        case .incompatibleProtocol(let value):
            "Trace-session protocol 1.0 is required\(value.map { "; sidecar selected \($0)" } ?? "")."
        case .protocolViolation(let message): "Trace-session protocol error: \(message)"
        case .notInitialized: "Trace-session client is not initialized."
        case .remote(let code, let protocolCode, let message): "\(protocolCode ?? String(code)): \(message)"
        case .terminated(let status): "Trace-session helper exited with status \(status)."
        case .timedOut(let method): "Timed out waiting for \(method)."
        }
    }
}

actor TraceSessionClient {
    static let protocolVersion = "1.0"
    typealias DiagnosticsHandler = @Sendable (String) async -> Void
    typealias TerminationHandler = @Sendable (Int32) async -> Void

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let executableOverride: URL?
    private let responseTimeout: Duration
    private let shutdownTimeout: Duration
    private var stdoutBuffer = NDJSONBuffer(maximumLineBytes: 8 * 1024 * 1024)
    private var stderrBuffer = NDJSONBuffer(maximumLineBytes: 256 * 1024)
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeoutTasks: [JSONRPCID: Task<Void, Never>] = [:]
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    private var readerTasks: [Task<Void, Never>] = []
    private var diagnosticsHandler: DiagnosticsHandler?
    private var terminationHandler: TerminationHandler?
    private var initialized = false
    private var expectedTermination = false
    private var didTerminate = false

    init(
        executableURL: URL? = nil,
        responseTimeout: Duration = .seconds(30),
        shutdownTimeout: Duration = .seconds(2)
    ) {
        executableOverride = executableURL
        self.responseTimeout = responseTimeout
        self.shutdownTimeout = shutdownTimeout
        signal(SIGPIPE, SIG_IGN)
    }

    func start(
        backend: TraceSessionBackend,
        workingDirectoryURL: URL? = nil,
        diagnosticsHandler: @escaping DiagnosticsHandler = { _ in },
        terminationHandler: @escaping TerminationHandler = { _ in }
    ) async throws -> TraceSessionInitialization {
        guard !process.isRunning, !initialized else {
            throw TraceSessionClientError.protocolViolation("client already started")
        }
        try validate(backend)
        self.diagnosticsHandler = diagnosticsHandler
        self.terminationHandler = terminationHandler
        let environmentURL = ProcessInfo.processInfo.environment["ADAPTIVE_AGENT_TRACE_SESSION_PATH"]
            .map(URL.init(fileURLWithPath:))
        guard let executable = executableOverride
                ?? environmentURL
                ?? Bundle.main.url(
                    forResource: "trace-session-sidecar",
                    withExtension: nil,
                    subdirectory: "TraceSession"
                ),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TraceSessionClientError.executableMissing
        }
        process.executableURL = executable
        process.arguments = backend.launchArguments
        process.currentDirectoryURL = workingDirectoryURL
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            Task { await self?.terminated(process.terminationStatus) }
        }
        do {
            try process.run()
            startReaders()
            let result = try await request(
                method: "initialize",
                params: [
                    "protocolVersion": .string(Self.protocolVersion),
                    "clientInfo": .object([
                        "name": .string("adaptive-agent-desktop"),
                        "version": .string(
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                                ?? "1.0.0"
                        )
                    ])
                ],
                id: .string("initialize")
            )
            let info: TraceSessionInitialization = try decode(result, method: "initialize")
            guard info.protocolVersion == Self.protocolVersion else {
                throw TraceSessionClientError.incompatibleProtocol(info.protocolVersion)
            }
            guard info.backend.readOnly else {
                throw TraceSessionClientError.protocolViolation("backend is not read-only")
            }
            guard info.backend.kind == backend.kind else {
                throw TraceSessionClientError.protocolViolation(
                    "expected \(backend.kind) backend, received \(info.backend.kind)"
                )
            }
            initialized = true
            return info
        } catch {
            await stopImmediately()
            throw error
        }
    }

    func listSessions(
        _ parameters: TraceSessionListParameters = .init()
    ) async throws -> [TraceSessionListItem] {
        try requireInitialized()
        let value = try JSONValue.encode(parameters)
        return try decode(
            try await request(method: "trace/listSessions", params: value.objectValue ?? [:]),
            method: "trace/listSessions"
        )
    }

    func getTrace(rootRunId: String) async throws -> TraceReport {
        try requireInitialized()
        guard !rootRunId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TraceSessionClientError.protocolViolation("rootRunId must not be empty")
        }
        return try decode(
            try await request(
                method: "trace/get",
                params: [
                    "target": .object([
                        "kind": .string("root-run"),
                        "rootRunId": .string(rootRunId)
                    ]),
                    "include": .object([
                        "plans": .bool(false),
                        "messages": .bool(false),
                        "reasoning": .bool(false),
                        "rawToolPayloads": .bool(false)
                    ])
                ]
            ),
            method: "trace/get"
        )
    }

    func shutdown() async {
        guard process.isRunning else {
            cleanUp()
            return
        }
        expectedTermination = true
        if initialized {
            do {
                _ = try await request(method: "shutdown", duration: shutdownTimeout)
            } catch {
                await diagnosticsHandler?(ProtocolRedactor.redact(error.localizedDescription))
            }
        }
        stdinPipe.fileHandleForWriting.closeFile()
        await waitForExit()
        cleanUp()
    }

    private func validate(_ backend: TraceSessionBackend) throws {
        switch backend {
        case .sqlite(let path):
            if path.isEmpty || !path.hasPrefix("/") {
                throw TraceSessionClientError.invalidBackend("SQLite path must be absolute")
            }
        case .postgres(let name):
            if name.isEmpty {
                throw TraceSessionClientError.invalidBackend("Postgres environment variable name is empty")
            }
        }
    }

    private func requireInitialized() throws {
        if !initialized { throw TraceSessionClientError.notInitialized }
    }

    private func request(
        method: String,
        params: [String: JSONValue] = [:],
        id: JSONRPCID = .string(UUID().uuidString),
        duration: Duration? = nil
    ) async throws -> JSONValue {
        guard process.isRunning else {
            throw TraceSessionClientError.terminated(process.terminationStatus)
        }
        let data = try encodeRequest(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let timeout = duration ?? responseTimeout
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.timedOut(id, method: method)
            }
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)
                timeoutTasks.removeValue(forKey: id)?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func encodeRequest(
        id: JSONRPCID,
        method: String,
        params: [String: JSONValue]
    ) throws -> Data {
        var data = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "method": .string(method),
            "params": .object(params)
        ]))
        guard data.count <= 1024 * 1024 else {
            throw TraceSessionClientError.protocolViolation("request exceeds 1048576 bytes")
        }
        data.append(0x0a)
        return data
    }

    private func decode<T: Decodable>(_ value: JSONValue, method: String) throws -> T {
        do {
            return try value.decode(T.self)
        } catch {
            throw TraceSessionClientError.protocolViolation("invalid \(method) result")
        }
    }

    private func startReaders() {
        let stdoutStream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(64)) {
            stdoutContinuation = $0
        }
        let stderrStream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(32)) {
            stderrContinuation = $0
        }
        let stdoutSink = stdoutContinuation
        let stderrSink = stderrContinuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutSink?.finish()
            } else if case .dropped = stdoutSink?.yield(data) {
                Task {
                    await self?.fail(
                        TraceSessionClientError.protocolViolation("stdout queue exceeded its capacity")
                    )
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrSink?.finish()
            } else {
                _ = stderrSink?.yield(data)
            }
        }
        readerTasks = [
            Task { [weak self] in
                for await data in stdoutStream { await self?.consumeStdout(data) }
            },
            Task { [weak self] in
                for await data in stderrStream { await self?.consumeStderr(data) }
            }
        ]
    }

    private func consumeStdout(_ data: Data) async {
        do {
            for line in try stdoutBuffer.append(data) { try decodeLine(line) }
        } catch {
            await fail(error)
        }
    }

    private func consumeStderr(_ data: Data) async {
        do {
            for line in try stderrBuffer.append(data) where !line.isEmpty {
                let message = String(decoding: line, as: UTF8.self)
                await diagnosticsHandler?(ProtocolRedactor.redact(message))
            }
        } catch {
            stderrBuffer.reset()
            await diagnosticsHandler?(
                "Trace-session diagnostic line exceeded 262144 bytes and was discarded."
            )
        }
    }

    private func decodeLine(_ data: Data) throws {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw TraceSessionClientError.protocolViolation("malformed JSON response")
        }
        guard let object = value.objectValue,
              object["jsonrpc"] == .string("2.0"),
              let idValue = object["id"] else {
            throw TraceSessionClientError.protocolViolation("invalid JSON-RPC response")
        }
        let id: JSONRPCID
        switch idValue {
        case .string(let value): id = .string(value)
        case .number(let value) where value.isFinite: id = .number(value)
        default: throw TraceSessionClientError.protocolViolation("invalid response id")
        }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            continuation.resume(
                throwing: TraceSessionClientError.protocolViolation("invalid response envelope")
            )
            return
        }
        if let result = object["result"] {
            continuation.resume(returning: result)
            return
        }
        guard let error = object["error"]?.objectValue,
              case .number(let rawCode) = error["code"],
              let code = Int(exactly: rawCode),
              let message = error["message"]?.stringValue else {
            continuation.resume(
                throwing: TraceSessionClientError.protocolViolation("invalid error response")
            )
            return
        }
        continuation.resume(throwing: TraceSessionClientError.remote(
            code: code,
            protocolCode: error["data"]?.objectValue?["protocolCode"]?.stringValue,
            message: message
        ))
    }

    private func timedOut(_ id: JSONRPCID, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: TraceSessionClientError.timedOut(method))
        timeoutTasks.removeValue(forKey: id)
    }

    private func fail(_ error: Error) async {
        let continuations = pending.values
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        await diagnosticsHandler?(ProtocolRedactor.redact(error.localizedDescription))
        if process.isRunning { process.terminate() }
    }

    private func terminated(_ status: Int32) async {
        guard !didTerminate else { return }
        didTerminate = true
        let error = TraceSessionClientError.terminated(status)
        let continuations = pending.values
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        stopReaders()
        if !expectedTermination {
            await diagnosticsHandler?(error.localizedDescription)
            await terminationHandler?(status)
        }
    }

    private func stopImmediately() async {
        expectedTermination = true
        if process.isRunning { process.terminate() }
        stdinPipe.fileHandleForWriting.closeFile()
        await waitForExit()
        cleanUp()
    }

    private func waitForExit() async {
        for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { process.terminate() }
        for _ in 0..<10 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    private func stopReaders() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        readerTasks.forEach { $0.cancel() }
        readerTasks.removeAll()
    }

    private func cleanUp() {
        stopReaders()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        initialized = false
    }
}
