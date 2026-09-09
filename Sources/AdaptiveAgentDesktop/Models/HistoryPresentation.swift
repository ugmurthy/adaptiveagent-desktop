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
    }

    struct HistoryDetail: Equatable {
        let output: JSONValue?
        let usage: TraceUsageTotals?
        let files: [RunFile]
    }

    struct HistoryNode: Identifiable {
        let id: String
        let label: String
        let item: HistoryItem?
        let rootRunId: String?
        let newest: Date
        var children: [HistoryNode]
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
        let local = runs.filter { !$0.status.isActive }.flatMap { record in
            record.runIds.map { runId in
                HistoryItem(
                    rootRunId: historyRootRunId(for: runId), runId: runId,
                    runtimeSessionID: record.runtimeSessionID, sessionId: record.sessionId,
                    title: record.title, status: record.status.rawValue,
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
        let active = Set(runs.filter { $0.status.isActive }.flatMap(\.runIds))
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
        var sessionNames: [String: String] = [:]
        for (rootID, runs) in Dictionary(grouping: items, by: \.rootRunId) {
            guard query.isEmpty || runs.contains(where: { item in
                [item.title, item.id, rootID, item.sessionId ?? "", item.status, item.type]
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
            let owner = runs.first { $0.id == rootID } ?? runs[0]
            let newest = roots.map(\.newest).max() ?? .distantPast
            let root: HistoryNode
            if roots.count == 1, roots[0].item?.id == rootID {
                root = roots[0]
            } else {
                root = HistoryNode(id: "root:\(rootID)", label: "Root \(rootID)", item: nil,
                                   rootRunId: rootID, newest: newest, children: roots)
            }
            if let session = owner.sessionId, !session.isEmpty {
                let key = "session:\(session)"
                groups[key, default: []].append(root)
                sessionNames[key] = session
            } else {
                // A missing session is not an artificial shared session joining unrelated roots.
                groups["no-session:\(rootID)"] = [HistoryNode(
                    id: root.id, label: "No session · \(root.label)", item: root.item,
                    rootRunId: rootID, newest: newest, children: root.children
                )]
            }
        }
        return sorted(groups.flatMap { key, roots -> [HistoryNode] in
            guard let session = sessionNames[key] else { return roots }
            return [HistoryNode(id: key, label: "Session \(session)", item: nil, rootRunId: nil,
                                newest: roots.map(\.newest).max() ?? .distantPast, children: sorted(roots))]
        })
    }

    func deletableHistoryRoot(for runId: String) -> String? {
        guard let item = historyItem(rootRunId: runId), item.rootRunId == runId,
              item.allowsDeletion,
              !runs.contains(where: { $0.runIds.contains(runId) && ($0.status.isActive || $0.hasRequestInFlight) }) else { return nil }
        return item.rootRunId
    }

    func setHistoryExpanded(_ expanded: Bool, node: HistoryNode) {
        if expanded {
            expandedHistoryIDs.insert(node.id)
            if let root = node.rootRunId { loadHistoryReport(root) }
        } else {
            expandedHistoryIDs.remove(node.id)
        }
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
                activityStartedAt: $0.activityStartedAt
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
        if case .array(let events) = inspection.objectValue?["events"] {
            for event in events {
                guard let event = event.objectValue, event["runId"]?.stringValue == runId,
                      event["type"]?.stringValue == "tool.completed",
                      let payload = event["payload"]?.objectValue, payload["skipped"] != .bool(true),
                      let tool = payload["toolName"]?.stringValue,
                      let output = payload["output"]?.objectValue,
                      tool == "write_file" || (tool == "edit_file" && output["changed"] == .bool(true)) else { continue }
                for key in ["path", tool == "write_file" ? "intermediatePath" : "backupPath"] {
                    guard let path = output[key]?.stringValue, NSString(string: path).isAbsolutePath else { continue }
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    guard url.path.hasPrefix(root + "/") else { continue }
                    files[url.path] = RunFile(path: url.path, workspaceRoot: root,
                                             operation: tool == "edit_file" && key == "path" ? .edited : .written,
                                             isSupportFile: key != "path", sourceRunId: runId)
                }
            }
        }
        return HistoryDetail(
            output: run["result"].map(ProtocolRedactor.redact),
            usage: run["usage"].flatMap { try? $0.decode(TraceUsageTotals.self) },
            files: files.values.sorted { $0.path < $1.path }
        )
    }
}
