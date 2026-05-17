import Foundation
import AppKit
import AOSRPCSchema

// MARK: - ProviderService
//
// Per docs/plans/onboarding.md §"Shell — ProviderService + Onboard UI".
// Owns three pieces of UI-facing state:
//   1. `providers`: per-provider summary, each in `ready` / `unauthenticated` /
//      `unknown`. `unknown` is the **Shell-local** loading state that gates
//      every action on the first `provider.status` reply.
//   2. `statusLoaded`: flips true the first time `refreshStatus` succeeds.
//      Until that flip, `hasReadyProvider` returns false AND `startLogin`
//      refuses to run. This restores the boundary "Shell may not act on
//      provider state until the sidecar has spoken first."
//   3. `loginSession`: in-progress OAuth login, drives the onboard sub-states.
//
// `unknown` is a Shell-LOCAL state ONLY — it never appears on the wire. The
// wire schema (`AOSRPCSchema.ProviderState`) has only `ready` and
// `unauthenticated`. Mapping happens in `applyStatusResult` /
// `handleStatusChanged`.
//
// Notification handlers update local state. RPC requests are issued via
// the supplied `RPCClient`. The view layer reads via @Observable; mutation
// happens only through this service.

@MainActor
@Observable
public final class ProviderService {

    public enum State: Sendable, Equatable {
        case ready
        case unauthenticated
        /// Shell-local loading state. NEVER serialized over the wire. Holds
        /// until the first `provider.status` reply lands.
        case unknown
    }

    public struct Provider: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        /// `oauth` (chatgpt-plan) → onboard via login button.
        /// `apiKey` (deepseek, …) → onboard via SecureField in Settings.
        public let authMethod: ProviderAuthMethod
        public var state: State

        public init(id: String, name: String, authMethod: ProviderAuthMethod, state: State) {
            self.id = id
            self.name = name
            self.authMethod = authMethod
            self.state = state
        }
    }

    public struct LoginSession: Equatable, Sendable {
        public let loginId: String
        public let providerId: String
        public var state: ProviderLoginState
        public var message: String?
        public var errorCode: Int?

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

    public enum ActionError: Error, Equatable, LocalizedError {
        case emptyApiKey
        case unknownProvider(String)
        case unsupportedAuthMethod(String)
        case keychainLoadFailed(providerId: String, detail: String)
        case keychainSaveFailed(String)
        case keychainDeleteFailed(String)
        case sidecarPushFailed(String)
        case sidecarClearFailed(String)
        case sidecarLogoutFailed(String)
        case cancelLoginFailed(String)

        public var errorDescription: String? {
            switch self {
            case .emptyApiKey:
                return "API key cannot be empty"
            case .unknownProvider(let providerId):
                return "Unknown provider: \(providerId)"
            case .unsupportedAuthMethod(let providerId):
                return "Provider \(providerId) does not use API key auth"
            case .keychainLoadFailed(let providerId, let detail):
                return "Keychain load failed for \(providerId): \(detail)"
            case .keychainSaveFailed(let detail):
                return "Keychain save failed: \(detail)"
            case .keychainDeleteFailed(let detail):
                return "Keychain delete failed: \(detail)"
            case .sidecarPushFailed(let detail):
                return "Sidecar push failed: \(detail)"
            case .sidecarClearFailed(let detail):
                return "Sidecar clear failed: \(detail)"
            case .sidecarLogoutFailed(let detail):
                return "Sidecar logout failed: \(detail)"
            case .cancelLoginFailed(let detail):
                return "Cancel failed: \(detail)"
            }
        }
    }

    public static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription {
            return message
        }
        return String(describing: error)
    }

    /// Seed entry: id stays stable so the onboard list has *something* to
    /// render before the first status reply, but `state == .unknown` until
    /// `refreshStatus` confirms. The display name is intentionally the
    /// neutral provider id rather than a hardcoded marketing string —
    /// `applyStatusResult` overwrites it with the sidecar's authoritative
    /// `ProviderInfo.name` on first success.
    public private(set) var providers: [Provider] = [
        Provider(id: "chatgpt-plan", name: "chatgpt-plan", authMethod: .oauth, state: .unknown),
        Provider(id: "deepseek", name: "deepseek", authMethod: .apiKey, state: .unknown),
    ]
    public private(set) var loginSession: LoginSession?

    /// Flips `true` the first time `refreshStatus()` returns successfully.
    /// `false` means "we have not yet heard back from the sidecar — do not
    /// claim provider state, do not allow `startLogin`."
    public private(set) var statusLoaded: Bool = false

    /// Last `refreshStatus` failure surfaced to the UI. Cleared on the next
    /// successful refresh. Drives the onboard loading affordance copy when
    /// the first refresh fails.
    public private(set) var statusError: String?

    /// Only true once the sidecar has confirmed at least one provider in
    /// `ready` state. Returns false in the `unknown` (loading) phase so the
    /// onboard view does not render the "ready, take input" branch from
    /// stale Shell-local guesses.
    public var hasReadyProvider: Bool {
        statusLoaded && providers.contains { $0.state == .ready }
    }

    private let rpc: RPCClient
    private let keychain: KeychainService
    private var successDismissTask: Task<Void, Never>?
    /// Set of providerIds whose Keychain key has already been hydrated to
    /// the sidecar in this process lifetime. Prevents repeated push if
    /// `refreshStatus` is called multiple times.
    private var hydratedApiKeyProviders: Set<String> = []

    public init(rpc: RPCClient, keychain: KeychainService = .shared) {
        self.rpc = rpc
        self.keychain = keychain
        registerHandlers()
    }

    private func registerHandlers() {
        rpc.registerNotificationHandler(method: RPCMethod.providerLoginStatus) { [weak self] (params: ProviderLoginStatusParams) in
            await self?.handleLoginStatus(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.providerStatusChanged) { [weak self] (params: ProviderStatusChangedParams) in
            await self?.handleStatusChanged(params)
        }
    }

    // MARK: - RPC entry points

    public func refreshStatus() async {
        do {
            let result = try await rpc.request(
                method: RPCMethod.providerStatus,
                params: ProviderStatusParams(),
                as: ProviderStatusResult.self
            )
            applyStatusResult(result)
            statusLoaded = true
            statusError = nil
            // Hydrate Keychain → sidecar for any apiKey provider that hasn't
            // been pushed yet this process lifetime. The sidecar is purely
            // in-memory for keys, so we re-push on every Shell start.
            await hydrateApiKeysFromKeychain(infos: result.providers)
        } catch {
            FileHandle.standardError.write(
                Data("[provider] refreshStatus failed: \(error)\n".utf8)
            )
            statusError = String(describing: error)
            // Keep `statusLoaded == false` so the onboard panel renders the
            // loading affordance rather than a guess. UI distinguishes
            // "loading" (statusError == nil) from "couldn't reach sidecar"
            // (statusError != nil).
        }
    }

    public func startLogin(providerId: String) async {
        // Hard gate: never drive `provider.startLogin` while the Shell has
        // not yet observed the sidecar's authoritative provider state. The
        // onboard UI also disables its tap target via `canStartLogin` so
        // this is a defense-in-depth check.
        guard statusLoaded else {
            loginSession = LoginSession(
                loginId: "",
                providerId: providerId,
                state: .failed,
                message: "Provider status not yet loaded"
            )
            return
        }
        do {
            let result = try await rpc.request(
                method: RPCMethod.providerStartLogin,
                params: ProviderStartLoginParams(providerId: providerId),
                as: ProviderStartLoginResult.self
            )
            loginSession = LoginSession(
                loginId: result.loginId,
                providerId: providerId,
                state: .awaitingCallback
            )
            if let url = URL(string: result.authorizeUrl) {
                NSWorkspace.shared.open(url)
            }
        } catch let RPCClientError.server(rpcError) {
            // Pre-check failures (loginInProgress / unknownProvider /
            // loginNotConfigured) come back as JSON-RPC error responses; do
            // not create a session, just surface the message inline.
            loginSession = LoginSession(
                loginId: "",
                providerId: providerId,
                state: .failed,
                message: rpcError.message,
                errorCode: rpcError.code
            )
        } catch {
            loginSession = LoginSession(
                loginId: "",
                providerId: providerId,
                state: .failed,
                message: String(describing: error)
            )
        }
    }

    /// True iff the onboard UI should let the user click a provider card.
    public var canStartLogin: Bool { statusLoaded }

    public func cancelLogin() async throws {
        guard let session = loginSession, !session.loginId.isEmpty else {
            loginSession = nil
            return
        }
        do {
            _ = try await rpc.request(
                method: RPCMethod.providerCancelLogin,
                params: ProviderCancelLoginParams(loginId: session.loginId),
                as: ProviderCancelLoginResult.self
            )
        } catch {
            loginSession = LoginSession(
                loginId: session.loginId,
                providerId: session.providerId,
                state: .failed,
                message: Self.message(for: ActionError.cancelLoginFailed(Self.message(for: error)))
            )
            throw ActionError.cancelLoginFailed(Self.message(for: error))
        }
        // Definitive teardown happens via `provider.loginStatus { failed }`
        // notification, not the cancel response. No state mutation here.
    }

    public func dismissLoginSession() {
        loginSession = nil
        successDismissTask?.cancel()
        successDismissTask = nil
    }

    // MARK: - Notification handlers (internal for tests)

    internal func handleLoginStatus(_ p: ProviderLoginStatusParams) {
        guard var session = loginSession, session.loginId == p.loginId else {
            return
        }
        session.state = p.state
        session.message = p.message
        session.errorCode = p.errorCode
        loginSession = session

        if p.state == .success {
            // Per design: re-query status, then auto-dismiss after 600ms so
            // the OpenedPanelView naturally takes over.
            Task { [weak self] in
                await self?.refreshStatus()
            }
            successDismissTask?.cancel()
            // Capture the loginId so the dismiss is bound to *this* login.
            // The cancellation check runs *before* the actor hop; if the
            // user dismisses or starts a new login during the 600 ms
            // window, we must re-verify on the MainActor side that the
            // current session is still the one we armed for, otherwise we
            // would wipe a freshly started session.
            let armedLoginId = session.loginId
            successDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard self.loginSession?.loginId == armedLoginId else { return }
                    self.dismissLoginSession()
                }
            }
        }
    }

    internal func handleStatusChanged(_ p: ProviderStatusChangedParams) {
        let mappedState: State = (p.state == .ready) ? .ready : .unauthenticated
        if let idx = providers.firstIndex(where: { $0.id == p.providerId }) {
            providers[idx].state = mappedState
        }
        // A push from the sidecar is sufficient evidence that we have
        // authoritative state for this provider. Flip the gate so subsequent
        // `startLogin` clicks are allowed without waiting for an explicit
        // `refreshStatus`.
        statusLoaded = true
        statusError = nil
    }

    // MARK: - Helpers

    private func applyStatusResult(_ result: ProviderStatusResult) {
        // Merge by id; preserve seed entries that the sidecar didn't enumerate.
        var byId: [String: Provider] = [:]
        for p in providers { byId[p.id] = p }
        for info in result.providers {
            let mapped: State = (info.state == .ready) ? .ready : .unauthenticated
            byId[info.id] = Provider(
                id: info.id,
                name: info.name,
                authMethod: info.authMethod,
                state: mapped
            )
        }
        providers = byId.values.sorted { $0.id < $1.id }
    }

    // MARK: - API key (apiKey-auth providers)

    /// Read all Keychain-stored API keys for providers the sidecar reported
    /// as `apiKey`-auth, and push each to the sidecar. Keychain access and
    /// push failures are surfaced through `statusError`; they are not treated
    /// as "missing key" because that would hide durable auth corruption.
    private func hydrateApiKeysFromKeychain(infos: [ProviderInfo]) async {
        for info in infos where info.authMethod == .apiKey {
            if hydratedApiKeyProviders.contains(info.id) { continue }
            let key: String?
            do {
                key = try keychain.loadApiKey(providerId: info.id)
            } catch {
                let actionError = ActionError.keychainLoadFailed(
                    providerId: info.id,
                    detail: Self.message(for: error)
                )
                FileHandle.standardError.write(
                    Data("[provider] \(Self.message(for: actionError))\n".utf8)
                )
                statusError = Self.message(for: actionError)
                continue
            }
            guard let key, !key.isEmpty else {
                // No key persisted is a stable state, not a failure. Mark
                // hydrated so we don't retry every refresh — user must save
                // a key via Settings to leave this state.
                hydratedApiKeyProviders.insert(info.id)
                continue
            }
            do {
                try await pushApiKey(providerId: info.id, apiKey: key)
            } catch {
                FileHandle.standardError.write(
                    Data("[provider] hydrate push failed for \(info.id): \(Self.message(for: error))\n".utf8)
                )
                statusError = Self.message(for: error)
                continue
            }
            hydratedApiKeyProviders.insert(info.id)
        }
    }

    /// User-driven save: persist to Keychain THEN push to sidecar. The
    /// sidecar's ack flips `state` via the `statusChanged` notification it
    /// emits — no local mutation here.
    public func saveApiKey(providerId: String, apiKey: String) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActionError.emptyApiKey }
        // Validate locally before touching Keychain so an invalid/OAuth
        // providerId can't leave an orphan secret persisted on disk.
        guard let provider = providers.first(where: { $0.id == providerId }) else {
            throw ActionError.unknownProvider(providerId)
        }
        guard provider.authMethod == .apiKey else {
            throw ActionError.unsupportedAuthMethod(providerId)
        }
        do {
            try keychain.saveApiKey(providerId: providerId, apiKey: trimmed)
        } catch {
            throw ActionError.keychainSaveFailed(Self.message(for: error))
        }
        try await pushApiKey(providerId: providerId, apiKey: trimmed)
    }

    /// Read-only peek into the Keychain-stored API key, used by views to
    /// pre-fill the editing field. Goes through ProviderService so views
    /// don't reach into `KeychainService.shared` directly. Returns `nil`
    /// when no key is stored; throws on Keychain access errors so the
    /// caller can decide whether to surface them.
    public func peekApiKey(providerId: String) throws -> String? {
        try keychain.loadApiKey(providerId: providerId)
    }

    /// User-driven clear: delete from Keychain THEN tell the sidecar to
    /// drop the in-memory copy. Order matters — Keychain is the durable
    /// truth; sidecar memory is recoverable from Keychain on next boot.
    public func clearApiKey(providerId: String) async throws {
        do {
            _ = try keychain.deleteApiKey(providerId: providerId)
        } catch {
            throw ActionError.keychainDeleteFailed(Self.message(for: error))
        }
        do {
            _ = try await rpc.request(
                method: RPCMethod.providerClearApiKey,
                params: ProviderClearApiKeyParams(providerId: providerId),
                as: ProviderClearApiKeyResult.self
            )
        } catch {
            throw ActionError.sidecarClearFailed(Self.message(for: error))
        }
    }

    /// Auth-method-agnostic logout. Used by Settings to expose a "Sign out"
    /// action for OAuth providers (which have no Keychain entry to delete).
    /// For apiKey providers, also wipes the local Keychain copy so the
    /// durable truth matches the sidecar's in-memory clear.
    public func logout(providerId: String) async throws {
        // Local Keychain wipe first when applicable — keeps the
        // "Keychain is durable truth" invariant from clearApiKey.
        if let p = providers.first(where: { $0.id == providerId }), p.authMethod == .apiKey {
            do {
                _ = try keychain.deleteApiKey(providerId: providerId)
            } catch {
                throw ActionError.keychainDeleteFailed(Self.message(for: error))
            }
        }
        do {
            _ = try await rpc.request(
                method: RPCMethod.providerLogout,
                params: ProviderLogoutParams(providerId: providerId),
                as: ProviderLogoutResult.self
            )
        } catch {
            throw ActionError.sidecarLogoutFailed(Self.message(for: error))
        }
    }

    private func pushApiKey(providerId: String, apiKey: String) async throws {
        do {
            _ = try await rpc.request(
                method: RPCMethod.providerSetApiKey,
                params: ProviderSetApiKeyParams(providerId: providerId, apiKey: apiKey),
                as: ProviderSetApiKeyResult.self
            )
        } catch {
            throw ActionError.sidecarPushFailed(Self.message(for: error))
        }
    }

    // MARK: - Test seams

    internal func _testSetLoginSession(_ s: LoginSession?) { loginSession = s }
    internal func _testSetProviders(_ ps: [Provider]) {
        providers = ps
    }
    internal func _testSetStatusLoaded(_ loaded: Bool) {
        statusLoaded = loaded
    }
}
