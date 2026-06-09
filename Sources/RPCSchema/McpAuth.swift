import Foundation

// MARK: - mcp.auth.* params / results
//
// MCP server-scoped OAuth Host surface. This namespace is separate from
// provider.* because MCP auth belongs to configured MCP servers, not LLM
// providers.

public enum McpAuthServerState: String, Codable, Sendable, Equatable, CaseIterable {
    case notConfigured
    case unauthenticated
    case authenticating
    case ready
    case failed
}

public enum McpAuthType: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case headers
    case oauth
}

public enum McpAuthLoginState: String, Codable, Sendable, Equatable, CaseIterable {
    case starting
    case awaitingBrowser
    case awaitingCallback
    case exchanging
    case success
    case failed
    case cancelled
}

public enum McpAuthStatusReason: String, Codable, Sendable, Equatable, CaseIterable {
    case loginRequired
    case authInvalidated
    case insufficientScope
    case loggedOut
}

public struct McpAuthServerInfo: Codable, Sendable, Equatable {
    public let serverId: String
    public let state: McpAuthServerState
    public let authType: McpAuthType
    public let authorizationServerUrl: String?
    public let resource: String?
    public let scopes: [String]?
    public let message: String?

    public init(
        serverId: String,
        state: McpAuthServerState,
        authType: McpAuthType,
        authorizationServerUrl: String? = nil,
        resource: String? = nil,
        scopes: [String]? = nil,
        message: String? = nil
    ) {
        self.serverId = serverId
        self.state = state
        self.authType = authType
        self.authorizationServerUrl = authorizationServerUrl
        self.resource = resource
        self.scopes = scopes
        self.message = message
    }
}

public struct McpAuthStatusParams: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: EmptyCodingKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyCodingKey.self)
    }
}

public struct McpAuthStatusResult: Codable, Sendable, Equatable {
    public let servers: [McpAuthServerInfo]
    public init(servers: [McpAuthServerInfo]) { self.servers = servers }
}

public struct McpAuthStartLoginParams: Codable, Sendable, Equatable {
    public let serverId: String
    public let scope: String?
    public init(serverId: String, scope: String? = nil) {
        self.serverId = serverId
        self.scope = scope
    }
}

public struct McpAuthStartLoginResult: Codable, Sendable, Equatable {
    public let loginId: String
    public let authorizeUrl: String
    public init(loginId: String, authorizeUrl: String) {
        self.loginId = loginId
        self.authorizeUrl = authorizeUrl
    }
}

public struct McpAuthCancelLoginParams: Codable, Sendable, Equatable {
    public let loginId: String
    public init(loginId: String) { self.loginId = loginId }
}

public struct McpAuthCancelLoginResult: Codable, Sendable, Equatable {
    public let cancelled: Bool
    public init(cancelled: Bool) { self.cancelled = cancelled }
}

public struct McpAuthLogoutParams: Codable, Sendable, Equatable {
    public let serverId: String
    public init(serverId: String) { self.serverId = serverId }
}

public struct McpAuthLogoutResult: Codable, Sendable, Equatable {
    public let cleared: Bool
    public init(cleared: Bool) { self.cleared = cleared }
}

public struct McpAuthLoginStatusParams: Codable, Sendable, Equatable {
    public let loginId: String
    public let serverId: String
    public let state: McpAuthLoginState
    public let authorizeUrl: String?
    public let message: String?

    public init(
        loginId: String,
        serverId: String,
        state: McpAuthLoginState,
        authorizeUrl: String? = nil,
        message: String? = nil
    ) {
        self.loginId = loginId
        self.serverId = serverId
        self.state = state
        self.authorizeUrl = authorizeUrl
        self.message = message
    }
}

public struct McpAuthStatusChangedParams: Codable, Sendable, Equatable {
    public let serverId: String
    public let state: McpAuthServerState
    public let reason: McpAuthStatusReason?
    public let message: String?

    public init(
        serverId: String,
        state: McpAuthServerState,
        reason: McpAuthStatusReason? = nil,
        message: String? = nil
    ) {
        self.serverId = serverId
        self.state = state
        self.reason = reason
        self.message = message
    }
}

private struct EmptyCodingKey: CodingKey {
    var stringValue: String { "" }
    var intValue: Int? { nil }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { return nil }
}
