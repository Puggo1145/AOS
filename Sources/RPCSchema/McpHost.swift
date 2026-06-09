import Foundation

// MARK: - mcp.* params / results
//
// MCP Host management surface. `mcp.auth.*` owns OAuth login state; this
// namespace owns configured server lifecycle and the Settings-facing list.

public enum McpConnectionState: String, Codable, Sendable, Equatable, CaseIterable {
    case disconnected
    case connected
    case failed
}

public enum McpTransportType: String, Codable, Sendable, Equatable, CaseIterable {
    case stdio
    case streamableHttp
}

public struct McpServerStatusInfo: Codable, Sendable, Equatable, Identifiable {
    public let serverId: String
    public let name: String
    public let description: String
    public let transportType: McpTransportType
    public let connectionState: McpConnectionState
    public let authState: McpAuthServerState
    public let authType: McpAuthType
    public let message: String?

    public var id: String { serverId }

    public init(
        serverId: String,
        name: String,
        description: String,
        transportType: McpTransportType,
        connectionState: McpConnectionState,
        authState: McpAuthServerState,
        authType: McpAuthType,
        message: String? = nil
    ) {
        self.serverId = serverId
        self.name = name
        self.description = description
        self.transportType = transportType
        self.connectionState = connectionState
        self.authState = authState
        self.authType = authType
        self.message = message
    }
}

public struct McpStatusParams: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: EmptyCodingKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyCodingKey.self)
    }
}

public struct McpStatusResult: Codable, Sendable, Equatable {
    public let servers: [McpServerStatusInfo]
    public init(servers: [McpServerStatusInfo]) { self.servers = servers }
}

public struct McpServerConfigInfo: Codable, Sendable, Equatable {
    public let serverId: String
    public let description: String
    public let transportType: McpTransportType
    public let authType: McpAuthType?
    public let autoConnect: Bool?
    public let command: String?
    public let args: [String]?
    public let env: [String: String]?
    public let url: String?
    public let headers: [String: String]?

    public init(
        serverId: String,
        description: String,
        transportType: McpTransportType,
        authType: McpAuthType? = nil,
        autoConnect: Bool? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.serverId = serverId
        self.description = description
        self.transportType = transportType
        self.authType = authType
        self.autoConnect = autoConnect
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }
}

public struct McpGetConfigParams: Codable, Sendable, Equatable {
    public let serverId: String
    public init(serverId: String) { self.serverId = serverId }
}

public struct McpGetConfigResult: Codable, Sendable, Equatable {
    public let config: McpServerConfigInfo
    public init(config: McpServerConfigInfo) { self.config = config }
}

public struct McpAddParams: Codable, Sendable, Equatable {
    public let serverId: String
    public let description: String
    public let transportType: McpTransportType
    public let authType: McpAuthType?
    public let autoConnect: Bool?
    public let command: String?
    public let args: [String]?
    public let env: [String: String]?
    public let url: String?
    public let headers: [String: String]?

    public init(
        serverId: String,
        description: String,
        transportType: McpTransportType,
        authType: McpAuthType? = nil,
        autoConnect: Bool? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.serverId = serverId
        self.description = description
        self.transportType = transportType
        self.authType = authType
        self.autoConnect = autoConnect
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }
}

public struct McpAddResult: Codable, Sendable, Equatable {
    public let server: McpServerStatusInfo
    public init(server: McpServerStatusInfo) { self.server = server }
}

public struct McpUpdateParams: Codable, Sendable, Equatable {
    public let serverId: String
    public let description: String
    public let transportType: McpTransportType
    public let authType: McpAuthType?
    public let autoConnect: Bool?
    public let command: String?
    public let args: [String]?
    public let env: [String: String]?
    public let url: String?
    public let headers: [String: String]?

    public init(
        serverId: String,
        description: String,
        transportType: McpTransportType,
        authType: McpAuthType? = nil,
        autoConnect: Bool? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.serverId = serverId
        self.description = description
        self.transportType = transportType
        self.authType = authType
        self.autoConnect = autoConnect
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }
}

public struct McpUpdateResult: Codable, Sendable, Equatable {
    public let server: McpServerStatusInfo
    public init(server: McpServerStatusInfo) { self.server = server }
}

public struct McpConnectParams: Codable, Sendable, Equatable {
    public let serverId: String
    public init(serverId: String) { self.serverId = serverId }
}

public struct McpConnectResult: Codable, Sendable, Equatable {
    public let server: McpServerStatusInfo
    public init(server: McpServerStatusInfo) { self.server = server }
}

public struct McpDisconnectParams: Codable, Sendable, Equatable {
    public let serverId: String
    public init(serverId: String) { self.serverId = serverId }
}

public struct McpDisconnectResult: Codable, Sendable, Equatable {
    public let server: McpServerStatusInfo
    public init(server: McpServerStatusInfo) { self.server = server }
}

public struct McpDeleteParams: Codable, Sendable, Equatable {
    public let serverId: String
    public init(serverId: String) { self.serverId = serverId }
}

public struct McpDeleteResult: Codable, Sendable, Equatable {
    public let deleted: Bool
    public init(deleted: Bool) { self.deleted = deleted }
}

public struct McpStatusChangedParams: Codable, Sendable, Equatable {
    public let server: McpServerStatusInfo
    public init(server: McpServerStatusInfo) { self.server = server }
}

private struct EmptyCodingKey: CodingKey {
    var stringValue: String { "" }
    var intValue: Int? { nil }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { return nil }
}
