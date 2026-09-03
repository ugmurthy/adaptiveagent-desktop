import AppKit
import MarkdownUI
import SwiftUI

private enum SidebarItemID: Hashable {
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

    var body: some View {
        NavigationSplitView {
            runSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 680)
        .toolbar { toolbar }
        .inspector(isPresented: $inspectorPresented) {
            RuntimeInspectorView()
                .environmentObject(model)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
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
        .onChange(of: model.selectedTabID) { _, _ in synchronizeSidebarSelection() }
    }

    private var runSidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                if !activeRuns.isEmpty {
                    Section("Active") {
                        ForEach(activeRuns) { record in
                            RunRow(record: record).tag(SidebarItemID.live(record.id))
                        }
                    }
                }

                Section {
                    HistorySearchField(
                        text: historySearchBinding,
                        isSearching: model.isSearchingHistory
                    )
                    .listRowSeparator(.hidden)

                    ForEach(recentRuns) { record in
                        RunRow(record: record)
                            .tag(SidebarItemID.live(record.id))
                            .contextMenu {
                                if let rootRunId = model.deletableRootRunID(for: record.id) {
                                    deleteRunButton(rootRunId: rootRunId)
                                }
                            }
                    }

                    ForEach(visibleTraceHistory) { item in
                        HistoryRunRow(item: item, isDeleting: model.deletingRunIDs.contains(item.rootRunId))
                            .tag(SidebarItemID.history(item.rootRunId))
                            .contextMenu {
                                if item.allowsDeletion {
                                    deleteRunButton(rootRunId: item.rootRunId)
                                }
                            }
                    }

                    historyStatusRow
                } header: {
                    HStack {
                        Text("History")
                        Spacer()
                        Button(action: model.refreshHistory) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh run history")
                    }
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
                Text("\(activeRuns.count + recentRuns.count + visibleTraceHistory.count)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            RunTabsBar()
                .environmentObject(model)
            Divider()
            Group {
                if let tab = model.selectedTab,
                   let recordID = tab.selectedRunID,
                   let record = model.runs.first(where: { $0.id == recordID }) {
                    RunDetailView(record: record, tabID: tab.id)
                        .environmentObject(model)
                } else if let tab = model.selectedTab,
                          let rootRunId = tab.selectedHistoryRunID,
                          let item = model.historyItem(rootRunId: rootRunId) {
                    HistoricalRunDetailView(item: item, tabID: tab.id)
                        .environmentObject(model)
                } else if let tab = model.selectedTab, model.isConnected {
                    NewRequestView(tabID: tab.id)
                        .environmentObject(model)
                        .id(tab.id)
                } else {
                    ConnectionStateView()
                        .environmentObject(model)
                }
            }
            .id(model.selectedTabID)
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
            Menu {
                Button("New Run", systemImage: "play.fill", action: model.newRun)
                    .keyboardShortcut("n")
                Button("New Chat", systemImage: "bubble.left.and.bubble.right.fill", action: model.newChat)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            } label: {
                Label("New", systemImage: "plus")
            }
            .disabled(!model.isConnected)

            Menu {
                Button("Markdown Appearance…", systemImage: "textformat") {
                    openSettings()
                }
                Divider()
                Button("Workspace Configuration…", systemImage: "externaldrive") {
                    model.showConfiguration = true
                }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Appearance and workspace settings")

            Button {
                inspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show runtime inspector")

            Button(action: model.requestQuit) {
                Label("Quit", systemImage: "power")
            }
            .help("Quit AdaptiveAgent Desktop (⌘Q)")
        }
    }

    private var activeRuns: [AppModel.RunRecord] { model.runs.filter { $0.status.isActive } }
    private var recentRuns: [AppModel.RunRecord] {
        let query = model.historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.runs.filter { record in
            guard !record.status.isActive else { return false }
            guard !query.isEmpty else { return true }
            return [record.title, record.latestRunId ?? "", record.status.rawValue, record.kind.rawValue]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var visibleTraceHistory: [AppModel.HistoryItem] {
        let liveIDs = Set(model.runs.flatMap(\.runIds))
        let source = historySearchIsEmpty ? model.historyItems : model.historySearchResults
        return source.filter { !liveIDs.contains($0.rootRunId) }
    }

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
        } else if !historySearchIsEmpty, recentRuns.isEmpty, visibleTraceHistory.isEmpty, !model.isSearchingHistory {
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
                if historySearchIsEmpty, !model.historyItems.isEmpty {
                    Button("Load Older", action: model.loadOlderHistory)
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var sidebarSelection: Binding<Set<SidebarItemID>> {
        Binding(
            get: { sidebarSelections },
            set: { selections in
                let newlySelected = selections.subtracting(sidebarSelections)
                sidebarSelections = selections
                guard let selection = newlySelected.first else { return }
                switch selection {
                case .live(let recordID): model.openRunTab(recordID)
                case .history(let rootRunId): model.openHistoryTab(rootRunId)
                }
            }
        )
    }

    private var selectedDeletionRunIDs: Set<String> {
        Set(sidebarSelections.compactMap { item in
            switch item {
            case .live(let recordID):
                return model.deletableRootRunID(for: recordID)
            case .history(let rootRunId):
                guard model.historyItem(rootRunId: rootRunId)?.allowsDeletion != false else { return nil }
                return rootRunId
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
}

private struct RunTabsBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(model.tabs) { tab in
                        RunTabCell(
                            tab: tab,
                            record: tab.selectedRunID.flatMap { recordID in
                                model.runs.first { $0.id == recordID }
                            },
                            historyItem: tab.selectedHistoryRunID.flatMap { rootRunId in
                                model.historyItem(rootRunId: rootRunId)
                            },
                            isSelected: model.selectedTabID == tab.id,
                            select: { model.selectTab(tab.id) },
                            close: { model.closeTab(tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Divider()
                .frame(height: 22)

            Button(action: model.newRun) {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!model.isConnected)
            .help("Open a new tab")
            .accessibilityLabel("New tab")
            .padding(.horizontal, 6)
        }
        .frame(height: 40)
        .background(.bar)
    }
}

private struct RunTabCell: View {
    let tab: AppModel.RunTab
    let record: AppModel.RunRecord?
    let historyItem: AppModel.HistoryItem?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Image(systemName: record?.kind.systemImage ?? historyItem?.systemImage ?? tab.draftKind.systemImage)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Text(record?.title ?? historyItem?.title ?? "New \(tab.draftKind.rawValue)")
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let record {
                        RunTabStatusBadge(record: record)
                    } else if let historyItem {
                        Text(historyItem.status.capitalized)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
            .accessibilityLabel("Close \(record?.title ?? historyItem?.title ?? "New \(tab.draftKind.rawValue)") tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(minWidth: 120, maxWidth: 280, minHeight: 28)
        .background(
            isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.primary.opacity(0.14) : Color.clear)
        }
    }
}

private struct RunTabStatusBadge: View {
    let record: AppModel.RunRecord

    var body: some View {
        HStack(spacing: 4) {
            if record.hasRequestInFlight, record.interaction == nil {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(label)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.11), in: Capsule())
    }

    private var label: String {
        switch record.status {
        case .waitingForApproval: return "Approval"
        case .waitingForClarification: return "Question"
        default: return record.status.rawValue
        }
    }

    private var symbol: String {
        switch record.status {
        case .queued, .running: return "circle.fill"
        case .waitingForApproval: return "hand.raised.fill"
        case .waitingForClarification: return "questionmark.bubble.fill"
        case .succeeded: return "checkmark"
        case .failed: return "exclamationmark"
        case .unknown, .interrupted: return "minus"
        }
    }

    private var color: Color {
        switch record.status {
        case .queued, .running: return .accentColor
        case .waitingForApproval, .waitingForClarification: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .unknown, .interrupted: return .secondary
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

private struct HistoryRunRow: View {
    let item: AppModel.HistoryItem
    let isDeleting: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isDeleting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            } else {
                Image(systemName: item.systemImage)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(2)
                HStack(spacing: 5) {
                    Text(item.status.capitalized)
                    Text("·")
                    Text(Self.relativeDate(item.startedAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.status), started \(item.startedAt)")
    }

    private var statusColor: Color {
        switch item.status {
        case "queued", "planning", "running", "awaiting_subagent": .accentColor
        case "awaiting_approval", "clarification_requested": .orange
        case "succeeded": .green
        case "failed": .red
        default: .secondary
        }
    }

    private static func relativeDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }
}

private extension AppModel.HistoryItem {
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
        VStack(spacing: 26) {
            Spacer()
            VStack(spacing: 9) {
                Image(systemName: draftKind == .run ? "sparkles" : "bubble.left.and.bubble.right")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
                Text(draftKind == .run ? "What should the agent do?" : "Start a conversation")
                    .font(.title2.weight(.semibold))
                Text(workspaceSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(spacing: 14) {
                Picker("Request type", selection: draftKindBinding) {
                    ForEach(AppModel.RunKind.allCases) { kind in
                        Label(kind.rawValue, systemImage: kind.systemImage).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .stroke(.separator, lineWidth: 1)
                    TextEditor(text: draftTextBinding)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                    if draftText.isEmpty {
                        Text(draftKind == .run ? "Describe a goal…" : "Write a message…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 17)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: 700, minHeight: 150, maxHeight: 230)

                if draftKind == .run {
                    AttachmentDraftView(tabID: tabID)
                        .environmentObject(model)
                        .frame(maxWidth: 700)
                }

                HStack {
                    if model.isWaitingForRunIdentity {
                        ProgressView()
                            .controlSize(.small)
                        Text("Creating run…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    DictationButton(text: draftTextBinding, controller: dictation)
                    Button(draftKind == .run ? "Start Run" : "Start Chat", action: submitDraft)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(
                            draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.isWaitingForRunIdentity
                                || (model.tab(withID: tabID)?.isImportingAttachments ?? false)
                                || (model.tab(withID: tabID)?.isSubmittingDraft ?? false)
                        )
                }
                .frame(maxWidth: 700)
            }

            existingRunActions
            Spacer()
        }
        .padding(36)
    }

    private var existingRunActions: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Existing Run")
                    .font(.callout.weight(.medium))
                Text("Enter a run ID to inspect or manage a run available to this runtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            TextField("Run ID", text: $existingRunID)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(width: 250)
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

    private var workspaceSummary: String {
        let path = model.effectiveWorkspaceRoot.isEmpty ? model.workspacePath : model.effectiveWorkspaceRoot
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var draftKind: AppModel.RunKind {
        model.tab(withID: tabID)?.draftKind ?? .run
    }

    private var draftText: String {
        model.tab(withID: tabID)?.draftText ?? ""
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
            HStack(spacing: 8) {
                ForEach(AttachmentKind.allCases, id: \.self) { kind in
                    Button("Add \(kind.displayName)", systemImage: kind.systemImage) {
                        model.chooseAttachments(kind: kind, forTab: tabID)
                    }
                    .disabled(
                        !model.attachmentEnabled(for: kind)
                            || (tab?.isImportingAttachments ?? false)
                            || (tab?.draftAttachments.count ?? 0) >= maximumAttachmentCount
                    )
                    .help(
                        model.attachmentUnavailableReason(for: kind)
                            ?? "Add \(kind.displayName.lowercased()) attachments to this run"
                    )
                }

                if tab?.isImportingAttachments == true {
                    ProgressView().controlSize(.small)
                    Text("Importing secure snapshots…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(limitSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

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

    private var maximumAttachmentCount: Int {
        min(model.attachmentCapabilities?.maxAttachmentCount ?? AttachmentStore.maximumAttachmentCount,
            AttachmentStore.maximumAttachmentCount)
    }

    private var limitSummary: String {
        guard let capabilities = model.attachmentCapabilities else {
            return "Connect to see attachment availability"
        }
        let fileSize = Self.formattedSize(min(capabilities.maxFileBytes, AttachmentStore.maximumFileBytes))
        let totalSize = Self.formattedSize(min(capabilities.maxSubmissionBytes, AttachmentStore.maximumSubmissionBytes))
        return "\(fileSize) each · \(maximumAttachmentCount) attachments · \(totalSize) total"
    }
}

private struct ConnectionStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            if model.isBusy {
                ProgressView()
                    .controlSize(.large)
                Text(model.status).font(.headline)
                Text(model.workspacePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                ContentUnavailableView {
                    Label("Runtime Not Ready", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(model.status)
                } actions: {
                    HStack {
                        Button("Configure") { model.showConfiguration = true }
                        Button("Try Again", action: model.connect)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
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
                        Text(item.rootRunId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Button("Open in Runtime", systemImage: "arrow.up.forward.app") {
                    model.openHistoryInRuntime(item.rootRunId)
                }
                .disabled(!model.isConnected)
            }
            .padding(.horizontal, 22)
            .frame(height: 66)

            Divider()

            if let report = model.historyReports[item.rootRunId] {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        summary(report)
                        if !toolActivities(report).isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("TIMELINE").sectionLabel()
                                CompactToolActivityView(
                                    activities: toolActivities(report),
                                    isExpanded: activityExpandedBinding
                                )
                            }
                        }
                        if let runTree = report.runTree, !runTree.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("RUN TREE").sectionLabel()
                                ForEach(runTree) { run in
                                    HStack {
                                        Text(String(repeating: "  ", count: run.depth) + (run.delegateName ?? "Root run"))
                                        Spacer()
                                        Text(run.status ?? "unknown").foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
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
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(34)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else if let error = model.historyReportErrors[item.rootRunId] {
                ContentUnavailableView {
                    Label("Unable to Load History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { model.retryHistoryReport(item.rootRunId) }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading historical trace…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func summary(_ report: TraceReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SUMMARY").sectionLabel()
            Text(report.summary.status.capitalized).font(.title3.weight(.semibold))
            Text(report.summary.reason).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Started").foregroundStyle(.secondary)
                    Text(item.startedAt).textSelection(.enabled)
                }
                GridRow {
                    Text("Tokens").foregroundStyle(.secondary)
                    Text("\(report.usage.total.totalTokens)").monospacedDigit()
                }
                GridRow {
                    Text("Estimated cost").foregroundStyle(.secondary)
                    Text(report.usage.total.estimatedCostUSD, format: .currency(code: "USD"))
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
            guard let toolName = entry.toolName else { return nil }
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
                toolState: state
            )
        }
    }

    private var activityExpandedBinding: Binding<Bool> {
        Binding(
            get: { model.tab(withID: tabID)?.activityExpanded ?? false },
            set: { model.setActivityExpanded($0, forTab: tabID) }
        )
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
                        } else if record.kind == .chat {
                            chatTranscript
                            RunActivityFeed(
                                record: record,
                                agentName: model.agentName,
                                isExpanded: activityExpandedBinding
                            )
                                .id("run-activity")
                        } else {
                            RunActivityFeed(
                                record: record,
                                agentName: model.agentName,
                                isExpanded: activityExpandedBinding
                            )
                                .id("run-activity")
                            runOutput
                                .id("run-output")
                        }

                        if let interaction = record.interaction {
                            InteractionCard(recordID: record.id, interaction: interaction)
                                .environmentObject(model)
                                .id("interaction-\(record.id.uuidString)")
                        }

                        if let error = record.errorMessage {
                            ErrorCard(message: error)
                                .id("error")
                        }

                        if let error = record.auxiliaryErrorMessage {
                            ErrorCard(message: error)
                                .id("auxiliary-error")
                        }

                        if !record.files.isEmpty {
                            FilesChangedView(record: record)
                                .environmentObject(model)
                                .id("files")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("run-bottom")
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollPosition(id: scrollPositionBinding, anchor: .center)
                .simultaneousGesture(DragGesture().onChanged { _ in
                    model.setFollowLive(false, forTab: tabID)
                })
                .onChange(of: record.activities) { oldActivities, activities in
                    let oldNarrativeCount = oldActivities.filter { $0.kind == .assistant }.count
                    let newNarrativeCount = activities.filter { $0.kind == .assistant }.count
                    guard detailMode == .results, newNarrativeCount > oldNarrativeCount else { return }
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

    @ViewBuilder private var inspectionOutput: some View {
        if let inspection = record.inspection {
            VStack(alignment: .leading, spacing: 12) {
                Text("INSPECTION").sectionLabel()
                RunActivityFeed(
                    record: record,
                    agentName: model.agentName,
                    isExpanded: activityExpandedBinding
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

    @ViewBuilder private var chatTranscript: some View {
        ForEach(record.chatMessages) { message in
            Group {
                if message.role == .user {
                    HStack {
                        Spacer(minLength: 80)
                        Text(message.content)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.agentName.isEmpty ? "AGENT" : model.agentName.uppercased())
                            .sectionLabel()
                        MarkdownText(content: message.content)
                    }
                }
            }
            .id("message-\(message.id.uuidString)")
        }
    }

    private var chatComposer: some View {
        ProminentRunComposer(
            title: "Message \(model.agentName.isEmpty ? "agent" : model.agentName)",
            placeholder: "Continue the conversation…",
            helper: "Send another message in this conversation.",
            actionTitle: "Send",
            systemImage: "bubble.left.fill",
            text: chatMessageBinding,
            isPending: record.isRequestInFlight,
            errorMessage: record.errorMessage,
            accessory: AnyView(DictationButton(text: chatMessageBinding, controller: dictation)),
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

    private var activityExpandedBinding: Binding<Bool> {
        Binding(
            get: { model.tab(withID: tabID)?.activityExpanded ?? false },
            set: { model.setActivityExpanded($0, forTab: tabID) }
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
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
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

private struct RunActivityFeed: View {
    let record: AppModel.RunRecord
    let agentName: String
    @Binding var isExpanded: Bool

    private var isThinking: Bool {
        record.interaction == nil
            && (record.status == .queued || record.status == .running || record.isRequestInFlight)
    }

    private var showsDuration: Bool {
        !record.status.isActive && record.activityStartedAt != nil && record.activityFinishedAt != nil
    }

    private var assistantActivities: [AppModel.RunActivity] {
        record.activities.filter { $0.kind == .assistant }
    }

    private var toolActivities: [AppModel.RunActivity] {
        record.activities.filter { $0.kind == .tool }
    }

    var body: some View {
        if !record.activities.isEmpty || isThinking || showsDuration {
            VStack(alignment: .leading, spacing: 8) {
                Text("ACTIVITY").sectionLabel()
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(assistantActivities) { activity in
                        RunActivityRow(activity: activity, agentName: agentName)
                            .id(activity.id)
                    }
                    if !toolActivities.isEmpty {
                        CompactToolActivityView(activities: toolActivities, isExpanded: $isExpanded)
                    }
                    if isThinking {
                        ThinkingActivityRow(startedAt: record.activityStartedAt)
                            .id("thinking")
                    } else if showsDuration,
                              let startedAt = record.activityStartedAt,
                              let finishedAt = record.activityFinishedAt {
                        FinishedActivityRow(
                            status: record.status,
                            duration: max(0, finishedAt.timeIntervalSince(startedAt))
                        )
                    }
                }
            }
        }
    }
}

private struct CompactToolActivityView: View {
    let activities: [AppModel.RunActivity]
    @Binding var isExpanded: Bool

    private var latest: AppModel.RunActivity { activities[activities.count - 1] }
    private var completedCount: Int {
        activities.filter { activity in
            switch activity.toolState {
            case .succeeded, .failed, .skipped: true
            case .awaitingApproval, .running, nil: false
            }
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Activity")
                        .font(.callout.weight(.semibold))
                    Text("\(completedCount) of \(activities.count) complete")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Divider().frame(height: 16)
                    Text(latest.toolName ?? "tool")
                        .font(.caption.monospaced().weight(.medium))
                        .lineLimit(1)
                    if let detail = latest.detail {
                        Text("· \(detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if latest.toolState == .running { ProgressView().controlSize(.mini) }
                    Text(stateLabel(latest.toolState))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateColor(latest.toolState))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .keyboardShortcut("a", modifiers: [.option, .command])

            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(activities) { ToolActivityRow(activity: $0) }
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
        }
    }

    private func stateLabel(_ state: AppModel.RunActivity.ToolState?) -> String {
        switch state {
        case .awaitingApproval: "Approval"
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case nil: ""
        }
    }

    private func stateColor(_ state: AppModel.RunActivity.ToolState?) -> Color {
        switch state {
        case .awaitingApproval: .orange
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        case .skipped, nil: .secondary
        }
    }
}

private struct RunActivityRow: View {
    let activity: AppModel.RunActivity
    let agentName: String

    var body: some View {
        switch activity.kind {
        case .assistant:
            if let content = activity.content {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(agentName.isEmpty ? "AGENT" : agentName.uppercased())
                            .sectionLabel()
                        if activity.isFinalAssistantMessage {
                            Text("FINAL")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.65), in: Capsule())
                        }
                    }
                    MarkdownText(content: content)
                }
            }
        case .tool:
            ToolActivityRow(activity: activity)
        }
    }
}

private struct ToolActivityRow: View {
    let activity: AppModel.RunActivity

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toolSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(stateColor)
                .frame(width: 24, height: 24)
                .background(stateColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            Text(activity.toolName ?? "tool")
                .font(.callout.monospaced().weight(.medium))
                .lineLimit(1)
            if let detail = activity.detail {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)
            if activity.toolState == .running {
                ProgressView().controlSize(.mini)
            }
            Text(stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(stateColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var toolSymbol: String {
        switch activity.toolName {
        case "web_search": return "magnifyingglass"
        case "read_web_page", "fetch_page": return "globe"
        case "read_file": return "doc.text.magnifyingglass"
        case "write_file": return "square.and.pencil"
        case "edit_file": return "pencil.line"
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

    private var stateColor: Color {
        switch activity.toolState {
        case .awaitingApproval: return .orange
        case .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .skipped, nil: return .secondary
        }
    }
}

private struct ThinkingActivityRow: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Thinking…")
                    .foregroundStyle(.secondary)
                if let startedAt {
                    Text(Self.durationText(max(0, context.date.timeIntervalSince(startedAt))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
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

    var body: some View {
        Label {
            Text("\(label) \(ThinkingActivityRow.durationText(duration))")
                .font(.caption.monospacedDigit())
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        status == .succeeded ? "Completed in" : "Stopped after"
    }

    private var symbol: String {
        switch status {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "stop.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .succeeded: return .green
        case .failed: return .red
        default: return .secondary
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
                    .foregroundStyle(.orange)
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
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35)))
    }

    @ViewBuilder private var interactionDetails: some View {
        switch interaction.kind {
        case .approval(let toolName, let input, _):
            if let toolName {
                LabeledContent("Tool") {
                    Text(toolName).font(.body.monospaced())
                }
            }
            if let input {
                ScrollView(.horizontal) {
                    Text(input.prettyPrinted)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
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

private struct FilesChangedView: View {
    @EnvironmentObject private var model: AppModel
    let record: AppModel.RunRecord

    private var primaryFiles: [AppModel.RunFile] { record.files.filter { !$0.isSupportFile } }
    private var supportFiles: [AppModel.RunFile] { record.files.filter(\.isSupportFile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FILES CHANGED · \(primaryFiles.count)").sectionLabel()
                Spacer()
                if record.files.filter({ model.fileExists($0) }).count > 1 {
                    Button("Show All in Finder") { model.revealAllFiles(for: record.id) }
                        .buttonStyle(.link)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(primaryFiles.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { Divider() }
                    FileRow(file: file)
                        .environmentObject(model)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            if !supportFiles.isEmpty {
                DisclosureGroup("Generated support files (\(supportFiles.count))") {
                    VStack(spacing: 0) {
                        ForEach(Array(supportFiles.enumerated()), id: \.element.id) { index, file in
                            if index > 0 { Divider() }
                            FileRow(file: file)
                                .environmentObject(model)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }

            Text("Tracks successful write_file and edit_file operations. Shell commands may change additional files.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct FileRow: View {
    @EnvironmentObject private var model: AppModel
    let file: AppModel.RunFile

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.text")
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
                    pathRow("Settings", text: $model.settingsConfigPath, action: model.chooseSettings)
                    pathRow("Agent", text: $model.agentConfigPath, action: model.chooseAgent)
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
                if model.hasActiveWork {
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
