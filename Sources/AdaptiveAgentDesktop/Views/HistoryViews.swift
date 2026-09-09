import SwiftUI
import MarkdownUI

struct HistoryTreeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: AppModel.HistoryNode
    let requestDeletion: (String) -> Void

    private var canExpand: Bool {
        !node.children.isEmpty || node.rootRunId.map { model.historyReports[$0] == nil } == true
    }

    var body: some View {
        if let runId = node.item?.id ?? node.rootRunId {
            row.tag(SidebarItemID.history(runId))
                .contextMenu {
                    if let root = model.deletableHistoryRoot(for: runId) {
                        Button("Delete Run…", systemImage: "trash", role: .destructive) { requestDeletion(root) }
                            .disabled(!model.isConnected || model.deletingRunIDs.contains(root))
                    }
                }
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

    @ViewBuilder private var label: some View {
        if let item = node.item {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.label).font(.callout.weight(.medium)).lineLimit(2)
                    Text(item.id).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(item.status.capitalized)
                        Spacer(minLength: 2)
                        if AppModel.historyDate(item.startedAt) != .distantPast {
                            Text(AppModel.historyDate(item.startedAt), format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("History run \(item.id), \(item.title), \(item.status), started \(item.startedAt)")
            .help("\(item.id)\nStarted: \(item.startedAt)")
        } else {
            Text(node.label).font(.caption.weight(.semibold)).lineLimit(2)
                .help(node.label)
        }
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
