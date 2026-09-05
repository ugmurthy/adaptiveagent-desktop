import AppKit
import SwiftUI
import XCTest

@testable import AdaptiveAgentDesktop

/// Explicit, opt-in development snapshots. No runtime is started or run submitted.
final class WorkbenchSnapshotTests: XCTestCase {
    @MainActor
    func testDevelopmentSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["WORKBENCH_SNAPSHOT_DIRECTORY"] else {
            throw XCTSkip("Set WORKBENCH_SNAPSHOT_DIRECTORY to render development fixtures")
        }
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApplication.shared.applicationIconImage = NSImage(contentsOf: icon)
        }
        for state in ["ready", "chat", "disconnected", "active", "attention", "dark", "expanded"] {
            let model = AppModel(
                client: RuntimeClient(executableURL: URL(fileURLWithPath: "/nonexistent/development-preview-runtime")),
                workingDirectoryURL: URL(fileURLWithPath: "/tmp/Workbench Preview")
            )
            // Consume bootstrap while connect's connected guard is closed. The view's
            // later .task cannot launch a runtime, including for disconnected fixtures.
            model.isConnected = true
            model.bootstrap()
            model.agentName = "Research Assistant"
            model.isConnected = state != "disconnected"
            model.status =
                state == "disconnected" ? "The runtime could not connect. Review your configuration and try again." : "Ready"
            let tabID = try XCTUnwrap(model.selectedTabID)
            if state == "chat" { model.setDraftKind(.chat, forTab: tabID) }
            if state == "expanded" {
                model.agentName = "Research Assistant with a deliberately long profile name for narrow windows"
                model.setDraftText("Review this workspace and suggest three useful next steps.", forTab: tabID)
            }
            if state == "active" || state == "attention" {
                var record = AppModel.RunRecord(
                    id: UUID(), agentName: "Research Assistant", kind: .run,
                    title: "Review the workspace and recommend next steps")
                record.runIds = ["development-preview"]
                record.status = state == "active" ? .running : .waitingForApproval
                if state == "attention" {
                    record.interaction = .init(
                        runId: "development-preview", approvalId: "preview-approval",
                        message: "The agent would like to save its findings in your workspace.",
                        kind: .approval(
                            toolName: "write_file", input: .object(["path": .string("notes.md")]), assistantContent: nil))
                }
                model.runs = [record]
                model.selectRun(record.id)
                model.isConnected = true
            }
            let view = NSHostingView(
                rootView: ContentView().environmentObject(model).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: state == "dark" ? .darkAqua : .aqua)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if state == "expanded" {
                // Exercise the native disclosure at the fixed 980-point fixture size.
                let point = NSPoint(x: 306, y: view.bounds.height - 596)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type, location: point,
                            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-\(state).png"))
            XCTAssertGreaterThan(data.count, 1000)
            window.orderOut(nil)
        }
    }

}
