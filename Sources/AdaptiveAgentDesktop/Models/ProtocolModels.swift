import Foundation

enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            let value = try container.decode(Double.self)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSON-RPC ids must be finite")
            }
            self = .number(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "JSON-RPC ids must be finite"))
            }
            try container.encode(value)
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        }
    }
}

struct RuntimeReady: Equatable, Sendable {
    let protocolVersion: String
    let bridgeVersion: String
    let pid: Int
}

struct RuntimeInitializationParameters: Codable, Equatable, Sendable {
    var cwd: String? = nil
    var agentConfigPath: String? = nil
    var settingsConfigPath: String? = nil
    var runtimeMode: String? = nil
    var provider: String? = nil
    var model: String? = nil
    var approvalMode: String? = nil
    var clarificationMode: String? = nil
    var inferenceMode: String? = nil
    var inferenceTier: String? = nil
    var gatewayURL: String? = nil
    var requireRunPermit: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case cwd
        case agentConfigPath
        case settingsConfigPath
        case runtimeMode
        case provider
        case model
        case approvalMode
        case clarificationMode
        case inferenceMode
        case inferenceTier
        case gatewayURL = "gatewayUrl"
        case requireRunPermit
    }
}

struct RuntimeInitializationResult: Codable, Equatable, Sendable {
    struct Agent: Codable, Equatable, Sendable {
        let id: String
        let name: String
    }

    let agent: Agent
    let runtimeMode: String
    let workspaceRoot: String
    let shellCwd: String
    let registeredToolNames: [String]
    let inferenceMode: String?
    let inferenceTier: String?
}

struct RuntimeInfo: Codable, Equatable, Sendable {
    struct ClientInfo: Codable, Equatable, Sendable {
        let name: String
        let version: String?
    }

    struct Connection: Codable, Equatable, Sendable {
        let configured: Bool
        let state: String
        let path: String?
    }

    struct Connections: Codable, Equatable, Sendable {
        let sqlite: Connection?
        let gateway: Connection?
    }

    let protocolVersion: String
    let bridgeVersion: String
    let initialized: Bool
    let clientInfo: ClientInfo
    let runtimeMode: String?
    let agentId: String?
    let workspaceRoot: String?
    let inferenceMode: String?
    let inferenceTier: String?
    let connections: Connections?
}

struct AccessTokenUpdateResult: Codable, Equatable, Sendable {
    let updated: Bool
}

enum ProtocolRedactor {
    private static let sensitiveKeys = ["accesstoken", "authorization", "apikey", "token"]

    static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values):
            return .array(values.map(redact))
        case .object(let fields):
            return .object(fields.mapValues { redact($0) }.mapValuesWithKeys { key, value in
                isSensitive(key) ? .string("<redacted>") : value
            })
        default:
            return value
        }
    }

    static func redact(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#,
            #"(?i)(\"?(?:access[_-]?token|api[_-]?key|authorization)\"?\s*[:=]\s*\"?)[^\"\s,}]+"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1<redacted>",
                options: .regularExpression
            )
        }
        return result
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return sensitiveKeys.contains { normalized == $0 || normalized.hasSuffix($0) }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func mapValuesWithKeys(_ transform: (String, JSONValue) -> JSONValue) -> Self {
        reduce(into: [:]) { result, entry in
            result[entry.key] = transform(entry.key, entry.value)
        }
    }
}

struct JSONRPCErrorObject: Equatable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    var protocolCode: String? {
        data?.objectValue?["protocolCode"]?.stringValue
    }
}

enum RuntimeProtocolMessage: Equatable, Sendable {
    case ready(RuntimeReady)
    case notification(method: String, params: JSONValue)
    case success(id: JSONRPCID, result: JSONValue)
    case failure(id: JSONRPCID, error: JSONRPCErrorObject)
}

enum ProtocolCodec {
    static let version = "1.16"

    static func encodeRequest(id: JSONRPCID, method: String, params: [String: JSONValue] = [:]) throws -> Data {
        let request = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "method": .string(method),
            "params": .object(params)
        ])
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }

    static func decodeMessage(_ data: Data) throws -> RuntimeProtocolMessage {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = value.objectValue else {
            throw RuntimeClientError.protocolViolation("JSON-RPC batches and non-object messages are unsupported")
        }
        guard object["jsonrpc"] == .string("2.0") else {
            throw RuntimeClientError.protocolViolation("message is not JSON-RPC 2.0")
        }

        if let methodValue = object["method"] {
            guard !object.keys.contains("id") else {
                throw RuntimeClientError.protocolViolation("runtime notifications must not contain an id")
            }
            guard let method = methodValue.stringValue else {
                throw RuntimeClientError.protocolViolation("notification method must be a string")
            }
            let params = object["params"] ?? .object([:])
            if method == "runtime/ready" {
                return .ready(try decodeReady(params))
            }
            return .notification(method: method, params: params)
        }

        guard let idValue = object["id"] else {
            throw RuntimeClientError.protocolViolation("response is missing an id")
        }
        let id = try decodeID(idValue)
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            throw RuntimeClientError.protocolViolation("response must contain exactly one of result or error")
        }
        if hasResult {
            return .success(id: id, result: object["result"] ?? .null)
        }
        return .failure(id: id, error: try decodeError(object["error"]))
    }

    private static func decodeReady(_ value: JSONValue) throws -> RuntimeReady {
        guard let params = value.objectValue,
              let protocolVersion = params["protocolVersion"]?.stringValue,
              let bridgeVersion = params["bridgeVersion"]?.stringValue,
              case .number(let pidValue) = params["pid"],
              let pid = Int(exactly: pidValue) else {
            throw RuntimeClientError.protocolViolation("runtime/ready params are invalid")
        }
        return RuntimeReady(protocolVersion: protocolVersion, bridgeVersion: bridgeVersion, pid: pid)
    }

    private static func decodeID(_ value: JSONValue) throws -> JSONRPCID {
        switch value {
        case .string(let id): return .string(id)
        case .number(let id) where id.isFinite: return .number(id)
        default: throw RuntimeClientError.protocolViolation("response id must be a string or finite number")
        }
    }

    private static func decodeError(_ value: JSONValue?) throws -> JSONRPCErrorObject {
        guard let object = value?.objectValue,
              case .number(let codeValue) = object["code"],
              let code = Int(exactly: codeValue),
              let message = object["message"]?.stringValue else {
            throw RuntimeClientError.protocolViolation("JSON-RPC error object is invalid")
        }
        return JSONRPCErrorObject(code: code, message: message, data: object["data"])
    }
}
