import Foundation

struct RuntimeReady: Decodable, Equatable {
    let version: Int
    let type: String
    let protocolVersion: Int
    let bridgeVersion: String
    let pid: Int
}

struct ResponseEnvelope: Decodable, Equatable {
    struct Failure: Decodable, Equatable { let code: String; let message: String }
    let version: Int
    let id: String
    let type: String
    let ok: Bool
    let result: JSONValue?
    let error: Failure?
}

struct AgentEventEnvelope: Decodable, Equatable {
    let version: Int
    let type: String
    let event: JSONValue
}

enum ProtocolCodec {
    static let version = 1

    static func encodeCommand(id: UUID, type: String, fields: [String: JSONValue] = [:]) throws -> Data {
        var command = fields
        command["version"] = .number(Double(version))
        command["id"] = .string(id.uuidString)
        command["type"] = .string(type)
        var data = try JSONEncoder().encode(JSONValue.object(command))
        data.append(0x0A)
        return data
    }
}
