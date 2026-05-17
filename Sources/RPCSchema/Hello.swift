import Foundation

// MARK: - rpc.hello / rpc.ping
//
// Per docs/designs/rpc-protocol.md §"rpc.*（双向）". `rpc.hello` is the first
// message Bun sends after spawn; Shell must accept before any business method
// is allowed (otherwise responds with `ErrUnhandshaked`).

public struct ClientInfo: Codable, Sendable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct ServerInfo: Codable, Sendable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct HelloParams: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let clientInfo: ClientInfo

    public init(protocolVersion: String, clientInfo: ClientInfo) {
        self.protocolVersion = protocolVersion
        self.clientInfo = clientInfo
    }
}

public struct HelloResult: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let serverInfo: ServerInfo

    public init(protocolVersion: String, serverInfo: ServerInfo) {
        self.protocolVersion = protocolVersion
        self.serverInfo = serverInfo
    }
}

/// `rpc.ping` carries no params and no result fields. We explicitly emit `{}`
/// so the wire payload matches the schema (synthesized Codable on an empty
/// struct would otherwise emit nothing).
public struct PingParams: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: EmptyCodingKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyCodingKey.self)
    }
}

public struct PingResult: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: EmptyCodingKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyCodingKey.self)
    }
}

private struct EmptyCodingKey: CodingKey {
    var stringValue: String { "" }
    var intValue: Int? { nil }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { return nil }
}
