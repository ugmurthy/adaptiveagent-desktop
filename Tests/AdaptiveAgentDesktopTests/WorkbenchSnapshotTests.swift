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
        for state in ["ready", "chat", "disconnected", "active", "attention", "timeline", "dark", "expanded", "inspector"] {
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
            if state == "active" || state == "attention" || state == "timeline" {
                var record = AppModel.RunRecord(
                    id: UUID(), agentName: "Research Assistant", modelName: "claude-sonnet-4.5", kind: .run,
                    title: "Review the workspace and recommend next steps")
                record.runIds = ["development-preview"]
                record.selectedAgentId = "research-assistant"
                record.selectedAgentName = "Research Assistant"
                record.status = state == "active" ? .running : state == "timeline" ? .succeeded : .waitingForApproval
                if state == "attention" {
                    record.interaction = .init(
                        runId: "development-preview", approvalId: "preview-approval",
                        message: "The agent would like to save its findings in your workspace.",
                        kind: .approval(
                            toolName: "write_file", input: .object(["path": .string("notes.md")]), assistantContent: nil))
                } else if state == "timeline" {
                    let start = AppModel.historyDate("2026-09-11T20:00:00.000Z")
                    let resultURL = URL(fileURLWithPath: "/tmp/Workbench Preview/notes.md")
                    try FileManager.default.createDirectory(
                        at: resultURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try "# Findings".write(to: resultURL, atomically: true, encoding: .utf8)
                    record.activityStartedAt = start
                    record.activityFinishedAt = start.addingTimeInterval(100)
                    record.activities = [
                        .init(id: "assistant:1", kind: .assistant, sourceRunId: "development-preview",
                              content: "I’ll inspect the workspace before making the change.",
                              createdAt: start.addingTimeInterval(2), eventSeq: 2),
                        .init(id: "tool:shell-1", kind: .tool, sourceRunId: "development-preview",
                              toolName: "shell_exec", detail: "swift test", toolState: .failed,
                              createdAt: start.addingTimeInterval(5), completedAt: start.addingTimeInterval(8), eventSeq: 3,
                              input: .object(["command": .string("swift test")]), errorMessage: "One test failed"),
                        .init(id: "assistant:2", kind: .assistant, sourceRunId: "development-preview",
                              content: "The first test exposed a stale expectation. I’ll update it and verify again.",
                              createdAt: start.addingTimeInterval(10), eventSeq: 4),
                        .init(id: "tool:edit-1", kind: .tool, sourceRunId: "development-preview",
                              toolName: "edit_file", detail: "notes.md", toolState: .succeeded,
                              createdAt: start.addingTimeInterval(30), completedAt: start.addingTimeInterval(32), eventSeq: 5,
                              input: .object(["path": .string(resultURL.path)]), output: .object(["changed": .bool(true)])),
                        .init(id: "tool:shell-2", kind: .tool, sourceRunId: "development-preview",
                              toolName: "shell_exec", detail: "swift test", toolState: .succeeded,
                              createdAt: start.addingTimeInterval(35), completedAt: start.addingTimeInterval(40), eventSeq: 6,
                              input: .object(["command": .string("swift test")]), output: .string("All tests passed")),
                        .init(id: "assistant:final", kind: .assistant, sourceRunId: "development-preview",
                              content: "Updated the notes and verified the test suite.", isFinalAssistantMessage: true,
                              createdAt: start.addingTimeInterval(42), eventSeq: 7)
                    ]
                    record.files = [
                        .init(path: resultURL.path, workspaceRoot: "/tmp/Workbench Preview", operation: .edited,
                              isSupportFile: false, sourceRunId: "development-preview", sourceActivityID: "tool:edit-1")
                    ]
                }
                model.runs = [record]
                model.selectRun(record.id)
                model.isConnected = true
            }
            let view = NSHostingView(
                rootView: ContentView(inspectorPresented: state == "inspector")
                    .environmentObject(model)
                    .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: state == "inspector" ? 1320 : 980, height: 760),
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

    @MainActor
    func testInspectorLayoutRemainsStableWhileResizing() {
        let model = AppModel(
            client: RuntimeClient(executableURL: URL(fileURLWithPath: "/nonexistent/layout-test-runtime")),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/Inspector Layout Test")
        )
        model.isConnected = true
        model.bootstrap()

        let view = NSHostingView(rootView: ContentView(inspectorPresented: true).environmentObject(model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        for width in [1320.0, 980.0, 1180.0, 1320.0] {
            window.setContentSize(NSSize(width: width, height: 760))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.bounds.width, width, accuracy: 1)
        }

        XCTAssertTrue(view.bounds.width.isFinite)
        XCTAssertTrue(view.bounds.height.isFinite)
        window.orderOut(nil)
    }

    @MainActor
    func testAgentCreatorCollisionSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["WORKBENCH_SNAPSHOT_DIRECTORY"] else {
            throw XCTSkip("Set WORKBENCH_SNAPSHOT_DIRECTORY to render the agent creator fixture")
        }
        let model = AppModel(
            client: RuntimeClient(executableURL: URL(fileURLWithPath: "/nonexistent/agent-creator-preview-runtime")),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/Agent Creator Preview")
        )
        model.agentCreator.stage = .review
        model.agentCreator.agentJSON = JSONValue.object([
            "id": .string("security-reviewer"),
            "name": .string("Security Reviewer"),
            "description": .string("Reviews TypeScript changes for exploitable security issues."),
            "provider": .string("mistral"),
            "model": .string("codestral"),
            "instructions": .array([
                .string("Prioritize exploitable findings."),
                .string("Explain concrete remediation steps.")
            ])
        ]).prettyPrinted
        model.agentCreator.draft = AgentDraftResult(
            generatorAgent: .init(requested: "default", id: "default", name: "Visual Fixture Agent"),
            path: "/workspace/agents/security-reviewer.json",
            agentsDir: "/workspace/agents",
            exists: true,
            duplicatePaths: [],
            targetFingerprint: "existing-profile-fingerprint",
            agent: .object(["id": .string("security-reviewer")]),
            notes: ["Generated from the requested TypeScript security-review brief."],
            recommendations: ["Review the selected provider and model before saving."]
        )

        let view = NSHostingView(
            rootView: AgentCreatorView()
                .environmentObject(model)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-agent-creator-collision.png"))
        XCTAssertGreaterThan(data.count, 1000)
        window.orderOut(nil)
    }

    @MainActor
    func testHistorySnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WORKBENCH_SNAPSHOT_DIRECTORY"] else {
            throw XCTSkip("Set WORKBENCH_SNAPSHOT_DIRECTORY to render history fixtures")
        }
        for state in ["normal", "unavailable", "error"] {
            let fixture = try HistoryFixture(mode: state)
            do {
                try await fixture.start()
                let model = fixture.model
                model.selectHistoryRun("root-a")
                try await fixture.wait { model.historyUsage["root-a"] != nil && model.historyDetails["root-a"] != nil }
                model.expandedHistoryIDs = ["session:session-research", "run:root-a", "run:child-a", "root:root-b"]
                model.loadHistoryReport("root-b")
                try await fixture.wait { model.historyReports["root-b"] != nil }
                model.selectHistoryRun("child-a")
                try await fixture.wait { model.historyDetails["child-a"] != nil }
                if state == "error" {
                    try "fail".write(to: fixture.directory.appendingPathComponent("fail"), atomically: true, encoding: .utf8)
                    model.retryHistoryReport("child-a")
                    try await fixture.wait { model.historyDetailErrors["child-a"] != nil && model.historyUsageErrors["root-a"] != nil }
                }
                let view = NSHostingView(rootView: ContentView().environmentObject(model).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 1060),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                view.layoutSubtreeIfNeeded()
                let description = view.debugDescription + view.subviews.map(\.debugDescription).joined(separator: "\n")
                XCTAssertFalse(description.contains("Open in Runtime"))
                XCTAssertFalse(description.contains("Run Actions"))
                XCTAssertFalse(description.contains("Steer"))
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-history-\(state).png"))
                window.orderOut(nil)
            } catch { await fixture.close(); throw error }
            await fixture.close()
        }
    }

}
