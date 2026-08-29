import Foundation

enum TraceSessionBackend: Equatable, Sendable {
    case sqlite(path: String)
    case postgres(environmentVariable: String)

    var kind: String {
        switch self {
        case .sqlite: "sqlite"
        case .postgres: "postgres"
        }
    }

    var launchArguments: [String] {
        switch self {
        case .sqlite(let path): ["--sqlite-path", path]
        case .postgres(let name): ["--database-url-env", name]
        }
    }
}

struct TraceSessionInitialization: Codable, Equatable, Sendable {
    struct Backend: Codable, Equatable, Sendable {
        let kind: String
        let readOnly: Bool
    }

    let protocolVersion: String
    let backend: Backend
}

struct TraceHistoryGoal: Codable, Equatable, Identifiable, Sendable {
    let rootRunId: String
    let runId: String
    let status: String?
    let startedAt: String?
    let completedAt: String?
    let goal: String?
    let linkedAt: String
    let type: String?
    let swarmRole: String?

    var id: String { rootRunId }
}

struct TraceSessionListItem: Codable, Equatable, Identifiable, Sendable {
    let sessionId: String?
    let startedAt: String
    let status: String?
    let goals: [TraceHistoryGoal]

    var id: String { sessionId ?? goals.first?.rootRunId ?? startedAt }
}

struct TraceSessionListParameters: Codable, Equatable, Sendable {
    var goals: [String]? = nil
    var limit: Int? = nil
    var until: String? = nil
}

struct TraceTargetSummary: Codable, Equatable, Sendable {
    let kind: String
    let requestedId: String
    let resolvedRootRunId: String?
}

struct TraceSessionOverview: Codable, Equatable, Sendable {
    let sessionId: String
    let status: String
    let createdAt: String
    let updatedAt: String
}

struct TraceRootRun: Codable, Equatable, Identifiable, Sendable {
    let rootRunId: String
    let runId: String
    let invocationKind: String
    let linkedAt: String
    let startedAt: String?
    let updatedAt: String?
    let completedAt: String?
    let status: String?
    let goal: String?
    let modelProvider: String?
    let modelName: String?

    var id: String { runId }
}

struct TraceUsageTotals: Codable, Equatable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let reasoningTokens: Int?
    let totalTokens: Int
    let estimatedCostUSD: Double
}

struct TraceUsageSummary: Codable, Equatable, Sendable {
    let total: TraceUsageTotals
}

struct TracePerformanceBucket: Codable, Equatable, Sendable {
    let count: Int
    let total: Double
    let max: Double
    let average: Double
}

struct TracePerformanceSummary: Codable, Equatable, Sendable {
    struct Model: Codable, Equatable, Sendable {
        let started: Int
        let completed: Int
        let failed: Int
        let retries: Int
        let durationMs: TracePerformanceBucket
    }

    struct Tools: Codable, Equatable, Sendable {
        let started: Int
        let completed: Int
        let failed: Int
        let durationMs: TracePerformanceBucket
    }

    let model: Model
    let tools: Tools
}

struct TraceTimelineEntry: Codable, Equatable, Identifiable, Sendable {
    let rootRunId: String
    let runId: String
    let depth: Int
    let stepId: String?
    let toolCallId: String?
    let eventType: String?
    let toolName: String?
    let startedAt: String?
    let completedAt: String?
    let durationMs: Double?
    let outcome: String
    let childRunId: String?
    let eventSeq: Int?

    var id: String {
        [runId, toolCallId ?? stepId ?? eventType ?? "event", String(eventSeq ?? -1)]
            .joined(separator: ":")
    }
}

struct TraceRunTreeEntry: Codable, Equatable, Identifiable, Sendable {
    let rootRunId: String
    let runId: String
    let parentRunId: String?
    let delegateName: String?
    let depth: Int
    let status: String?
    let createdAt: String?
    let updatedAt: String?
    let completedAt: String?

    var id: String { runId }
}

struct TraceReportSummary: Codable, Equatable, Sendable {
    let status: String
    let reason: String
}

struct TraceReport: Codable, Equatable, Sendable {
    let target: TraceTargetSummary
    let session: TraceSessionOverview?
    let rootRuns: [TraceRootRun]
    let usage: TraceUsageSummary
    let performance: TracePerformanceSummary?
    let timeline: [TraceTimelineEntry]
    let runTree: [TraceRunTreeEntry]?
    let summary: TraceReportSummary
    let warnings: [String]
}
