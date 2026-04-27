import Foundation

// MARK: - config.* params / results
//
// Per docs/designs/rpc-protocol.md §"config.*". `config.*` is a Shell→Bun
// namespace; the sidecar persists `selection` to ~/.aos/config.json and
// projects the catalog (provider list + per-provider models + default
// modelId) into `config.get` so the Shell settings panel does not need a
// separate "list models" RPC.

/// One picker row for a model's reasoning effort.
///   - `value` is what gets sent on the wire (and stored in
///     `~/.aos/config.json`) — the exact string the provider's API
///     expects.
///   - `label` is the human-readable name shown in the picker.
/// Effort vocabularies are per-model — there is no closed enum.
public struct ConfigEffort: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let value: String
    public let label: String

    public var id: String { value }

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct ConfigModelEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Effort levels this model accepts, in canonical low→high order.
    /// Empty → non-reasoning model: the Shell hides the effort picker.
    /// Otherwise the picker shows exactly these rows; the sidecar stores
    /// the picked `value` and forwards it to the provider untouched.
    public let supportedEfforts: [ConfigEffort]
    /// Default effort `value` for this model. `nil` for non-reasoning
    /// models. Used when the user has not picked or has stale config.
    public let defaultEffort: String?

    public init(id: String, name: String, supportedEfforts: [ConfigEffort], defaultEffort: String?) {
        self.id = id
        self.name = name
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
    }

    /// Convenience: the model has any reasoning capability at all.
    /// Drives whether the effort UI should be shown.
    public var reasoning: Bool { !supportedEfforts.isEmpty }
}

public struct ConfigProviderEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let defaultModelId: String
    public let models: [ConfigModelEntry]

    public init(id: String, name: String, defaultModelId: String, models: [ConfigModelEntry]) {
        self.id = id
        self.name = name
        self.defaultModelId = defaultModelId
        self.models = models
    }
}

public struct ConfigSelection: Codable, Sendable, Equatable {
    public let providerId: String
    public let modelId: String

    public init(providerId: String, modelId: String) {
        self.providerId = providerId
        self.modelId = modelId
    }
}

public struct ConfigGetParams: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: EmptyCodingKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyCodingKey.self)
    }
}

public struct ConfigGetResult: Codable, Sendable, Equatable {
    /// `nil` when the user has never picked a model.
    public let selection: ConfigSelection?
    /// User's last picked effort `value`, stored verbatim. `nil` when
    /// never picked. The Shell resolves the actual rendered effort
    /// against the active model's `supportedEfforts`; `defaultEffort`
    /// per model lives on `ConfigModelEntry`.
    public let effort: String?
    public let providers: [ConfigProviderEntry]
    /// One-shot completion gate. Once `true`, NotchView stops routing
    /// to the onboard panels even if a permission or provider drops —
    /// failures surface as inline warnings + Settings affordances.
    public let hasCompletedOnboarding: Bool
    /// `true` iff this `config.get` just discovered a malformed config
    /// file and reset it to `{}`. Shell shows a one-time banner so the
    /// user understands why their settings were wiped.
    public let recoveredFromCorruption: Bool

    public init(
        selection: ConfigSelection?,
        effort: String?,
        providers: [ConfigProviderEntry],
        hasCompletedOnboarding: Bool,
        recoveredFromCorruption: Bool
    ) {
        self.selection = selection
        self.effort = effort
        self.providers = providers
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.recoveredFromCorruption = recoveredFromCorruption
    }
}

public struct ConfigSetParams: Codable, Sendable, Equatable {
    public let providerId: String
    public let modelId: String

    public init(providerId: String, modelId: String) {
        self.providerId = providerId
        self.modelId = modelId
    }
}

public struct ConfigSetResult: Codable, Sendable, Equatable {
    public let selection: ConfigSelection

    public init(selection: ConfigSelection) {
        self.selection = selection
    }
}

public struct ConfigSetEffortParams: Codable, Sendable, Equatable {
    /// Wire `value` of one of the active model's supported efforts.
    public let effort: String

    public init(effort: String) {
        self.effort = effort
    }
}

public struct ConfigSetEffortResult: Codable, Sendable, Equatable {
    public let effort: String

    public init(effort: String) {
        self.effort = effort
    }
}

public struct ConfigMarkOnboardingCompletedParams: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: EmptyCodingKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyCodingKey.self)
    }
}

public struct ConfigMarkOnboardingCompletedResult: Codable, Sendable, Equatable {
    public let hasCompletedOnboarding: Bool

    public init(hasCompletedOnboarding: Bool) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}

private struct EmptyCodingKey: CodingKey {
    var stringValue: String { "" }
    var intValue: Int? { nil }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { return nil }
}
