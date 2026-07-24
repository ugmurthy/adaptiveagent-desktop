import AppKit
import SwiftUI

@main
struct AdaptiveAgentDesktopApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Run", action: model.newRun)
                    .keyboardShortcut("n")
                    .disabled(!model.isConnected)
                Button("New Chat", action: model.newChat)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.isConnected)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit AdaptiveAgent Desktop", action: model.requestQuit)
                    .keyboardShortcut("q")
            }
        }
        Settings {
            MarkdownSettingsView()
        }
    }
}
