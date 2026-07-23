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
        try await client.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
        do {
            _ = try await client.send(method: "runtime/info")
            XCTFail("legacy operational response should fail")
        } catch {
            guard case .protocolViolation = error as? RuntimeClientError else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
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
