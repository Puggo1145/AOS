import Foundation

// MARK: - provider.* params / results
//
// Per docs/designs/rpc-protocol.md §"provider.*" and docs/plans/onboarding.md.
// `provider.*` is a bidirectional namespace:
//   - Shell → Bun requests:  status, startLogin, cancelLogin
//   - Bun → Shell notifs:    loginStatus, statusChanged
//
// `ProviderState` is the wire-only state used by `provider.status` and
// `provider.statusChanged`. The Shell-local `unknown` state (used during the
// pre-handshake refresh window) is not represented here — it is a UI-only
// projection. Per design: do not serialize `unknown` over the wire.

public struct ProviderInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let authMethod: ProviderAuthMethod
    public let state: ProviderState

    public init(id: String, name: String, authMethod: ProviderAuthMethod, state: ProviderState) {
        self.id = id
        self.name = name
        self.authMethod = authMethod
        self.state = state
    }
}

public enum ProviderState: String, Codable, Sendable, Equatable, CaseIterable {
    case ready
    case unauthenticated
}

/// How the user authenticates with this provider. Drives Shell UI:
/// `oauth` shows a login button; `apiKey` shows a secure text field.
public enum ProviderAuthMethod: String, Codable, Sendable, Equatable, CaseIterable {
    case oauth
    case apiKey
}

public enum ProviderLoginState: String, Codable, Sendable, Equatable, CaseIterable {
    case awaitingCallback
    case exchanging
    case success
    case failed
}

public enum ProviderStatusReason: String, Codable, Sendable, Equatable, CaseIterable {
    case authInvalidated
    case loggedOut
}

// MARK: - Requests / Results

public struct ProviderStatusParams: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: EmptyCodingKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyCodingKey.self)
    }
}

public struct ProviderStatusResult: Codable, Sendable, Equatable {
    public let providers: [ProviderInfo]
    public init(providers: [ProviderInfo]) { self.providers = providers }
}

public struct ProviderStartLoginParams: Codable, Sendable, Equatable {
    public let providerId: String
    public init(providerId: String) { self.providerId = providerId }
}

public struct ProviderStartLoginResult: Codable, Sendable, Equatable {
    public let loginId: String
    public let authorizeUrl: String
    public init(loginId: String, authorizeUrl: String) {
        self.loginId = loginId
        self.authorizeUrl = authorizeUrl
    }
}

public struct ProviderCancelLoginParams: Codable, Sendable, Equatable {
    public let loginId: String
    public init(loginId: String) { self.loginId = loginId }
}

public struct ProviderCancelLoginResult: Codable, Sendable, Equatable {
    /// `false` when the session has already terminated (success / failed) by
    /// the time the cancel arrives — the session state is preserved.
    public let cancelled: Bool
    public init(cancelled: Bool) { self.cancelled = cancelled }
}

// MARK: - Notifications

public struct ProviderLoginStatusParams: Codable, Sendable, Equatable {
    public let loginId: String
    public let providerId: String
    public let state: ProviderLoginState
    public let message: String?
    public let errorCode: Int?

    public init(
        loginId: String,
        providerId: String,
        state: ProviderLoginState,
        message: String? = nil,
        errorCode: Int? = nil
    ) {
        self.loginId = loginId
        self.providerId = providerId
        self.state = state
        self.message = message
        self.errorCode = errorCode
    }
}

public struct ProviderStatusChangedParams: Codable, Sendable, Equatable {
    public let providerId: String
    public let state: ProviderState
    public let reason: ProviderStatusReason?
    public let message: String?

    public init(
        providerId: String,
        state: ProviderState,
        reason: ProviderStatusReason? = nil,
        message: String? = nil
    ) {
        self.providerId = providerId
        self.state = state
        self.reason = reason
        self.message = message
    }
}

// MARK: - provider.setApiKey / provider.clearApiKey
//
// Used by apiKey-auth providers (e.g. deepseek). The Shell owns durable
// persistence (Keychain) and pushes the current value to the sidecar at
// startup AND on user edits. The sidecar holds the key in memory only.
//
// Sidecar emits `provider.statusChanged` after applying the change so the
// Shell ProviderService can refresh its state without polling.

public struct ProviderSetApiKeyParams: Codable, Sendable, Equatable {
    public let providerId: String
    public let apiKey: String

    public init(providerId: String, apiKey: String) {
        self.providerId = providerId
        self.apiKey = apiKey
    }
}

public struct ProviderSetApiKeyResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public init(ok: Bool) { self.ok = ok }
}

public struct ProviderClearApiKeyParams: Codable, Sendable, Equatable {
    public let providerId: String
    public init(providerId: String) { self.providerId = providerId }
}

public struct ProviderClearApiKeyResult: Codable, Sendable, Equatable {
    /// `false` when no key was present — handler is idempotent.
    public let cleared: Bool
    public init(cleared: Bool) { self.cleared = cleared }
}

// `provider.logout` — Shell → Bun. Auth-method-agnostic clear: deletes
// the OAuth token file or wipes the in-memory apiKey, so the next
// `startLogin` / `setApiKey` runs against a clean slate.

public struct ProviderLogoutParams: Codable, Sendable, Equatable {
    public let providerId: String
    public init(providerId: String) { self.providerId = providerId }
}

public struct ProviderLogoutResult: Codable, Sendable, Equatable {
    /// `false` when nothing was cleared — handler is idempotent.
    public let cleared: Bool
    public init(cleared: Bool) { self.cleared = cleared }
}

private struct EmptyCodingKey: CodingKey {
    var stringValue: String { "" }
    var intValue: Int? { nil }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { return nil }
}
