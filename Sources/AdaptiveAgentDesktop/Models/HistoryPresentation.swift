import Foundation

extension AppModel {
    private static let historyDateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let historyDateFormatter = ISO8601DateFormatter()

    struct HistoryRunSnapshot: Equatable {
        let id: UUID
        let runtimeSessionID: UUID?
        let kind: RunKind
        let title: String
        let sessionId: String?
        let runIds: [String]
        let status: RunStatus
        let activityStartedAt: Date?
        let isRequestInFlight: Bool
    }

    struct HistoryDetail: Equatable {
        let output: JSONValue?
        let usage: TraceUsageTotals?
        let files: [RunFile]
        let activities: [RunActivity]
    }

    struct HistoryNode: Identifiable {
        let id: String
        let label: String
        let item: HistoryItem?
        let rootRunId: String?
        let newest: Date
        var children: [HistoryNode]

        var runCount: Int {
            (item == nil ? 0 : 1) + children.reduce(0) { $0 + $1.runCount }
        }

        var sessionId: String? {
            item?.sessionId ?? children.lazy.compactMap(\.sessionId).first
        }

        var representedRootRunIds: Set<String> {
            let representedRoot = rootRunId ?? item?.rootRunId
            return children.reduce(into: representedRoot.map { Set([$0]) } ?? []) {
                $0.formUnion($1.representedRootRunIds)
            }
        }
    }

    struct HistorySection: Identifiable {
        let id: String
        let title: String
        let nodes: [HistoryNode]
    }

    enum HistoryStatusFilter: String, CaseIterable, Identifiable {
        case blocked, waiting, failed

        var id: String { rawValue }
    }

    struct HistoryFilters: Equatable {
        var statuses: Set<HistoryStatusFilter> = []
        var kinds: Set<RunKind> = []
        var hasSession: Bool? = nil

        var isActive: Bool { !statuses.isEmpty || !kinds.isEmpty || hasSession != nil }
    }

    static func historyDate(_ value: String) -> Date {
        historyDateFormatterWithFractionalSeconds.date(from: value)
            ?? historyDateFormatter.date(from: value)
            ?? .distantPast
    }

    static func historyNewestFirst(_ lhs: HistoryItem, _ rhs: HistoryItem) -> Bool {
        let left = historyDate(lhs.startedAt), right = historyDate(rhs.startedAt)
        return left == right ? lhs.id < rhs.id : left > right
    }

    var allHistoryItems: [HistoryItem] {
        if cachedHistoryItemsRevision == historyPresentationRevision {
            return cachedAllHistoryItems
        }
        let local = runs.filter { !$0.status.isActive && !$0.isRequestInFlight }.flatMap { record in
            record.runIds.map { runId in
                HistoryItem(
                    rootRunId: historyRootRunId(for: runId), runId: runId,
                    runtimeSessionID: record.runtimeSessionID, sessionId: record.sessionId,
                    sessionTitle: record.authoritativeSessionTitle, sessionName: record.sessionName,
                    title: record.runGoal ?? record.title, status: record.status.rawValue,
                    startedAt: record.activityStartedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                    completedAt: nil, type: record.kind.rawValue
                )
            }
        }
        let known = mergeHistory(local, historyItems + historySearchResults)
        let knownByID = Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0) })
        let ownerByRoot = Dictionary(grouping: known, by: \.rootRunId).compactMapValues(\.first)
        var items = known
        for (root, report) in historyReports {
            guard let owner = ownerByRoot[root] else { continue }
            for run in report.runTree ?? [] {
                let existing = knownByID[run.runId]
                items.append(HistoryItem(
                    rootRunId: root, runId: run.runId, parentRunId: run.parentRunId,
                    runtimeSessionID: owner.runtimeSessionID, sessionId: owner.sessionId,
                    title: existing?.title ?? run.delegateName ?? "Run \(run.runId)",
                    status: run.status ?? existing?.status ?? "unknown",
                    startedAt: run.createdAt ?? existing?.startedAt ?? "",
                    completedAt: run.completedAt, type: existing?.type ?? "run"
                ))
            }
        }
        let active = Set(runs.filter { $0.status.isActive || $0.isRequestInFlight }.flatMap(\.runIds))
        cachedAllHistoryItems = mergeHistory([], items)
            .filter { !active.contains($0.id) && !active.contains($0.rootRunId) }
        cachedHistoryItemsRevision = historyPresentationRevision
        return cachedAllHistoryItems
    }

    var historyTree: [HistoryNode] {
        let query = historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if cachedHistoryTreeRevision != historyPresentationRevision || cachedHistoryTreeQuery != query {
            cachedHistoryTree = Self.historyTree(items: allHistoryItems, query: query)
            cachedHistoryTreeRevision = historyPresentationRevision
            cachedHistoryTreeQuery = query
        }
        return cachedHistoryTree
    }

    static func historyTree(items: [HistoryItem], query: String = "") -> [HistoryNode] {
        func sorted(_ nodes: [HistoryNode]) -> [HistoryNode] {
            nodes.sorted { $0.newest == $1.newest ? $0.id < $1.id : $0.newest > $1.newest }
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var groups: [String: [HistoryNode]] = [:]
        var sessionTitles: [String: (date: Date, id: String, rootID: String, title: String)] = [:]
        for (rootID, runs) in Dictionary(grouping: items, by: \.rootRunId) {
            guard query.isEmpty || runs.contains(where: { item in
                [item.title, item.sessionTitle ?? "", item.id, rootID, item.sessionId ?? "", item.status, item.type]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }) else { continue }
            let ids = Set(runs.map(\.id))
            let dates = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, historyDate($0.startedAt)) })
            var childrenByParent: [String: [HistoryItem]] = [:]
            for item in runs {
                if let parent = item.parentRunId, ids.contains(parent) {
                    childrenByParent[parent, default: []].append(item)
                }
            }
            for parent in childrenByParent.keys {
                childrenByParent[parent]?.sort {
                    let left = dates[$0.id] ?? .distantPast
                    let right = dates[$1.id] ?? .distantPast
                    return left == right ? $0.id < $1.id : left > right
                }
            }
            var visited: Set<String> = []
            func node(_ item: HistoryItem) -> HistoryNode {
                visited.insert(item.id)
                let children = (childrenByParent[item.id] ?? [])
                    .filter { !visited.contains($0.id) }.map(node)
                return HistoryNode(
                    id: "run:\(item.id)", label: item.title, item: item, rootRunId: rootID,
                    newest: max(dates[item.id] ?? .distantPast, children.map(\.newest).max() ?? .distantPast),
                    children: children
                )
            }
            var roots = runs.filter { $0.parentRunId == nil || !ids.contains($0.parentRunId!) }.map(node)
            // Preserve disconnected/cyclic evidence without infinitely recursing or dropping a run.
            for item in runs where !visited.contains(item.id) { roots.append(node(item)) }
            roots.sort {
                guard let lhs = $0.item, let rhs = $1.item else { return $0.id < $1.id }
                return historyNewestFirst(lhs, rhs)
            }
            let newest = roots.map(\.newest).max() ?? .distantPast
            let root: HistoryNode
            if roots.count == 1 {
                root = roots[0]
            } else {
                // Multiple in-group roots need a wrapper so no persisted run is dropped.
                root = HistoryNode(id: "root:\(rootID)", label: "Root \(rootID)", item: nil,
                                   rootRunId: rootID, newest: newest, children: roots)
            }
            let owner = runs.first { $0.id == rootID } ?? runs[0]
            if let session = owner.sessionId, !session.isEmpty {
                let key = "session:\(session)"
                groups[key, default: []].append(root)
                let candidate = (date: historyDate(owner.startedAt), id: owner.id,
                                 rootID: rootID,
                                 title: owner.sessionTitle ?? "Session \(String(session.prefix(8)))")
                if let current = sessionTitles[key] {
                    if candidate.date > current.date || (candidate.date == current.date && candidate.id < current.id) {
                        sessionTitles[key] = candidate
                    }
                } else {
                    sessionTitles[key] = candidate
                }
            } else {
                // A missing session is not an artificial shared session joining unrelated roots.
                let key = "no-session:\(rootID)"
                groups[key] = [root]
                sessionTitles[key] = (
                    date: historyDate(owner.startedAt), id: owner.id, rootID: rootID,
                    title: owner.sessionTitle ?? "Session \(String(rootID.prefix(8)))"
                )
            }
        }
        return sorted(groups.flatMap { key, roots -> [HistoryNode] in
            guard let sessionTitle = sessionTitles[key] else { return roots }
            if roots.count == 1, let only = roots.first {
                return [HistoryNode(
                    id: only.id, label: sessionTitle.title, item: only.item,
                    rootRunId: only.rootRunId, newest: only.newest, children: only.children
                )]
            }
            var children = sorted(roots)
            guard let firstIndex = children.firstIndex(where: { $0.rootRunId == sessionTitle.rootID }),
                  let firstItem = children[firstIndex].item else {
                return [HistoryNode(
                    id: key, label: sessionTitle.title, item: nil, rootRunId: nil,
                    newest: roots.map(\.newest).max() ?? .distantPast, children: children
                )]
            }
            let firstRoot = children.remove(at: firstIndex)
            children.append(contentsOf: firstRoot.children)
            return [HistoryNode(
                id: key, label: sessionTitle.title, item: firstItem, rootRunId: nil,
                newest: roots.map(\.newest).max() ?? .distantPast, children: sorted(children)
            )]
        })
    }

    func deletableHistoryRoot(for runId: String) -> String? {
        guard let item = historyItem(rootRunId: runId), item.rootRunId == runId,
              !runs.contains(where: { $0.runIds.contains(runId) && ($0.status.isActive || $0.hasRequestInFlight) }) else { return nil }
        return item.rootRunId
    }

    func setHistoryExpanded(_ expanded: Bool, node: HistoryNode) {
        if expanded {
            expandedHistoryIDs.insert(node.id)
            if let root = node.rootRunId ?? node.item?.rootRunId { loadHistoryReport(root) }
        } else {
            expandedHistoryIDs.remove(node.id)
        }
    }

    func collapseAllHistory() {
        expandedHistoryIDs.removeAll()
    }

    func expandHistoryThread(containing runId: String) {
        func expandPath(_ node: HistoryNode) -> Bool {
            let containsRun = node.item?.id == runId || node.rootRunId == runId
                || node.children.contains(where: expandPath)
            if containsRun { setHistoryExpanded(true, node: node) }
            return containsRun
        }
        _ = historyTree.contains(where: expandPath)
    }

    func togglePinnedHistoryRun(_ rootRunId: String) {
        if pinnedHistoryRunIDs.contains(rootRunId) {
            pinnedHistoryRunIDs.remove(rootRunId)
        } else {
            pinnedHistoryRunIDs.insert(rootRunId)
        }
    }

    static func historyStatusCategory(_ status: String) -> HistoryStatusFilter? {
        switch status.lowercased() {
        case "queued", "planning", "running", "awaiting_subagent",
             "replan_required": return .blocked
        case "awaiting_approval", "approval required", "clarification_requested", "question pending": return .waiting
        case "failed": return .failed
        default: return nil
        }
    }

    static func historyDisplayStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "succeeded", "completed": return "Completed"
        case "failed": return "Failed"
        case "queued", "planning", "running", "awaiting_subagent": return "Blocked"
        case "awaiting_approval", "approval required", "clarification_requested", "question pending": return "Waiting"
        case "interrupted": return "Interrupted"
        default: return "Unknown"
        }
    }

    static func historyTimeText(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        guard date != .distantPast else { return "" }
        if calendar.isDate(date, equalTo: now, toGranularity: .day) {
            guard now.timeIntervalSince(date) >= 60 else { return "now" }
            return date.formatted(.relative(presentation: .named))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, equalTo: yesterday, toGranularity: .day) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func historyFiltersAccept(_ node: HistoryNode, filters: HistoryFilters) -> Bool {
        let items = historyItems(in: node)
        if !filters.statuses.isEmpty {
            guard items.contains(where: {
                historyStatusCategory($0.status).map(filters.statuses.contains) == true
            }) else { return false }
        }
        if !filters.kinds.isEmpty {
            guard items.contains(where: {
                filters.kinds.contains($0.type.lowercased() == "chat" ? .chat : .run)
            }) else { return false }
        }
        switch filters.hasSession {
        case .some(true):
            guard items.contains(where: { !($0.sessionId ?? "").isEmpty }) else { return false }
        case .some(false):
            guard items.contains(where: { ($0.sessionId ?? "").isEmpty }) else { return false }
        case .none:
            break
        }
        return true
    }

    private static func historyItems(in node: HistoryNode) -> [HistoryItem] {
        (node.item.map { [$0] } ?? []) + node.children.flatMap(historyItems)
    }

    static func historySections(roots: [HistoryNode], pinnedRunIDs: Set<String>,
                                filters: HistoryFilters = HistoryFilters(),
                                calendar: Calendar = .current, now: Date = Date()) -> [HistorySection] {
        let visible = roots.filter { historyFiltersAccept($0, filters: filters) }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        var nowNodes: [HistoryNode] = []
        var pinnedNodes: [HistoryNode] = []
        var todayNodes: [HistoryNode] = []
        var yesterdayNodes: [HistoryNode] = []
        var weekNodes: [HistoryNode] = []
        var earlierNodes: [HistoryNode] = []
        for node in visible {
            let categories = historyItems(in: node).compactMap { historyStatusCategory($0.status) }
            if categories.contains(where: { $0 != .failed }) {
                nowNodes.append(node)
            } else if !pinnedRunIDs.isDisjoint(with: node.representedRootRunIds) {
                pinnedNodes.append(node)
            } else if calendar.isDate(node.newest, equalTo: now, toGranularity: .day) {
                todayNodes.append(node)
            } else if let yesterday, calendar.isDate(node.newest, equalTo: yesterday, toGranularity: .day) {
                yesterdayNodes.append(node)
            } else if let weekStart, node.newest >= weekStart {
                weekNodes.append(node)
            } else {
                earlierNodes.append(node)
            }
        }
        let buckets: [(title: String, nodes: [HistoryNode])] = [
            ("Pinned", pinnedNodes), ("Now", nowNodes), ("Today", todayNodes),
            ("Yesterday", yesterdayNodes), ("This Week", weekNodes),
            (earlierNodes.count > 1 ? "Earlier · \(earlierNodes.count)" : "Earlier", earlierNodes),
        ]
        return buckets.filter { !$0.nodes.isEmpty }
            .map { HistorySection(id: $0.title, title: $0.title, nodes: $0.nodes) }
    }

    var historySections: [HistorySection] {
        Self.historySections(roots: historyTree, pinnedRunIDs: pinnedHistoryRunIDs, filters: historyFilters)
    }

    static func historyRunSnapshots(_ runs: [RunRecord]) -> [HistoryRunSnapshot] {
        runs.map {
            HistoryRunSnapshot(
                id: $0.id,
                runtimeSessionID: $0.runtimeSessionID,
                kind: $0.kind,
                title: $0.title,
                sessionId: $0.sessionId,
                runIds: $0.runIds,
                status: $0.status,
                activityStartedAt: $0.activityStartedAt,
                isRequestInFlight: $0.isRequestInFlight
            )
        }
    }

    func invalidateHistoryPresentation() {
        historyPresentationRevision &+= 1
    }

    static func historyDetail(_ inspection: JSONValue, runId: String, workspace: String) throws -> HistoryDetail {
        guard let run = inspection.objectValue?["run"]?.objectValue, run["id"]?.stringValue == runId else {
            throw TraceSessionClientError.protocolViolation("inspection returned a different run")
        }
        let root = URL(fileURLWithPath: workspace, isDirectory: true).standardizedFileURL.path
        var files: [String: RunFile] = [:]
        var activities: [RunActivity] = []
        if case .array(let events) = inspection.objectValue?["events"] {
            let selectedEvents = events.compactMap(\.objectValue).filter { $0["runId"]?.stringValue == runId }
            activities = historyActivities(from: selectedEvents, runId: runId)
            for event in selectedEvents {
                guard event["type"]?.stringValue == "tool.completed",
                      let payload = event["payload"]?.objectValue, payload["skipped"] != .bool(true),
                      let tool = payload["toolName"]?.stringValue,
                      let output = payload["output"]?.objectValue,
                      tool == "write_file" || (tool == "edit_file" && output["changed"] == .bool(true)) else { continue }
                let sourceActivityID = event["toolCallId"]?.stringValue.map { "tool:\($0)" }
                for key in ["path", tool == "write_file" ? "intermediatePath" : "backupPath"] {
                    guard let path = output[key]?.stringValue, NSString(string: path).isAbsolutePath else { continue }
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    guard url.path.hasPrefix(root + "/") else { continue }
                    files[url.path] = RunFile(path: url.path, workspaceRoot: root,
                                             operation: tool == "edit_file" && key == "path" ? .edited : .written,
                                             isSupportFile: key != "path", sourceRunId: runId,
                                             sourceActivityID: sourceActivityID)
                }
            }
        }
        return HistoryDetail(
            output: run["result"].map(ProtocolRedactor.redact),
            usage: run["usage"].flatMap { try? $0.decode(TraceUsageTotals.self) },
            files: files.values.sorted { $0.path < $1.path },
            activities: activities
        )
    }

    private static func historyActivities(
        from events: [[String: JSONValue]],
        runId: String
    ) -> [RunActivity] {
        var activities: [RunActivity] = []
        let orderedEvents = events.enumerated().sorted { left, right in
            let leftSequence = activitySequence(left.element["seq"])
            let rightSequence = activitySequence(right.element["seq"])
            if let leftSequence, let rightSequence, leftSequence != rightSequence {
                return leftSequence < rightSequence
            }
            let leftDate = left.element["createdAt"]?.stringValue.map(historyDate) ?? .distantPast
            let rightDate = right.element["createdAt"]?.stringValue.map(historyDate) ?? .distantPast
            return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
        }

        for (_, event) in orderedEvents {
            guard let type = event["type"]?.stringValue else { continue }
            let payload = event["payload"]?.objectValue ?? [:]
            let eventDate = event["createdAt"]?.stringValue.map(historyDate).flatMap { $0 == .distantPast ? nil : $0 }
            let eventSequence = activitySequence(event["seq"])

            if let rawContent = payload["assistantContent"]?.stringValue {
                let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    let stepKey = event["stepId"]?.stringValue ?? event["id"]?.stringValue ?? content
                    let id = "assistant:\(runId):\(stepKey)"
                    if !activities.contains(where: { $0.id == id || ($0.kind == .assistant && $0.content == content) }) {
                        activities.append(RunActivity(
                            id: id, kind: .assistant, sourceRunId: runId, content: content,
                            createdAt: eventDate, eventSeq: eventSequence
                        ))
                    }
                }
            }

            guard ["approval.requested", "tool.started", "tool.completed", "tool.failed"].contains(type),
                  let toolName = payload["toolName"]?.stringValue else { continue }
            let correlationID = event["toolCallId"]?.stringValue
                ?? [runId, event["stepId"]?.stringValue ?? "step", toolName].joined(separator: ":")
            let id = "tool:\(correlationID)"
            let state: RunActivity.ToolState = switch type {
            case "approval.requested": .awaitingApproval
            case "tool.started": .running
            case "tool.completed": payload["skipped"] == .bool(true) ? .skipped : .succeeded
            default: .failed
            }
            let detail = compactToolDetail(toolName: toolName, input: payload["input"]?.objectValue)
            if let index = activities.firstIndex(where: { $0.id == id }) {
                activities[index].toolName = toolName
                activities[index].toolState = state
                if let detail { activities[index].detail = detail }
                if let input = payload["input"] { activities[index].input = ProtocolRedactor.redact(input) }
                if let output = payload["output"] { activities[index].output = ProtocolRedactor.redact(output) }
                if let error = payload["error"]?.stringValue { activities[index].errorMessage = error }
                if state != .running && state != .awaitingApproval { activities[index].completedAt = eventDate }
            } else {
                activities.append(RunActivity(
                    id: id, kind: .tool, sourceRunId: runId, toolName: toolName,
                    detail: detail, toolState: state, createdAt: eventDate,
                    completedAt: state == .running || state == .awaitingApproval ? nil : eventDate,
                    eventSeq: eventSequence,
                    input: payload["input"].map(ProtocolRedactor.redact),
                    output: payload["output"].map(ProtocolRedactor.redact),
                    errorMessage: payload["error"]?.stringValue
                ))
            }
        }
        return activities
    }

    private static func activitySequence(_ value: JSONValue?) -> Int? {
        guard case .number(let number) = value, number.isFinite,
              number.rounded(.towardZero) == number else { return nil }
        return Int(exactly: number)
    }
}
