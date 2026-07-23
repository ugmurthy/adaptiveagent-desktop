import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            Form {
                Section("Runtime") {
                    pathRow("Workspace", text: $model.workspacePath, action: model.chooseWorkspace)
                    pathRow("Agent profile", text: $model.agentConfigPath, action: model.chooseAgent)
                    TextField("Settings override (auto-discovered if blank)", text: $model.settingsConfigPath)
                    Button("Connect and initialize", action: model.connect).disabled(model.isBusy || model.isConnected)
                    Text(model.status).foregroundStyle(.secondary)
                }
                Section("Run") {
                    TextEditor(text: $model.goal).frame(minHeight: 90)
                    TextField("Session ID (optional)", text: $model.sessionId)
                    Button("Start run", action: model.startRun).disabled(!model.isConnected || model.isBusy || model.goal.isEmpty)
                    HStack {
                        TextField("Chat message", text: $model.message)
                        Button("Send", action: model.sendChat).disabled(!model.isConnected || model.message.isEmpty)
                    }
                    TextField("Current run ID", text: $model.currentRunId)
                    HStack {
                        Button("Inspect", action: model.inspect)
                        Button("Resume", action: model.resume)
                        Button("Retry", action: model.retry)
                        Button("Interrupt", action: model.interrupt)
                    }.disabled(model.currentRunId.isEmpty)
                    HStack {
                        TextField("Steering message", text: $model.steerMessage)
                        Button("Steer", action: model.steer)
                    }.disabled(model.currentRunId.isEmpty || model.steerMessage.isEmpty)
                }
                if let interaction = model.interaction {
                    interactionView(interaction)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 390)

            VStack(alignment: .leading) {
                Text("Events").font(.headline)
                List(Array(model.events.enumerated()), id: \.offset) { _, event in
                    Text(event).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.padding().frame(minWidth: 480)
        }.frame(minWidth: 900, minHeight: 620)
    }

    private func pathRow(_ title: String, text: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack { TextField(title, text: text); Button("Choose…", action: action) }
    }

    @ViewBuilder private func interactionView(_ interaction: AppModel.Interaction) -> some View {
        Section("Input required") {
            switch interaction {
            case .approval(_, let message):
                Text(message)
                HStack { Button("Approve") { model.resolveApproval(true) }; Button("Reject") { model.resolveApproval(false) } }
            case .clarification(_, let message):
                Text(message)
                TextField("Answer", text: $model.interactionText)
                Button("Send answer", action: model.resolveClarification).disabled(model.interactionText.isEmpty)
            }
        }
    }
}
