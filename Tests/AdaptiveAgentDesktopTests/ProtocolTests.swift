import XCTest
@testable import AdaptiveAgentDesktop

final class ProtocolTests: XCTestCase {
    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object(["name": .string("agent"), "items": .array([.number(1), .bool(true), .null])])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testRequestEncodingUsesJSONRPCStringIDAndNewline() throws {
        let data = try ProtocolCodec.encodeRequest(
            id: .string("11111111-2222-3333-4444-555555555555"),
            method: "agent/run",
            params: ["goal": .string("Ship it")]
        )
        XCTAssertEqual(data.last, 0x0A)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(data.dropLast()))
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["jsonrpc"], .string("2.0"))
        XCTAssertEqual(object["id"], .string("11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(object["method"], .string("agent/run"))
        XCTAssertEqual(object["params"]?.objectValue?["goal"], .string("Ship it"))
        XCTAssertNil(object["version"])
        XCTAssertNil(object["type"])
    }

    func testReadyNotificationRequiresNoIDAndExactStringVersion() throws {
        let message = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":12}}"#.utf8))
        XCTAssertEqual(message, .ready(RuntimeReady(protocolVersion: "1.10", bridgeVersion: "0.1.0", pid: 12)))

        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","id":"ready","method":"runtime/ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":12}}"#.utf8)))
        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":1.10,"bridgeVersion":"0.1.0","pid":12}}"#.utf8)))
    }

    func testResponsesPreserveIDTypesAndDecodeProtocolErrorCode() throws {
        let stringID = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","id":"1","result":{"runId":"r"}}"#.utf8))
        XCTAssertEqual(stringID, .success(id: .string("1"), result: .object(["runId": .string("r")])))

        let numericID = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8))
        XCTAssertEqual(numericID, .success(id: .number(1), result: .null))

        let failure = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","id":"e","error":{"code":-32602,"message":"Invalid parameters","data":{"protocolCode":"INVALID_PARAMS"}}}"#.utf8))
        XCTAssertEqual(failure, .failure(
            id: .string("e"),
            error: JSONRPCErrorObject(
                code: -32602,
                message: "Invalid parameters",
                data: .object(["protocolCode": .string("INVALID_PARAMS")])
            )
        ))
    }

    func testNotificationsAreDistinctFromResponses() throws {
        let event = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"agent/event","params":{"type":"run.started"}}"#.utf8))
        XCTAssertEqual(event, .notification(method: "agent/event", params: .object(["type": .string("run.started")])))

        let output = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"cli/output","params":{"stream":"stdout","line":"ok"}}"#.utf8))
        XCTAssertEqual(output, .notification(method: "cli/output", params: .object(["stream": .string("stdout"), "line": .string("ok")])))
    }

    func testLegacyMessagesAndBatchesAreRejected() {
        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"{"version":1,"id":"hello","type":"hello"}"#.utf8)))
        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"[{"jsonrpc":"2.0","id":1,"result":null}]"#.utf8)))
        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"agent/event","id":1,"params":{}}"#.utf8)))
    }

    func testNDJSONBufferHandlesFragmentedAndMultipleMessages() {
        var buffer = NDJSONBuffer()
        XCTAssertTrue(buffer.append(Data(#"{"jsonrpc":"2.0""#.utf8)).isEmpty)
        let lines = buffer.append(Data("}\n{\"jsonrpc\":\"2.0\"}\npartial".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, [#"{"jsonrpc":"2.0"}"#, #"{"jsonrpc":"2.0"}"#])
        XCTAssertEqual(buffer.append(Data(" line\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["partial line"])
    }

    @MainActor
    func testAppModelUsesLaunchDirectoryAndLocalSettingsForInitialization() async throws {
        let workspace = try temporaryDirectoryURL()
        let settings = workspace.appendingPathComponent("agent.settings.json")
        try "{}".write(to: settings, atomically: true, encoding: .utf8)
        let requestLog = temporaryFileURL(named: "app-model-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.10"}}' ;;
    runtime/initialize)
      printf '{"jsonrpc":"2.0","id":"%s","result":{"agent":{"id":"default","name":"Default Agent"},"runtimeMode":"memory","workspaceRoot":"%s","shellCwd":"%s","registeredToolNames":["write_file"]}}\n' "$id" \#(shellQuote(workspace.path)) \#(shellQuote(workspace.path))
      ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        let model = AppModel(client: client, workingDirectoryURL: workspace)

        XCTAssertEqual(model.workspacePath, workspace.standardizedFileURL.path)
        XCTAssertEqual(model.settingsConfigPath, settings.path)
        model.bootstrap()
        for _ in 0..<100 where !model.isConnected {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isConnected, model.status)
        XCTAssertEqual(model.agentName, "Default Agent")
        XCTAssertEqual(model.effectiveWorkspaceRoot, workspace.path)

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let runtimeInitialize = try XCTUnwrap(requests.first {
            $0.objectValue?["method"] == .string("runtime/initialize")
        })
        let params = try XCTUnwrap(runtimeInitialize.objectValue?["params"]?.objectValue)
        XCTAssertEqual(params["cwd"], .string(workspace.path))
        XCTAssertEqual(params["settingsConfigPath"], .string(settings.path))
        XCTAssertEqual(params["approvalMode"], .string("manual"))
        XCTAssertEqual(params["clarificationMode"], .string("interactive"))
        XCTAssertNil(params["agentConfigPath"])
        await model.shutdown()
    }

    @MainActor
    func testRunActionCanInspectAnEnteredRunIDWithoutAnExistingRecord() async throws {
        let workspace = try temporaryDirectoryURL()
        let requestLog = temporaryFileURL(named: "entered-run-action-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.10"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{"runtimeMode":"memory"}}\n' "$id" ;;
    run/inspect) printf '{"jsonrpc":"2.0","id":"%s","result":{"run":{"id":"persisted-run","status":"failed"},"events":[]}}\n' "$id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        let model = AppModel(client: client, workingDirectoryURL: workspace)
        model.bootstrap()
        for _ in 0..<100 where !model.isConnected {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isConnected, model.status)
        XCTAssertTrue(model.runs.isEmpty)

        model.runCommand("run/inspect", runId: "  persisted-run  ")
        for _ in 0..<100 {
            if model.runs.first?.output != nil, model.runs.first?.isRequestInFlight == false { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let record = try XCTUnwrap(model.runs.first)
        XCTAssertEqual(model.selectedRunItemID, record.id)
        XCTAssertEqual(record.latestRunId, "persisted-run")
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.output?.objectValue?["run"]?.objectValue?["id"], .string("persisted-run"))

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let inspection = try XCTUnwrap(requests.first {
            $0.objectValue?["method"] == .string("run/inspect")
        })
        XCTAssertEqual(inspection.objectValue?["params"]?.objectValue?["runId"], .string("persisted-run"))
        await model.shutdown()
    }

    @MainActor
    func testRunResultApprovalEventsAndStructuredWrittenFilesArePresented() throws {
        let workspace = try temporaryDirectoryURL()
        let sourceDirectory = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let writtenFile = sourceDirectory.appendingPathComponent("Generated.swift")
        let editedFile = sourceDirectory.appendingPathComponent("Existing.swift")
        try "generated".write(to: writtenFile, atomically: true, encoding: .utf8)
        try "edited".write(to: editedFile, atomically: true, encoding: .utf8)

        let model = AppModel(workingDirectoryURL: workspace)
        model.effectiveWorkspaceRoot = workspace.path
        let recordID = UUID()
        model.runs = [AppModel.RunRecord(id: recordID, kind: .run, title: "Generate files")]
        model.acceptResult(.object([
            "status": .string("success"),
            "runId": .string("root-run"),
            "output": .string("# Done\n\nGenerated the requested files.")
        ]), for: recordID)

        XCTAssertEqual(model.runs[0].status, .succeeded)
        XCTAssertEqual(model.runs[0].output, .string("# Done\n\nGenerated the requested files."))

        model.receive(method: "agent/event", params: .object([
            "schemaVersion": .number(1),
            "type": .string("delegate.spawned"),
            "runId": .string("root-run"),
            "payload": .object(["childRunId": .string("child-run"), "rootRunId": .string("root-run")])
        ]))
        model.receive(method: "agent/event", params: .object([
            "schemaVersion": .number(1),
            "type": .string("approval.requested"),
            "runId": .string("child-run"),
            "payload": .object([
                "toolName": .string("shell_exec"),
                "input": .object(["command": .string("git status")])
            ])
        ]))
        XCTAssertEqual(model.runs[0].status, .waitingForApproval)
        guard case .approval(let toolName, let input, _) = model.runs[0].interaction?.kind else {
            return XCTFail("approval.requested should create an approval interaction")
        }
        XCTAssertEqual(toolName, "shell_exec")
        XCTAssertEqual(input?.objectValue?["command"], .string("git status"))
        XCTAssertEqual(model.runs[0].interaction?.runId, "child-run")

        model.acceptResult(.object([
            "status": .string("approval_requested"),
            "runId": .string("root-run"),
            "message": .string("Approval required")
        ]), for: recordID)
        XCTAssertEqual(model.runs[0].interaction?.runId, "child-run", "the paused root response must not replace the requesting child run")
        model.runs[0].interaction?.isResolving = true
        model.acceptResult(.object(["runId": .string("child-run"), "approved": .bool(true)]), for: recordID)
        XCTAssertNil(model.runs[0].interaction)
        XCTAssertEqual(model.runs[0].status, .running)
        XCTAssertEqual(model.runs[0].latestRunId, "root-run")

        model.receive(method: "agent/event", params: toolCompletedEvent(
            runId: "root-run",
            toolName: "write_file",
            output: ["path": .string(writtenFile.path), "sizeBytes": .number(9)]
        ))
        model.receive(method: "agent/event", params: toolCompletedEvent(
            runId: "child-run",
            toolName: "edit_file",
            output: ["path": .string(editedFile.path), "changed": .bool(true)]
        ))
        model.receive(method: "agent/event", params: toolCompletedEvent(
            runId: "root-run",
            toolName: "edit_file",
            output: ["path": .string(writtenFile.path), "changed": .bool(false)]
        ))
        model.receive(method: "agent/event", params: toolCompletedEvent(
            runId: "root-run",
            toolName: "write_file",
            output: ["path": .string(workspace.deletingLastPathComponent().appendingPathComponent("outside.txt").path)]
        ))

        XCTAssertEqual(model.runs[0].files.count, 2)
        XCTAssertEqual(model.runs[0].files.map(\.path), [writtenFile.path, editedFile.path].sorted())
        let childFile = try XCTUnwrap(model.runs[0].files.first { $0.path == editedFile.path })
        XCTAssertEqual(childFile.operation, .edited)
        XCTAssertEqual(childFile.sourceRunId, "child-run")
        XCTAssertEqual(model.relativeDisplayPath(for: childFile), "Sources/Existing.swift")
        XCTAssertTrue(model.fileExists(childFile))
    }

    func testRuntimeProcessUsesSuppliedWorkingDirectory() async throws {
        let workspace = try temporaryDirectoryURL()
        let pwdLog = temporaryFileURL(named: "pwd.txt")
        let executable = try makeRuntimeScript(#"""
pwd > \#(shellQuote(pwdLog.path))
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.10"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        try await client.start(workingDirectoryURL: workspace, notificationHandler: { _, _ in }, errorHandler: { _ in })
        _ = try await client.initializeRuntime()
        await client.shutdown()
        let reportedPath = try String(contentsOf: pwdLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: reportedPath).resolvingSymlinksInPath().path,
            workspace.resolvingSymlinksInPath().path
        )
    }

    func testLongRunningAgentRequestCanDisableTheStandardResponseTimeout() async throws {
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.10"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id" ;;
    agent/run) sleep 0.15; printf '{"jsonrpc":"2.0","id":"%s","result":{"status":"success","runId":"slow-run","output":"Done"}}\n' "$id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .milliseconds(30))
        try await client.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
        _ = try await client.initializeRuntime()
        let result = try await client.send(
            method: "agent/run",
            params: ["goal": .string("Wait")],
            timeoutPolicy: .none
        )
        XCTAssertEqual(result.objectValue?["runId"], .string("slow-run"))
        await client.shutdown()
    }

    func testHandshakeRuntimeGateNotificationsErrorsAndGracefulShutdown() async throws {
        let logURL = temporaryFileURL(named: "requests.log")
        let shutdownURL = temporaryFileURL(named: "shutdown.txt")
        let executable = try makeRuntimeScript(#"""
printf '%s' '{"jsonrpc":"2.0","method":"runtime/'
sleep 0.05
printf '%s\n' 'ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(logURL.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize)
      printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","capabilities":{}}}'
      ;;
    runtime/initialize)
      printf '{"jsonrpc":"2.0","id":"%s","result":{"runtimeMode":"postgres"}}\n' "$id"
      printf '%s\n' '{"jsonrpc":"2.0","method":"agent/event","params":{"schemaVersion":1,"type":"run.started","runId":"run-1"}}'
      sleep 0.02
      printf '%s\n' '{"jsonrpc":"2.0","method":"cli/output","params":{"requestId":"cli-1","stream":"stdout","line":"ok"}}'
      ;;
    agent/run)
      printf '{"jsonrpc":"2.0","id":"%s","result":{"runId":"run-1"}}\n' "$id"
      ;;
    interaction/resolveApproval)
      printf '{"jsonrpc":"2.0","id":"%s","result":{"runId":"run-1","approved":true}}\n' "$id"
      ;;
    runtime/info)
      printf '{"jsonrpc":"2.0","id":"%s","error":{"code":-32602,"message":"No info","data":{"protocolCode":"INVALID_PARAMS"}}}\n' "$id"
      ;;
    runtime/shutdown)
      printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"
      if IFS= read -r extra; then
        printf '%s' 'stdin-still-open-with-data' > \#(shellQuote(shutdownURL.path))
      else
        printf '%s' 'response-before-eof' > \#(shellQuote(shutdownURL.path))
      fi
      exit 0
      ;;
    *) exit 91 ;;
  esac
done
"""#)
        let recorder = NotificationRecorder()
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        do {
            try await client.start(notificationHandler: { method, params in
                if method == "agent/event" { try? await Task.sleep(for: .milliseconds(50)) }
                await recorder.append(method: method, params: params)
            }, errorHandler: { _ in })
        } catch {
            return XCTFail("protocol startup failed: \(error)")
        }

        let firstRequest = try XCTUnwrap(try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").first)
        let initialize = try JSONDecoder().decode(JSONValue.self, from: Data(firstRequest.utf8))
        XCTAssertEqual(initialize.objectValue?["jsonrpc"], .string("2.0"))
        XCTAssertEqual(initialize.objectValue?["id"], .string("initialize"))
        XCTAssertEqual(initialize.objectValue?["method"], .string("initialize"))
        XCTAssertEqual(initialize.objectValue?["params"]?.objectValue?["protocolVersion"], .string("1.10"))

        do {
            _ = try await client.send(method: "agent/run", params: ["goal": .string("too early")])
            XCTFail("agent/run must be gated until runtime/initialize succeeds")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .notInitialized("Agent runtime"))
        }
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").count, 1)

        let initialized: JSONValue
        do {
            initialized = try await client.initializeRuntime(params: ["runtimeMode": .string("postgres")])
        } catch {
            await client.shutdown()
            return XCTFail("runtime/initialize failed: \(error)")
        }
        XCTAssertEqual(initialized.objectValue?["runtimeMode"], .string("postgres"))
        let notifications = await waitForNotifications(recorder, count: 2)
        XCTAssertEqual(notifications.map(\.method), ["agent/event", "cli/output"])

        let run: JSONValue
        do {
            run = try await client.send(method: "agent/run", params: ["goal": .string("Ship it")])
        } catch {
            await client.shutdown()
            return XCTFail("agent/run failed: \(error)")
        }
        XCTAssertEqual(run.objectValue?["runId"], .string("run-1"))
        do {
            _ = try await client.send(method: "runtime/info")
            XCTFail("runtime/info should return its JSON-RPC error")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .remote(code: -32602, protocolCode: "INVALID_PARAMS", message: "No info"))
        }

        let approval = try await client.send(
            method: "interaction/resolveApproval",
            params: ["runId": .string("run-1"), "approved": .bool(true)]
        )
        XCTAssertEqual(approval.objectValue?["approved"], .bool(true))
        let approvalRequest = try XCTUnwrap(
            try String(contentsOf: logURL, encoding: .utf8)
                .split(separator: "\n")
                .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                .first { $0.objectValue?["method"] == .string("interaction/resolveApproval") }
        )
        XCTAssertEqual(approvalRequest.objectValue?["jsonrpc"], .string("2.0"))
        XCTAssertNotNil(approvalRequest.objectValue?["id"])
        XCTAssertEqual(approvalRequest.objectValue?["params"]?.objectValue?["runId"], .string("run-1"))
        XCTAssertEqual(approvalRequest.objectValue?["params"]?.objectValue?["approved"], .bool(true))

        await client.shutdown()
        XCTAssertEqual(try String(contentsOf: shutdownURL, encoding: .utf8), "response-before-eof")
    }

    func testOutOfOrderResponsesAreCorrelatedByID() async throws {
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":123}}'
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.10"}}'
IFS= read -r line
id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"
IFS= read -r first
IFS= read -r second
first_id="$(printf '%s' "$first" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
second_id="$(printf '%s' "$second" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
case "$first" in *'"runId":"first"'*) first_label=first ;; *) first_label=second ;; esac
case "$second" in *'"runId":"first"'*) second_label=first ;; *) second_label=second ;; esac
printf '{"jsonrpc":"2.0","id":"%s","result":{"label":"%s"}}\n' "$second_id" "$second_label"
printf '{"jsonrpc":"2.0","id":"%s","result":{"label":"%s"}}\n' "$first_id" "$first_label"
IFS= read -r line
id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        try await client.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
        _ = try await client.initializeRuntime()

        async let first = client.send(method: "run/inspect", params: ["runId": .string("first")])
        async let second = client.send(method: "run/inspect", params: ["runId": .string("second")])
        let (firstResult, secondResult) = try await (first, second)
        XCTAssertEqual(firstResult.objectValue?["label"], .string("first"))
        XCTAssertEqual(secondResult.objectValue?["label"], .string("second"))
        await client.shutdown()
    }

    func testUnsupportedAndLegacyStartupNeverFallBack() async throws {
        let requestLog = temporaryFileURL(named: "unsupported-requests.log")
        let unsupported = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.9","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do printf '%s\n' "$line" >> \#(shellQuote(requestLog.path)); done
"""#)
        let unsupportedClient = RuntimeClient(executableURL: unsupported, readyTimeout: .seconds(1))
        do {
            try await unsupportedClient.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
            XCTFail("unsupported protocol should fail startup")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .incompatibleRuntime("1.9"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestLog.path))

        let legacy = try makeRuntimeScript(#"""
printf '%s\n' '{"version":1,"type":"runtime.ready","protocolVersion":1,"bridgeVersion":"0.1.0","pid":123}'
sleep 5
"""#)
        let legacyClient = RuntimeClient(executableURL: legacy, readyTimeout: .seconds(1))
        do {
            try await legacyClient.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
            XCTFail("legacy startup should fail")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .incompatibleRuntime(nil))
        }
    }

    func testLegacyOperationalMessageIsRejected() async throws {
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":123}}'
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.10"}}'
IFS= read -r line
printf '%s\n' '{"version":1,"id":"old","type":"response","ok":true,"result":{}}'
sleep 5
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        let terminations = TerminationRecorder()
        try await client.start(
            notificationHandler: { _, _ in },
            errorHandler: { _ in },
            terminationHandler: { status in await terminations.append(status) }
        )
        do {
            _ = try await client.send(method: "runtime/info")
            XCTFail("legacy operational response should fail")
        } catch {
            guard case .protocolViolation = error as? RuntimeClientError else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        for _ in 0..<50 {
            if !(await terminations.values).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let terminationValues = await terminations.values
        XCTAssertFalse(terminationValues.isEmpty, "post-initialization protocol failure must notify the app that the runtime stopped")
        await client.shutdown()
    }

    func testUnexpectedRuntimeTerminationFailsPendingRequest() async throws {
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.10","bridgeVersion":"0.1.0","pid":123}}'
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.10"}}'
IFS= read -r line
exit 7
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        try await client.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
        do {
            _ = try await client.send(method: "runtime/info")
            XCTFail("request should fail when the runtime exits")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .terminated(7))
        }
        await client.shutdown()
    }

    private func makeRuntimeScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaptiveAgentDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agent-runtime")
        try "#!/bin/sh\nset -eu\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func temporaryFileURL(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaptiveAgentDesktopTests-\(UUID().uuidString)-\(name)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func temporaryDirectoryURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaptiveAgentDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func toolCompletedEvent(
        runId: String,
        toolName: String,
        output: [String: JSONValue]
    ) -> JSONValue {
        .object([
            "schemaVersion": .number(1),
            "type": .string("tool.completed"),
            "runId": .string(runId),
            "payload": .object(["toolName": .string(toolName), "output": .object(output)])
        ])
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func waitForNotifications(_ recorder: NotificationRecorder, count: Int) async -> [(method: String, params: JSONValue)] {
        for _ in 0..<50 {
            let values = await recorder.values
            if values.count >= count { return values }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await recorder.values
    }
}

private actor NotificationRecorder {
    private(set) var values: [(method: String, params: JSONValue)] = []

    func append(method: String, params: JSONValue) {
        values.append((method, params))
    }
}

private actor TerminationRecorder {
    private(set) var values: [Int32] = []

    func append(_ status: Int32) {
        values.append(status)
    }
}
