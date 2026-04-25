import Foundation

// MARK: - config.* params / results
//
// Per docs/designs/rpc-protocol.md §"config.*". `config.*` is a Shell→Bun
// namespace; the sidecar persists `selection` to ~/.aos/config.json and
// projects the catalog (provider list + per-provider models + default
// modelId) into `config.get` so the Shell settings panel does not need a
// separate "list models" RPC.

/// Reasoning effort levels. Mirrors `EFFORT_LEVELS` in the sidecar
/// catalog. The sidecar clamps per-model at request time; the Shell
/// renders this enum directly in the picker.
public enum ConfigEffort: String, Codable, Sendable, Equatable, CaseIterable {
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public struct ConfigModelEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// `false` → the model has no notion of reasoning effort. Settings UI
    /// should disable the effort picker while this model is selected.
    public let reasoning: Bool
    /// `false` → "xhigh" is not accepted; settings picker should disable
    /// that row specifically.
    public let supportsXhigh: Bool

    public init(id: String, name: String, reasoning: Bool, supportsXhigh: Bool) {
        self.id = id
        self.name = name
        self.reasoning = reasoning
        self.supportsXhigh = supportsXhigh
    }
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
    /// `nil` when the user has never picked an effort. Shell falls back
    /// to `defaultEffort` for the initial UI selection.
    public let effort: ConfigEffort?
    public let defaultEffort: ConfigEffort
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
        effort: ConfigEffort?,
        defaultEffort: ConfigEffort,
        providers: [ConfigProviderEntry],
        hasCompletedOnboarding: Bool,
        recoveredFromCorruption: Bool
    ) {
        self.selection = selection
        self.effort = effort
        self.defaultEffort = defaultEffort
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
    public let effort: ConfigEffort

    public init(effort: ConfigEffort) {
        self.effort = effort
    }
}

public struct ConfigSetEffortResult: Codable, Sendable, Equatable {
    public let effort: ConfigEffort

    public init(effort: ConfigEffort) {
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
