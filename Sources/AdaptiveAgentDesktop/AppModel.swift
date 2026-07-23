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
    private var client = RuntimeClient()

    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { workspacePath = panel.url?.path ?? "" }
    }

    func chooseAgent() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK { agentConfigPath = panel.url?.path ?? "" }
    }

    func connect() { perform {
        let client = self.client
        do {
            self.status = "Starting runtime…"
            try await client.start(notificationHandler: { [weak self] method, params in
                await self?.receive(method: method, params: params)
            }, errorHandler: { [weak self] message in
                await self?.recordError(message)
            }, terminationHandler: { [weak self] status in
                await self?.runtimeTerminated(status: status)
            })
            self.status = "Initializing runtime…"
            var fields: [String: JSONValue] = [:]
            if !self.workspacePath.isEmpty { fields["cwd"] = .string(self.workspacePath) }
            if !self.agentConfigPath.isEmpty { fields["agentConfigPath"] = .string(self.agentConfigPath) }
            if !self.settingsConfigPath.isEmpty { fields["settingsConfigPath"] = .string(self.settingsConfigPath) }
            let result = try await client.initializeRuntime(params: fields)
            self.isConnected = true
            self.status = "Ready"
            self.events.append("Initialized\n\(result.prettyPrinted)")
        } catch {
            await client.shutdown()
            self.client = RuntimeClient()
            throw error
        }
    } }

    func startRun() { perform {
        var fields: [String: JSONValue] = ["goal": .string(self.goal)]
        if !self.sessionId.isEmpty { fields["sessionId"] = .string(self.sessionId) }
        let result = try await self.client.send(method: "agent/run", params: fields)
        self.acceptResult(result)
    } }

    func sendChat() { perform {
        var fields: [String: JSONValue] = ["message": .string(self.message)]
        if !self.sessionId.isEmpty { fields["sessionId"] = .string(self.sessionId) }
        let result = try await self.client.send(method: "agent/chat", params: fields)
        self.message = ""; self.acceptResult(result)
    } }

    func steer() { perform {
        let result = try await self.client.send(method: "run/steer", params: ["runId": .string(self.currentRunId), "message": .string(self.steerMessage)])
        self.steerMessage = ""; self.acceptResult(result)
    } }

    func interrupt() { runCommand("run/interrupt") }
    func inspect() { runCommand("run/inspect") }
    func resume() { runCommand("run/resume") }
    func retry() { runCommand("run/retry") }

    func resolveApproval(_ approved: Bool) { perform {
        guard case .approval(let runId, _) = self.interaction else { return }
        let result = try await self.client.send(method: "interaction/resolveApproval", params: ["runId": .string(runId), "approved": .bool(approved)])
        self.interaction = nil; self.acceptResult(result)
    } }

    func resolveClarification() { perform {
        guard case .clarification(let runId, _) = self.interaction else { return }
        let result = try await self.client.send(method: "interaction/resolveClarification", params: ["runId": .string(runId), "answer": .string(self.interactionText)])
        self.interaction = nil; self.interactionText = ""; self.acceptResult(result)
    } }

    func shutdown() async { await client.shutdown() }

    private func runCommand(_ method: String) { perform {
        let result = try await self.client.send(method: method, params: ["runId": .string(self.currentRunId)])
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

    private func receive(method: String, params: JSONValue) {
        events.append("\(method)\n\(params.prettyPrinted)")
        guard method == "agent/event",
              let object = params.objectValue,
              object["type"]?.stringValue == "run.created",
              let runId = object["runId"]?.stringValue,
              let rootRunId = object["payload"]?.objectValue?["rootRunId"]?.stringValue,
              runId == rootRunId else { return }
        currentRunId = rootRunId
    }
    private func recordError(_ message: String) { events.append("Runtime diagnostic: \(message)") }
    private func runtimeTerminated(status: Int32) {
        isConnected = false
        self.status = "Runtime exited with status \(status)"
        client = RuntimeClient()
    }
}
