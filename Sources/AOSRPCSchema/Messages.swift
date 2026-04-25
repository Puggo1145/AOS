import Foundation

// MARK: - JSON-RPC envelopes
//
// Per docs/designs/rpc-protocol.md §"消息模型". All envelopes pin
// `jsonrpc = "2.0"`. `params` is always an object (TS / Swift struct);
// no positional array form is supported.

/// JSON-RPC request id. Spec allows numbers and strings; nulls are not used.
public enum RPCId: Hashable, Sendable, Codable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "RPCId must be int or string"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i): try container.encode(i)
        case .string(let s): try container.encode(s)
        }
    }
}

/// JSON-RPC 2.0 request, generic over its `params` payload.
public struct RPCRequest<P: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: RPCId
    public let method: String
    public let params: P

    public init(id: RPCId, method: String, params: P) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// JSON-RPC 2.0 success response, generic over its `result` payload.
public struct RPCResponse<R: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: RPCId
    public let result: R

    public init(id: RPCId, result: R) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
    }
}

/// JSON-RPC 2.0 error response.
public struct RPCErrorResponse: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: RPCId
    public let error: RPCError

    public init(id: RPCId, error: RPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.error = error
    }
}

/// JSON-RPC 2.0 notification (no `id`, no response).
public struct RPCNotification<P: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let method: String
    public let params: P

    public init(method: String, params: P) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

// MARK: - Error model
//
// Per docs/designs/rpc-protocol.md §"错误模型". Standard JSON-RPC codes plus
// AOS application-segment codes.

public struct RPCError: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Canonical AOS RPC error codes.
public enum RPCErrorCode {
    /// Standard JSON-RPC errors.
    public static let parseError: Int = -32700
    public static let invalidRequest: Int = -32600
    public static let methodNotFound: Int = -32601
    public static let invalidParams: Int = -32602
    public static let internalError: Int = -32603

    /// AOS application generic segment.
    public static let unhandshaked: Int = -32000
    public static let payloadTooLarge: Int = -32001
    public static let timeout: Int = -32002
    public static let permissionDenied: Int = -32003

    /// Auth segment (provider OAuth login). Per onboarding plan.
    public static let loginInProgress: Int = -32200
    public static let loginCancelled: Int = -32201
    public static let loginTimeout: Int = -32202
    public static let unknownProvider: Int = -32203
    public static let loginNotConfigured: Int = -32204

    /// Agent segment (agent loop runtime). Per docs/designs/rpc-protocol.md
    /// "错误模型" allocation `-32300 ~ -32399`.
    public static let agentContextOverflow: Int = -32300
    public static let agentConfigInvalid: Int = -32301
}

// MARK: - Method name constants

/// String constants for every RPC method shipped in this stage.
public enum RPCMethod {
    public static let rpcHello = "rpc.hello"
    public static let rpcPing = "rpc.ping"
    public static let agentSubmit = "agent.submit"
    public static let agentCancel = "agent.cancel"
    public static let agentReset = "agent.reset"
    public static let conversationTurnStarted = "conversation.turnStarted"
    public static let conversationReset = "conversation.reset"
    public static let uiToken = "ui.token"
    public static let uiStatus = "ui.status"
    public static let uiError = "ui.error"
    public static let providerStatus = "provider.status"
    public static let providerStartLogin = "provider.startLogin"
    public static let providerCancelLogin = "provider.cancelLogin"
    public static let providerLoginStatus = "provider.loginStatus"
    public static let providerStatusChanged = "provider.statusChanged"
    public static let configGet = "config.get"
    public static let configSet = "config.set"
    public static let configSetEffort = "config.setEffort"
}

// MARK: - JSONValue
//
// Recursive JSON value used for opaque payloads (e.g. `BehaviorEnvelope.payload`,
// `RPCError.data`). Encoding emits canonical, sorted-key JSON so byte-equal
// fixture roundtrips work on both Shell (Swift) and Sidecar (TS) sides.

public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? container.decode(Int.self) {
            self = .int(i)
            return
        }
        if let d = try? container.decode(Double.self) {
            self = .double(d)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
            return
        }
        if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognized JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let a):
            try container.encode(a)
        case .object(let o):
            try container.encode(o)
        }
    }
}
