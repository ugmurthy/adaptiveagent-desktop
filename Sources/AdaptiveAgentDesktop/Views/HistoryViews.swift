import SwiftUI
import AppKit
import MarkdownUI

struct HistoryTreeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: AppModel.HistoryNode
    var isThreadRoot = false
    let requestDeletion: (String) -> Void

    @State private var isHovered = false

    private var rowRunId: String? { node.item?.id ?? node.rootRunId }

    private var canExpand: Bool {
        !node.children.isEmpty
    }

    private var threadRunCount: Int {
        guard isThreadRoot else { return 0 }
        return node.runCount
    }

    var body: some View {
        if let runId = rowRunId {
            row.tag(SidebarItemID.history(runId))
                .contextMenu { actions(runId: runId) }
        } else {
            row
        }
    }

    @ViewBuilder private var row: some View {
        if canExpand {
            DisclosureGroup(isExpanded: Binding(
                get: { model.expandedHistoryIDs.contains(node.id) },
                set: { model.setHistoryExpanded($0, node: node) }
            )) {
                ForEach(node.children) { child in HistoryTreeRow(node: child, requestDeletion: requestDeletion) }
                if let root = node.rootRunId, model.historyReports[root] == nil {
                    if let error = model.historyReportErrors[root] {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry children") { model.loadHistoryReport(root) }
                    } else {
                        ProgressView("Loading runs…").controlSize(.small)
                    }
                }
            } label: { label }
        } else {
            label
        }
    }

    @ViewBuilder private func actions(runId: String) -> some View {
        Button("Copy Goal", systemImage: "doc.on.doc") {
            Self.copyToPasteboard(node.item?.title ?? node.label)
        }
        Button("Copy Run ID", systemImage: "number") {
            Self.copyToPasteboard(runId)
        }
        Button("Copy Session ID", systemImage: "person.crop.circle") {
            Self.copyToPasteboard(node.sessionId ?? "")
        }
        .disabled((node.sessionId ?? "").isEmpty)
        if let root = node.rootRunId ?? node.item?.rootRunId {
            if model.pinnedHistoryRunIDs.contains(root) {
                Button("Unpin from Top", systemImage: "pin.slash") { model.togglePinnedHistoryRun(root) }
            } else {
                Button("Pin to Top", systemImage: "pin") { model.togglePinnedHistoryRun(root) }
            }
        }
        if let root = model.deletableHistoryRoot(for: runId) {
            Button("Delete Run…", systemImage: "trash", role: .destructive) { requestDeletion(root) }
                .disabled(!model.isConnected || model.deletingRunIDs.contains(root))
        }
    }

    @ViewBuilder private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let item = node.item {
                    Circle()
                        .fill(Self.statusDotColor(item.status))
                        .frame(width: 7, height: 7)
                    Text(node.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                } else {
                    Text(node.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if threadRunCount > 1 {
                    Text("\(threadRunCount) runs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
            }
            if node.item != nil || rowRunId != nil {
                HStack(spacing: 5) {
                    if let item = node.item {
                        Image(systemName: AppModel.historyDisplayStatus(item.status) == "Waiting" ? "hand.raised" : "circle.dotted")
                            .font(.system(size: 8))
                        Text(AppModel.historyDisplayStatus(item.status))
                        let timeText = AppModel.historyTimeText(AppModel.historyDate(item.startedAt))
                        if !timeText.isEmpty {
                            Text("· \(timeText)")
                        }
                    }
                    Spacer(minLength: 2)
                    if rowRunId != nil {
                        Menu {
                            actions(runId: rowRunId ?? "")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 11))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .opacity(isHovered ? 1 : 0)
                        .allowsHitTesting(isHovered)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .help(tooltipText)
    }

    private var accessibilityText: String {
        guard let item = node.item else { return node.label }
        let timeText = AppModel.historyTimeText(AppModel.historyDate(item.startedAt))
        var text = "History run \(item.title), \(AppModel.historyDisplayStatus(item.status))"
        if !timeText.isEmpty { text += ", \(timeText)" }
        return text
    }

    private var tooltipText: String {
        guard let item = node.item else {
            guard let session = node.sessionId, !session.isEmpty else { return node.label }
            return "\(node.label)\nSession \(session)"
        }
        var lines = [item.title, "Run \(item.id)"]
        if let session = item.sessionId, !session.isEmpty { lines.append("Session \(session)") }
        if AppModel.historyDate(item.startedAt) != .distantPast {
            lines.append(AppModel.historyDate(item.startedAt).formatted(date: .abbreviated, time: .shortened))
        }
        return lines.joined(separator: "\n")
    }

    private static func statusDotColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "queued", "planning", "running", "awaiting_subagent":
            return .accentColor
        case "awaiting_approval", "approval required", "clarification_requested", "question pending":
            return .orange
        case "succeeded", "completed":
            return .green
        case "failed":
            return .red
        default:
            return .secondary
        }
    }

    private static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct HistoricalOutputView: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.HistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SELECTED RUN · OUTPUT & FILES").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            if let detail = model.historyDetails[item.id] {
                if let output = detail.output, output != .null {
                    if let text = output.stringValue {
                        Markdown(text).textSelection(.enabled)
                    } else {
                        Text(output.prettyPrinted).font(.callout.monospaced()).textSelection(.enabled)
                    }
                } else {
                    Text("No persisted output for this run.").foregroundStyle(.secondary)
                }
                if let usage = detail.usage {
                    Text("Selected run usage (not added to the root total)")
                        .font(.caption).foregroundStyle(.secondary)
                    HistoryTokenLine(usage: usage)
                } else {
                    Text("Selected-run usage unavailable; root accounting is shown separately below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("FILES · \(detail.files.count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text("Persisted write_file / edit_file evidence only; not a complete artifact inventory. Select a child run to see its output and files.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(detail.files) { file in
                    HStack(alignment: .top) {
                        Image(systemName: "doc")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.relativeDisplayPath(for: file)).font(.callout.monospaced())
                                .textSelection(.enabled)
                            Text("\(file.operation.rawValue)\(file.isSupportFile ? " · Support file" : "") · Run \(file.sourceRunId)")
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if model.fileExists(file) {
                            Button("Reveal") { model.revealFile(file) }
                        } else {
                            Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if detail.files.isEmpty { Text("No file evidence recorded.").font(.caption).foregroundStyle(.secondary) }
            } else if model.historyDetailErrors[item.id] == nil {
                ProgressView("Loading selected run…")
            }
            if let error = model.historyDetailErrors[item.id] {
                Label("Output/files could not refresh: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry detail") { model.retryHistoryReport(item.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HistoryTokenLine: View {
    let usage: TraceUsageTotals
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(usage.totalTokens) tokens · \(Self.cost(usage.estimatedCostUSD)) estimated")
                .font(.callout.weight(.semibold)).monospacedDigit()
            Text("Prompt \(usage.promptTokens) · Completion \(usage.completionTokens) · Reasoning \(usage.reasoningTokens.map(String.init) ?? "unavailable")")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    static func cost(_ value: Double) -> String { String(format: "$%.6f", value) }
}

struct HistoryUsageView: View {
    let usage: TraceUsageSummary
    let rootRunId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ROOT + DESCENDANTS · USAGE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text(rootRunId).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HistoryTokenLine(usage: usage.total)
            if let models = usage.byProviderModel, !models.isEmpty {
                Text("MODEL ATTRIBUTION").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(model.provider) / \(model.model)").font(.callout.weight(.medium))
                        HistoryTokenLine(usage: model.usage)
                    }
                }
                Text("Runtime attribution of cumulative run usage; model switches within a run may not be separately attributed. Breakdowns are included in, not added to, the root total.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Provider/model breakdown unavailable.").font(.caption).foregroundStyle(.secondary)
            }
            if let models = usage.toolOutputByProviderModel, !models.isEmpty {
                Text("MODEL USAGE REPORTED BY TOOLS · INCLUDED IN ROOT TOTAL")
                    .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                    Text("\(model.provider) / \(model.model)").font(.callout.weight(.medium))
                    HistoryTokenLine(usage: model.usage)
                }
            }
            Divider()
            Text("SEARCH / TOOL PROVIDERS · SEPARATE ACCOUNTING")
                .font(.caption.weight(.bold)).foregroundStyle(.secondary)
            if let accounting = usage.toolAccounting {
                Text("\(accounting.totalRequests) reported requests · \(HistoryTokenLine.cost(accounting.estimatedCostUSD)) priced subtotal")
                    .font(.callout).monospacedDigit()
                ForEach(Array(accounting.byProviderOperation.enumerated()), id: \.offset) { _, provider in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(provider.provider) / \(provider.operation)").font(.callout.weight(.medium))
                        Text("\(provider.requests) \(Self.requestLabel(provider.requests)) · \(provider.billableRequests) billable · \(provider.cachedToolCalls) cached calls · \(provider.unpricedRequests) unpriced")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(provider.billableRequests == 0 && provider.unpricedRequests > 0
                             ? "No priced subtotal · cost unavailable for unpriced requests"
                             : "\(HistoryTokenLine.cost(provider.estimatedCostUSD)) priced subtotal")
                        .font(.caption).monospacedDigit()
                    }
                }
                Text("\(accounting.unpricedRequests) unpriced \(Self.requestLabel(accounting.unpricedRequests)). Reported accounting only; missing provider metadata is not zero-cost usage. Tool costs are not added to model totals here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Provider requests and costs unavailable. The runtime did not report tool accounting; unavailable does not mean free.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func requestLabel(_ count: Int) -> String {
        count == 1 ? "request" : "requests"
    }
}
