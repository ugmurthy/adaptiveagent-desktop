import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum RunKind: String, CaseIterable, Identifiable {
        case run = "Run"
        case chat = "Chat"

        var id: Self { self }
        var systemImage: String { self == .run ? "play.fill" : "bubble.left.and.bubble.right.fill" }
    }

    enum RunStatus: String {
        case unknown = "Unknown"
        case queued = "Queued"
        case running = "Running"
        case waitingForApproval = "Approval required"
        case waitingForClarification = "Question pending"
        case succeeded = "Completed"
        case failed = "Failed"
        case interrupted = "Interrupted"

        var isActive: Bool {
            switch self {
            case .queued, .running, .waitingForApproval, .waitingForClarification: return true
            case .unknown, .succeeded, .failed, .interrupted: return false
            }
        }
    }

    struct ChatMessage: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let content: String
    }

    struct Interaction: Equatable {
        enum Kind: Equatable {
            case approval(toolName: String?, input: JSONValue?, assistantContent: String?)
            case clarification(suggestedQuestions: [String])
        }

        let runId: String
        var message: String
        var kind: Kind
        var isResolving = false
        var errorMessage: String?
    }

    struct RunFile: Identifiable, Equatable {
        enum Operation: String { case written = "Written", edited = "Edited" }

        var id: String { path }
        let path: String
        let workspaceRoot: String
        var operation: Operation
        var isSupportFile: Bool
        var sourceRunId: String
    }

    struct RunRecord: Identifiable, Equatable {
        let id: UUID
        let kind: RunKind
        var title: String
        var sessionId: String?
        var runIds: [String] = []
        var status: RunStatus = .queued
        var output: JSONValue?
        var errorMessage: String?
        var interaction: Interaction?
        var files: [RunFile] = []
        var chatMessages: [ChatMessage] = []
        var isRequestInFlight = false

        var latestRunId: String? { runIds.last }
    }

    @Published var workspacePath = ""
    @Published var agentConfigPath = ""
    @Published var settingsConfigPath = ""
    @Published var status = "Starting…"
    @Published var events: [String] = []
    @Published var isBusy = false
    @Published var isConnected = false
    @Published var showConfiguration = false
    @Published var showQuitConfirmation = false

    @Published var agentName = ""
    @Published var agentId = ""
    @Published var runtimeMode = ""
    @Published var effectiveWorkspaceRoot = ""
    @Published var shellCwd = ""
    @Published var registeredToolNames: [String] = []

    @Published var runs: [RunRecord] = []
    @Published var selectedRunItemID: UUID?
    @Published var draftKind: RunKind = .run
    @Published var draftText = ""
    @Published var chatMessage = ""
    @Published var steerMessage = ""

    private var client: RuntimeClient
    private var didBootstrap = false
    private var isQuitting = false
    private var pendingRootAssignments: [UUID] = []
    private var runToRoot: [String: String] = [:]
    private var recordByRoot: [String: UUID] = [:]
    private var resolvedInteractions: Set<UUID> = []

    init(
        client: RuntimeClient = RuntimeClient(),
        workingDirectoryURL: URL? = nil
    ) {
        let launchDirectory = (workingDirectoryURL
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL
        self.client = client
        workspacePath = launchDirectory.path
        let localSettings = launchDirectory.appendingPathComponent("agent.settings.json", isDirectory: false)
        if FileManager.default.isReadableFile(atPath: localSettings.path) {
            settingsConfigPath = localSettings.path
        }
    }

    var selectedRun: RunRecord? {
        guard let selectedRunItemID else { return nil }
        return runs.first { $0.id == selectedRunItemID }
    }

    var hasActiveWork: Bool {
        runs.contains { $0.status.isActive || $0.isRequestInFlight }
    }

    var isWaitingForRunIdentity: Bool { !pendingRootAssignments.isEmpty }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        connect()
    }

    func connect() {
        guard !isBusy, !isConnected else { return }
        isBusy = true
        Task {
            await connectRuntime()
            isBusy = false
        }
    }

    func applyConfiguration() {
        showConfiguration = false
        guard !isBusy else { return }
        isBusy = true
        Task {
            if isConnected {
                status = "Restarting runtime…"
                await client.shutdown()
            }
            markActiveRunsInterrupted()
            client = RuntimeClient()
            isConnected = false
            resetRuntimeMappings()
            await connectRuntime()
            isBusy = false
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        workspacePath = url.path
        let localSettings = url.appendingPathComponent("agent.settings.json", isDirectory: false)
        settingsConfigPath = FileManager.default.isReadableFile(atPath: localSettings.path) ? localSettings.path : ""
    }

    func chooseAgent() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK else { return }
        agentConfigPath = panel.url?.path ?? ""
    }

    func chooseSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK else { return }
        settingsConfigPath = panel.url?.path ?? ""
    }

    func newRun() {
        draftKind = .run
        draftText = ""
        selectedRunItemID = nil
    }

    func newChat() {
        draftKind = .chat
        draftText = ""
        selectedRunItemID = nil
    }

    func submitDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !text.isEmpty, !isWaitingForRunIdentity else { return }

        let recordID = UUID()
        let sessionId = draftKind == .chat ? UUID().uuidString : nil
        var record = RunRecord(
            id: recordID,
            kind: draftKind,
            title: title(for: text),
            sessionId: sessionId,
            status: .queued,
            isRequestInFlight: true
        )
        if draftKind == .chat {
            record.chatMessages.append(ChatMessage(role: .user, content: text))
        }
        runs.insert(record, at: 0)
        selectedRunItemID = recordID
        draftText = ""

        let method = draftKind == .run ? "agent/run" : "agent/chat"
        var fields: [String: JSONValue] = [draftKind == .run ? "goal" : "message": .string(text)]
        if let sessionId { fields["sessionId"] = .string(sessionId) }
        beginAgentRequest(method: method, fields: fields, recordID: recordID)
    }

    func sendChatMessage() {
        let text = chatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recordID = selectedRunItemID,
              let index = runs.firstIndex(where: { $0.id == recordID }),
              runs[index].kind == .chat,
              !runs[index].isRequestInFlight,
              !text.isEmpty,
              !isWaitingForRunIdentity else { return }

        runs[index].chatMessages.append(ChatMessage(role: .user, content: text))
        runs[index].isRequestInFlight = true
        runs[index].status = .queued
        runs[index].errorMessage = nil
        runs[index].interaction = nil
        var fields: [String: JSONValue] = ["message": .string(text)]
        if let sessionId = runs[index].sessionId { fields["sessionId"] = .string(sessionId) }
        chatMessage = ""
        beginAgentRequest(method: "agent/chat", fields: fields, recordID: recordID)
    }

    func resolveApproval(_ approved: Bool, for recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }),
              var interaction = runs[index].interaction,
              case .approval = interaction.kind,
              !interaction.isResolving else { return }
        interaction.isResolving = true
        interaction.errorMessage = nil
        resolvedInteractions.remove(recordID)
        runs[index].interaction = interaction
        runs[index].isRequestInFlight = true

        Task {
            do {
                let result = try await client.send(
                    method: "interaction/resolveApproval",
                    params: ["runId": .string(interaction.runId), "approved": .bool(approved)],
                    timeoutPolicy: .none
                )
                acceptResult(result, for: recordID)
            } catch {
                interactionFailed(error, for: recordID)
            }
        }
    }

    func resolveClarification(_ answer: String, for recordID: UUID) {
        let response = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty,
              let index = runs.firstIndex(where: { $0.id == recordID }),
              var interaction = runs[index].interaction,
              case .clarification = interaction.kind,
              !interaction.isResolving else { return }
        interaction.isResolving = true
        interaction.errorMessage = nil
        resolvedInteractions.remove(recordID)
        runs[index].interaction = interaction
        runs[index].isRequestInFlight = true

        Task {
            do {
                let result = try await client.send(
                    method: "interaction/resolveClarification",
                    params: ["runId": .string(interaction.runId), "answer": .string(response)],
                    timeoutPolicy: .none
                )
                acceptResult(result, for: recordID)
            } catch {
                interactionFailed(error, for: recordID)
            }
        }
    }

    func steerSelectedRun() {
        let message = steerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recordID = selectedRunItemID,
              let index = runs.firstIndex(where: { $0.id == recordID }),
              let runId = runs[index].latestRunId,
              !message.isEmpty else { return }
        steerMessage = ""
        Task {
            do {
                let result = try await client.send(
                    method: "run/steer",
                    params: ["runId": .string(runId), "message": .string(message)],
                    timeoutPolicy: .none
                )
                acceptResult(result, for: recordID)
            } catch {
                recordRequestFailed(error, for: recordID)
            }
        }
    }

    func runCommand(_ method: String, runId value: String) {
        let runId = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !runId.isEmpty else { return }

        if let record = runs.first(where: { $0.runIds.contains(runId) }) {
            selectedRunItemID = record.id
            sendRunCommand(method, runId: runId, recordID: record.id)
            return
        }

        let recordID = UUID()
        let abbreviatedRunId = runId.count > 20 ? String(runId.prefix(17)) + "…" : runId
        runs.insert(RunRecord(
            id: recordID,
            kind: .run,
            title: "Run \(abbreviatedRunId)",
            runIds: [runId],
            status: .unknown
        ), at: 0)
        bind(rootRunId: runId, to: recordID)
        selectedRunItemID = recordID
        sendRunCommand(method, runId: runId, recordID: recordID)
    }

    func runCommand(_ method: String, for recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }),
              let runId = runs[index].latestRunId else { return }
        sendRunCommand(method, runId: runId, recordID: recordID)
    }

    private func sendRunCommand(_ method: String, runId: String, recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        let longRunning = ["run/resume", "run/retry", "run/recover", "run/continue"].contains(method)
        let mayCreateRun = ["run/recover", "run/continue"].contains(method)
        runs[index].isRequestInFlight = true
        runs[index].errorMessage = nil
        if longRunning {
            runs[index].status = .running
        }
        if mayCreateRun {
            pendingRootAssignments.append(recordID)
        }
        Task {
            do {
                let result = try await client.send(
                    method: method,
                    params: ["runId": .string(runId)],
                    timeoutPolicy: longRunning ? .none : .standard
                )
                appendEvent("\(method) response\n\(result.prettyPrinted)")
                if method == "run/inspect" {
                    acceptInspection(result, for: recordID)
                } else {
                    acceptResult(result, for: recordID)
                    if method == "run/interrupt",
                       let index = runs.firstIndex(where: { $0.id == recordID }) {
                        runs[index].status = .interrupted
                    }
                }
            } catch {
                recordRequestFailed(error, for: recordID)
            }
        }
    }

    func revealFile(_ file: RunFile) {
        guard let url = validatedWorkspaceFileURL(path: file.path, rootPath: file.workspaceRoot),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealAllFiles(for recordID: UUID) {
        guard let record = runs.first(where: { $0.id == recordID }) else { return }
        let urls = record.files.compactMap { file -> URL? in
            guard let url = validatedWorkspaceFileURL(path: file.path, rootPath: file.workspaceRoot),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func relativeDisplayPath(for file: RunFile) -> String {
        guard let url = validatedWorkspaceFileURL(path: file.path, rootPath: file.workspaceRoot) else {
            return URL(fileURLWithPath: file.path).lastPathComponent
        }
        let root = URL(fileURLWithPath: file.workspaceRoot, isDirectory: true).standardizedFileURL.path
        guard url.path != root, url.path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.count + 1))
    }

    func fileExists(_ file: RunFile) -> Bool {
        guard let url = validatedWorkspaceFileURL(path: file.path, rootPath: file.workspaceRoot) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func requestQuit() {
        if hasActiveWork {
            showQuitConfirmation = true
        } else {
            quitAfterShutdown()
        }
    }

    func confirmQuit() {
        showQuitConfirmation = false
        quitAfterShutdown()
    }

    func shutdown() async {
        status = "Shutting down…"
        await client.shutdown()
        isConnected = false
    }

    // Internal for focused event/result tests.
    func acceptResult(_ result: JSONValue, for recordID: UUID) {
        appendEvent("Response\n\(result.prettyPrinted)")
        removePendingAssignment(recordID)
        guard let object = result.objectValue,
              let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        runs[index].isRequestInFlight = false

        let runId = object["runId"]?.stringValue
        if let runId {
            bind(rootRunId: runToRoot[runId] ?? runId, to: recordID)
        }
        let effectiveRunId = runId ?? runs[index].latestRunId ?? ""
        let message = object["message"]?.stringValue ?? "Runtime requires input."

        switch object["status"]?.stringValue {
        case "success":
            resolvedInteractions.remove(recordID)
            runs[index].status = .succeeded
            runs[index].interaction = nil
            runs[index].errorMessage = nil
            if let output = object["output"] {
                applyOutput(output, to: index)
            }
        case "failure":
            resolvedInteractions.remove(recordID)
            runs[index].status = object["code"]?.stringValue == "INTERRUPTED" ? .interrupted : .failed
            runs[index].interaction = nil
            runs[index].errorMessage = object["error"]?.stringValue ?? "The run failed."
        case "approval_requested":
            if resolvedInteractions.contains(recordID) {
                runs[index].interaction = nil
                runs[index].status = .running
            } else if var existing = runs[index].interaction, case .approval = existing.kind {
                existing.message = message
                runs[index].interaction = existing
            } else {
                runs[index].interaction = Interaction(
                    runId: effectiveRunId,
                    message: message,
                    kind: .approval(toolName: object["toolName"]?.stringValue, input: nil, assistantContent: nil)
                )
            }
            if !resolvedInteractions.contains(recordID) { runs[index].status = .waitingForApproval }
        case "clarification_requested":
            if resolvedInteractions.contains(recordID) {
                runs[index].interaction = nil
                runs[index].status = .running
            } else {
                let suggestions = object["suggestedQuestions"]?.stringArray ?? []
                runs[index].status = .waitingForClarification
                runs[index].interaction = Interaction(
                    runId: effectiveRunId,
                    message: message,
                    kind: .clarification(suggestedQuestions: suggestions)
                )
            }
        default:
            if runs[index].interaction?.isResolving == true {
                runs[index].interaction = nil
                runs[index].status = .running
                resolvedInteractions.insert(recordID)
            }
        }
    }

    // Internal for focused event/result tests.
    func receive(method: String, params: JSONValue) {
        appendEvent("\(method)\n\(params.prettyPrinted)")
        guard method == "agent/event",
              let event = params.objectValue,
              let type = event["type"]?.stringValue,
              let runId = event["runId"]?.stringValue else { return }
        let payload = event["payload"]?.objectValue ?? [:]

        if type == "delegate.spawned",
           let childRunId = payload["childRunId"]?.stringValue,
           let rootRunId = payload["rootRunId"]?.stringValue {
            runToRoot[childRunId] = rootRunId
            return
        }

        if type == "run.created" {
            let rootRunId = payload["rootRunId"]?.stringValue ?? runId
            runToRoot[runId] = rootRunId
            if runId == rootRunId {
                if recordByRoot[rootRunId] == nil, let pendingID = pendingRootAssignments.first {
                    bind(rootRunId: rootRunId, to: pendingID)
                    removePendingAssignment(pendingID)
                }
                updateStatus(.running, forRunId: runId)
            }
            return
        }

        switch type {
        case "run.started":
            updateStatus(.running, forRunId: runId)
        case "run.completed":
            guard let index = recordIndex(forRunId: runId) else { return }
            runs[index].status = .succeeded
            runs[index].isRequestInFlight = false
            runs[index].interaction = nil
            if let output = payload["output"] { applyOutput(output, to: index) }
        case "run.failed", "replan.required":
            guard let index = recordIndex(forRunId: runId) else { return }
            runs[index].status = payload["code"]?.stringValue == "INTERRUPTED" ? .interrupted : .failed
            runs[index].isRequestInFlight = false
            runs[index].interaction = nil
            runs[index].errorMessage = payload["error"]?.stringValue ?? "The run failed."
        case "run.status_changed":
            handleStatusChange(payload["toStatus"]?.stringValue, runId: runId)
        case "approval.requested":
            guard let index = recordIndex(forRunId: runId) else { return }
            resolvedInteractions.remove(runs[index].id)
            let toolName = payload["toolName"]?.stringValue
            let message = toolName.map { "Allow \($0) to continue?" } ?? "The agent needs approval to continue."
            runs[index].status = .waitingForApproval
            runs[index].interaction = Interaction(
                runId: runId,
                message: message,
                kind: .approval(
                    toolName: toolName,
                    input: payload["input"],
                    assistantContent: payload["assistantContent"]?.stringValue
                )
            )
        case "clarification.requested":
            guard let index = recordIndex(forRunId: runId) else { return }
            resolvedInteractions.remove(runs[index].id)
            runs[index].status = .waitingForClarification
            runs[index].interaction = Interaction(
                runId: runId,
                message: payload["message"]?.stringValue ?? "The agent needs more information to continue.",
                kind: .clarification(suggestedQuestions: payload["suggestedQuestions"]?.stringArray ?? [])
            )
        case "tool.completed":
            captureFiles(from: payload, sourceRunId: runId)
        default:
            break
        }
    }

    private func connectRuntime() async {
        do {
            let workingDirectory = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
            status = "Starting agent runtime…"
            try await client.start(
                workingDirectoryURL: workingDirectory,
                notificationHandler: { [weak self] method, params in
                    await self?.receive(method: method, params: params)
                },
                errorHandler: { [weak self] message in
                    await self?.recordDiagnostic(message)
                },
                terminationHandler: { [weak self] status in
                    await self?.runtimeTerminated(status: status)
                }
            )
            status = "Loading workspace configuration…"
            var fields: [String: JSONValue] = [
                "cwd": .string(workingDirectory.path),
                "approvalMode": .string("manual"),
                "clarificationMode": .string("interactive")
            ]
            if !agentConfigPath.isEmpty { fields["agentConfigPath"] = .string(agentConfigPath) }
            if !settingsConfigPath.isEmpty { fields["settingsConfigPath"] = .string(settingsConfigPath) }
            let result = try await client.initializeRuntime(params: fields)
            applyRuntimeInformation(result, fallbackWorkspace: workingDirectory.path)
            isConnected = true
            status = "Ready"
            appendEvent("Initialized\n\(result.prettyPrinted)")
        } catch {
            await client.shutdown()
            client = RuntimeClient()
            isConnected = false
            status = error.localizedDescription
            appendEvent("Initialization error: \(error.localizedDescription)")
            showConfiguration = true
        }
    }

    private func applyRuntimeInformation(_ result: JSONValue, fallbackWorkspace: String) {
        guard let object = result.objectValue else {
            effectiveWorkspaceRoot = fallbackWorkspace
            return
        }
        let agent = object["agent"]?.objectValue
        agentName = agent?["name"]?.stringValue ?? agent?["id"]?.stringValue ?? "Agent"
        agentId = agent?["id"]?.stringValue ?? ""
        runtimeMode = object["runtimeMode"]?.stringValue ?? ""
        effectiveWorkspaceRoot = object["workspaceRoot"]?.stringValue ?? fallbackWorkspace
        shellCwd = object["shellCwd"]?.stringValue ?? effectiveWorkspaceRoot
        registeredToolNames = object["registeredToolNames"]?.stringArray ?? []
    }

    private func beginAgentRequest(method: String, fields: [String: JSONValue], recordID: UUID) {
        pendingRootAssignments.append(recordID)
        if let index = runs.firstIndex(where: { $0.id == recordID }) { runs[index].status = .running }
        Task {
            do {
                let result = try await client.send(method: method, params: fields, timeoutPolicy: .none)
                acceptResult(result, for: recordID)
            } catch {
                recordRequestFailed(error, for: recordID)
            }
        }
    }

    private func bind(rootRunId: String, to recordID: UUID) {
        recordByRoot[rootRunId] = recordID
        runToRoot[rootRunId] = rootRunId
        guard let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        if !runs[index].runIds.contains(rootRunId) { runs[index].runIds.append(rootRunId) }
    }

    private func recordIndex(forRunId runId: String) -> Int? {
        let rootRunId = runToRoot[runId] ?? runId
        guard let recordID = recordByRoot[rootRunId] else { return nil }
        return runs.firstIndex { $0.id == recordID }
    }

    private func updateStatus(_ status: RunStatus, forRunId runId: String) {
        guard let index = recordIndex(forRunId: runId) else { return }
        runs[index].status = status
    }

    private func handleStatusChange(_ status: String?, runId: String) {
        switch status {
        case "queued": updateStatus(.queued, forRunId: runId)
        case "running": updateStatus(.running, forRunId: runId)
        case "completed", "success", "succeeded": updateStatus(.succeeded, forRunId: runId)
        case "failed": updateStatus(.failed, forRunId: runId)
        case "interrupted": updateStatus(.interrupted, forRunId: runId)
        default: break
        }
    }

    private func acceptInspection(_ result: JSONValue, for recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        runs[index].isRequestInFlight = false
        runs[index].errorMessage = nil
        if runs[index].output == nil {
            runs[index].output = result
        }

        let inspectedRun = result.objectValue?["run"]?.objectValue
        let runId = inspectedRun?["id"]?.stringValue ?? runs[index].latestRunId
        if let runId {
            handleStatusChange(inspectedRun?["status"]?.stringValue, runId: runId)
        }
    }

    private func applyOutput(_ output: JSONValue, to index: Int) {
        runs[index].output = output
        guard runs[index].kind == .chat else { return }
        let content = output.stringValue ?? output.prettyPrinted
        if runs[index].chatMessages.last?.role != .assistant || runs[index].chatMessages.last?.content != content {
            runs[index].chatMessages.append(ChatMessage(role: .assistant, content: content))
        }
    }

    private func captureFiles(from payload: [String: JSONValue], sourceRunId: String) {
        guard payload["skipped"] != .bool(true),
              let toolName = payload["toolName"]?.stringValue,
              let output = payload["output"]?.objectValue,
              let index = recordIndex(forRunId: sourceRunId) else { return }

        switch toolName {
        case "write_file":
            if let path = output["path"]?.stringValue {
                registerFile(path: path, operation: .written, support: false, sourceRunId: sourceRunId, at: index)
            }
            if let path = output["intermediatePath"]?.stringValue {
                registerFile(path: path, operation: .written, support: true, sourceRunId: sourceRunId, at: index)
            }
        case "edit_file":
            guard output["changed"] == .bool(true) else { return }
            if let path = output["path"]?.stringValue {
                registerFile(path: path, operation: .edited, support: false, sourceRunId: sourceRunId, at: index)
            }
            if let path = output["backupPath"]?.stringValue {
                registerFile(path: path, operation: .written, support: true, sourceRunId: sourceRunId, at: index)
            }
        default:
            break
        }
    }

    private func registerFile(
        path: String,
        operation: RunFile.Operation,
        support: Bool,
        sourceRunId: String,
        at index: Int
    ) {
        let rootPath = workspaceRootURL.path
        guard let url = validatedWorkspaceFileURL(path: path, rootPath: rootPath) else { return }
        if let fileIndex = runs[index].files.firstIndex(where: { $0.path == url.path }) {
            runs[index].files[fileIndex].operation = operation
            runs[index].files[fileIndex].isSupportFile = support
            runs[index].files[fileIndex].sourceRunId = sourceRunId
        } else {
            runs[index].files.append(RunFile(
                path: url.path,
                workspaceRoot: rootPath,
                operation: operation,
                isSupportFile: support,
                sourceRunId: sourceRunId
            ))
        }
        runs[index].files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var workspaceRootURL: URL {
        URL(
            fileURLWithPath: effectiveWorkspaceRoot.isEmpty ? workspacePath : effectiveWorkspaceRoot,
            isDirectory: true
        ).standardizedFileURL
    }

    private func validatedWorkspaceFileURL(path: String, rootPath: String) -> URL? {
        guard NSString(string: path).isAbsolutePath else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        let standardizedRoot = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        guard url.path != standardizedRoot, url.path.hasPrefix(standardizedRoot + "/") else { return nil }
        return url
    }

    private func recordRequestFailed(_ error: Error, for recordID: UUID) {
        removePendingAssignment(recordID)
        guard let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        runs[index].isRequestInFlight = false
        runs[index].status = .failed
        runs[index].errorMessage = error.localizedDescription
        appendEvent("Error: \(error.localizedDescription)")
    }

    private func interactionFailed(_ error: Error, for recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }),
              var interaction = runs[index].interaction else { return }
        runs[index].isRequestInFlight = false
        interaction.isResolving = false
        interaction.errorMessage = error.localizedDescription
        runs[index].interaction = interaction
        appendEvent("Interaction error: \(error.localizedDescription)")
    }

    private func removePendingAssignment(_ recordID: UUID) {
        if let index = pendingRootAssignments.firstIndex(of: recordID) {
            pendingRootAssignments.remove(at: index)
        }
    }

    private func title(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 54 ? String(firstLine.prefix(51)) + "…" : firstLine
    }

    private func appendEvent(_ event: String) {
        events.append(event)
        if events.count > 500 { events.removeFirst(events.count - 500) }
    }

    private func recordDiagnostic(_ message: String) {
        appendEvent("Runtime diagnostic: \(message)")
    }

    private func runtimeTerminated(status: Int32) {
        isConnected = false
        self.status = "Runtime exited with status \(status)"
        markActiveRunsInterrupted()
        resetRuntimeMappings()
        client = RuntimeClient()
    }

    private func markActiveRunsInterrupted() {
        for index in runs.indices where runs[index].status.isActive || runs[index].isRequestInFlight {
            runs[index].status = .interrupted
            runs[index].isRequestInFlight = false
        }
    }

    private func resetRuntimeMappings() {
        pendingRootAssignments.removeAll()
        runToRoot.removeAll()
        recordByRoot.removeAll()
        resolvedInteractions.removeAll()
        agentName = ""
        agentId = ""
        runtimeMode = ""
        effectiveWorkspaceRoot = ""
        shellCwd = ""
        registeredToolNames = []
    }

    private func quitAfterShutdown() {
        guard !isQuitting else { return }
        isQuitting = true
        Task {
            await shutdown()
            NSApplication.shared.terminate(nil)
        }
    }
}

private extension JSONValue {
    var stringArray: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }
}
