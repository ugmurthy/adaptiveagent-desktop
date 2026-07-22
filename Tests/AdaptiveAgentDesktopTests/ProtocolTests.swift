import XCTest
@testable import AdaptiveAgentDesktop

final class ProtocolTests: XCTestCase {
    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object(["name": .string("agent"), "items": .array([.number(1), .bool(true), .null])])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testSuccessAndErrorEnvelopeDecoding() throws {
        let success = try JSONDecoder().decode(ResponseEnvelope.self, from: Data(#"{"version":1,"id":"a","type":"response","ok":true,"result":{"runId":"r"}}"#.utf8))
        XCTAssertTrue(success.ok)
        XCTAssertEqual(success.result?.objectValue?["runId"], .string("r"))
        let failure = try JSONDecoder().decode(ResponseEnvelope.self, from: Data(#"{"version":1,"id":"b","type":"response","ok":false,"error":{"code":"BAD","message":"No"}}"#.utf8))
        XCTAssertEqual(failure.error?.code, "BAD")
    }

    func testReadyAndAgentEventDecoding() throws {
        let ready = try JSONDecoder().decode(RuntimeReady.self, from: Data(#"{"version":1,"type":"runtime.ready","protocolVersion":1,"bridgeVersion":"0.1.0","pid":12}"#.utf8))
        XCTAssertEqual(ready.protocolVersion, 1)
        let event = try JSONDecoder().decode(AgentEventEnvelope.self, from: Data(#"{"version":1,"type":"agent.event","event":{"type":"run.started"}}"#.utf8))
        XCTAssertEqual(event.event.objectValue?["type"], .string("run.started"))
    }

    func testCommandEncodingUsesUUIDAndNewline() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let data = try ProtocolCodec.encodeCommand(id: id, type: "run.start", fields: ["goal": .string("Ship it")])
        XCTAssertEqual(data.last, 0x0A)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(data.dropLast()))
        XCTAssertEqual(value.objectValue?["version"], .number(1))
        XCTAssertEqual(value.objectValue?["id"], .string(id.uuidString))
        XCTAssertEqual(value.objectValue?["goal"], .string("Ship it"))
    }
}
