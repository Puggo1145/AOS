import Foundation
import RPCSchema

// MARK: - ConfigService
//
// Owns the Shell-side projection of the user's global config. The sidecar's
// `config.get` returns both the saved selection and the catalog snapshot
// (provider list + per-provider models + per-provider default modelId), so
// this service is the single binding source for the Settings panel.
//
// Mutation is one-shot and round-trips the sidecar:
//   selectModel(provider, model) → `config.set` → updates `selection` from
//   the response. We do not optimistically update — the sidecar is the
//   storage authority; on error the UI reflects the previous selection.

@MainActor
@Observable
public final class ConfigService {

    public private(set) var providers: [ConfigProviderEntry] = []
    public private(set) var selection: ConfigSelection?
    /// Last `value` the user picked, stored verbatim. The picker reads
    /// the active model's `supportedEfforts` to render rows; this string
    /// just decides which row gets the checkmark.
    public private(set) var effort: String?
    public private(set) var permissionLevel: ConfigPermissionLevel = .default
    public private(set) var loaded: Bool = false
    public private(set) var lastError: String?
    /// Onboarding completion latch. Mirrored from `~/.notch-agent/config.json`
    /// via `config.get`. Once flipped to `true` the routing in NotchView
    /// stops sending the user back to the onboard panels even if a
    /// permission or provider drops.
    public private(set) var hasCompletedOnboarding: Bool = false
    /// Set to `true` for one app session if `config.get` reported that
    /// `~/.notch-agent/config.json` was malformed and reset to `{}`. The Notch
    /// reads this to show a one-time banner; `dismissCorruptionNotice()`
    /// clears it (e.g., when the user closes the banner).
    public private(set) var recoveredFromCorruption: Bool = false

    /// Effective selection used by the agent loop: explicit user pick if set,
    /// else the default of the first provider (which mirrors the sidecar's
    /// fallback in `agent/loop.ts`).
    public var effectiveSelection: ConfigSelection? {
        if let s = selection { return s }
        guard let first = providers.first else { return nil }
        return ConfigSelection(providerId: first.id, modelId: first.defaultModelId)
    }

    /// Effort to display in the picker for a given model. Returns `nil`
    /// for non-reasoning models (the picker is hidden in that case).
    /// Resolution mirrors the sidecar's `effectiveEffort`:
    ///   1. user pick, if it's one of the model's supported `value`s
    ///   2. the model's `defaultEffort`
    ///   3. the model's first supported level
    public func effort(for model: ConfigModelEntry?) -> ConfigEffort? {
        guard let model, !model.supportedEfforts.isEmpty else { return nil }
        if let pick = effort, let row = model.supportedEfforts.first(where: { $0.value == pick }) {
            return row
        }
        if let def = model.defaultEffort,
           let row = model.supportedEfforts.first(where: { $0.value == def }) {
            return row
        }
        return model.supportedEfforts.first
    }

    public func provider(id: String) -> ConfigProviderEntry? {
        providers.first(where: { $0.id == id })
    }

    public func model(providerId: String, modelId: String) -> ConfigModelEntry? {
        provider(id: providerId)?.models.first(where: { $0.id == modelId })
    }

    private let rpc: RPCClient

    public init(rpc: RPCClient) {
        self.rpc = rpc
    }

    // MARK: - RPC entry points

    public func refresh() async {
        do {
            let result = try await rpc.request(
                method: RPCMethod.configGet,
                params: ConfigGetParams(),
                as: ConfigGetResult.self
            )
            providers = result.providers
            selection = result.selection
            effort = result.effort
            permissionLevel = result.permissionLevel
            hasCompletedOnboarding = result.hasCompletedOnboarding
            // Only flip `true` — never flip back via a later refresh.
            // The flag is a one-shot session notice; the sidecar will
            // report `recoveredFromCorruption: false` on every subsequent
            // call now that the file is valid again, but the user still
            // hasn't acknowledged the original reset.
            if result.recoveredFromCorruption { recoveredFromCorruption = true }
            loaded = true
            lastError = nil
        } catch {
            lastError = String(describing: error)
            FileHandle.standardError.write(
                Data("[config] refresh failed: \(error)\n".utf8)
            )
        }
    }

    public func selectModel(providerId: String, modelId: String) async {
        do {
            let result = try await rpc.request(
                method: RPCMethod.configSet,
                params: ConfigSetParams(providerId: providerId, modelId: modelId),
                as: ConfigSetResult.self
            )
            selection = result.selection
            lastError = nil
        } catch let RPCClientError.server(rpcError) {
            lastError = rpcError.message
        } catch {
            lastError = String(describing: error)
        }
    }

    public func selectEffort(_ newEffort: ConfigEffort) async {
        do {
            let result = try await rpc.request(
                method: RPCMethod.configSetEffort,
                params: ConfigSetEffortParams(effort: newEffort.value),
                as: ConfigSetEffortResult.self
            )
            effort = result.effort
            lastError = nil
        } catch let RPCClientError.server(rpcError) {
            lastError = rpcError.message
        } catch {
            lastError = String(describing: error)
        }
    }

    public func selectPermissionLevel(_ newLevel: ConfigPermissionLevel) async {
        do {
            let result = try await rpc.request(
                method: RPCMethod.configSetPermissionLevel,
                params: ConfigSetPermissionLevelParams(permissionLevel: newLevel),
                as: ConfigSetPermissionLevelResult.self
            )
            permissionLevel = result.permissionLevel
            lastError = nil
        } catch let RPCClientError.server(rpcError) {
            lastError = rpcError.message
        } catch {
            lastError = String(describing: error)
        }
    }

    /// One-shot latch. Persists via RPC before flipping the local
    /// `hasCompletedOnboarding` flag so a storage/RPC failure cannot route
    /// the current Shell session past onboarding without durable authority.
    /// Calling more than once is a no-op on disk (idempotent merge).
    public func markOnboardingCompleted() async {
        guard !hasCompletedOnboarding else { return }
        do {
            let result = try await rpc.request(
                method: RPCMethod.configMarkOnboardingCompleted,
                params: ConfigMarkOnboardingCompletedParams(),
                as: ConfigMarkOnboardingCompletedResult.self
            )
            hasCompletedOnboarding = result.hasCompletedOnboarding
            lastError = nil
        } catch {
            lastError = String(describing: error)
            FileHandle.standardError.write(
                Data("[config] markOnboardingCompleted failed: \(error)\n".utf8)
            )
        }
    }

    /// Clear the corruption banner after the user has acknowledged it.
    /// Local-only — there's nothing to persist on disk.
    public func dismissCorruptionNotice() {
        recoveredFromCorruption = false
    }

    internal func _testApply(
        providers newProviders: [ConfigProviderEntry],
        selection newSelection: ConfigSelection?,
        effort newEffort: String? = nil,
        permissionLevel newPermissionLevel: ConfigPermissionLevel = .default,
        hasCompletedOnboarding completed: Bool = false
    ) {
        providers = newProviders
        selection = newSelection
        effort = newEffort
        permissionLevel = newPermissionLevel
        hasCompletedOnboarding = completed
        loaded = true
        lastError = nil
    }
}
