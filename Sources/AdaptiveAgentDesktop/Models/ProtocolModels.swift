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
    static let version = "1.10"

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
