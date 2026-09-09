import AppKit
import XCTest
@testable import AdaptiveAgentDesktop

@MainActor
final class HistoryFixture {
    let directory: URL
    let model: AppModel
    let runtime: RuntimeClient
    let trace: TraceSessionClient

    init(mode: String = "normal") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try mode.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        for name in ["runtime", "trace"] {
            let executable = directory.appendingPathComponent(name)
            try Self.script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        runtime = RuntimeClient(executableURL: directory.appendingPathComponent("runtime"), responseTimeout: .seconds(2))
        trace = TraceSessionClient(executableURL: directory.appendingPathComponent("trace"), responseTimeout: .seconds(2))
        model = AppModel(client: runtime, traceClient: trace, workingDirectoryURL: directory,
                         attachmentStoreRootURL: directory.appendingPathComponent("attachments"))
    }

    func start() async throws {
        model.bootstrap()
        try await wait { self.model.historyState == .loaded }
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Fixture timed out: \(model.status), \(model.historyState)")
        throw TraceSessionClientError.timedOut("fixture")
    }

    func close() async {
        await trace.shutdown()
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func requests(_ name: String) throws -> [JSONValue] {
        try String(contentsOf: directory.appendingPathComponent("\(name).log"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    // A finite allowlist prevents a regression from submitting, resuming, or mutating a run.
    // The only persisted evidence is synthetic data inside this temporary directory.
    private static let script = #"""
#!/usr/bin/python3
import json, sys, os
from pathlib import Path
home = Path(__file__).parent
runtime = Path(__file__).name == "runtime"
def emit(value):
    print(json.dumps(value), flush=True)
def tokens(prompt, completion, cost):
    return dict(promptTokens=prompt, completionTokens=completion, reasoningTokens=3,
                totalTokens=prompt+completion, estimatedCostUSD=cost)
total = tokens(120, 45, .0123)
usage = dict(total=total, byRootRun=[dict(rootRunId="root-a", usage=total)], byProviderModel=[
    dict(provider="openai", model="research-large", usage=tokens(100, 30, .01)),
    dict(provider="anthropic", model="review-small", usage=tokens(20, 15, .0023))],
    toolAccounting=dict(totalRequests=4, billableRequests=2, cachedToolCalls=1, unpricedRequests=1,
        estimatedCostUSD=.008, byProviderOperation=[
        dict(provider="search-provider", operation="search", toolCalls=3, requests=3, billableRequests=2,
             cachedToolCalls=1, unpricedRequests=0, estimatedCostUSD=.008),
        dict(provider="unpriced-provider", operation="fetch", toolCalls=1, requests=1, billableRequests=0,
             cachedToolCalls=0, unpricedRequests=1, estimatedCostUSD=0)]))
def goal(root, run, title, started="2026-09-08T10:00:00Z"):
    return dict(rootRunId=root, runId=run, goal=title, status="succeeded", linkedAt=started, startedAt=started, type="run")
def group(session, goals):
    return dict(sessionId=session, startedAt="2020-01-01T00:00:00Z", status="succeeded", goals=goals,
                cursor=dict(startedAt=goals[0]["startedAt"], key=session or goals[0]["rootRunId"]))
groups = [group("session-research", [goal("root-a", "root-a", "Research report")]),
          group(None, [goal("root-b", "run-b", "Review without a session", "2026-09-08T09:00:00Z")])]
tree = [dict(rootRunId="root-a", runId=run, parentRunId=parent, delegateName=title, depth=depth,
             createdAt=f"2026-09-08T10:0{depth}:00Z", status="succeeded") for run,parent,title,depth in [
             ("root-a", None, "Research report", 0), ("child-a", "root-a", "Source analysis", 1),
             ("grandchild-a", "child-a", "Citation verification", 2)]]
report = dict(target=dict(kind="root-run",requestedId="root-a",resolvedRootRunId="root-a"),
              session=None,rootRuns=[],usage=dict(total=total),timeline=[],runTree=tree,
              summary=dict(status="succeeded",reason="Research and delegated review completed."),warnings=[])
if runtime:
    emit(dict(jsonrpc="2.0",method="runtime/ready",params=dict(protocolVersion="1.17",bridgeVersion="0.1.0",pid=os.getpid())))
for line in sys.stdin:
    request=json.loads(line)
    with (home / ("runtime.log" if runtime else "trace.log")).open("a") as log: log.write(line)
    method=request["method"]; params=request.get("params",{})
    mode=(home/"mode").read_text()
    response=dict(jsonrpc="2.0",id=request["id"])
    if (home/"fail").exists() and method in ["run/inspect","trace/get","trace/usage"]:
        response["error"]=dict(code=-32000,message="Fixture retrieval failed; token=secret",data=dict(protocolCode="UNAVAILABLE"))
    else:
        if method=="initialize":
            result=dict(protocolVersion="1.17") if runtime else dict(protocolVersion="1.0",backend=dict(kind="sqlite",readOnly=True))
        elif runtime and method=="runtime/initialize":
            result=dict(agent=dict(id="fixture",name="History Preview"),runtimeMode="sqlite",workspaceRoot=str(home),shellCwd=str(home),registeredToolNames=[])
        elif runtime and method=="runtime/info":
            result=dict(protocolVersion="1.17",bridgeVersion="0.1.0",initialized=True,clientInfo=dict(name="fixture"),runtimeMode="sqlite",connections=dict(sqlite=dict(configured=True,state="connected",path=str(home/"fixture.sqlite"))))
        elif not runtime and method=="trace/listSessions":
            if mode in ["pages","legacy"]:
                result=[group(f"session-{i:03}",[goal(f"root-{i:03}",f"root-{i:03}",f"Report {i}")]) for i in range(100)] if "after" not in params else [group("last-session",[goal("last-root","last-root","Oldest report")])]
                # A very old sibling must never be used as the next-page boundary.
                if "after" not in params: result[0]["goals"].append(goal("ancient","ancient","Ancient sibling","2000-01-01T00:00:00Z"))
                if mode=="legacy":
                    for item in result: item.pop("cursor",None)
            else: result=groups
        elif not runtime and method=="trace/get":
            result=dict(report)
            if params["target"]["rootRunId"]=="root-b":
                result["runTree"]=[dict(rootRunId="root-b",runId="run-b",parentRunId=None,depth=0,status="succeeded",createdAt="2026-09-08T09:00:00Z")]
        elif not runtime and method=="trace/usage":
            result=dict(usage)
            if mode=="unavailable": result.pop("toolAccounting",None)
        elif runtime and method=="run/inspect":
            run=params["runId"]
            result=dict(run=dict(id=run,result=f"Verified findings from {run}.",usage=tokens(20,15,.0023),status="succeeded"),events=[
                dict(type="tool.completed",runId=run,payload=dict(toolName="write_file",output=dict(path=str(home/"report.md"))))])
        elif method in ["shutdown","runtime/shutdown"]: result={}
        else:
            sys.exit(91)
        response["result"]=result
    emit(response)
    if method in ["shutdown","runtime/shutdown"]: break
"""#
}

final class HistoryTests: XCTestCase {
    @MainActor
    func testParsedDatesDedupAndRecursiveHierarchy() throws {
        let model = AppModel(workingDirectoryURL: URL(fileURLWithPath: "/tmp"))
        func item(_ id: String, root: String? = nil, parent: String? = nil, session: String? = "s", time: String) -> AppModel.HistoryItem {
            .init(rootRunId: root ?? id, runId: id, parentRunId: parent, sessionId: session,
                  title: id, status: "succeeded", startedAt: time, completedAt: nil, type: "run")
        }
        let root = item("root", time: "2026-09-08T09:00:00Z")
        let child = item("child", root: "root", parent: "root", time: "2026-09-08T03:30:00-07:00")
        let sibling = item("sibling", root: "root", parent: "root", time: "2026-09-08T11:00:00Z")
        let grandchild = item("grandchild", root: "root", parent: "child", time: "2026-09-08T13:00:00Z")
        let noSession = item("solo", session: nil, time: "2026-09-08T12:00:00Z")
        let other = item("other", session: "new-session", time: "2026-09-08T12:30:00Z")
        let merged = model.mergeHistory([root, child], [root, child, sibling, grandchild, noSession, other])
        XCTAssertEqual(merged.map(\.id), ["grandchild", "other", "solo", "sibling", "child", "root"])
        let tree = AppModel.historyTree(items: merged)
        XCTAssertEqual(tree.map(\.id), ["session:s", "session:new-session", "run:solo"])
        XCTAssertEqual(tree[0].children.count, 1, "No redundant root/run identity row")
        XCTAssertEqual(tree[0].children[0].children.map(\.item?.id), ["sibling", "child"], "Run siblings use their own start time")
        XCTAssertEqual(tree[0].children[0].children[1].children[0].item?.id, "grandchild")
        XCTAssertTrue(tree[2].label.hasPrefix("No session"))
        let ties = [item("b", time: "2026-09-08T01:00:00-07:00"), item("a", time: "2026-09-08T08:00:00.000Z")]
        XCTAssertEqual(model.mergeHistory([], ties).map(\.id), ["a", "b"])
        XCTAssertEqual(AppModel.historyTree(items: merged, query: "grandchild").first?.children.first?.item?.id, "root")
    }

    @MainActor
    func testSelectionFetchesChildWithoutCreatingExecutionAndRefreshRecoversErrors() async throws {
        let fixture = try HistoryFixture()
        do {
            try await fixture.start()
            let model = fixture.model
            XCTAssertTrue(model.historyReports.isEmpty, "Trace children load lazily")
            let session = try XCTUnwrap(model.historyTree.first)
            model.setHistoryExpanded(true, node: session)
            XCTAssertTrue(model.historyReports.isEmpty)
            model.setHistoryExpanded(true, node: try XCTUnwrap(session.children.first))
            try await fixture.wait { model.historyUsage["root-a"] != nil }
            XCTAssertEqual(model.historyItem(rootRunId: "grandchild-a")?.parentRunId, "child-a")
            model.selectHistoryRun("child-a")
            try await fixture.wait { model.historyDetails["child-a"] != nil }
            XCTAssertEqual(model.selectedHistoryRunID, "child-a")
            XCTAssertEqual(model.historyDetails["child-a"]?.output, .string("Verified findings from child-a."))
            XCTAssertEqual(model.historyDetails["child-a"]?.usage?.totalTokens, 35)
            XCTAssertEqual(model.historyUsage["root-a"]?.total.totalTokens, 165)
            XCTAssertEqual(model.historyUsage["root-a"]?.byProviderModel?.count, 2)
            XCTAssertEqual(model.historyUsage["root-a"]?.toolAccounting?.unpricedRequests, 1)
            XCTAssertEqual(model.historyDetails["child-a"]?.files.first?.sourceRunId, "child-a")
            XCTAssertFalse(model.fileExists(try XCTUnwrap(model.historyDetails["child-a"]?.files.first)))
            XCTAssertEqual(model.deletableHistoryRoot(for: "root-a"), "root-a")
            XCTAssertNil(model.deletableHistoryRoot(for: "child-a"), "A child selection must never delete its root")
            XCTAssertTrue(model.runs.isEmpty)
            XCTAssertNil(model.selectedTab?.selectedRunID)

            try "fail".write(to: fixture.directory.appendingPathComponent("fail"), atomically: true, encoding: .utf8)
            model.retryHistoryReport("child-a")
            try await fixture.wait { model.historyDetailErrors["child-a"] != nil && model.historyUsageErrors["root-a"] != nil }
            XCTAssertFalse(model.historyDetailErrors["child-a"]?.contains("secret") == true)
            try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("fail"))
            model.retryHistoryReport("child-a")
            try await fixture.wait { model.historyDetails["child-a"] != nil && model.historyUsageErrors["root-a"] == nil }
            XCTAssertNil(model.historyReportErrors["root-a"])
            XCTAssertNil(model.historyDetailErrors["child-a"])
            let requests = try fixture.requests("runtime")
            XCTAssertEqual(requests.filter { $0.objectValue?["method"] == .string("run/inspect") }.count, 3)
            XCTAssertTrue(requests.allSatisfy { !$0.objectValue!["method"]!.stringValue!.hasPrefix("agent/") })
            let traceRequests = try fixture.requests("trace")
            XCTAssertTrue(traceRequests.contains { $0.objectValue?["method"] == .string("trace/usage") })
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @MainActor
    func testCursorPagesKeepBoundaryAndLegacyHelperNeverUsesUnsafeUntil() async throws {
        for mode in ["pages", "legacy"] {
            let fixture = try HistoryFixture(mode: mode)
            do {
                try await fixture.start()
                XCTAssertEqual(fixture.model.historyItems.count, 101)
                if mode == "pages" {
                    XCTAssertTrue(fixture.model.hasOlderHistory)
                    fixture.model.loadOlderHistory()
                    try await fixture.wait { fixture.model.historyItems.count == 102 }
                    XCTAssertFalse(fixture.model.hasOlderHistory)
                    let pages = try fixture.requests("trace").filter { $0.objectValue?["method"] == .string("trace/listSessions") }
                    XCTAssertEqual(pages.count, 2)
                    let first = pages[0].objectValue?["params"]?.objectValue
                    let second = pages[1].objectValue?["params"]?.objectValue
                    XCTAssertEqual(first?["until"], second?["until"])
                    XCTAssertEqual(second?["after"]?.objectValue?["key"], .string("session-099"))
                    XCTAssertEqual(second?["after"]?.objectValue?["startedAt"], .string("2026-09-08T10:00:00Z"))
                } else {
                    XCTAssertFalse(fixture.model.hasOlderHistory)
                    XCTAssertNotNil(fixture.model.historyPagingMessage)
                    fixture.model.loadOlderHistory()
                    try await Task.sleep(for: .milliseconds(80))
                    XCTAssertEqual(try fixture.requests("trace").filter { $0.objectValue?["method"] == .string("trace/listSessions") }.count, 1)
                }
            } catch { await fixture.close(); throw error }
            await fixture.close()
        }
        let value = try JSONValue.encode(TraceSessionListParameters(after: .init(startedAt: nil, key: "null-time")))
        XCTAssertEqual(value.objectValue?["after"]?.objectValue?["startedAt"], .null)
    }

    @MainActor
    func testFileEvidenceFiltersRunPathsAndFailedOrUnchangedTools() throws {
        func event(_ run: String = "child", type: String = "tool.completed", tool: String = "write_file", path: String, changed: Bool = true) -> JSONValue {
            .object(["type": .string(type), "runId": .string(run), "payload": .object([
                "toolName": .string(tool), "output": .object(["path": .string(path), "changed": .bool(changed)])])])
        }
        let inspection: JSONValue = .object([
            "run": .object(["id": .string("child"), "result": .object(["authorization": .string("secret"), "answer": .string("Selected answer")])]),
            "events": .array([
                event(path: "/tmp/work/answer.md"), event(path: "/tmp/work/../escape.md"),
                event("other", path: "/tmp/work/other.md"), event(type: "tool.failed", path: "/tmp/work/failed.md"),
                event(tool: "edit_file", path: "/tmp/work/unchanged.md", changed: false),
                event(path: "relative.md"), event(tool: "shell_exec", path: "/tmp/work/shell.md")])])
        let detail = try AppModel.historyDetail(inspection, runId: "child", workspace: "/tmp/work")
        XCTAssertEqual(detail.files.map(\.path), ["/tmp/work/answer.md"])
        XCTAssertEqual(detail.files.first?.sourceRunId, "child")
        XCTAssertFalse(detail.output!.prettyPrinted.contains("secret"))
        let incompleteUsage: JSONValue = .object([
            "run": .object(["id": .string("child"), "result": .string("Still visible"), "usage": .object(["promptTokens": .number(1)])]),
            "events": .array([])])
        XCTAssertEqual(try AppModel.historyDetail(incompleteUsage, runId: "child", workspace: "/tmp/work").output, .string("Still visible"))
        XCTAssertNil(try AppModel.historyDetail(incompleteUsage, runId: "child", workspace: "/tmp/work").usage)
        XCTAssertThrowsError(try AppModel.historyDetail(inspection, runId: "root", workspace: "/tmp/work"))
    }
}
