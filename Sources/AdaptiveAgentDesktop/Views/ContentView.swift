import AppKit
import MarkdownUI
import SwiftUI

enum SidebarItemID: Hashable {
    case live(UUID)
    case history(String)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var inspectorPresented = false
    @State private var sidebarSelections: Set<SidebarItemID> = []
    @State private var pendingDeletionRunIDs: Set<String> = []
    @State private var deletionConfirmationPresented = false

    init(inspectorPresented: Bool = false) {
        _inspectorPresented = State(initialValue: inspectorPresented)
    }

    var body: some View {
        // SwiftUI's native inspector can enter an AppKit constraint-update cycle
        // when it changes a NavigationSplitView's width on macOS 26.
        HStack(spacing: 0) {
            NavigationSplitView {
                runSidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            } detail: {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if inspectorPresented {
                Divider()
                RuntimeInspectorView()
                    .environmentObject(model)
                    .frame(width: 340)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .tint(.teal)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showConfiguration) {
            ConfigurationView()
                .environmentObject(model)
        }
        .alert("Quit AdaptiveAgent Desktop?", isPresented: $model.showQuitConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Quit", role: .destructive, action: model.confirmQuit)
        } message: {
            Text("One or more runs still need attention or are in progress. The agent runtime will be shut down before the app exits.")
        }
        .confirmationDialog(
            deletionConfirmationTitle,
            isPresented: $deletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(deletionConfirmationButtonTitle, role: .destructive) {
                model.deleteRuns(rootRunIDs: pendingDeletionRunIDs)
                sidebarSelections.subtract(sidebarItems(for: pendingDeletionRunIDs))
                pendingDeletionRunIDs = []
            }
            Button("Cancel", role: .cancel) { pendingDeletionRunIDs = [] }
        } message: {
            Text("This permanently removes the selected run data. This action cannot be undone.")
        }
        .alert("Couldn’t Delete Runs", isPresented: runDeletionErrorPresented) {
            Button("OK", action: model.clearRunDeletionError)
        } message: {
            Text(model.runDeletionError ?? "The selected runs could not be deleted.")
        }
        .task { model.bootstrap() }
        .onAppear { synchronizeSidebarSelection() }
        .onChange(of: model.selectedTabID) { _, _ in synchronizeSidebarSelection() }
    }

    private var runSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $sidebarSelections) {
                if !activeRuns.isEmpty {
                    Section("Active") {
                        ForEach(activeRuns) { record in
                            RunRow(record: record).tag(SidebarItemID.live(record.id))
                        }
                    }
                }

                Section {
                    HStack(spacing: 6) {
                        HistorySearchField(
                            text: historySearchBinding,
                            isSearching: model.isSearchingHistory
                        )
                        historyFilterMenu
                    }
                    .listRowSeparator(.hidden)
                } header: {
                    HStack {
                        Text("History")
                        Spacer()
                        Button(action: model.collapseAllHistory) {
                            Image(systemName: "rectangle.compress.vertical")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.expandedHistoryIDs.isEmpty)
                        .help("Collapse all expanded history")
                        Button(action: model.refreshHistory) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh run history")
                    }
                }

                ForEach(model.historySections) { section in
                    Section(section.title) {
                        ForEach(section.nodes) { node in
                            HistoryTreeRow(node: node, isThreadRoot: true) { rootRunId in
                                let selected = selectedDeletionRunIDs
                                pendingDeletionRunIDs = selected.contains(rootRunId) ? selected : [rootRunId]
                                deletionConfirmationPresented = true
                            }
                        }
                    }
                }

                Section {
                    historyStatusRow
                }
            }
            .onChange(of: sidebarSelections) { previous, selections in
                guard let selection = selections.subtracting(previous).first else { return }
                switch selection {
                case .live(let recordID): model.selectRun(recordID)
                case .history(let rootRunId):
                    model.selectHistoryRun(rootRunId)
                    model.expandHistoryThread(containing: rootRunId)
                }
            }
            Divider()
            HStack {
                Menu {
                    Button("New Run", systemImage: "play.fill", action: model.newRun)
                    Button("New Chat", systemImage: "bubble.left.and.bubble.right.fill", action: model.newChat)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                Spacer()
                Button(action: requestSelectedRunDeletion) {
                    if selectedDeletionRunIDs.contains(where: model.deletingRunIDs.contains) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(selectedDeletionRunIDs.isEmpty || !model.isConnected)
                .help("Delete selected runs")
                Text("\(activeRuns.count + model.allHistoryItems.count) runs")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
    }

    @ViewBuilder private var detail: some View {
        if let tab = model.selectedTab {
            SelectedTabDetail(tab: tab)
                .environmentObject(model)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isConnected ? Color.green : model.isBusy ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
                Text(model.isConnected ? (model.agentName.isEmpty ? "Ready" : model.agentName) : model.status)
                    .lineLimit(1)
                if model.isConnected, !model.runtimeMode.isEmpty {
                    Text(model.runtimeMode.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .help(model.effectiveWorkspaceRoot.isEmpty ? model.workspacePath : model.effectiveWorkspaceRoot)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.newRun) {
                Label("New Run", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut("n")
            .disabled(!model.isConnected)
            .help("New Run")

            Button(action: model.newChat) {
                Label("New Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!model.isConnected)
            .help("New Chat")

            Menu {
                Button("Markdown Appearance…", systemImage: "textformat") {
                    openSettings()
                }
                Divider()
                Button("Workspace Configuration…", systemImage: "externaldrive") {
                    model.showConfiguration = true
                }
                .disabled(!model.canEditSelectedRuntimeConfiguration)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help(model.canEditSelectedRuntimeConfiguration
                ? "Appearance and workspace settings"
                : "Runtime settings are locked after a run or chat starts")

            Button {
                inspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(inspectorPresented ? "Hide runtime inspector" : "Show runtime inspector")
        }
    }

    private var activeRuns: [AppModel.RunRecord] { model.runs.filter { $0.status.isActive } }
    private var historySearchIsEmpty: Bool {
        model.historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var historyStatusRow: some View {
        if !historySearchIsEmpty, let error = model.historySearchError {
            VStack(alignment: .leading, spacing: 5) {
                Text("History search couldn’t refresh: \(error)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Retry") { model.updateHistorySearch(model.historySearchQuery) }
                    .buttonStyle(.borderless)
            }
        } else if !historySearchIsEmpty, model.historyTree.isEmpty, !model.isSearchingHistory {
            VStack(spacing: 8) {
                Text("No historical runs match “\(model.historySearchQuery)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Clear Search") { model.updateHistorySearch("") }
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity)
        } else {
            switch model.historyState {
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Loading history…") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 5) {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Button("Retry", action: model.refreshHistory).buttonStyle(.borderless)
                }
            case .unavailable(let message):
                Text(message).font(.caption).foregroundStyle(.secondary)
            case .loaded:
                if let message = model.historyPagingMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if historySearchIsEmpty, model.hasOlderHistory {
                    Button("Load Older", action: model.loadOlderHistory)
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var selectedDeletionRunIDs: Set<String> {
        Set(sidebarSelections.compactMap { item in
            switch item {
            case .live(let recordID):
                return model.deletableRootRunID(for: recordID)
            case .history(let runId):
                return model.deletableHistoryRoot(for: runId)
            }
        })
    }

    private var deletionConfirmationTitle: String {
        pendingDeletionRunIDs.count == 1 ? "Delete Run?" : "Delete \(pendingDeletionRunIDs.count) Runs?"
    }

    private var deletionConfirmationButtonTitle: String {
        pendingDeletionRunIDs.count == 1 ? "Delete Run" : "Delete Runs"
    }

    private var runDeletionErrorPresented: Binding<Bool> {
        Binding(
            get: { model.runDeletionError != nil },
            set: { if !$0 { model.clearRunDeletionError() } }
        )
    }

    @ViewBuilder
    private func deleteRunButton(rootRunId: String) -> some View {
        Button("Delete Run…", systemImage: "trash", role: .destructive) {
            let selected = selectedDeletionRunIDs
            pendingDeletionRunIDs = selected.contains(rootRunId) ? selected : [rootRunId]
            deletionConfirmationPresented = true
        }
        .disabled(model.deletingRunIDs.contains(rootRunId) || !model.isConnected)
    }

    private func requestSelectedRunDeletion() {
        pendingDeletionRunIDs = selectedDeletionRunIDs
        deletionConfirmationPresented = !pendingDeletionRunIDs.isEmpty
    }

    private func sidebarItems(for rootRunIDs: Set<String>) -> Set<SidebarItemID> {
        Set(sidebarSelections.filter { item in
            switch item {
            case .live(let recordID):
                guard let rootRunId = model.deletableRootRunID(for: recordID) else { return false }
                return rootRunIDs.contains(rootRunId)
            case .history(let rootRunId):
                return rootRunIDs.contains(rootRunId)
            }
        })
    }

    private func synchronizeSidebarSelection() {
        let selectedItem: SidebarItemID?
        if let recordID = model.selectedRunItemID {
            selectedItem = .live(recordID)
        } else if let rootRunId = model.selectedHistoryRunID {
            selectedItem = .history(rootRunId)
        } else {
            selectedItem = nil
        }
        guard let selectedItem else {
            sidebarSelections = []
            return
        }
        if !sidebarSelections.contains(selectedItem) {
            sidebarSelections = [selectedItem]
        }
    }

    private var historySearchBinding: Binding<String> {
        Binding(
            get: { model.historySearchQuery },
            set: { query in model.updateHistorySearch(query) }
        )
    }

    @ViewBuilder private var historyFilterMenu: some View {
        Menu {
            Toggle("Running", isOn: historyStatusFilterBinding(.running))
            Toggle("Waiting", isOn: historyStatusFilterBinding(.waiting))
            Toggle("Failed", isOn: historyStatusFilterBinding(.failed))
            Divider()
            Toggle("Runs", isOn: historyKindFilterBinding(.run))
            Toggle("Chats", isOn: historyKindFilterBinding(.chat))
            Divider()
            Toggle("Has session", isOn: Binding(
                get: { model.historyFilters.hasSession == true },
                set: { isOn in model.historyFilters.hasSession = isOn ? true : nil }
            ))
            Divider()
            Button("Clear Filters") { model.historyFilters = AppModel.HistoryFilters() }
                .disabled(!model.historyFilters.isActive)
        } label: {
            Image(systemName: model.historyFilters.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter history")
    }

    private func historyStatusFilterBinding(_ filter: AppModel.HistoryStatusFilter) -> Binding<Bool> {
        Binding(
            get: { model.historyFilters.statuses.contains(filter) },
            set: { isOn in
                if isOn {
                    model.historyFilters.statuses.insert(filter)
                } else {
                    model.historyFilters.statuses.remove(filter)
                }
            }
        )
    }

    private func historyKindFilterBinding(_ kind: AppModel.RunKind) -> Binding<Bool> {
        Binding(
            get: { model.historyFilters.kinds.contains(kind) },
            set: { isOn in
                if isOn {
                    model.historyFilters.kinds.insert(kind)
                } else {
                    model.historyFilters.kinds.remove(kind)
                }
            }
        )
    }
}

private struct SelectedTabDetail: View {
    @EnvironmentObject private var model: AppModel
    let tab: AppModel.RunTab

    @ViewBuilder var body: some View {
        if let recordID = tab.selectedRunID,
           let record = model.runs.first(where: { $0.id == recordID }) {
            RunDetailView(record: record, tabID: tab.id)
        } else if let rootRunId = tab.selectedHistoryRunID,
                  let item = model.historyItem(rootRunId: rootRunId) {
            HistoricalRunDetailView(item: item, tabID: tab.id)
        } else if model.isConnected {
            NewRequestView(tabID: tab.id)
        } else {
            ConnectionStateView()
        }
    }
}

private struct RunRow: View {
    let record: AppModel.RunRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.kind.systemImage)
                .foregroundStyle(statusColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if record.hasRequestInFlight {
                        ProgressView().controlSize(.mini)
                    }
                    Text(record.status.rawValue)
                    if !record.files.isEmpty {
                        Text("·")
                        Image(systemName: "doc.on.doc")
                        Text("\(record.files.filter { !$0.isSupportFile }.count)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch record.status {
        case .queued, .running: return .accentColor
        case .waitingForApproval, .waitingForClarification: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .unknown, .interrupted: return .secondary
        }
    }
}

private struct HistorySearchField: View {
    @Binding var text: String
    let isSearching: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search run history…", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel("Search run history")
            if isSearching {
                ProgressView().controlSize(.mini)
            } else if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear history search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isFocused ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: isFocused ? 2 : 1)
        }
        .onExitCommand {
            if !text.isEmpty { text = "" } else { isFocused = false }
        }
        .background {
            Button("") { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }
}

extension AppModel.HistoryItem {
    var systemImage: String {
        type == "chat" ? "bubble.left.and.bubble.right.fill" : "play.fill"
    }

    var allowsDeletion: Bool {
        ![
            "queued", "planning", "running", "awaiting_subagent",
            "awaiting_approval", "clarification_requested"
        ].contains(status.lowercased())
    }
}

private struct NewRequestView: View {
    @EnvironmentObject private var model: AppModel
    let tabID: UUID
    @StateObject private var dictation = DictationController()
    @State private var existingRunID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("What should the agent do?")
                    .font(.system(size: 26, weight: .semibold))

                VStack(alignment: .leading, spacing: 0) {
                    WorkspaceContextView(compact: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: draftTextBinding)
                            .font(.body)
                            .accessibilityLabel(draftKind == .run ? "Run goal" : "Chat message")
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        if draftText.isEmpty {
                            Text(draftKind == .run ? "Describe a goal…" : "Write a message…")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 150)
                    .padding(.horizontal, 4)

                    if draftKind == .run {
                        AttachmentDraftView(tabID: tabID)
                            .environmentObject(model)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }

                    Divider()
                        .padding(.horizontal, 16)

                    HStack(spacing: 10) {
                        if draftKind == .run {
                            attachmentMenu
                        }

                        Picker("Request type", selection: draftKindBinding) {
                            ForEach(AppModel.RunKind.allCases) { kind in
                                Image(systemName: kind.systemImage)
                                    .accessibilityLabel(kind.rawValue)
                                    .tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 92)
                        .help(draftKind == .run ? "Run" : "Chat")

                        if model.isWaitingForRunIdentity {
                            ProgressView()
                                .controlSize(.small)
                            Text("Creating run…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        DictationButton(text: draftTextBinding, controller: dictation)

                        Button(action: submitDraft) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 30, height: 30)
                        }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(submissionDisabled)
                            .help(draftKind == .run ? "Start Run (⌘↩)" : "Start Chat (⌘↩)")
                            .accessibilityLabel(draftKind == .run ? "Start Run" : "Start Chat")
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)

                HStack(alignment: .firstTextBaseline) {
                    if draftKind == .run {
                        Text(AttachmentDraftView.limitSummary(for: model))
                    }
                    Spacer()
                    Text("⌘↩ to \(draftKind == .run ? "start" : "send")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                DisclosureGroup {
                    existingRunActions.padding(.top, 10)
                } label: {
                    Label("Open an existing run…", systemImage: "clock.arrow.circlepath")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity, minHeight: 600, alignment: .center)
        }
    }

    private var attachmentMenu: some View {
        Menu {
            ForEach(AttachmentKind.allCases, id: \.self) { kind in
                Button("\(kind.displayName)…", systemImage: kind.systemImage) {
                    model.chooseAttachments(kind: kind, forTab: tabID)
                }
                .disabled(!attachmentAvailable(kind))
                .help(model.attachmentUnavailableReason(for: kind) ?? "Add \(kind.displayName.lowercased()) attachments")
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "paperclip")
                    .frame(width: 30, height: 30)
                if attachmentCount > 0 {
                    Text("\(attachmentCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 7, y: -6)
                }
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .frame(width: 36, height: 32)
        .help("Attach a file, image, or audio recording")
        .accessibilityLabel("Attach")
    }

    private var existingRunActions: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Existing Run")
                    .font(.callout.weight(.medium))
                Text("Inspect or manage a run by ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            TextField("Run ID", text: $existingRunID)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(minWidth: 120, maxWidth: 230)
            RunActionsMenu { method in
                model.runCommand(method, runId: existingRunID)
            }
            .disabled(existingRunID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 700, minHeight: 68)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(.separator)
        }
    }

    private var draftKind: AppModel.RunKind {
        model.tab(withID: tabID)?.draftKind ?? .run
    }

    private var draftText: String {
        model.tab(withID: tabID)?.draftText ?? ""
    }

    private var attachmentCount: Int {
        model.tab(withID: tabID)?.draftAttachments.count ?? 0
    }

    private var submissionDisabled: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isWaitingForRunIdentity
            || (model.tab(withID: tabID)?.isImportingAttachments ?? false)
            || (model.tab(withID: tabID)?.isSubmittingDraft ?? false)
    }

    private func attachmentAvailable(_ kind: AttachmentKind) -> Bool {
        model.attachmentEnabled(for: kind)
            && !(model.tab(withID: tabID)?.isImportingAttachments ?? false)
            && attachmentCount < AttachmentDraftView.maximumAttachmentCount(for: model)
    }

    private var draftKindBinding: Binding<AppModel.RunKind> {
        Binding(
            get: { model.tab(withID: tabID)?.draftKind ?? .run },
            set: { model.setDraftKind($0, forTab: tabID) }
        )
    }

    private var draftTextBinding: Binding<String> {
        Binding(
            get: { model.tab(withID: tabID)?.draftText ?? "" },
            set: { model.setDraftText($0, forTab: tabID) }
        )
    }

    private func submitDraft() {
        dictation.cancel()
        model.submitDraft(in: tabID)
    }
}

private struct AttachmentDraftView: View {
    @EnvironmentObject private var model: AppModel
    let tabID: UUID

    private var tab: AppModel.RunTab? { model.tab(withID: tabID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachments = tab?.draftAttachments, !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.kind.systemImage)
                                Text(attachment.kind.displayName)
                                    .foregroundStyle(.secondary)
                                Text(attachment.name).lineLimit(1)
                                Text(Self.formattedSize(attachment.sizeBytes))
                                    .foregroundStyle(.secondary)
                                Button {
                                    model.removeAttachment(attachment, fromTab: tabID)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .disabled(tab?.isSubmittingDraft == true)
                                .accessibilityLabel("Remove \(attachment.name)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.quaternary.opacity(0.55), in: Capsule())
                        }
                    }
                }
            }

            if tab?.isImportingAttachments == true {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Importing secure snapshots…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let error = tab?.attachmentErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    static func formattedSize(_ sizeBytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    static func maximumAttachmentCount(for model: AppModel) -> Int {
        min(model.attachmentCapabilities?.maxAttachmentCount ?? AttachmentStore.maximumAttachmentCount,
            AttachmentStore.maximumAttachmentCount)
    }

    static func limitSummary(for model: AppModel) -> String {
        guard let capabilities = model.attachmentCapabilities else {
            return "Connect to see attachment availability"
        }
        let fileSize = Self.formattedSize(min(capabilities.maxFileBytes, AttachmentStore.maximumFileBytes))
        let totalSize = Self.formattedSize(min(capabilities.maxSubmissionBytes, AttachmentStore.maximumSubmissionBytes))
        return "\(fileSize) each · \(maximumAttachmentCount(for: model)) attachments · \(totalSize) total"
    }
}

private struct WorkspaceContextView: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    private var workspace: String {
        model.effectiveWorkspaceRoot.isEmpty ? model.workspacePath : model.effectiveWorkspaceRoot
    }

    private var agent: String {
        if !model.agentName.isEmpty { return model.agentName }
        if !model.agentConfigPath.isEmpty {
            return URL(fileURLWithPath: model.agentConfigPath).deletingPathExtension().lastPathComponent
        }
        return "Agent from settings"
    }

    @ViewBuilder var body: some View {
        if compact {
            compactContent
        } else {
            standardContent
        }
    }

    private var compactContent: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Agent Settings…", systemImage: "sparkles") { model.showConfiguration = true }
                Button("Choose Agent…", systemImage: "person.crop.circle") { model.showConfiguration = true }
                Divider()
                Button("Runtime Settings…", systemImage: "gearshape.2") { model.showConfiguration = true }
            } label: {
                Label(agent, systemImage: "sparkles")
            }
            .help(model.agentConfigPath.isEmpty ? "Agent selected by runtime settings" : model.agentConfigPath)

            Menu {
                Button("Change Workspace…", systemImage: "folder") { model.showConfiguration = true }
                Button("Workspace Settings…", systemImage: "gearshape") { model.showConfiguration = true }
            } label: {
                Label(workspace.isEmpty ? "Choose workspace" : URL(fileURLWithPath: workspace).lastPathComponent,
                      systemImage: "folder")
            }
            .help(workspace)

            Spacer(minLength: 0)

            Menu {
                ForEach(AppModel.supportedClarificationModes, id: \.self) { mode in
                    Button {
                        model.configuredClarificationMode = mode
                    } label: {
                        if model.configuredClarificationMode == mode {
                            Label(mode.capitalized, systemImage: "checkmark")
                        } else {
                            Text(mode.capitalized)
                        }
                    }
                }
            } label: {
                Text("Prep: \(model.configuredClarificationMode.capitalized)")
            }
            .fixedSize(horizontal: true, vertical: false)
            .help("Preparation: \(model.configuredClarificationMode.capitalized)")

            Menu {
                ForEach(AppModel.supportedApprovalModes, id: \.self) { mode in
                    Button {
                        model.configuredApprovalMode = mode
                    } label: {
                        if model.configuredApprovalMode == mode {
                            Label(mode.capitalized, systemImage: "checkmark")
                        } else {
                            Text(mode.capitalized)
                        }
                    }
                }
            } label: {
                Text("Approval: \(model.configuredApprovalMode.capitalized)")
            }
            .fixedSize(horizontal: true, vertical: false)
            .help("Approval: \(model.configuredApprovalMode.capitalized)")
        }
        .font(.caption)
        .controlSize(.small)
        .disabled(!model.canEditSelectedRuntimeConfiguration || model.isBusy)
    }

    private var standardContent: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(agent, systemImage: "sparkles")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.agentConfigPath.isEmpty ? "Agent selected by runtime settings" : model.agentConfigPath)
                Label(workspace.isEmpty ? "Choose a workspace" : URL(fileURLWithPath: workspace).lastPathComponent,
                      systemImage: "folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(workspace)
            }
            Spacer(minLength: 8)
            Button("Change…") { model.showConfiguration = true }
                .disabled(!model.canEditSelectedRuntimeConfiguration || model.isBusy)
                .help("Change agent, workspace, and runtime settings before starting")
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ConnectionStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 8) {
                Text("A workspace for your agent")
                    .font(.system(size: 28, weight: .semibold))
                Text("Choose where to work and which agent to use. Then turn a goal into a result.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            WorkspaceContextView()
            if model.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.status)
                }
                .foregroundStyle(.secondary)
            } else {
                Label("Runtime needs attention", systemImage: "exclamationmark.circle")
                    .font(.headline)
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Configure…") { model.showConfiguration = true }
                        .disabled(!model.canEditSelectedRuntimeConfiguration)
                    Spacer()
                    Button("Connect Runtime", action: model.connect)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: 580)
        .padding(40)
    }
}

private struct HistoricalRunDetailView: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.HistoryItem
    let tabID: UUID

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.status.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(item.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.retryHistoryReport(item.id)
                }
            }
            .padding(.horizontal, 22)
            .frame(height: 66)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let report = model.historyReports[item.rootRunId] {
                        historicalTimeline(report)
                        selectedRunAccounting
                    } else if let error = model.historyReportErrors[item.rootRunId] {
                        Label("Trace unavailable: \(error)", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView("Loading root trace…")
                    }
                    if let usage = model.historyUsage[item.rootRunId] ?? model.historyReports[item.rootRunId]?.usage {
                        HistoryUsageView(usage: usage, rootRunId: item.rootRunId)
                    }
                    if let error = model.historyUsageErrors[item.rootRunId] {
                        Text("Provider accounting could not refresh: \(error)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let report = model.historyReports[item.rootRunId] {
                        summary(report)
                        if !report.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("DATA WARNINGS").sectionLabel()
                                ForEach(report.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func summary(_ report: TraceReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ROOT TRACE SUMMARY").sectionLabel()
            Text(report.summary.status.capitalized).font(.title3.weight(.semibold))
            Text(report.summary.reason).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Started").foregroundStyle(.secondary)
                    Text(item.startedAt).textSelection(.enabled)
                }
                if let performance = report.performance {
                    GridRow {
                        Text("Model / tools").foregroundStyle(.secondary)
                        Text("\(Self.duration(performance.model.durationMs.total)) / \(Self.duration(performance.tools.durationMs.total))")
                    }
                }
            }
            .font(.callout)
        }
    }

    private func toolActivities(_ report: TraceReport) -> [AppModel.RunActivity] {
        report.timeline.compactMap { entry in
            guard entry.runId == item.id, let toolName = entry.toolName else { return nil }
            let state: AppModel.RunActivity.ToolState
            if entry.outcome.hasPrefix("failed") {
                state = .failed
            } else if entry.outcome.hasPrefix("running") {
                state = .running
            } else {
                state = .succeeded
            }
            return AppModel.RunActivity(
                id: "history:\(entry.id)",
                kind: .tool,
                sourceRunId: entry.runId,
                toolName: toolName,
                detail: entry.durationMs.map(Self.duration),
                toolState: state,
                createdAt: entry.startedAt.map(AppModel.historyDate),
                completedAt: entry.completedAt.map(AppModel.historyDate),
                eventSeq: entry.eventSeq
            )
        }
        .sorted { left, right in
            if let leftSequence = left.eventSeq, let rightSequence = right.eventSeq,
               leftSequence != rightSequence { return leftSequence < rightSequence }
            return (left.createdAt ?? .distantPast) < (right.createdAt ?? .distantPast)
        }
    }

    private func historicalTimeline(_ report: TraceReport) -> some View {
        let activities = toolActivities(report)
        let detail = model.historyDetails[item.id]
        let startedAt = AppModel.historyDate(item.startedAt)
        let completedAt = item.completedAt.map(AppModel.historyDate)
        return LazyVStack(alignment: .leading, spacing: 0) {
            TimelineRow(date: startedAt == .distantPast ? nil : startedAt, symbol: "person", accessibilityLabel: "Goal") {
                Text(item.title).textSelection(.enabled).padding(.vertical, 5)
            }
            ForEach(activities) { activity in
                ToolActivityRow(activity: activity, files: historyFiles(for: activity, activities: activities))
            }
            ForEach(unattachedHistoryFiles(activities: activities)) { file in
                TimelineRow(date: nil, symbol: "doc", accessibilityLabel: "File artifact") {
                    FileRow(file: file).environmentObject(model)
                }
            }
            if let output = detail?.output, output != .null {
                RunActivityRow(
                    activity: AppModel.RunActivity(
                        id: "history-result:\(item.id)",
                        kind: .assistant,
                        sourceRunId: item.id,
                        content: output.stringValue ?? output.prettyPrinted,
                        isFinalAssistantMessage: true,
                        createdAt: completedAt
                    ),
                    agentName: "Agent",
                    modelName: report.rootRuns.first(where: { $0.runId == item.id })?.modelName ?? "",
                    files: []
                )
            }
            if let completedAt {
                FinishedActivityRow(
                    status: item.status.lowercased().contains("fail") ? .failed : .succeeded,
                    duration: max(0, completedAt.timeIntervalSince(startedAt)),
                    toolCount: activities.count,
                    fileCount: detail?.files.count ?? 0,
                    finishedAt: completedAt
                )
            }
        }
    }

    @ViewBuilder private var selectedRunAccounting: some View {
        if let detail = model.historyDetails[item.id], let usage = detail.usage {
            VStack(alignment: .leading, spacing: 5) {
                Text("SELECTED RUN USAGE").sectionLabel()
                HistoryTokenLine(usage: usage)
            }
        } else if model.historyDetails[item.id] == nil && model.historyDetailErrors[item.id] == nil {
            ProgressView("Loading selected run…")
        }
        if let error = model.historyDetailErrors[item.id] {
            Label("Output/files could not refresh: \(error)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func historyFiles(
        for activity: AppModel.RunActivity,
        activities: [AppModel.RunActivity]
    ) -> [AppModel.RunFile] {
        guard activity.toolName == "write_file" || activity.toolName == "edit_file" else { return [] }
        return (model.historyDetails[item.id]?.files ?? []).filter { file in
            guard file.sourceRunId == activity.sourceRunId else { return false }
            return activities.last(where: {
                $0.sourceRunId == file.sourceRunId
                    && ($0.toolName == "write_file" || $0.toolName == "edit_file")
            })?.id == activity.id
        }
    }

    private func unattachedHistoryFiles(activities: [AppModel.RunActivity]) -> [AppModel.RunFile] {
        let attached = Set(activities.flatMap { historyFiles(for: $0, activities: activities).map(\.id) })
        return (model.historyDetails[item.id]?.files ?? []).filter { !attached.contains($0.id) }
    }

    private static func duration(_ milliseconds: Double) -> String {
        if milliseconds < 1_000 { return "\(Int(milliseconds)) ms" }
        return String(format: "%.1f s", milliseconds / 1_000)
    }
}

private struct RunDetailView: View {
    @EnvironmentObject private var model: AppModel
    let record: AppModel.RunRecord
    let tabID: UUID
    @StateObject private var dictation = DictationController()
    @State private var hasNewerContent = false

    var body: some View {
        VStack(spacing: 0) {
            runHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if !record.attachments.isEmpty {
                            SubmittedAttachmentsView(attachments: record.attachments)
                                .id("attachments")
                        }
                        if detailMode == .inspection {
                            inspectionOutput
                                .id("run-inspection")
                        } else {
                            RunActivityFeed(
                                record: record,
                                agentName: record.agentName,
                                modelName: record.modelName
                            )
                                .id("run-activity")
                            runOutput
                                .id("run-output")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("run-bottom")
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: 1120, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollPosition(id: scrollPositionBinding, anchor: .center)
                .simultaneousGesture(DragGesture().onChanged { _ in
                    model.setFollowLive(false, forTab: tabID)
                })
                .onChange(of: record.activities) { oldActivities, activities in
                    guard detailMode == .results, activities != oldActivities else { return }
                    if followLive {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("run-bottom", anchor: .bottom)
                        }
                    } else {
                        hasNewerContent = true
                    }
                }
                .onChange(of: record.chatMessages) { oldMessages, messages in
                    guard detailMode == .results, messages != oldMessages else { return }
                    if followLive {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("run-bottom", anchor: .bottom)
                        }
                    } else {
                        hasNewerContent = true
                    }
                }
                .onChange(of: record.output) { oldValue, newValue in
                    guard oldValue != newValue, newValue != nil else { return }
                    if followLive {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("run-bottom", anchor: .bottom)
                        }
                    } else {
                        hasNewerContent = true
                    }
                }
                .onChange(of: record.interaction) { oldValue, newValue in
                    guard oldValue != newValue, newValue != nil else { return }
                    if followLive {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("run-bottom", anchor: .bottom)
                        }
                    } else {
                        hasNewerContent = true
                    }
                }
                .onChange(of: record.errorMessage) { oldValue, newValue in
                    guard oldValue != newValue, newValue != nil else { return }
                    if followLive {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("run-bottom", anchor: .bottom)
                        }
                    } else {
                        hasNewerContent = true
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followLive && hasNewerContent {
                        Button("Jump to Latest", systemImage: "arrow.down") {
                            model.setFollowLive(true, forTab: tabID)
                            hasNewerContent = false
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("run-bottom", anchor: .bottom)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(14)
                    }
                }
            }

            if record.kind == .chat {
                Divider()
                chatComposer
            } else if record.status == .running, record.latestRunId != nil {
                Divider()
                steerComposer
            }
        }
        .onChange(of: tabID) { dictation.cancel() }
        .onChange(of: record.id) { dictation.cancel() }
    }

    private var runHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: record.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusBadge(status: record.status)
                    if let startedAt = record.activityStartedAt {
                        summaryChip(
                            ThinkingActivityRow.durationText(max(0, (record.activityFinishedAt ?? .now).timeIntervalSince(startedAt))),
                            symbol: "clock",
                            accessibilityLabel: "Run duration",
                            target: "run-goal"
                        )
                    }
                    let toolCount = record.activities.filter { $0.kind == .tool }.count
                    if toolCount > 0, let firstTool = record.activities.first(where: { $0.kind == .tool }) {
                        summaryChip(
                            "\(toolCount)", symbol: "wrench.and.screwdriver",
                            accessibilityLabel: "\(toolCount) tool calls", target: firstTool.id
                        )
                    }
                    if !record.files.isEmpty {
                        summaryChip(
                            "\(record.files.count)", symbol: "doc",
                            accessibilityLabel: "\(record.files.count) files changed",
                            target: record.files.first?.sourceActivityID ?? "run-activity"
                        )
                    }
                    if let runId = record.latestRunId {
                        Text(runId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
            if record.hasRequestInFlight { ProgressView().controlSize(.small) }
            if record.status.isActive, record.latestRunId != nil {
                Button("Interrupt", systemImage: "stop.fill", role: .destructive) {
                    model.runCommand("run/interrupt", for: record.id)
                }
                .disabled(record.auxiliaryOperations.contains(.interrupt))
                .help("Request that the runtime interrupt this run")
            }
            RunActionsMenu(record: record, showResults: {
                model.setDetailMode(.results, forTab: tabID)
            }) { method in
                model.runCommand(method, for: record.id)
            }
            .disabled(record.latestRunId == nil)
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
    }

    private func summaryChip(
        _ text: String,
        symbol: String,
        accessibilityLabel: String,
        target: String
    ) -> some View {
        Button {
            model.setScrollPosition(target, forTab: tabID)
        } label: {
            Label(text, systemImage: symbol)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.35), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var inspectionOutput: some View {
        if let inspection = record.inspection {
            VStack(alignment: .leading, spacing: 12) {
                Text("INSPECTION").sectionLabel()
                RunActivityFeed(
                    record: record,
                    agentName: record.agentName,
                    modelName: record.modelName
                )
                InspectionOutputView(inspection: inspection, hasRelevantActivity: !record.activities.isEmpty)
            }
        } else if record.auxiliaryOperations.contains(.inspect) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading inspection…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            Text("No inspection details were returned.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    @ViewBuilder private var runOutput: some View {
        if let output = record.output,
           !record.activities.contains(where: { $0.isFinalAssistantMessage }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("RESULT").sectionLabel()
                OutputView(output: output)
            }
        } else if record.isRequestInFlight || record.status == .running || record.status == .queued {
            EmptyView()
        } else if record.interaction == nil
                    && record.errorMessage == nil
                    && !record.activities.contains(where: { $0.isFinalAssistantMessage }) {
            Text("No result was returned.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private var chatComposer: some View {
        ProminentRunComposer(
            title: "Message \(record.agentName.isEmpty ? "agent" : record.agentName)",
            placeholder: "Continue the conversation…",
            helper: "Send another message in this conversation.",
            actionTitle: "Send",
            systemImage: "bubble.left.fill",
            text: chatMessageBinding,
            isPending: record.isRequestInFlight,
            errorMessage: record.errorMessage,
            accessory: AnyView(DictationButton(text: chatMessageBinding, controller: dictation)),
            collapsesWhenIdle: !record.status.isActive,
            action: sendChatMessage
        )
    }

    private var steerComposer: some View {
        ProminentRunComposer(
            title: "Steer active run",
            placeholder: "Add a correction or new priority…",
            helper: "The agent will apply this at the next safe point.",
            actionTitle: "Steer",
            systemImage: "arrow.triangle.turn.up.right.diamond.fill",
            text: steerMessageBinding,
            isPending: record.auxiliaryOperations.contains(.steer),
            errorMessage: record.auxiliaryErrorMessage,
            action: { model.steerRun(in: tabID) }
        )
    }

    private var chatMessage: String {
        model.tab(withID: tabID)?.chatMessage ?? ""
    }

    private var steerMessage: String {
        model.tab(withID: tabID)?.steerMessage ?? ""
    }

    private var detailMode: AppModel.RunDetailMode {
        model.tab(withID: tabID)?.detailMode ?? .results
    }

    private var followLive: Bool {
        model.tab(withID: tabID)?.followLive ?? true
    }

    private var chatMessageBinding: Binding<String> {
        Binding(
            get: { model.tab(withID: tabID)?.chatMessage ?? "" },
            set: { model.setChatMessage($0, forTab: tabID) }
        )
    }

    private var steerMessageBinding: Binding<String> {
        Binding(
            get: { model.tab(withID: tabID)?.steerMessage ?? "" },
            set: { model.setSteerMessage($0, forTab: tabID) }
        )
    }

    private var scrollPositionBinding: Binding<String?> {
        Binding(
            get: { model.tab(withID: tabID)?.scrollPosition },
            set: { model.setScrollPosition($0, forTab: tabID) }
        )
    }

    private func sendChatMessage() {
        dictation.cancel()
        model.sendChatMessage(in: tabID)
    }
}

private struct SubmittedAttachmentsView: View {
    let attachments: [AppModel.SubmittedAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ATTACHMENTS").sectionLabel()
            ForEach(attachments) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: attachment.kind.systemImage)
                        .foregroundStyle(.secondary)
                    Text(attachment.kind.displayName)
                        .foregroundStyle(.secondary)
                    Text(attachment.name)
                        .lineLimit(1)
                    Spacer()
                    Text(AttachmentDraftView.formattedSize(attachment.sizeBytes))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct ProminentRunComposer: View {
    let title: String
    let placeholder: String
    let helper: String
    let actionTitle: String
    let systemImage: String
    @Binding var text: String
    let isPending: Bool
    let errorMessage: String?
    var accessory: AnyView? = nil
    var collapsesWhenIdle = false
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isExpanded = false

    var body: some View {
        if collapsesWhenIdle && !isExpanded && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                isExpanded = true
                Task { @MainActor in isFocused = true }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: systemImage)
                    Text(placeholder).foregroundStyle(.secondary)
                    Spacer()
                    Text(actionTitle).fontWeight(.semibold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityLabel("\(title). \(placeholder)")
        } else {
            expandedComposer
        }
    }

    private var expandedComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                Text(title.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .focused($isFocused)
                .accessibilityLabel(title)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: isFocused ? 2 : 1)
                }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(helper)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer()
                accessory
                Button(action: action) {
                    if isPending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isPending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("\(actionTitle) (⌘Return)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: isFocused) { _, focused in
            if collapsesWhenIdle && !focused
                && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isExpanded = false
            }
        }
    }
}

private struct DictationButton: View {
    @Binding var text: String
    @ObservedObject var controller: DictationController
    @State private var textBeforeDictation = ""
    @State private var showsError = false

    var body: some View {
        Button(action: toggleDictation) {
            Group {
                switch controller.phase {
                case .starting, .stopping:
                    ProgressView()
                        .controlSize(.mini)
                case .recording:
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                case .idle:
                    Image(systemName: "mic.fill")
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .disabled(controller.phase == .starting || controller.phase == .stopping)
        .help(controller.phase == .recording ? "Stop dictation" : "Start dictation")
        .accessibilityLabel(controller.phase == .recording ? "Stop dictation" : "Start dictation")
        .onChange(of: controller.transcript) { _, transcript in
            guard !transcript.isEmpty else { return }
            text = textBeforeDictation + transcript
        }
        .onChange(of: controller.errorMessage) { _, message in
            showsError = message != nil
        }
        .onDisappear(perform: controller.cancel)
        .alert("Dictation Unavailable", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "Dictation could not start.")
        }
    }

    private func toggleDictation() {
        switch controller.phase {
        case .idle:
            textBeforeDictation = text
            if let lastCharacter = textBeforeDictation.last, !lastCharacter.isWhitespace {
                textBeforeDictation.append(" ")
            }
            Task { await controller.start() }
        case .recording:
            controller.stop()
        case .starting, .stopping:
            break
        }
    }
}

private struct StatusBadge: View {
    let status: AppModel.RunStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .queued, .running: return .accentColor
        case .waitingForApproval, .waitingForClarification: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .unknown, .interrupted: return .secondary
        }
    }
}

private struct RunActionsMenu: View {
    @EnvironmentObject private var model: AppModel
    let record: AppModel.RunRecord?
    let showResults: (() -> Void)?
    let action: (String) -> Void

    init(
        record: AppModel.RunRecord? = nil,
        showResults: (() -> Void)? = nil,
        action: @escaping (String) -> Void
    ) {
        self.record = record
        self.showResults = showResults
        self.action = action
    }

    var body: some View {
        Menu {
            if let showResults {
                Button("Results", systemImage: "doc.text") { showResults() }
            }
            Button("Inspect", systemImage: "info.circle") { action("run/inspect") }
                .disabled(record?.auxiliaryOperations.contains(.inspect) == true)
            Divider()
            Button("Resume", systemImage: "play") { action("run/resume") }
                .disabled(record?.isRequestInFlight == true)
            Button("Retry", systemImage: "arrow.clockwise") { action("run/retry") }
                .disabled(record?.isRequestInFlight == true)
            Button("Recover", systemImage: "lifepreserver") { action("run/recover") }
                .disabled(model.isWaitingForRunIdentity || record?.isRequestInFlight == true)
            Button("Continue", systemImage: "arrow.right.circle") { action("run/continue") }
                .disabled(model.isWaitingForRunIdentity || record?.isRequestInFlight == true)
            Divider()
            Button("Interrupt", systemImage: "stop.fill", role: .destructive) { action("run/interrupt") }
                .disabled(record?.auxiliaryOperations.contains(.interrupt) == true)
        } label: {
            Label("Run Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct TimelineRow<Content: View>: View {
    let date: Date?
    let symbol: String
    var showsProgress = false
    let accessibilityLabel: String
    var help: String? = nil
    let content: Content

    init(
        date: Date?,
        symbol: String,
        showsProgress: Bool = false,
        accessibilityLabel: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.date = date
        self.symbol = symbol
        self.showsProgress = showsProgress
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if let date {
                    Text(date, format: .dateTime.hour().minute().second())
                } else {
                    Text("—")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 70, alignment: .leading)
            .padding(.top, 8)

            VStack(spacing: 0) {
                Group {
                    if showsProgress {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: symbol)
                            .font(.caption.weight(.semibold))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .help(help ?? accessibilityLabel)
                .accessibilityLabel(accessibilityLabel)

                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 32)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.bottom, 14)
        }
    }
}

private struct ChatTimelineRow: View {
    let message: AppModel.ChatMessage
    let agentName: String
    let modelName: String

    var body: some View {
        TimelineRow(
            date: message.createdAt,
            symbol: message.role == .user ? "person" : "sparkles",
            accessibilityLabel: message.role == .user ? "You" : agentLabel,
            help: message.role == .assistant ? agentLabel : nil
        ) {
            MarkdownText(content: message.content)
                .padding(.vertical, 5)
        }
    }

    private var agentLabel: String {
        [agentName.isEmpty ? "Agent" : agentName, modelName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct ToolActivityDetail: View {
    let activity: AppModel.RunActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let input = activity.input {
                detailSection("INPUT", value: input.prettyPrinted)
            }
            if let output = activity.output {
                detailSection("OUTPUT", value: output.prettyPrinted)
            }
            if let error = activity.errorMessage {
                detailSection("ERROR", value: error, isFailure: true)
            }
            if activity.input == nil && activity.output == nil && activity.errorMessage == nil {
                Text("No additional detail was recorded.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detailSection(_ label: String, value: String, isFailure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).sectionLabel()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(isFailure ? Color.red : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RunActivityFeed: View {
    @EnvironmentObject private var model: AppModel
    let record: AppModel.RunRecord
    let agentName: String
    let modelName: String

    private var isThinking: Bool {
        record.interaction == nil
            && (record.status == .queued || record.status == .running || record.isRequestInFlight)
            && record.activities.last?.toolState != .running
    }

    private var showsDuration: Bool {
        !record.status.isActive && record.activityStartedAt != nil && record.activityFinishedAt != nil
    }

    private var feedItems: [TimelineFeedItem] {
        let activities = record.activities.enumerated().map {
            TimelineFeedItem.activity($0.element, order: $0.offset)
        }
        let messages = record.chatMessages.enumerated().map {
            TimelineFeedItem.message($0.element, order: record.activities.count + $0.offset)
        }
        return (activities + messages).sorted { left, right in
            if left.date == right.date { return left.order < right.order }
            return left.date < right.date
        }
    }

    var body: some View {
        if record.kind == .run || !feedItems.isEmpty || isThinking || showsDuration {
            LazyVStack(alignment: .leading, spacing: 0) {
                if record.kind == .run {
                    TimelineRow(date: record.activityStartedAt, symbol: "person", accessibilityLabel: "Goal") {
                        Text(record.title)
                            .textSelection(.enabled)
                            .padding(.vertical, 5)
                    }
                    .id("run-goal")
                }
                ForEach(feedItems) { item in
                    switch item {
                    case .activity(let activity, _):
                        RunActivityRow(
                            activity: activity,
                            agentName: agentName,
                            modelName: modelName,
                            files: files(for: activity)
                        )
                        .id(activity.id)
                    case .message(let message, _):
                        ChatTimelineRow(message: message, agentName: agentName, modelName: modelName)
                            .id("message-\(message.id.uuidString)")
                    }
                }
                ForEach(unattachedFiles) { file in
                    TimelineRow(date: nil, symbol: "doc", accessibilityLabel: "File artifact") {
                        FileRow(file: file).environmentObject(model)
                    }
                }
                if let interaction = record.interaction {
                    TimelineRow(
                        date: interaction.createdAt,
                        symbol: interactionSymbol(interaction),
                        accessibilityLabel: "Interaction required"
                    ) {
                        InteractionCard(recordID: record.id, interaction: interaction)
                            .environmentObject(model)
                    }
                    .id("interaction-\(record.id.uuidString)")
                }
                if let error = record.errorMessage {
                    TimelineRow(date: record.activityFinishedAt, symbol: "exclamationmark.triangle", accessibilityLabel: "Run failed") {
                        ErrorCard(message: error)
                    }
                    .id("error")
                }
                if let error = record.auxiliaryErrorMessage {
                    TimelineRow(date: nil, symbol: "exclamationmark.triangle", accessibilityLabel: "Operation failed") {
                        ErrorCard(message: error)
                    }
                    .id("auxiliary-error")
                }
                if isThinking {
                    ThinkingActivityRow(startedAt: record.activityStartedAt)
                        .id("thinking")
                } else if showsDuration,
                          let startedAt = record.activityStartedAt,
                          let finishedAt = record.activityFinishedAt {
                    FinishedActivityRow(
                        status: record.status,
                        duration: max(0, finishedAt.timeIntervalSince(startedAt)),
                        toolCount: record.activities.filter { $0.kind == .tool }.count,
                        fileCount: record.files.count,
                        finishedAt: finishedAt
                    )
                }
            }
        }
    }

    private var unattachedFiles: [AppModel.RunFile] {
        let attached = Set(record.activities.flatMap { files(for: $0).map(\.id) })
        return record.files.filter { !attached.contains($0.id) }
    }

    private func files(for activity: AppModel.RunActivity) -> [AppModel.RunFile] {
        record.files.filter { file in
            if let sourceActivityID = file.sourceActivityID { return sourceActivityID == activity.id }
            guard activity.kind == .tool,
                  activity.sourceRunId == file.sourceRunId,
                  activity.toolName == "write_file" || activity.toolName == "edit_file" else { return false }
            return record.activities.last(where: {
                $0.kind == .tool && $0.sourceRunId == file.sourceRunId
                    && ($0.toolName == "write_file" || $0.toolName == "edit_file")
            })?.id == activity.id
        }
    }

    private func interactionSymbol(_ interaction: AppModel.Interaction) -> String {
        switch interaction.kind {
        case .approval: "checkmark.shield"
        case .clarification: "questionmark.bubble"
        }
    }

    private enum TimelineFeedItem: Identifiable {
        case activity(AppModel.RunActivity, order: Int)
        case message(AppModel.ChatMessage, order: Int)

        var id: String {
            switch self {
            case .activity(let activity, _): "activity:\(activity.id)"
            case .message(let message, _): "message:\(message.id.uuidString)"
            }
        }
        var date: Date {
            switch self {
            case .activity(let activity, _): activity.createdAt ?? .distantPast
            case .message(let message, _): message.createdAt
            }
        }
        var order: Int {
            switch self {
            case .activity(_, let order), .message(_, let order): order
            }
        }
    }
}

private struct RunActivityRow: View {
    let activity: AppModel.RunActivity
    let agentName: String
    let modelName: String
    let files: [AppModel.RunFile]

    var body: some View {
        switch activity.kind {
        case .assistant:
            if let content = activity.content {
                TimelineRow(
                    date: activity.createdAt,
                    symbol: "sparkles",
                    accessibilityLabel: agentLabel,
                    help: agentLabel
                ) {
                    VStack(alignment: .leading, spacing: 7) {
                        if activity.isFinalAssistantMessage {
                            Text("RESULT")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        MarkdownText(content: content)
                    }
                    .padding(activity.isFinalAssistantMessage ? 12 : 0)
                    .overlay(alignment: .leading) {
                        if activity.isFinalAssistantMessage {
                            Rectangle().fill(.secondary).frame(width: 2)
                        }
                    }
                }
            }
        case .tool:
            ToolActivityRow(activity: activity, files: files)
        }
    }

    private var agentLabel: String {
        [agentName.isEmpty ? "Agent" : agentName, modelName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct ToolActivityRow: View {
    @EnvironmentObject private var model: AppModel
    let activity: AppModel.RunActivity
    let files: [AppModel.RunFile]
    @State private var isExpanded = false

    var body: some View {
        TimelineRow(
            date: activity.createdAt,
            symbol: toolSymbol,
            showsProgress: activity.toolState == .running,
            accessibilityLabel: activity.toolName ?? "Tool",
            help: activity.toolName
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 9) {
                        Text(activity.detail ?? "Tool activity")
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        status
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(activity.toolName ?? "Tool"), \(activity.detail ?? "activity"), \(stateLabel)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                if isExpanded {
                    ToolActivityDetail(activity: activity)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                ForEach(files) { file in
                    FileRow(file: file).environmentObject(model)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var status: some View {
        if activity.toolState == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Running… \(ThinkingActivityRow.durationText(max(0, context.date.timeIntervalSince(activity.createdAt ?? context.date))))")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: stateSymbol)
                Text(stateLabel)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(activity.toolState == .failed ? Color.red : Color.secondary)
        }
    }

    private var toolSymbol: String {
        switch activity.toolName {
        case "web_search": return "magnifyingglass"
        case "read_web_page", "fetch_page": return "globe"
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "edit_file": return "square.and.pencil"
        case "shell_exec": return "terminal"
        default:
            return activity.toolName?.localizedCaseInsensitiveContains("file") == true
                ? "doc"
                : "wrench.and.screwdriver"
        }
    }

    private var stateLabel: String {
        switch activity.toolState {
        case .awaitingApproval: return "Approval"
        case .running: return "Running"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case nil: return ""
        }
    }

    private var stateSymbol: String {
        switch activity.toolState {
        case .awaitingApproval: return "hand.raised"
        case .running: return "circle.dotted"
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        case .skipped: return "forward"
        case nil: return "circle"
        }
    }
}

private struct ThinkingActivityRow: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TimelineRow(
                date: startedAt,
                symbol: "sparkles",
                showsProgress: true,
                accessibilityLabel: "Agent thinking",
                help: "Agent"
            ) {
                if let startedAt {
                    Text("Thinking… \(Self.durationText(max(0, context.date.timeIntervalSince(startedAt))))")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Thinking…")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    fileprivate static func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded(.down))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct FinishedActivityRow: View {
    let status: AppModel.RunStatus
    let duration: TimeInterval
    let toolCount: Int
    let fileCount: Int
    let finishedAt: Date

    var body: some View {
        TimelineRow(date: finishedAt, symbol: symbol, accessibilityLabel: label) {
            Text(
                "\(label) \(ThinkingActivityRow.durationText(duration))"
                    + " · \(toolCount) \(toolCount == 1 ? "tool call" : "tool calls")"
                    + " · \(fileCount) \(fileCount == 1 ? "file" : "files")"
            )
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(status == .failed ? Color.red : Color.secondary)
        }
    }

    private var label: String {
        status == .succeeded ? "Completed in" : "Stopped after"
    }

    private var symbol: String {
        switch status {
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "stop.circle"
        }
    }
}

private struct InspectionOutputView: View {
    let inspection: JSONValue
    let hasRelevantActivity: Bool

    var body: some View {
        if let object = inspection.objectValue,
           case .array(let events)? = object["events"] {
            VStack(alignment: .leading, spacing: 12) {
                if !hasRelevantActivity {
                    Text("No assistant or tool activity was recorded for this run.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let run = object["run"], run != .null {
                    DisclosureGroup("Run metadata") {
                        OutputView(output: run)
                            .equatable()
                            .padding(.top, 8)
                    }
                }

                DisclosureGroup("Raw events · \(events.count)") {
                    if events.isEmpty {
                        Text("No events recorded.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(events.indices, id: \.self) { index in
                                InspectionEventView(event: events[index], index: index)
                                    .equatable()
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
        } else {
            OutputView(output: inspection)
                .equatable()
        }
    }
}

private struct InspectionEventView: View, Equatable {
    let event: JSONValue
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(event.objectValue?["type"]?.stringValue ?? "Event \(index + 1)")
                    .font(.callout.weight(.medium))
                if let sequence = event.objectValue?["seq"]?.numberText {
                    Text("#\(sequence)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            OutputView(output: event)
                .equatable()
        }
    }
}

private struct OutputView: View, Equatable {
    let output: JSONValue

    var body: some View {
        if let markdown = output.stringValue {
            MarkdownText(content: markdown)
        } else {
            ScrollView(.horizontal) {
                Text(output.prettyPrinted)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private extension JSONValue {
    var numberText: String? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value).map(String.init) ?? String(value)
    }
}

private struct MarkdownText: View {
    let content: String
    private var preferences = MarkdownPreferences()

    init(content: String) {
        self.content = content
    }

    var body: some View {
        Markdown(content)
            .markdownTheme(theme)
            .markdownImageProvider(NonLoadingMarkdownImageProvider())
            .markdownInlineImageProvider(NonLoadingMarkdownImageProvider())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineSpacing(1)
            .padding(CGFloat(preferences.pageMargin))
            .background(preferences.pageBackgroundColor)
    }

    private var theme: Theme {
        Theme.gitHub
            .text {
                FontFamily(preferences.bodyFont.markdownFamily)
                FontSize(CGFloat(preferences.bodySize))
                ForegroundColor(Color.primary)
                BackgroundColor(nil)
            }
            .code {
                FontFamily(preferences.codeFont.markdownFamily)
                FontSize(CGFloat(preferences.codeSize))
                BackgroundColor(Color.secondary.opacity(0.12))
            }
            .heading1 { configuration in
                markdownHeading(
                    configuration,
                    font: preferences.headingFont.markdownFamily,
                    size: preferences.heading1Size,
                    showsDivider: true
                )
            }
            .heading2 { configuration in
                markdownHeading(
                    configuration,
                    font: preferences.headingFont.markdownFamily,
                    size: preferences.heading2Size,
                    showsDivider: true
                )
            }
            .heading3 { configuration in
                markdownHeading(
                    configuration,
                    font: preferences.headingFont.markdownFamily,
                    size: preferences.heading3Size
                )
            }
            .heading4 { configuration in
                markdownHeading(
                    configuration,
                    font: preferences.headingFont.markdownFamily,
                    size: preferences.heading4Size
                )
            }
            .heading5 { configuration in
                markdownHeading(
                    configuration,
                    font: preferences.headingFont.markdownFamily,
                    size: preferences.heading5Size
                )
            }
            .heading6 { configuration in
                markdownHeading(
                    configuration,
                    font: preferences.headingFont.markdownFamily,
                    size: preferences.heading6Size
                )
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
                    .markdownMargin(top: 0, bottom: 10)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.225))
                        .markdownTextStyle {
                            FontFamily(preferences.codeFont.markdownFamily)
                            FontSize(CGFloat(preferences.codeSize))
                            BackgroundColor(nil)
                        }
                        .padding(16)
                }
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 0, bottom: 16)
            }
    }
}

@MainActor private func markdownHeading(
    _ configuration: BlockConfiguration,
    font: FontProperties.Family,
    size: Double,
    showsDivider: Bool = false
) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.125))
            .markdownMargin(top: 24, bottom: 16)
            .markdownTextStyle {
                FontFamily(font)
                FontWeight(.semibold)
                FontSize(CGFloat(size))
                BackgroundColor(nil)
            }
        if showsDivider {
            Divider()
        }
    }
}

private struct NonLoadingMarkdownImageProvider: ImageProvider, InlineImageProvider {
    func makeImage(url _: URL?) -> some View {
        Label("Image preview unavailable", systemImage: "photo")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    func image(with _: URL, label _: String) async throws -> Image {
        Image(systemName: "photo")
    }
}

private enum MarkdownFont: String, CaseIterable, Identifiable {
    case system
    case serif
    case rounded
    case monospaced

    var id: Self { self }

    var name: String {
        switch self {
        case .system: return "System Sans"
        case .serif: return "System Serif"
        case .rounded: return "System Rounded"
        case .monospaced: return "System Monospaced"
        }
    }

    var markdownFamily: FontProperties.Family {
        switch self {
        case .system: return .system(.default)
        case .serif: return .system(.serif)
        case .rounded: return .system(.rounded)
        case .monospaced: return .system(.monospaced)
        }
    }
}

private struct MarkdownPreferences: DynamicProperty {
    private enum Key {
        static let bodyFont = "markdown.appearance.bodyFont"
        static let headingFont = "markdown.appearance.headingFont"
        static let codeFont = "markdown.appearance.codeFont"
        static let bodySize = "markdown.appearance.bodySize"
        static let heading1Size = "markdown.appearance.heading1Size"
        static let heading2Size = "markdown.appearance.heading2Size"
        static let heading3Size = "markdown.appearance.heading3Size"
        static let heading4Size = "markdown.appearance.heading4Size"
        static let heading5Size = "markdown.appearance.heading5Size"
        static let heading6Size = "markdown.appearance.heading6Size"
        static let codeSize = "markdown.appearance.codeSize"
        static let pageMargin = "markdown.appearance.pageMargin"
        static let usesSystemBackground = "markdown.appearance.usesSystemBackground"
        static let backgroundRed = "markdown.appearance.backgroundRed"
        static let backgroundGreen = "markdown.appearance.backgroundGreen"
        static let backgroundBlue = "markdown.appearance.backgroundBlue"
    }

    @AppStorage(Key.bodyFont) var bodyFont: MarkdownFont = .system
    @AppStorage(Key.headingFont) var headingFont: MarkdownFont = .system
    @AppStorage(Key.codeFont) var codeFont: MarkdownFont = .monospaced
    @AppStorage(Key.bodySize) var bodySize = 16.0
    @AppStorage(Key.heading1Size) var heading1Size = 32.0
    @AppStorage(Key.heading2Size) var heading2Size = 24.0
    @AppStorage(Key.heading3Size) var heading3Size = 20.0
    @AppStorage(Key.heading4Size) var heading4Size = 16.0
    @AppStorage(Key.heading5Size) var heading5Size = 14.0
    @AppStorage(Key.heading6Size) var heading6Size = 14.0
    @AppStorage(Key.codeSize) var codeSize = 14.0
    @AppStorage(Key.pageMargin) var pageMargin = 0.0
    @AppStorage(Key.usesSystemBackground) var usesSystemBackground = true
    @AppStorage(Key.backgroundRed) var backgroundRed = 1.0
    @AppStorage(Key.backgroundGreen) var backgroundGreen = 1.0
    @AppStorage(Key.backgroundBlue) var backgroundBlue = 1.0

    var bodyFontBinding: Binding<MarkdownFont> { $bodyFont }
    var headingFontBinding: Binding<MarkdownFont> { $headingFont }
    var codeFontBinding: Binding<MarkdownFont> { $codeFont }
    var bodySizeBinding: Binding<Double> { $bodySize }
    var heading1SizeBinding: Binding<Double> { $heading1Size }
    var heading2SizeBinding: Binding<Double> { $heading2Size }
    var heading3SizeBinding: Binding<Double> { $heading3Size }
    var heading4SizeBinding: Binding<Double> { $heading4Size }
    var heading5SizeBinding: Binding<Double> { $heading5Size }
    var heading6SizeBinding: Binding<Double> { $heading6Size }
    var codeSizeBinding: Binding<Double> { $codeSize }
    var pageMarginBinding: Binding<Double> { $pageMargin }
    var usesSystemBackgroundBinding: Binding<Bool> { $usesSystemBackground }

    var pageBackgroundColor: Color {
        usesSystemBackground
            ? .clear
            : Color(red: backgroundRed, green: backgroundGreen, blue: backgroundBlue)
    }

    var customBackgroundColorBinding: Binding<Color> {
        Binding(
            get: { Color(red: backgroundRed, green: backgroundGreen, blue: backgroundBlue) },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
                backgroundRed = Double(converted.redComponent)
                backgroundGreen = Double(converted.greenComponent)
                backgroundBlue = Double(converted.blueComponent)
            }
        )
    }

    func reset() {
        bodyFont = .system
        headingFont = .system
        codeFont = .monospaced
        bodySize = 16
        heading1Size = 32
        heading2Size = 24
        heading3Size = 20
        heading4Size = 16
        heading5Size = 14
        heading6Size = 14
        codeSize = 14
        pageMargin = 0
        usesSystemBackground = true
        backgroundRed = 1
        backgroundGreen = 1
        backgroundBlue = 1
    }
}

struct MarkdownSettingsView: View {
    private var preferences = MarkdownPreferences()

    private static let preview = """
    # Field Notes

    ## A clearer reading experience

    Good typography lets the content lead. Adjust this page until **headings**, body copy, and `inline code` feel comfortable.

    ### Details matter

    > A generous margin gives every idea room to breathe.

    ```swift
    let response = await agent.run(goal)
    ```
    """

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Typefaces") {
                    fontPicker("Body", selection: preferences.bodyFontBinding)
                    fontPicker("Headings", selection: preferences.headingFontBinding)
                    fontPicker("Code", selection: preferences.codeFontBinding)
                }

                Section("Type Scale") {
                    sizeControl("Body", value: preferences.bodySizeBinding, range: 12...24)
                    sizeControl("Heading 1", value: preferences.heading1SizeBinding, range: 20...48)
                    sizeControl("Heading 2", value: preferences.heading2SizeBinding, range: 18...40)
                    sizeControl("Heading 3", value: preferences.heading3SizeBinding, range: 16...32)
                    sizeControl("Heading 4", value: preferences.heading4SizeBinding, range: 12...28)
                    sizeControl("Heading 5", value: preferences.heading5SizeBinding, range: 12...24)
                    sizeControl("Heading 6", value: preferences.heading6SizeBinding, range: 12...24)
                    sizeControl("Code", value: preferences.codeSizeBinding, range: 10...22)
                }

                Section("Page") {
                    sizeControl("Margin", value: preferences.pageMarginBinding, range: 0...64)
                    Toggle("Use the current surface background", isOn: preferences.usesSystemBackgroundBinding)
                    ColorPicker(
                        "Custom background",
                        selection: preferences.customBackgroundColorBinding,
                        supportsOpacity: false
                    )
                    .disabled(preferences.usesSystemBackground)
                }
            }
            .formStyle(.grouped)
            .frame(width: 430)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIVE PREVIEW")
                        .sectionLabel()
                    Text("Changes are saved automatically and applied to every markdown response.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    MarkdownText(content: Self.preview)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.separator)
                }

                HStack {
                    Spacer()
                    Button("Restore Defaults", action: preferences.reset)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 640)
    }

    private func fontPicker(_ title: String, selection: Binding<MarkdownFont>) -> some View {
        Picker(title, selection: selection) {
            ForEach(MarkdownFont.allCases) { font in
                Text(font.name).tag(font)
            }
        }
    }

    private func sizeControl(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: 1)
                    .frame(width: 150)
                Text("\(Int(value.wrappedValue)) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct InteractionCard: View {
    @EnvironmentObject private var model: AppModel
    let recordID: UUID
    let interaction: AppModel.Interaction
    @State private var clarificationAnswer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .help(toolHelp)
                    .accessibilityLabel(toolHelp)
                Text(title)
                    .font(.headline)
                Spacer()
                if interaction.isResolving { ProgressView().controlSize(.small) }
            }

            Text(interaction.message)
            interactionDetails

            if let error = interaction.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            actions
        }
        .padding(18)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
    }

    @ViewBuilder private var interactionDetails: some View {
        switch interaction.kind {
        case .approval(_, let input, _):
            if let input {
                Text(input.prettyPrinted)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            }
        case .clarification(let suggestions):
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { clarificationAnswer = suggestion }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch interaction.kind {
        case .approval:
            HStack {
                Spacer()
                Button("Reject", role: .destructive) { model.resolveApproval(false, for: recordID) }
                    .disabled(interaction.isResolving)
                Button("Approve") { model.resolveApproval(true, for: recordID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(interaction.isResolving)
            }
        case .clarification:
            HStack {
                TextField("Answer", text: $clarificationAnswer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.resolveClarification(clarificationAnswer, for: recordID) }
                Button("Send") { model.resolveClarification(clarificationAnswer, for: recordID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || interaction.isResolving)
            }
        }
    }

    private var title: String {
        switch interaction.kind {
        case .approval: return "Approval required"
        case .clarification: return "Input required"
        }
    }

    private var icon: String {
        switch interaction.kind {
        case .approval: return "checkmark.shield"
        case .clarification: return "questionmark.bubble"
        }
    }

    private var toolHelp: String {
        if case .approval(let toolName, _, _) = interaction.kind { return toolName ?? title }
        return title
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
        Label {
            Text(message).textSelection(.enabled)
        } icon: {
            Image(systemName: "xmark.octagon.fill")
        }
        .foregroundStyle(.red)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct FileRow: View {
    @EnvironmentObject private var model: AppModel
    let file: AppModel.RunFile

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.relativeDisplayPath(for: file))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.operation.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.fileExists(file) {
                Button("Show in Finder") { model.revealFile(file) }
                    .buttonStyle(.link)
            } else {
                Text("File no longer exists")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Show in Finder") { model.revealFile(file) }
                .disabled(!model.fileExists(file))
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
        .help(file.path)
    }
}

private struct RuntimeInspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Runtime") {
                LabeledContent("Status", value: model.status)
                if !model.agentName.isEmpty { LabeledContent("Agent", value: model.agentName) }
                if !model.agentId.isEmpty { LabeledContent("Agent ID", value: model.agentId) }
                if !model.runtimeMode.isEmpty { LabeledContent("Mode", value: model.runtimeMode) }
                if let info = model.runtimeInfoSnapshot {
                    LabeledContent("Initialized", value: info.initialized ? "Yes" : "No")
                    LabeledContent("Inference mode", value: info.inferenceMode ?? "Runtime default")
                    LabeledContent("Inference tier", value: info.inferenceTier ?? "Runtime default")
                    LabeledContent("Gateway", value: connectionDescription(info.connections?.gateway))
                    LabeledContent("SQLite", value: connectionDescription(info.connections?.sqlite))
                }
                if let error = model.runtimeInfoError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Button {
                    model.refreshRuntimeInfo()
                } label: {
                    if model.isRefreshingRuntimeInfo {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh Runtime Info", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!model.isConnected || model.isRefreshingRuntimeInfo)
            }

            Section("Workspace") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Root").font(.caption).foregroundStyle(.secondary)
                    Text(model.effectiveWorkspaceRoot.isEmpty ? model.workspacePath : model.effectiveWorkspaceRoot)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if !model.shellCwd.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shell directory").font(.caption).foregroundStyle(.secondary)
                        Text(model.shellCwd).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Button("Edit Configuration") { model.showConfiguration = true }
                    .disabled(!model.canEditSelectedRuntimeConfiguration)
            }

            if !model.registeredToolNames.isEmpty {
                Section("Tools") {
                    Text(model.registeredToolNames.joined(separator: ", "))
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            Section("Protocol Events") {
                if model.events.isEmpty {
                    Text("No events received.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.events.suffix(100).enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.vertical, 3)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func connectionDescription(_ connection: RuntimeInfo.Connection?) -> String {
        guard let connection else { return "Unknown" }
        return connection.configured ? connection.state : "Not configured"
    }
}

private struct ConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workspace Configuration").font(.title2.weight(.semibold))
                    Text("The runtime resolves settings and the selected agent from this workspace.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            Form {
                if !model.isConnected && !model.isBusy {
                    Section("Initialization Error") {
                        Label(model.status, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                Section("Workspace") {
                    pathRow("Working directory", text: $model.workspacePath, action: model.chooseWorkspace)
                    Text("This path is sent as runtime/initialize cwd and used as the agent runtime process directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Configuration Overrides") {
                    pathRow("Runtime Settings", text: $model.settingsConfigPath, action: model.chooseSettings)
                    pathRow("Agent Profile", text: $model.agentConfigPath, action: model.chooseAgent)
                    HStack {
                        Button("Reload Values", action: model.reloadSettingsConfiguration)
                            .disabled(model.settingsConfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        if let error = model.settingsConfigurationError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                    }
                    .font(.caption)
                    Text("The app loads supported non-secret values from the selected settings file. Other settings remain runtime-managed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Runtime") {
                    Picker("Mode", selection: $model.configuredRuntimeMode) {
                        Text("Settings or runtime default").tag("")
                        Text("Memory").tag("memory")
                        Text("SQLite").tag("sqlite")
                        Text("Postgres").tag("postgres")
                    }
                    Picker("Provider", selection: $model.configuredProvider) {
                        Text("Settings or agent default").tag("")
                        Text("OpenRouter").tag("openrouter")
                        Text("Ollama").tag("ollama")
                        Text("Mistral").tag("mistral")
                        Text("Mesh").tag("mesh")
                    }
                    TextField("Model", text: $model.configuredModel, prompt: Text("Settings or agent default"))
                        .font(.body.monospaced())
                    Picker("Inference mode", selection: Binding(
                        get: { model.configuredInferenceMode },
                        set: { mode in model.selectInferenceMode(mode) }
                    )) {
                        Text("Runtime default").tag("")
                        Text("Gateway").tag("gateway")
                        Text("Local").tag("local")
                        Text("Bring your own key").tag("byok")
                    }
                    Picker("Inference tier", selection: $model.configuredInferenceTier) {
                        Text("Runtime default").tag("")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                        Text("Extra high").tag("xtra-high")
                    }
                    .disabled(model.configuredInferenceMode != "gateway")
                    TextField("Gateway URL", text: $model.configuredGatewayURL, prompt: Text("wss://gateway.example.com/rpc"))
                        .font(.body.monospaced())
                    Toggle("Require run permit", isOn: $model.configuredRequireRunPermit)
                    Text("A gateway URL is required for gateway inference or required run permits. Inference tier is sent only in gateway mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Gateway Access Token") {
                    SecureField("Access token", text: $model.accessTokenDraft)
                        .textContentType(.password)
                    HStack {
                        Button(model.accessTokenUpdateFailed ? "Retry" : "Apply Token") {
                            model.updateAccessToken()
                        }
                        .disabled(model.accessTokenDraft.isEmpty || model.isUpdatingAccessToken)
                        Button("Clear Entry", action: model.clearAccessToken)
                            .disabled(model.accessTokenDraft.isEmpty || model.isUpdatingAccessToken)
                        if model.isUpdatingAccessToken {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let message = model.accessTokenMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(model.accessTokenUpdateFailed ? .red : .secondary)
                    }
                    Text("The token is kept only in app memory and sent with auth/updateAccessToken after negotiation. Clearing this field does not revoke a token already sent; restart the runtime to clear it. You can instead launch the app with ADAPTIVE_AGENT_ACCESS_TOKEN set in its environment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Interaction") {
                    Picker("Approval", selection: $model.configuredApprovalMode) {
                        Text("Auto").tag("auto")
                        Text("Manual").tag("manual")
                        Text("Reject").tag("reject")
                    }
                    Picker("Clarification", selection: $model.configuredClarificationMode) {
                        Text("Interactive").tag("interactive")
                        Text("Fail").tag("fail")
                    }
                    Text("These values are sent explicitly when the runtime initializes. Manual approval and interactive clarification are used when the settings file does not specify them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if model.selectedSessionHasActiveWork {
                    Label("Applying changes interrupts active runs.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(model.isConnected ? "Restart Runtime" : "Initialize", action: model.applyConfiguration)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.workspacePath.isEmpty || model.isBusy)
            }
            .padding(18)
        }
        .frame(width: 680, height: 640)
    }

    private func pathRow(_ title: String, text: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack {
            TextField(title, text: text)
                .font(.body.monospaced())
            Button("Choose…", action: action)
        }
    }
}

private extension View {
    func sectionLabel() -> some View {
        font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }
}
