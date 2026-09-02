import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let supportedRuntimeModes = ["memory", "sqlite", "postgres"]
    static let supportedProviders = ["openrouter", "ollama", "mistral", "mesh"]
    static let supportedApprovalModes = ["auto", "manual", "reject"]
    static let supportedClarificationModes = ["interactive", "fail"]
    static let supportedInferenceModes = ["gateway", "local", "byok"]
    static let supportedInferenceTiers = ["low", "medium", "high", "xtra-high"]

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
        var selectedHistoryRunID: String?
        var draftKind: RunKind
        var draftText: String
        var draftAttachments: [AttachmentDescriptor]
        var attachmentErrorMessage: String?
        var isImportingAttachments: Bool
        var isSubmittingDraft: Bool
        var chatMessage: String
        var pendingChatMessage: String?
        var steerMessage: String
        var scrollPosition: String?
        var detailMode: RunDetailMode
        var activityExpanded: Bool
        var followLive: Bool

        init(
            id: UUID = UUID(),
            selectedRunID: UUID? = nil,
            selectedHistoryRunID: String? = nil,
            draftKind: RunKind = .run,
            draftText: String = "",
            draftAttachments: [AttachmentDescriptor] = [],
            attachmentErrorMessage: String? = nil,
            isImportingAttachments: Bool = false,
            isSubmittingDraft: Bool = false,
            chatMessage: String = "",
            pendingChatMessage: String? = nil,
            steerMessage: String = "",
            scrollPosition: String? = nil,
            detailMode: RunDetailMode = .results,
            activityExpanded: Bool = false,
            followLive: Bool = true
        ) {
            self.id = id
            self.selectedRunID = selectedRunID
            self.selectedHistoryRunID = selectedHistoryRunID
            self.draftKind = draftKind
            self.draftText = draftText
            self.draftAttachments = draftAttachments
            self.attachmentErrorMessage = attachmentErrorMessage
            self.isImportingAttachments = isImportingAttachments
            self.isSubmittingDraft = isSubmittingDraft
            self.chatMessage = chatMessage
            self.pendingChatMessage = pendingChatMessage
            self.steerMessage = steerMessage
            self.scrollPosition = scrollPosition
            self.detailMode = detailMode
            self.activityExpanded = activityExpanded
            self.followLive = followLive
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
        enum Role: String { case user, assistant }
        let id = UUID()
        let role: Role
        let content: String

        var protocolValue: JSONValue {
            .object([
                "role": .string(role.rawValue),
                "content": .string(content)
            ])
        }
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
        var approvalId: String? = nil
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

    struct SubmittedAttachment: Identifiable, Equatable {
        let id: String
        let name: String
        let sizeBytes: Int64
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
        var attachments: [SubmittedAttachment] = []
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

    struct HistoryItem: Identifiable, Equatable {
        let rootRunId: String
        let sessionId: String?
        let title: String
        let status: String
        let startedAt: String
        let completedAt: String?
        let type: String

        var id: String { rootRunId }
    }

    enum HistoryLoadState: Equatable {
        case unavailable(String)
        case loading
        case loaded
        case failed(String)
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
    @Published private(set) var runtimeInfoSnapshot: RuntimeInfo?
    @Published private(set) var runtimeInfoError: String?
    @Published private(set) var isRefreshingRuntimeInfo = false
    @Published private(set) var attachmentCapabilities: AttachmentCapabilities?
    @Published private(set) var localAttachmentStoreError: String?

    @Published var configuredRuntimeMode = ""
    @Published var configuredProvider = ""
    @Published var configuredModel = ""
    @Published var configuredInferenceMode = ""
    @Published var configuredInferenceTier = ""
    @Published var configuredGatewayURL = ""
    @Published var configuredRequireRunPermit = false
    @Published var configuredApprovalMode = "manual"
    @Published var configuredClarificationMode = "interactive"
    @Published private(set) var settingsConfigurationError: String?
    @Published var accessTokenDraft = ""
    @Published private(set) var accessTokenMessage: String?
    @Published private(set) var accessTokenUpdateFailed = false
    @Published private(set) var isUpdatingAccessToken = false

    @Published var runs: [RunRecord] = []
    @Published private(set) var tabs: [RunTab] = []
    @Published private(set) var selectedTabID: UUID?
    @Published private(set) var historyItems: [HistoryItem] = []
    @Published private(set) var historyReports: [String: TraceReport] = [:]
    @Published private(set) var historyReportErrors: [String: String] = [:]
    @Published private(set) var loadingHistoryRunID: String?
    @Published private(set) var historyState: HistoryLoadState = .unavailable("Connect to load history")
    @Published private(set) var historySearchResults: [HistoryItem] = []
    @Published private(set) var isSearchingHistory = false
    @Published private(set) var historySearchError: String?
    @Published var historySearchQuery = ""

    private var client: RuntimeClient
    private var traceClient: TraceSessionClient
    private var attachmentStore: AttachmentStore?
    private let attachmentStoreRootURL: URL?
    private var attachmentStoreDidClean = false
    private var didBootstrap = false
    private var isQuitting = false
    private var pendingRootAssignments: [UUID] = []
    private var runToRoot: [String: String] = [:]
    private var recordByRoot: [String: UUID] = [:]
    private var resolvedInteractions: Set<UUID> = []
    private var loadedSettingsConfigPath: String?
    private var eventGenerationByRunID: [String: UInt64] = [:]
    private var inspectionCacheMetadata: [UUID: InspectionCacheMetadata] = [:]
    private var historySearchTask: Task<Void, Never>?
    private var historyRefreshTask: Task<Void, Never>?
    private var traceConnected = false
    private let inspectionClock = ContinuousClock()

    init(
        client: RuntimeClient = RuntimeClient(),
        traceClient: TraceSessionClient = TraceSessionClient(),
        workingDirectoryURL: URL? = nil,
        attachmentStoreRootURL: URL? = nil
    ) {
        let launchDirectory = (workingDirectoryURL
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL
        let initialTab = RunTab()
        self.client = client
        self.traceClient = traceClient
        self.attachmentStoreRootURL = attachmentStoreRootURL
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

    var selectedHistoryRunID: String? { selectedTab?.selectedHistoryRunID }

    var selectedRun: RunRecord? {
        guard let selectedRunItemID else { return nil }
        return runs.first { $0.id == selectedRunItemID }
    }

    var hasActiveWork: Bool {
        runs.contains { $0.status.isActive || $0.hasRequestInFlight }
    }

    var isWaitingForRunIdentity: Bool { !pendingRootAssignments.isEmpty }

    var attachmentsEnabled: Bool {
        isConnected
            && attachmentStore != nil
            && attachmentCapabilities?.enabled == true
            && attachmentCapabilities?.acceptedKinds.contains("file") == true
    }

    var attachmentUnavailableReason: String? {
        if let localAttachmentStoreError { return localAttachmentStoreError }
        guard isConnected else { return "Connect to the runtime to attach files." }
        guard let attachmentCapabilities else { return "This runtime does not report file attachment support." }
        guard attachmentCapabilities.enabled else {
            return attachmentCapabilities.reason ?? "File attachments are disabled by the runtime."
        }
        guard attachmentCapabilities.acceptedKinds.contains("file") else {
            return "This runtime does not accept generic file attachments."
        }
        return nil
    }

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
        guard !isBusy else { return }
        isBusy = true
        Task {
            if isConnected {
                status = "Restarting runtime…"
                await stopTraceHistory()
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

    func selectInferenceMode(_ mode: String) {
        configuredInferenceMode = mode
        if mode == "local" || mode == "byok" {
            configuredRequireRunPermit = false
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
        configuredInferenceMode = ""
        configuredInferenceTier = ""
        configuredGatewayURL = ""
        configuredRequireRunPermit = false
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

            if let inferenceMode = settings.inference?.mode {
                if Self.supportedInferenceModes.contains(inferenceMode) {
                    configuredInferenceMode = inferenceMode
                } else {
                    unsupportedValues.append("inference.mode \(inferenceMode)")
                }
            }
            if let inferenceTier = settings.inference?.tier {
                if Self.supportedInferenceTiers.contains(inferenceTier) {
                    configuredInferenceTier = inferenceTier
                } else {
                    unsupportedValues.append("inference.tier \(inferenceTier)")
                }
            }
            configuredGatewayURL = settings.gateway?.url ?? ""
            configuredRequireRunPermit = settings.gateway?.requireRunPermit ?? false

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
        let abandonedAttachments = tabs[closingIndex].selectedRunID == nil
            ? tabs[closingIndex].draftAttachments
            : []
        let wasSelected = selectedTabID == tabID
        tabs.remove(at: closingIndex)

        if let attachmentStore, !abandonedAttachments.isEmpty {
            Task {
                for descriptor in abandonedAttachments { try? await attachmentStore.removeDraft(descriptor) }
            }
        }

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
            tabs[index].selectedHistoryRunID = nil
            tabs[index].draftKind = record.kind
            tabs[index].scrollPosition = nil
            tabs[index].activityExpanded = false
            tabs[index].followLive = record.status.isActive
            return
        }

        let tab = RunTab(selectedRunID: recordID, draftKind: record.kind)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openHistoryTab(_ rootRunId: String) {
        guard let selectedItem = historyItem(rootRunId: rootRunId) else { return }
        if !historyItems.contains(where: { $0.rootRunId == rootRunId }) {
            historyItems = mergeHistory(historyItems, [selectedItem])
        }
        if let existing = tabs.first(where: { $0.selectedHistoryRunID == rootRunId }) {
            selectedTabID = existing.id
        } else if let index = selectedTabIndex, isReusableDraft(tabs[index]) {
            tabs[index].selectedRunID = nil
            tabs[index].selectedHistoryRunID = rootRunId
            tabs[index].scrollPosition = nil
            tabs[index].activityExpanded = false
            tabs[index].followLive = false
        } else {
            let tab = RunTab(selectedHistoryRunID: rootRunId, followLive: false)
            tabs.append(tab)
            selectedTabID = tab.id
        }
        loadHistoryReport(rootRunId)
    }

    func historyItem(rootRunId: String) -> HistoryItem? {
        historyItems.first { $0.rootRunId == rootRunId }
            ?? historySearchResults.first { $0.rootRunId == rootRunId }
    }

    func openHistoryInRuntime(_ rootRunId: String) {
        runCommand(
            "run/inspect",
            runId: rootRunId,
            displayTitle: historyItem(rootRunId: rootRunId)?.title
        )
    }

    func newRun() {
        openDraftTab(kind: .run)
    }

    func newChat() {
        openDraftTab(kind: .chat)
    }

    func setDraftKind(_ kind: RunKind, forTab tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              !tabs[index].isImportingAttachments,
              !tabs[index].isSubmittingDraft else { return }
        let discardedAttachments = kind == .chat ? tabs[index].draftAttachments : []
        tabs[index].draftKind = kind
        if !discardedAttachments.isEmpty {
            tabs[index].draftAttachments = []
            tabs[index].attachmentErrorMessage = nil
            if let attachmentStore {
                Task {
                    for descriptor in discardedAttachments { try? await attachmentStore.removeDraft(descriptor) }
                }
            }
        }
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

    func setActivityExpanded(_ expanded: Bool, forTab tabID: UUID) {
        updateTab(tabID) { $0.activityExpanded = expanded }
    }

    func setFollowLive(_ follow: Bool, forTab tabID: UUID) {
        updateTab(tabID) { $0.followLive = follow }
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
            && tab.selectedHistoryRunID == nil
            && tab.draftText.isEmpty
            && tab.draftAttachments.isEmpty
            && tab.chatMessage.isEmpty
            && tab.steerMessage.isEmpty
    }

    private func updateTab(_ tabID: UUID, _ update: (inout RunTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        update(&tabs[index])
    }

    func chooseAttachments(forTab tabID: UUID) {
        guard attachmentsEnabled,
              let tab = tab(withID: tabID),
              tab.draftKind == .run,
              !tab.isImportingAttachments else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        guard panel.runModal() == .OK else { return }
        Task { await importAttachments(panel.urls, forTab: tabID) }
    }

    func importAttachments(_ urls: [URL], forTab tabID: UUID) async {
        guard attachmentsEnabled,
              let attachmentStore,
              let index = tabs.firstIndex(where: { $0.id == tabID && $0.selectedRunID == nil }),
              tabs[index].draftKind == .run,
              !tabs[index].isImportingAttachments,
              !urls.isEmpty else { return }
        tabs[index].isImportingAttachments = true
        tabs[index].attachmentErrorMessage = nil
        let existing = tabs[index].draftAttachments
        do {
            let imported = try await attachmentStore.importFiles(urls, existing: existing)
            guard let currentIndex = tabs.firstIndex(where: {
                $0.id == tabID && $0.selectedRunID == nil && $0.draftKind == .run
            }) else {
                for descriptor in imported { try? await attachmentStore.removeDraft(descriptor) }
                return
            }
            tabs[currentIndex].draftAttachments.append(contentsOf: imported)
            tabs[currentIndex].isImportingAttachments = false
        } catch {
            if let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[currentIndex].isImportingAttachments = false
                tabs[currentIndex].attachmentErrorMessage = error.localizedDescription
            }
        }
    }

    func removeAttachment(_ descriptor: AttachmentDescriptor, fromTab tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID && $0.selectedRunID == nil }),
              tabs[index].draftAttachments.contains(descriptor),
              let attachmentStore else { return }
        tabs[index].draftAttachments.removeAll { $0 == descriptor }
        tabs[index].attachmentErrorMessage = nil
        Task {
            do { try await attachmentStore.removeDraft(descriptor) }
            catch {
                if let currentIndex = tabs.firstIndex(where: { $0.id == tabID && $0.selectedRunID == nil }) {
                    tabs[currentIndex].attachmentErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func submitDraft(in tabID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID && $0.selectedRunID == nil }) else { return }
        let kind = tabs[tabIndex].draftKind
        let text = tabs[tabIndex].draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = tabs[tabIndex].draftAttachments
        guard isConnected, !text.isEmpty, !isWaitingForRunIdentity,
              !tabs[tabIndex].isImportingAttachments, !tabs[tabIndex].isSubmittingDraft else { return }
        guard kind == .run || attachments.isEmpty else { return }
        guard attachments.isEmpty || attachmentsEnabled else {
            tabs[tabIndex].attachmentErrorMessage = attachmentUnavailableReason
            return
        }
        if attachments.isEmpty {
            finishDraftSubmission(in: tabID, kind: kind, text: text, attachments: [])
            return
        }
        tabs[tabIndex].isSubmittingDraft = true
        tabs[tabIndex].attachmentErrorMessage = nil

        Task {
            do {
                guard let attachmentStore else { throw AttachmentStoreError.unavailable }
                try await attachmentStore.markOwned(attachments)
                if !finishDraftSubmission(in: tabID, kind: kind, text: text, attachments: attachments) {
                    try? await attachmentStore.discardOwned(attachments)
                }
            } catch {
                guard let currentIndex = tabs.firstIndex(where: { $0.id == tabID && $0.selectedRunID == nil }) else { return }
                tabs[currentIndex].isSubmittingDraft = false
                tabs[currentIndex].attachmentErrorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func finishDraftSubmission(
        in tabID: UUID,
        kind: RunKind,
        text: String,
        attachments: [AttachmentDescriptor]
    ) -> Bool {
        guard let tabIndex = tabs.firstIndex(where: {
            $0.id == tabID && $0.selectedRunID == nil && $0.draftKind == kind
        }) else { return false }

        let recordID = UUID()
        let runId = recordID.uuidString
        let sessionId = kind == .chat ? UUID().uuidString : nil
        var record = RunRecord(
            id: recordID,
            kind: kind,
            title: title(for: text),
            sessionId: sessionId,
            status: .queued,
            attachments: attachments.map { SubmittedAttachment(id: $0.attachmentId, name: $0.name, sizeBytes: $0.sizeBytes) },
            isRequestInFlight: true
        )
        if kind == .chat {
            record.chatMessages.append(ChatMessage(role: .user, content: text))
        }
        runs.insert(record, at: 0)
        bind(rootRunId: runId, to: recordID)
        tabs[tabIndex].selectedRunID = recordID
        tabs[tabIndex].draftText = ""
        tabs[tabIndex].draftAttachments = []
        tabs[tabIndex].isSubmittingDraft = false
        tabs[tabIndex].scrollPosition = nil

        let method = kind == .run ? "agent/run" : "agent/chat"
        var fields: [String: JSONValue] = ["runId": .string(runId)]
        if kind == .run {
            fields["goal"] = .string(text)
            if !attachments.isEmpty {
                fields["attachments"] = .array(attachments.map(\.protocolValue))
            }
        } else {
            fields["transcript"] = .array(record.chatMessages.map(\.protocolValue))
        }
        if let sessionId { fields["sessionId"] = .string(sessionId) }
        beginAgentRequest(method: method, fields: fields, recordID: recordID)
        return true
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
        let runId = UUID().uuidString
        var fields: [String: JSONValue] = [
            "runId": .string(runId),
            "transcript": .array(runs[index].chatMessages.map(\.protocolValue))
        ]
        if let sessionId = runs[index].sessionId { fields["sessionId"] = .string(sessionId) }
        bind(rootRunId: runId, to: recordID)
        tabs[tabIndex].pendingChatMessage = text
        tabs[tabIndex].chatMessage = ""
        beginAgentRequest(method: "agent/chat", fields: fields, recordID: recordID)
    }

    func resolveApproval(_ approved: Bool, for recordID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == recordID }),
              var interaction = runs[index].interaction,
              case .approval = interaction.kind,
              !interaction.isResolving else { return }
        guard let approvalId = interaction.approvalId else {
            interaction.errorMessage = "The runtime did not provide an approval ID."
            runs[index].interaction = interaction
            return
        }
        interaction.isResolving = true
        interaction.errorMessage = nil
        resolvedInteractions.remove(recordID)
        runs[index].interaction = interaction
        runs[index].isRequestInFlight = true

        Task {
            do {
                let result = try await client.send(
                    method: "interaction/resolveApproval",
                    params: [
                        "runId": .string(interaction.runId),
                        "approvalId": .string(approvalId),
                        "approved": .bool(approved)
                    ],
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
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let recordID = tab.selectedRunID else { return }
        let message = tab.steerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = runs.firstIndex(where: { $0.id == recordID }),
              let runId = runs[index].latestRunId,
              !runs[index].auxiliaryOperations.contains(.steer),
              !message.isEmpty else { return }
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

    func runCommand(_ method: String, runId value: String, displayTitle: String? = nil) {
        let runId = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !runId.isEmpty else { return }
        let preferredTitle = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = runs.firstIndex(where: { $0.runIds.contains(runId) }) {
            if let preferredTitle, !preferredTitle.isEmpty {
                runs[index].title = preferredTitle
            }
            let recordID = runs[index].id
            openRunTab(recordID)
            if method == "run/inspect" { showInspection(for: recordID) }
            sendRunCommand(method, runId: runId, recordID: recordID)
            return
        }

        let recordID = UUID()
        let abbreviatedRunId = runId.count > 20 ? String(runId.prefix(17)) + "…" : runId
        runs.insert(RunRecord(
            id: recordID,
            kind: .run,
            title: preferredTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Run \(abbreviatedRunId)",
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
        await stopTraceHistory()
        await client.shutdown()
        isConnected = false
        runtimeInfoSnapshot = nil
    }

    func refreshHistory() {
        guard isConnected else { return }
        Task {
            if traceConnected {
                await loadHistory(replacing: true)
            } else if let runtimeInfoSnapshot {
                traceClient = TraceSessionClient()
                await startTraceHistory(using: runtimeInfoSnapshot)
            }
        }
    }

    func loadOlderHistory() {
        guard case .loaded = historyState, let oldest = historyItems.last?.startedAt else { return }
        Task { await loadHistory(replacing: false, until: oldest) }
    }

    func updateHistorySearch(_ query: String) {
        historySearchQuery = query
        historySearchTask?.cancel()
        historySearchError = nil
        historySearchResults = localHistoryMatches(query)
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            isSearchingHistory = false
            return
        }
        guard traceConnected else {
            isSearchingHistory = false
            return
        }
        isSearchingHistory = true
        historySearchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let sessions = try await traceClient.listSessions(.init(goals: [normalized], limit: 100))
                guard !Task.isCancelled,
                      historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == normalized else { return }
                historySearchResults = mergeHistory(localHistoryMatches(normalized), flattenHistory(sessions))
                isSearchingHistory = false
            } catch {
                guard !Task.isCancelled else { return }
                guard historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == normalized else { return }
                historySearchError = redactedErrorDescription(error)
                isSearchingHistory = false
            }
        }
    }

    func retryHistoryReport(_ rootRunId: String) {
        historyReports.removeValue(forKey: rootRunId)
        loadHistoryReport(rootRunId)
    }

    func updateAccessToken() {
        guard !accessTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            accessTokenUpdateFailed = true
            accessTokenMessage = "Enter a non-empty access token."
            return
        }
        guard isConnected else {
            accessTokenUpdateFailed = false
            accessTokenMessage = "The token will be applied when the runtime initializes."
            return
        }
        guard !isUpdatingAccessToken else { return }
        let accessToken = accessTokenDraft
        isUpdatingAccessToken = true
        accessTokenUpdateFailed = false
        Task {
            do {
                _ = try await client.updateAccessToken(accessToken)
                accessTokenMessage = "Access token updated for the current runtime process."
            } catch {
                accessTokenUpdateFailed = true
                accessTokenMessage = "Token update failed: \(redactedErrorDescription(error))"
            }
            isUpdatingAccessToken = false
        }
    }

    func clearAccessToken() {
        accessTokenDraft = ""
        accessTokenUpdateFailed = false
        accessTokenMessage = isConnected
            ? "Local entry cleared. Restart the runtime to remove a token already sent to the process."
            : "Local access token entry cleared."
    }

    func refreshRuntimeInfo() {
        guard isConnected, !isRefreshingRuntimeInfo else { return }
        isRefreshingRuntimeInfo = true
        Task {
            await loadRuntimeInfo()
            isRefreshingRuntimeInfo = false
        }
    }

    // Internal for focused event/result tests.
    func acceptResult(_ result: JSONValue, for recordID: UUID) {
        appendEvent("Response\n\(result.prettyPrinted)")
        removePendingAssignment(recordID)
        guard let object = result.objectValue,
              let index = runs.firstIndex(where: { $0.id == recordID }) else { return }
        runs[index].isRequestInFlight = false
        clearPendingChatMessage(for: recordID)

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
                    approvalId: object["approvalId"]?.stringValue,
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
        for index in tabs.indices where tabs[index].selectedRunID == recordID {
            tabs[index].steerMessage = ""
        }
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
            scheduleHistoryRefresh()
        case "run.failed", "replan.required":
            guard isRootEvent, let index = recordIndex(forRunId: runId) else { return }
            runs[index].status = payload["code"]?.stringValue == "INTERRUPTED" ? .interrupted : .failed
            finishActivityTimer(at: index)
            runs[index].isRequestInFlight = false
            runs[index].interaction = nil
            runs[index].errorMessage = payload["error"]?.stringValue ?? "The run failed."
            scheduleHistoryRefresh()
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
                approvalId: payload["approvalId"]?.stringValue,
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
            let gatewayURL = configuredGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if (configuredInferenceMode == "gateway" || configuredRequireRunPermit) && gatewayURL.isEmpty {
                throw RuntimeClientError.protocolViolation("Gateway URL is required for gateway inference or required run permits.")
            }
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
            let accessToken = accessTokenDraft
            if !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = "Updating runtime access token…"
                do {
                    _ = try await client.updateAccessToken(accessToken)
                    accessTokenUpdateFailed = false
                    accessTokenMessage = "Access token applied for the current runtime process."
                } catch {
                    accessTokenUpdateFailed = true
                    accessTokenMessage = "Token update failed: \(redactedErrorDescription(error))"
                    throw error
                }
            }
            var managedAttachmentRoot: String?
            do {
                let store: AttachmentStore
                if let attachmentStore {
                    store = attachmentStore
                } else {
                    store = try AttachmentStore(rootURL: attachmentStoreRootURL)
                }
                if !attachmentStoreDidClean {
                    try await store.cleanAbandonedDrafts()
                    attachmentStoreDidClean = true
                }
                attachmentStore = store
                managedAttachmentRoot = store.rootURL.path
                localAttachmentStoreError = nil
            } catch {
                attachmentStore = nil
                localAttachmentStoreError = "File attachments are unavailable: \(error.localizedDescription)"
            }
            status = "Loading workspace configuration…"
            let parameters = RuntimeInitializationParameters(
                cwd: workingDirectory.path,
                agentConfigPath: agentConfigPath.isEmpty ? nil : agentConfigPath,
                settingsConfigPath: settingsConfigPath.isEmpty ? nil : settingsConfigPath,
                runtimeMode: configuredRuntimeMode.isEmpty ? nil : configuredRuntimeMode,
                provider: configuredProvider.isEmpty ? nil : configuredProvider,
                model: configuredModel.isEmpty ? nil : configuredModel,
                approvalMode: configuredApprovalMode,
                clarificationMode: configuredClarificationMode,
                inferenceMode: configuredInferenceMode.isEmpty ? nil : configuredInferenceMode,
                inferenceTier: configuredInferenceMode == "gateway" && !configuredInferenceTier.isEmpty
                    ? configuredInferenceTier
                    : nil,
                gatewayURL: gatewayURL.isEmpty ? nil : gatewayURL,
                requireRunPermit: configuredRequireRunPermit,
                managedAttachmentRoot: managedAttachmentRoot
            )
            let result = try await client.initializeRuntime(parameters: parameters)
            applyRuntimeInformation(result, fallbackWorkspace: workingDirectory.path)
            isConnected = true
            status = "Ready"
            showConfiguration = false
            appendEvent("Initialized\n\(String(describing: result))")
            await loadRuntimeInfo()
        } catch {
            await client.shutdown()
            client = RuntimeClient()
            isConnected = false
            status = redactedErrorDescription(error)
            appendEvent("Initialization error: \(error.localizedDescription)")
            showConfiguration = true
        }
    }

    private func applyRuntimeInformation(_ result: RuntimeInitializationResult, fallbackWorkspace: String) {
        agentName = result.agent.name.isEmpty ? result.agent.id : result.agent.name
        agentId = result.agent.id
        runtimeMode = result.runtimeMode
        effectiveWorkspaceRoot = result.workspaceRoot.isEmpty ? fallbackWorkspace : result.workspaceRoot
        shellCwd = result.shellCwd.isEmpty ? effectiveWorkspaceRoot : result.shellCwd
        registeredToolNames = result.registeredToolNames
        attachmentCapabilities = result.attachments
    }

    private func loadRuntimeInfo() async {
        do {
            let info = try await client.runtimeInfo()
            runtimeInfoSnapshot = info
            runtimeInfoError = nil
            if !traceConnected { await startTraceHistory(using: info) }
        } catch {
            runtimeInfoError = redactedErrorDescription(error)
        }
    }

    private func startTraceHistory(using info: RuntimeInfo) async {
        let backend: TraceSessionBackend
        switch info.runtimeMode {
        case "sqlite":
            guard let path = info.connections?.sqlite?.path, !path.isEmpty else {
                historyState = .unavailable("History unavailable: runtime did not report its SQLite path")
                return
            }
            backend = .sqlite(path: path)
        case "postgres":
            backend = .postgres(environmentVariable: "DATABASE_URL")
        default:
            historyState = .unavailable("History requires SQLite or Postgres")
            historyItems = []
            historySearchResults = []
            return
        }

        do {
            _ = try await traceClient.start(
                backend: backend,
                workingDirectoryURL: workspaceRootURL,
                diagnosticsHandler: { [weak self] message in
                    await self?.recordTraceDiagnostic(message)
                },
                terminationHandler: { [weak self] status in
                    await self?.traceTerminated(status: status)
                }
            )
            traceConnected = true
            await loadHistory(replacing: true)
        } catch {
            historyState = .failed(redactedErrorDescription(error))
        }
    }

    private func stopTraceHistory() async {
        historySearchTask?.cancel()
        historySearchTask = nil
        historyRefreshTask?.cancel()
        historyRefreshTask = nil
        await traceClient.shutdown()
        traceClient = TraceSessionClient()
        traceConnected = false
        loadingHistoryRunID = nil
        isSearchingHistory = false
        historySearchError = nil
    }

    private func loadHistory(replacing: Bool, until: String? = nil) async {
        historyState = .loading
        do {
            let sessions = try await traceClient.listSessions(.init(limit: 100, until: until))
            let loaded = flattenHistory(sessions)
            if replacing {
                let openHistoryIDs = Set(tabs.compactMap(\.selectedHistoryRunID))
                let openItems = historyItems.filter { openHistoryIDs.contains($0.rootRunId) }
                historyItems = mergeHistory(openItems, loaded)
            } else {
                historyItems = mergeHistory(historyItems, loaded)
            }
            historyState = .loaded
            updateHistorySearch(historySearchQuery)
        } catch {
            historyState = .failed(redactedErrorDescription(error))
        }
    }

    private func loadHistoryReport(_ rootRunId: String) {
        guard historyReports[rootRunId] == nil, loadingHistoryRunID != rootRunId else { return }
        loadingHistoryRunID = rootRunId
        historyReportErrors.removeValue(forKey: rootRunId)
        Task {
            do {
                let report = try await traceClient.getTrace(rootRunId: rootRunId)
                historyReports[rootRunId] = report
            } catch {
                historyReportErrors[rootRunId] = redactedErrorDescription(error)
            }
            if loadingHistoryRunID == rootRunId { loadingHistoryRunID = nil }
        }
    }

    private func flattenHistory(_ sessions: [TraceSessionListItem]) -> [HistoryItem] {
        sessions.flatMap { session in
            session.goals.map { goal in
                let goalTitle = goal.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = goalTitle.flatMap { $0.isEmpty ? nil : $0 }
                return HistoryItem(
                    rootRunId: goal.rootRunId,
                    sessionId: session.sessionId,
                    title: displayTitle ?? "Run \(String(goal.rootRunId.prefix(12)))",
                    status: goal.status ?? session.status ?? "unknown",
                    startedAt: goal.startedAt ?? goal.linkedAt,
                    completedAt: goal.completedAt,
                    type: goal.type ?? "run"
                )
            }
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private func mergeHistory(_ first: [HistoryItem], _ second: [HistoryItem]) -> [HistoryItem] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.rootRunId, $0) })
        for item in second { byID[item.rootRunId] = item }
        return byID.values.sorted { $0.startedAt > $1.startedAt }
    }

    private func localHistoryMatches(_ query: String) -> [HistoryItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return historyItems }
        return historyItems.filter { item in
            [item.title, item.rootRunId, item.sessionId ?? "", item.status, item.type]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func scheduleHistoryRefresh() {
        guard case .loaded = historyState else { return }
        historyRefreshTask?.cancel()
        historyRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await loadHistory(replacing: true)
        }
    }

    private func recordTraceDiagnostic(_ message: String) {
        appendEvent("Trace diagnostic: \(message)")
    }

    private func traceTerminated(status: Int32) {
        historyState = .failed("History helper exited with status \(status)")
        loadingHistoryRunID = nil
        isSearchingHistory = false
        historySearchError = nil
        traceClient = TraceSessionClient()
        traceConnected = false
    }

    private func redactedErrorDescription(_ error: Error) -> String {
        let description = ProtocolRedactor.redact(error.localizedDescription)
        guard !accessTokenDraft.isEmpty else { return description }
        return description.replacingOccurrences(of: accessTokenDraft, with: "<redacted>")
    }

    private func beginAgentRequest(method: String, fields: [String: JSONValue], recordID: UUID) {
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
                if type == "tool.completed" {
                    captureFiles(
                        from: event["payload"]?.objectValue ?? [:],
                        sourceRunId: sourceRunId,
                        at: index
                    )
                }
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
        let capturedInput = input["type"]?.stringValue == "object"
            ? input["preview"]?.objectValue ?? input
            : input
        func capturedString(_ key: String) -> String? {
            capturedInput[key]?.stringValue ?? capturedInput[key]?.objectValue?["preview"]?.stringValue
        }
        let rawDetail: String?
        switch toolName {
        case "web_search":
            rawDetail = capturedString("query")
        case "read_web_page", "fetch_page":
            if let urlText = capturedString("url"),
               let host = URL(string: urlText)?.host {
                rawDetail = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            } else {
                rawDetail = capturedString("url")
            }
        case "read_file", "write_file", "edit_file":
            rawDetail = capturedString("path").map { URL(fileURLWithPath: $0).lastPathComponent }
        case "shell_exec":
            rawDetail = capturedString("command")
        default:
            if toolName.localizedCaseInsensitiveContains("file"),
               let path = capturedString("path") {
                rawDetail = URL(fileURLWithPath: path).lastPathComponent
            } else {
                rawDetail = ["query", "url", "path", "command", "name"]
                    .compactMap(capturedString)
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

    private func captureFiles(
        from payload: [String: JSONValue],
        sourceRunId: String,
        at targetIndex: Int? = nil
    ) {
        guard payload["skipped"] != .bool(true),
              let toolName = payload["toolName"]?.stringValue,
              let output = payload["output"]?.objectValue,
              let index = targetIndex ?? recordIndex(forRunId: sourceRunId) else { return }

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
        restorePendingChatMessage(for: recordID, at: index)
        runs[index].isRequestInFlight = false
        runs[index].status = .failed
        finishActivityTimer(at: index)
        runs[index].errorMessage = error.localizedDescription
        appendEvent("Error: \(error.localizedDescription)")
    }

    private func clearPendingChatMessage(for recordID: UUID) {
        for index in tabs.indices where tabs[index].selectedRunID == recordID {
            tabs[index].pendingChatMessage = nil
        }
    }

    private func restorePendingChatMessage(for recordID: UUID, at runIndex: Int) {
        guard runs[runIndex].kind == .chat else { return }
        var restoredMessage: String?
        for index in tabs.indices where tabs[index].selectedRunID == recordID {
            guard let pending = tabs[index].pendingChatMessage else { continue }
            restoredMessage = pending
            if tabs[index].chatMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tabs[index].chatMessage = pending
            }
            tabs[index].pendingChatMessage = nil
        }
        if let restoredMessage,
           runs[runIndex].chatMessages.last?.role == .user,
           runs[runIndex].chatMessages.last?.content == restoredMessage {
            runs[runIndex].chatMessages.removeLast()
        }
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
        var redacted = ProtocolRedactor.redact(event)
        if !accessTokenDraft.isEmpty {
            redacted = redacted.replacingOccurrences(of: accessTokenDraft, with: "<redacted>")
        }
        events.append(redacted)
        if events.count > 500 { events.removeFirst(events.count - 500) }
    }

    private nonisolated static func protocolDiagnostic(_ value: JSONValue) -> String {
        let maximumBytes = 64 * 1024
        let redacted = ProtocolRedactor.redact(value)
        guard let data = try? JSONEncoder().encode(redacted) else { return String(describing: redacted) }
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
        Task { await stopTraceHistory() }
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
        attachmentCapabilities = nil
        runtimeInfoSnapshot = nil
        runtimeInfoError = nil
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

    struct Inference: Decodable {
        let mode: String?
        let tier: String?
    }

    struct Gateway: Decodable {
        let url: String?
        let requireRunPermit: Bool?
    }

    let runtime: Runtime?
    let model: Model?
    let interaction: Interaction?
    let inference: Inference?
    let gateway: Gateway?
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
