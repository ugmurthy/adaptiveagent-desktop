import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var workspacePath = ""
    @Published var agentConfigPath = ""
    @Published var settingsConfigPath = ""
    @Published var goal = ""
    @Published var message = ""
    @Published var steerMessage = ""
    @Published var sessionId = ""
    @Published var currentRunId = ""
    @Published var status = "Not connected"
    @Published var events: [String] = []
    @Published var interaction: Interaction?
    @Published var interactionText = ""
    @Published var isBusy = false
    @Published var isConnected = false

    enum Interaction {
        case approval(runId: String, message: String)
        case clarification(runId: String, message: String)
    }
    private let client = SidecarClient()

    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { workspacePath = panel.url?.path ?? "" }
    }

    func chooseAgent() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK { agentConfigPath = panel.url?.path ?? "" }
    }

    func connect() { perform {
        guard ProcessInfo.processInfo.environment["DATABASE_URL"]?.isEmpty == false else {
            throw SidecarError.protocolViolation("DATABASE_URL is required in the app process environment")
        }
        try await self.client.start(eventHandler: { [weak self] event in
            await self?.receive(event)
        }, errorHandler: { [weak self] message in
            await self?.recordError(message)
        })
        var fields: [String: JSONValue] = ["runtimeMode": .string("postgres")]
        if !self.workspacePath.isEmpty { fields["cwd"] = .string(self.workspacePath) }
        if !self.agentConfigPath.isEmpty { fields["agentConfigPath"] = .string(self.agentConfigPath) }
        if !self.settingsConfigPath.isEmpty { fields["settingsConfigPath"] = .string(self.settingsConfigPath) }
        let result = try await self.client.send(type: "runtime.initialize", fields: fields)
        self.isConnected = true
        self.status = "Ready"
        self.events.append("Initialized\n\(result.prettyPrinted)")
    } }

    func startRun() { perform {
        var fields: [String: JSONValue] = ["goal": .string(self.goal)]
        if !self.sessionId.isEmpty { fields["sessionId"] = .string(self.sessionId) }
        let result = try await self.client.send(type: "run.start", fields: fields)
        self.acceptResult(result)
    } }

    func sendChat() { perform {
        var fields: [String: JSONValue] = ["message": .string(self.message)]
        if !self.sessionId.isEmpty { fields["sessionId"] = .string(self.sessionId) }
        let result = try await self.client.send(type: "chat.send", fields: fields)
        self.message = ""; self.acceptResult(result)
    } }

    func steer() { perform {
        let result = try await self.client.send(type: "run.steer", fields: ["runId": .string(self.currentRunId), "message": .string(self.steerMessage)])
        self.steerMessage = ""; self.acceptResult(result)
    } }

    func interrupt() { runCommand("run.interrupt") }
    func inspect() { runCommand("run.inspect") }
    func resume() { runCommand("run.resume") }
    func retry() { runCommand("run.retry") }

    func resolveApproval(_ approved: Bool) { perform {
        guard case .approval(let runId, _) = self.interaction else { return }
        let result = try await self.client.send(type: "approval.resolve", fields: ["runId": .string(runId), "approved": .bool(approved)])
        self.interaction = nil; self.acceptResult(result)
    } }

    func resolveClarification() { perform {
        guard case .clarification(let runId, _) = self.interaction else { return }
        let result = try await self.client.send(type: "clarification.resolve", fields: ["runId": .string(runId), "answer": .string(self.interactionText)])
        self.interaction = nil; self.interactionText = ""; self.acceptResult(result)
    } }

    func shutdown() async { await client.shutdown() }

    private func runCommand(_ type: String) { perform {
        let result = try await self.client.send(type: type, fields: ["runId": .string(self.currentRunId)])
        self.acceptResult(result)
    } }

    private func perform(_ operation: @escaping () async throws -> Void) {
        isBusy = true
        Task { do { try await operation() } catch { status = error.localizedDescription; events.append("Error: \(error.localizedDescription)") }; isBusy = false }
    }

    private func acceptResult(_ result: JSONValue) {
        events.append("Response\n\(result.prettyPrinted)")
        guard let object = result.objectValue else { return }
        let runId = object["runId"]?.stringValue ?? currentRunId
        if currentRunId.isEmpty { currentRunId = runId }
        let message = object["message"]?.stringValue ?? "Runtime requires input."
        switch object["status"]?.stringValue {
        case "approval_requested": interaction = .approval(runId: runId, message: message)
        case "clarification_requested": interaction = .clarification(runId: runId, message: message)
        default: break
        }
    }

    private func receive(_ event: JSONValue) {
        events.append(event.prettyPrinted)
        guard let object = event.objectValue,
              object["type"]?.stringValue == "run.created",
              let runId = object["runId"]?.stringValue,
              let rootRunId = object["payload"]?.objectValue?["rootRunId"]?.stringValue,
              runId == rootRunId else { return }
        currentRunId = rootRunId
    }
    private func recordError(_ message: String) { events.append("Runtime stderr: \(message)") }
}
