import AppKit
import SwiftUI

@main
struct AdaptiveAgentDesktopApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
        .commands { CommandGroup(replacing: .appTermination) { Button("Quit AdaptiveAgent Desktop") { Task { await model.shutdown(); NSApplication.shared.terminate(nil) } }.keyboardShortcut("q") } }
    }
}
