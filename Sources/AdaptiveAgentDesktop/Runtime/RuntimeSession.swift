import Foundation

/// Configuration and process state owned by one independently restartable runtime.
struct RuntimeConfiguration: Equatable, Sendable {
    var workspacePath: String
    var agentConfigPath = ""
    var settingsConfigPath = ""
    var runtimeMode = ""
    var provider = ""
    var model = ""
    var inferenceMode = ""
    var inferenceTier = ""
    var gatewayURL = ""
    var requireRunPermit = false
    var approvalMode = "manual"
    var clarificationMode = "interactive"
}

@MainActor
final class RuntimeSession {
    let id: UUID
    var configuration: RuntimeConfiguration
    var client: RuntimeClient
    var traceClient: TraceSessionClient

    var isConnected = false
    var isBusy = false
    var status = "Starting…"
    var agentName = ""
    var agentId = ""
    var runtimeMode = ""
    var effectiveWorkspaceRoot = ""
    var shellCwd = ""
    var registeredToolNames: [String] = []
    var runtimeInfo: RuntimeInfo?
    var runtimeInfoError: String?
    var attachmentCapabilities: AttachmentCapabilities?
    var traceConnected = false
    var loadedSettingsConfigPath: String?
    var settingsConfigurationError: String?
    var accessToken = ""
    var accessTokenMessage: String?
    var accessTokenUpdateFailed = false
    var isUpdatingAccessToken = false

    init(
        id: UUID = UUID(),
        configuration: RuntimeConfiguration,
        client: RuntimeClient = RuntimeClient(),
        traceClient: TraceSessionClient = TraceSessionClient()
    ) {
        self.id = id
        self.configuration = configuration
        self.client = client
        self.traceClient = traceClient
    }
}
