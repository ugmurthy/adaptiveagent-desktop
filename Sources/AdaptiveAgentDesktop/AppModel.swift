import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let supportedRuntimeModes = ["memory", "postgres"]
    static let supportedProviders = ["openrouter", "ollama", "mistral", "mesh"]
    static let supportedApprovalModes = ["auto", "manual", "reject"]
    static let supportedClarificationModes = ["interactive", "fail"]

    enum RunKind: String, CaseIterable, Identifiable {
        case run = "Run"
        case chat = "Chat"

        var id: Self { self }
        var systemImage: String { self == .run ? "play.fill" : "bubble.left.and.bubble.right.fill" }
    }

    enum RunDetailMode: Equatable {
        case results
        case inspection
    }

    struct RunTab: Identifiable, Equatable {
        let id: UUID
        var selectedRunID: UUID?
        var draftKind: RunKind
        var draftText: String
        var chatMessage: String
        var steerMessage: String
        var scrollPosition: String?
        var detailMode: RunDetailMode

        init(
            id: UUID = UUID(),
            selectedRunID: UUID? = nil,
            draftKind: RunKind = .run,
            draftText: String = "",
            chatMessage: String = "",
            steerMessage: String = "",
            scrollPosition: String? = nil,
            detailMode: RunDetailMode = .results
        ) {
            self.id = id
            self.selectedRunID = selectedRunID
            self.draftKind = draftKind
            self.draftText = draftText
            self.chatMessage = chatMessage
            self.steerMessage = steerMessage
            self.scrollPosition = scrollPosition
            self.detailMode = detailMode
        }
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

    enum AuxiliaryOperation: Hashable {
        case inspect
        case steer
        case interrupt
    }

    struct ChatMessage: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let content: String
    }

    struct RunActivity: Identifiable, Equatable {
        enum Kind: Equatable { case assistant, tool }
        enum ToolState: Equatable { case awaitingApproval, running, succeeded, failed, skipped }

        let id: String
        let kind: Kind
        let sourceRunId: String
        var content: String?
        var toolName: String?
        var detail: String?
        var toolState: ToolState?
        var isFinalAssistantMessage = false
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
        var inspection: JSONValue?
        var errorMessage: String?
        var interaction: Interaction?
        var files: [RunFile] = []
        var chatMessages: [ChatMessage] = []
        var activities: [RunActivity] = []
        var activityStartedAt: Date?
        var activityFinishedAt: Date?
        var isRequestInFlight = false
        var auxiliaryOperations: Set<AuxiliaryOperation> = []
        var auxiliaryErrorMessage: String?

        var latestRunId: String? { runIds.last }
        var hasRequestInFlight: Bool { isRequestInFlight || !auxiliaryOperations.isEmpty }
    }

    private struct InspectionCacheMetadata {
        let runId: String
        let eventGeneration: UInt64
        let fetchedAt: ContinuousClock.Instant
    }

    private static let inspectionMinimumRefreshInterval: Duration = .seconds(5)

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

    @Published var configuredRuntimeMode = ""
    @Published var configuredProvider = ""
    @Published var configuredModel = ""
    @Published var configuredApprovalMode = "manual"
    @Published var configuredClarificationMode = "interactive"
    @Published private(set) var settingsConfigurationError: String?

    @Published var runs: [RunRecord] = []
    @Published private(set) var tabs: [RunTab] = []
    @Published private(set) var selectedTabID: UUID?

    private var client: RuntimeClient
    private var didBootstrap = false
    private var isQuitting = false
    private var pendingRootAssignments: [UUID] = []
    private var runToRoot: [String: String] = [:]
    private var recordByRoot: [String: UUID] = [:]
    private var resolvedInteractions: Set<UUID> = []
    private var loadedSettingsConfigPath: String?
    private var eventGenerationByRunID: [String: UInt64] = [:]
    private var inspectionCacheMetadata: [UUID: InspectionCacheMetadata] = [:]
    private let inspectionClock = ContinuousClock()

    init(
        client: RuntimeClient = RuntimeClient(),
        workingDirectoryURL: URL? = nil
    ) {
        let launchDirectory = (workingDirectoryURL
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL
        let initialTab = RunTab()
        self.client = client
        tabs = [initialTab]
        selectedTabID = initialTab.id
        workspacePath = launchDirectory.path
        let localSettings = launchDirectory.appendingPathComponent("agent.settings.json", isDirectory: false)
        if FileManager.default.isReadableFile(atPath: localSettings.path) {
            settingsConfigPath = localSettings.path
        }
        reloadSettingsConfiguration()
    }

    var selectedTab: RunTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    var selectedRunItemID: UUID? { selectedTab?.selectedRunID }

    var selectedRun: RunRecord? {
        guard let selectedRunItemID else { return nil }
        return runs.first { $0.id == selectedRunItemID }
    }

    var hasActiveWork: Bool {
        runs.contains { $0.status.isActive || $0.hasRequestInFlight }
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
        let settingsPath = settingsConfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if loadedSettingsConfigPath != settingsPath {
            reloadSettingsConfiguration()
        }
        guard settingsConfigurationError == nil else {
            showConfiguration = true
            return
        }
        showConfiguration = false
        guard !isBusy else { return }
        isBusy = true
        Task {
            if isConnected {
                status = "Restarting runtime…"
                await client.shutdown()
                client = RuntimeClient()
            }
            markActiveRunsInterrupted()
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
        reloadSettingsConfiguration()
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
        reloadSettingsConfiguration()
    }

    func reloadSettingsConfiguration() {
        configuredRuntimeMode = ""
        configuredProvider = ""
        configuredModel = ""
        configuredApprovalMode = "manual"
        configuredClarificationMode = "interactive"
        settingsConfigurationError = nil

        let path = settingsConfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        loadedSettingsConfigPath = path
        guard !path.isEmpty else { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let settings = try JSONDecoder().decode(DesktopSettingsSeed.self, from: data)
            var unsupportedValues: [String] = []

            if let mode = settings.runtime?.mode {
                if Self.supportedRuntimeModes.contains(mode) {
                    configuredRuntimeMode = mode
                } else {
                    unsupportedValues.append("runtime.mode \(mode)")
                }
            }

            if let provider = settings.model?.overrideProvider {
                if Self.supportedProviders.contains(provider) {
                    configuredProvider = provider
                } else {
                    unsupportedValues.append("model.overrideProvider \(provider)")
                }
            }
            configuredModel = settings.model?.overrideModel ?? ""

            if let approvalMode = settings.interaction?.approvalMode {
                if Self.supportedApprovalModes.contains(approvalMode) {
                    configuredApprovalMode = approvalMode
                } else {
                    unsupportedValues.append("interaction.approvalMode \(approvalMode)")
                }
            } else if let autoApprove = settings.interaction?.autoApprove {
                configuredApprovalMode = autoApprove ? "auto" : "manual"
            }

            if let clarificationMode = settings.interaction?.clarificationMode {
                if Self.supportedClarificationModes.contains(clarificationMode) {
                    configuredClarificationMode = clarificationMode
                } else {
                    unsupportedValues.append("interaction.clarificationMode \(clarificationMode)")
                }
            } else if let interactive = settings.interaction?.interactive {
                configuredClarificationMode = interactive ? "interactive" : "fail"
            }

            if !unsupportedValues.isEmpty {
                settingsConfigurationError = "Unsupported settings value: \(unsupportedValues.joined(separator: ", "))."
            }
        } catch {
            settingsConfigurationError = "Could not load settings values: \(error.localizedDescription)"
        }
    }

    func tab(withID tabID: UUID) -> RunTab? {
        tabs.first { $0.id == tabID }
    }

    func selectTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
    }

    func closeTab(_ tabID: UUID) {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let wasSelected = selectedTabID == tabID
        tabs.remove(at: closingIndex)

        if tabs.isEmpty {
            let replacement = RunTab()
            tabs = [replacement]
            selectedTabID = replacement.id
        } else if wasSelected {
            selectedTabID = tabs[min(closingIndex, tabs.count - 1)].id
        }
    }

    func openRunTab(_ recordID: UUID) {
        guard let record = runs.first(where: { $0.id == recordID }) else { return }
        if let existing = tabs.first(where: { $0.selectedRunID == recordID }) {
            selectedTabID = existing.id
            return
        }

        if let index = selectedTabIndex, isReusableDraft(tabs[index]) {
            tabs[index].selectedRunID = recordID
            tabs[index].draftKind = record.kind
            tabs[index].scrollPosition = nil
            return
        }

        let tab = RunTab(selectedRunID: recordID, draftKind: record.kind)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func newRun() {
        openDraftTab(kind: .run)
    }

    func newChat() {
        openDraftTab(kind: .chat)
    }

    func setDraftKind(_ kind: RunKind, forTab tabID: UUID) {
        updateTab(tabID) { $0.draftKind = kind }
    }

    func setDraftText(_ text: String, forTab tabID: UUID) {
        updateTab(tabID) { $0.draftText = text }
    }

    func setChatMessage(_ message: String, forTab tabID: UUID) {
        updateTab(tabID) { $0.chatMessage = message }
    }

    func setSteerMessage(_ message: String, forTab tabID: UUID) {
        updateTab(tabID) { $0.steerMessage = message }
    }

    func setScrollPosition(_ position: String?, forTab tabID: UUID) {
        updateTab(tabID) { $0.scrollPosition = position }
    }

    func setDetailMode(_ mode: RunDetailMode, forTab tabID: UUID) {
        updateTab(tabID) {
            $0.detailMode = mode
            $0.scrollPosition = nil
        }
    }

    private var selectedTabIndex: Int? {
        guard let selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == selectedTabID }
    }

    private func openDraftTab(kind: RunKind) {
        let tab = RunTab(draftKind: kind)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    private func isReusableDraft(_ tab: RunTab) -> Bool {
        tab.selectedRunID == nil
            && tab.draftText.isEmpty
            && tab.chatMessage.isEmpty
            && tab.steerMessage.isEmpty
    }

    private func updateTab(_ tabID: UUID, _ update: (inout RunTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        update(&tabs[index])
    }

    func submitDraft(in tabID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID && $0.selectedRunID == nil }) else { return }
        let kind = tabs[tabIndex].draftKind
        let text = tabs[tabIndex].draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !text.isEmpty, !isWaitingForRunIdentity else { return }

        let recordID = UUID()
        let sessionId = kind == .chat ? UUID().uuidString : nil
        var record = RunRecord(
            id: recordID,
            kind: kind,
            title: title(for: text),
            sessionId: sessionId,
            status: .queued,
            isRequestInFlight: true
        )
        if kind == .chat {
            record.chatMessages.append(ChatMessage(role: .user, content: text))
        }
        runs.insert(record, at: 0)
        tabs[tabIndex].selectedRunID = recordID
        tabs[tabIndex].draftText = ""
        tabs[tabIndex].scrollPosition = nil

        let method = kind == .run ? "agent/run" : "agent/chat"
        var fields: [String: JSONValue] = [kind == .run ? "goal" : "message": .string(text)]
        if let sessionId { fields["sessionId"] = .string(sessionId) }
        beginAgentRequest(method: method, fields: fields, recordID: recordID)
    }

    func sendChatMessage(in tabID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let recordID = tabs[tabIndex].selectedRunID else { return }
        let text = tabs[tabIndex].chatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = runs.firstIndex(where: { $0.id == recordID }),
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
        tabs[tabIndex].chatMessage = ""
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
                acceptApprovalResolution(result, approved: approved, for: recordID)
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

    func steerRun(in tabID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let recordID = tabs[tabIndex].selectedRunID else { return }
        let message = tabs[tabIndex].steerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = runs.firstIndex(where: { $0.id == recordID }),
              let runId = runs[index].latestRunId,
              !runs[index].auxiliaryOperations.contains(.steer),
              !message.isEmpty else { return }
        tabs[tabIndex].steerMessage = ""
        runs[index].auxiliaryOperations.insert(.steer)
        runs[index].auxiliaryErrorMessage = nil
        Task {
            do {
                let result = try await client.send(
                    method: "run/steer",
                    params: ["runId": .string(runId), "message": .string(message)],
                    timeoutPolicy: .none
                )
                acceptSteeringResult(result, for: recordID)
            } catch {
                auxiliaryRequestFailed(error, operation: .steer, for: recordID)
            }
        }
    }

    func runCommand(_ method: String, runId value: String) {
        let runId = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !runId.isEmpty else { return }

        if let record = runs.first(where: { $0.runIds.contains(runId) }) {
            openRunTab(record.id)
            if method == "run/inspect" { showInspection(for: record.id) }
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
        openRunTab(recordID)
        if method == "run/inspect" { showInspection(for: recordID) }
        sendRunCommand(method, runId: runId, recordID: recordID)
    }

    func runCommand(_ method: String, for recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }),
              let runId = runs[index].latestRunId else { return }
        if method == "run/inspect" { showInspection(for: recordID) }
        sendRunCommand(method, runId: runId, recordID: recordID)
    }

    private func showInspection(for recordID: UUID) {
        guard let tabID = tabs.first(where: { $0.selectedRunID == recordID })?.id else { return }
        setDetailMode(.inspection, forTab: tabID)
    }

    private func sendRunCommand(_ method: String, runId: String, recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        if method == "run/inspect", canReuseInspection(for: recordID, runId: runId, at: index) {
            runs[index].auxiliaryErrorMessage = nil
            return
        }
        let longRunning = ["run/resume", "run/retry", "run/recover", "run/continue"].contains(method)
        let mayCreateRun = ["run/recover", "run/continue"].contains(method)
        let auxiliaryOperation: AuxiliaryOperation? = switch method {
        case "run/inspect": .inspect
        case "run/interrupt": .interrupt
        default: nil
        }
        guard !mayCreateRun || !isWaitingForRunIdentity else { return }
        if let auxiliaryOperation {
            guard !runs[index].auxiliaryOperations.contains(auxiliaryOperation) else { return }
            if method != "run/inspect" {
                inspectionCacheMetadata.removeValue(forKey: recordID)
            }
            runs[index].auxiliaryOperations.insert(auxiliaryOperation)
            runs[index].auxiliaryErrorMessage = nil
        } else {
            guard !runs[index].isRequestInFlight else { return }
            inspectionCacheMetadata.removeValue(forKey: recordID)
            runs[index].isRequestInFlight = true
            runs[index].errorMessage = nil
            if longRunning {
                runs[index].status = .running
                beginActivityTimer(at: index)
            }
            if mayCreateRun {
                pendingRootAssignments.append(recordID)
            }
        }
        let inspectionEventGeneration = method == "run/inspect" ? eventGenerationByRunID[runId, default: 0] : nil
        Task {
            do {
                let result = try await client.send(
                    method: method,
                    params: ["runId": .string(runId)],
                    timeoutPolicy: longRunning ? .none : .standard
                )
                try acceptRunCommandResult(
                    result,
                    method: method,
                    for: recordID,
                    requestedRunId: runId,
                    inspectionEventGeneration: inspectionEventGeneration
                )
            } catch {
                if let auxiliaryOperation {
                    auxiliaryRequestFailed(error, operation: auxiliaryOperation, for: recordID)
                } else {
                    recordRequestFailed(error, for: recordID)
                }
            }
        }
    }

    private func canReuseInspection(for recordID: UUID, runId: String, at index: Int) -> Bool {
        guard runs[index].inspection != nil,
              let metadata = inspectionCacheMetadata[recordID],
              metadata.runId == runId else { return false }
        let hasNotChanged = eventGenerationByRunID[runId, default: 0] == metadata.eventGeneration
        let isWithinRefreshInterval = inspectionClock.now
            < metadata.fetchedAt.advanced(by: Self.inspectionMinimumRefreshInterval)
        let isTerminal = !runs[index].status.isActive && runs[index].status != .unknown
        return isWithinRefreshInterval || (hasNotChanged && isTerminal)
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
            finishActivityTimer(at: index)
            runs[index].interaction = nil
            runs[index].errorMessage = nil
            if let output = object["output"] {
                applyOutput(output, to: index)
            }
        case "failure":
            resolvedInteractions.remove(recordID)
            runs[index].status = object["code"]?.stringValue == "INTERRUPTED" ? .interrupted : .failed
            finishActivityTimer(at: index)
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

    // Internal for focused protocol result tests.
    func acceptApprovalResolution(_ result: JSONValue, approved: Bool, for recordID: UUID) {
        guard !approved else {
            acceptResult(result, for: recordID)
            return
        }

        appendEvent("Approval resolution\n\(result.prettyPrinted)")
        guard let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        runs[index].isRequestInFlight = false
        runs[index].interaction = nil
        resolvedInteractions.remove(recordID)

        guard let run = result.objectValue?["run"]?.objectValue,
              let status = runtimeStatus(run["status"]?.stringValue) else {
            recordRequestFailed(
                RuntimeClientError.protocolViolation("approval rejection response is missing run status"),
                for: recordID
            )
            return
        }
        runs[index].status = status
        if status == .failed {
            finishActivityTimer(at: index)
            runs[index].errorMessage = run["errorMessage"]?.stringValue
                ?? run["error"]?.stringValue
                ?? "Approval was rejected."
        }
    }

    // Internal for focused protocol result tests.
    func acceptRunCommandResult(
        _ result: JSONValue,
        method: String,
        for recordID: UUID,
        requestedRunId: String? = nil,
        inspectionEventGeneration: UInt64? = nil
    ) throws {
        let diagnostic = method == "run/inspect"
            ? Self.inspectionDiagnostic(result)
            : Self.protocolDiagnostic(result)
        appendEvent("\(method) response\n\(diagnostic)")
        switch method {
        case "run/inspect":
            finishAuxiliaryOperation(.inspect, for: recordID)
            acceptInspection(
                result,
                for: recordID,
                requestedRunId: requestedRunId,
                eventGeneration: inspectionEventGeneration
            )
        case "run/interrupt":
            finishAuxiliaryOperation(.interrupt, for: recordID)
            if let index = runs.firstIndex(where: { $0.id == recordID }), runs[index].status.isActive {
                runs[index].status = .interrupted
                finishActivityTimer(at: index)
            }
        case "run/recover":
            guard let recoveredResult = result.objectValue?["result"] else {
                throw RuntimeClientError.protocolViolation("run/recover response is missing its nested result")
            }
            acceptResult(recoveredResult, for: recordID)
        default:
            acceptResult(result, for: recordID)
        }
    }

    // Internal for focused protocol result tests.
    func acceptSteeringResult(_ result: JSONValue, for recordID: UUID) {
        appendEvent("run/steer response\n\(result.prettyPrinted)")
        finishAuxiliaryOperation(.steer, for: recordID)
    }

    // Internal for focused event/result tests.
    func receive(method: String, params: JSONValue, diagnostic: String? = nil) {
        appendEvent("\(method)\n\(diagnostic ?? Self.protocolDiagnostic(params))")
        guard method == "agent/event",
              let event = params.objectValue,
              let type = event["type"]?.stringValue,
              let runId = event["runId"]?.stringValue else { return }
        eventGenerationByRunID[runId, default: 0] &+= 1
        let payload = event["payload"]?.objectValue ?? [:]

        if type == "delegate.spawned",
           let childRunId = payload["childRunId"]?.stringValue,
           let rootRunId = payload["rootRunId"]?.stringValue {
            if let index = recordIndex(forRunId: runId) {
                captureProgressActivity(
                    event: event,
                    type: type,
                    payload: payload,
                    sourceRunId: runId,
                    isRootEvent: false,
                    at: index
                )
            }
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
                if let index = recordIndex(forRunId: runId) { beginActivityTimer(at: index) }
            }
            return
        }

        let rootRunId = payload["rootRunId"]?.stringValue ?? runToRoot[runId] ?? runId
        let isRootEvent = rootRunId == runId
        if let index = recordIndex(forRunId: runId) {
            captureProgressActivity(
                event: event,
                type: type,
                payload: payload,
                sourceRunId: runId,
                isRootEvent: isRootEvent,
                at: index
            )
        }
        switch type {
        case "run.started":
            guard isRootEvent else { return }
            updateStatus(.running, forRunId: runId)
            if let index = recordIndex(forRunId: runId) { beginActivityTimer(at: index) }
        case "run.completed":
            guard isRootEvent, let index = recordIndex(forRunId: runId) else { return }
            runs[index].status = .succeeded
            finishActivityTimer(at: index)
            runs[index].isRequestInFlight = false
            runs[index].interaction = nil
            if let output = payload["output"] { applyOutput(output, to: index) }
        case "run.failed", "replan.required":
            guard isRootEvent, let index = recordIndex(forRunId: runId) else { return }
            runs[index].status = payload["code"]?.stringValue == "INTERRUPTED" ? .interrupted : .failed
            finishActivityTimer(at: index)
            runs[index].isRequestInFlight = false
            runs[index].interaction = nil
            runs[index].errorMessage = payload["error"]?.stringValue ?? "The run failed."
        case "run.status_changed":
            guard isRootEvent else { return }
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
                    let diagnostic = AppModel.protocolDiagnostic(params)
                    await self?.receive(method: method, params: params, diagnostic: diagnostic)
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
                "approvalMode": .string(configuredApprovalMode),
                "clarificationMode": .string(configuredClarificationMode)
            ]
            if !agentConfigPath.isEmpty { fields["agentConfigPath"] = .string(agentConfigPath) }
            if !settingsConfigPath.isEmpty { fields["settingsConfigPath"] = .string(settingsConfigPath) }
            if !configuredRuntimeMode.isEmpty { fields["runtimeMode"] = .string(configuredRuntimeMode) }
            if !configuredProvider.isEmpty { fields["provider"] = .string(configuredProvider) }
            if !configuredModel.isEmpty { fields["model"] = .string(configuredModel) }
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
        if let index = runs.firstIndex(where: { $0.id == recordID }) {
            runs[index].status = .running
            beginActivityTimer(at: index)
        }
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
        guard let status = runtimeStatus(status), let index = recordIndex(forRunId: runId) else { return }
        runs[index].status = status
        if status == .running {
            beginActivityTimer(at: index)
        } else if !status.isActive {
            finishActivityTimer(at: index)
        }
    }

    private func runtimeStatus(_ status: String?) -> RunStatus? {
        switch status {
        case "queued": .queued
        case "running": .running
        case "completed", "success", "succeeded": .succeeded
        case "failed": .failed
        case "interrupted": .interrupted
        default: nil
        }
    }

    private func acceptInspection(
        _ result: JSONValue,
        for recordID: UUID,
        requestedRunId: String?,
        eventGeneration: UInt64?
    ) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        runs[index].inspection = result
        let inspectedRun = result.objectValue?["run"]?.objectValue
        let runId = inspectedRun?["id"]?.stringValue ?? requestedRunId ?? runs[index].latestRunId

        if case .array(let events)? = result.objectValue?["events"] {
            for case .object(let event) in events {
                guard let type = event["type"]?.stringValue,
                      let sourceRunId = event["runId"]?.stringValue else { continue }
                captureProgressActivity(
                    event: event,
                    type: type,
                    payload: event["payload"]?.objectValue ?? [:],
                    sourceRunId: sourceRunId,
                    isRootEvent: sourceRunId == runId,
                    at: index
                )
            }
        }

        if let runId {
            inspectionCacheMetadata[recordID] = InspectionCacheMetadata(
                runId: runId,
                eventGeneration: eventGeneration ?? eventGenerationByRunID[runId, default: 0],
                fetchedAt: inspectionClock.now
            )
            handleStatusChange(inspectedRun?["status"]?.stringValue, runId: runId)
        }
    }

    private func applyOutput(_ output: JSONValue, to index: Int) {
        runs[index].output = output
        if runs[index].kind == .run, let content = output.stringValue {
            appendAssistantActivity(
                content: content,
                id: "assistant:\(runs[index].latestRunId ?? runs[index].id.uuidString):final",
                sourceRunId: runs[index].latestRunId ?? "",
                isFinal: true,
                at: index
            )
            return
        }
        guard runs[index].kind == .chat else { return }
        let content = output.stringValue ?? output.prettyPrinted
        if runs[index].chatMessages.last?.role != .assistant || runs[index].chatMessages.last?.content != content {
            runs[index].chatMessages.append(ChatMessage(role: .assistant, content: content))
        }
    }

    private func captureProgressActivity(
        event: [String: JSONValue],
        type: String,
        payload: [String: JSONValue],
        sourceRunId: String,
        isRootEvent: Bool,
        at index: Int
    ) {
        if let content = payload["assistantContent"]?.stringValue {
            let stepKey = event["stepId"]?.stringValue
                ?? event["id"]?.stringValue
                ?? content
            appendAssistantActivity(
                content: content,
                id: "assistant:\(sourceRunId):\(stepKey)",
                sourceRunId: sourceRunId,
                isFinal: false,
                at: index
            )
        }

        if type == "run.completed",
           isRootEvent,
           runs[index].kind == .run,
           let content = payload["output"]?.stringValue {
            appendAssistantActivity(
                content: content,
                id: "assistant:\(sourceRunId):final",
                sourceRunId: sourceRunId,
                isFinal: true,
                at: index
            )
        }

        guard ["approval.requested", "tool.started", "tool.completed", "tool.failed"].contains(type),
              let toolName = payload["toolName"]?.stringValue else { return }
        let correlationID = event["toolCallId"]?.stringValue
            ?? [sourceRunId, event["stepId"]?.stringValue ?? "step", toolName].joined(separator: ":")
        let id = "tool:\(correlationID)"
        let state: RunActivity.ToolState = switch type {
        case "approval.requested": .awaitingApproval
        case "tool.started": .running
        case "tool.completed": payload["skipped"] == .bool(true) ? .skipped : .succeeded
        default: .failed
        }
        let detail = Self.compactToolDetail(toolName: toolName, input: payload["input"]?.objectValue)

        if let activityIndex = runs[index].activities.firstIndex(where: { $0.id == id }) {
            runs[index].activities[activityIndex].toolName = toolName
            runs[index].activities[activityIndex].toolState = state
            if let detail { runs[index].activities[activityIndex].detail = detail }
        } else {
            appendActivity(RunActivity(
                id: id,
                kind: .tool,
                sourceRunId: sourceRunId,
                toolName: toolName,
                detail: detail,
                toolState: state
            ), at: index)
        }
    }

    private func appendAssistantActivity(
        content: String,
        id: String,
        sourceRunId: String,
        isFinal: Bool,
        at index: Int
    ) {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        if let activityIndex = runs[index].activities.firstIndex(where: { $0.id == id }) {
            runs[index].activities[activityIndex].content = content
            runs[index].activities[activityIndex].isFinalAssistantMessage = isFinal
            return
        }
        if let activityIndex = runs[index].activities.firstIndex(where: {
            $0.kind == .assistant && $0.sourceRunId == sourceRunId && $0.content == content
        }) {
            if isFinal { runs[index].activities[activityIndex].isFinalAssistantMessage = true }
            return
        }
        appendActivity(RunActivity(
            id: id,
            kind: .assistant,
            sourceRunId: sourceRunId,
            content: content,
            isFinalAssistantMessage: isFinal
        ), at: index)
    }

    private func appendActivity(_ activity: RunActivity, at index: Int) {
        runs[index].activities.append(activity)
        if runs[index].activities.count > 250 {
            runs[index].activities.removeFirst(runs[index].activities.count - 250)
        }
    }

    private nonisolated static func compactToolDetail(
        toolName: String,
        input: [String: JSONValue]?
    ) -> String? {
        guard let input else { return nil }
        let rawDetail: String?
        switch toolName {
        case "web_search":
            rawDetail = input["query"]?.stringValue
        case "read_web_page", "fetch_page":
            if let urlText = input["url"]?.stringValue,
               let host = URL(string: urlText)?.host {
                rawDetail = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            } else {
                rawDetail = input["url"]?.stringValue
            }
        case "read_file", "write_file", "edit_file":
            rawDetail = input["path"]?.stringValue.map { URL(fileURLWithPath: $0).lastPathComponent }
        case "shell_exec":
            rawDetail = input["command"]?.stringValue
        default:
            if toolName.localizedCaseInsensitiveContains("file"),
               let path = input["path"]?.stringValue {
                rawDetail = URL(fileURLWithPath: path).lastPathComponent
            } else {
                rawDetail = ["query", "url", "path", "command", "name"]
                    .compactMap { input[$0]?.stringValue }
                    .first
            }
        }
        guard let rawDetail else { return nil }
        let detail = rawDetail
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !detail.isEmpty else { return nil }
        return detail.count > 96 ? String(detail.prefix(93)) + "…" : detail
    }

    private func beginActivityTimer(at index: Int) {
        guard runs.indices.contains(index) else { return }
        if runs[index].activityStartedAt == nil || runs[index].activityFinishedAt != nil {
            runs[index].activityStartedAt = Date()
            runs[index].activityFinishedAt = nil
        }
    }

    private func finishActivityTimer(at index: Int) {
        guard runs.indices.contains(index),
              runs[index].activityStartedAt != nil,
              runs[index].activityFinishedAt == nil else { return }
        runs[index].activityFinishedAt = Date()
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
        finishActivityTimer(at: index)
        runs[index].errorMessage = error.localizedDescription
        appendEvent("Error: \(error.localizedDescription)")
    }

    // Internal for focused auxiliary-command lifecycle tests.
    func auxiliaryRequestFailed(_ error: Error, operation: AuxiliaryOperation, for recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        runs[index].auxiliaryOperations.remove(operation)
        runs[index].auxiliaryErrorMessage = error.localizedDescription
        appendEvent("Auxiliary command error: \(error.localizedDescription)")
    }

    private func finishAuxiliaryOperation(_ operation: AuxiliaryOperation, for recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        runs[index].auxiliaryOperations.remove(operation)
        runs[index].auxiliaryErrorMessage = nil
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

    private nonisolated static func protocolDiagnostic(_ value: JSONValue) -> String {
        let maximumBytes = 64 * 1024
        guard let data = try? JSONEncoder().encode(value) else { return String(describing: value) }
        guard data.count > maximumBytes else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: data.prefix(maximumBytes), as: UTF8.self) + "\n… diagnostic truncated"
    }

    private nonisolated static func inspectionDiagnostic(_ result: JSONValue) -> String {
        guard let object = result.objectValue else { return protocolDiagnostic(result) }
        let run = object["run"]?.objectValue
        let eventCount: Int
        if case .array(let events)? = object["events"] {
            eventCount = events.count
        } else {
            eventCount = 0
        }
        return [
            "runId: \(run?["id"]?.stringValue ?? "unknown")",
            "status: \(run?["status"]?.stringValue ?? "unknown")",
            "version: \(run?["version"]?.numberDescription ?? "unknown")",
            "events: \(eventCount)"
        ].joined(separator: "\n")
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
        for index in runs.indices {
            if runs[index].status.isActive || runs[index].isRequestInFlight {
                runs[index].status = .interrupted
                finishActivityTimer(at: index)
            }
            runs[index].isRequestInFlight = false
            runs[index].auxiliaryOperations.removeAll()
        }
    }

    private func resetRuntimeMappings() {
        pendingRootAssignments.removeAll()
        runToRoot.removeAll()
        recordByRoot.removeAll()
        resolvedInteractions.removeAll()
        eventGenerationByRunID.removeAll()
        inspectionCacheMetadata.removeAll()
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

private struct DesktopSettingsSeed: Decodable {
    struct Runtime: Decodable {
        let mode: String?
    }

    struct Model: Decodable {
        let overrideProvider: String?
        let overrideModel: String?
    }

    struct Interaction: Decodable {
        let autoApprove: Bool?
        let approvalMode: String?
        let interactive: Bool?
        let clarificationMode: String?
    }

    let runtime: Runtime?
    let model: Model?
    let interaction: Interaction?
}

private extension JSONValue {
    var stringArray: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    var numberDescription: String? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value).map(String.init) ?? String(value)
    }
}
