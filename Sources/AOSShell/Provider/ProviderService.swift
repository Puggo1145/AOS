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
        public var state: State

        public init(id: String, name: String, state: State) {
            self.id = id
            self.name = name
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

    /// Seed entry: id stays stable so the onboard list has *something* to
    /// render before the first status reply, but `state == .unknown` until
    /// `refreshStatus` confirms. The display name is intentionally the
    /// neutral provider id rather than a hardcoded marketing string —
    /// `applyStatusResult` overwrites it with the sidecar's authoritative
    /// `ProviderInfo.name` on first success.
    public private(set) var providers: [Provider] = [
        Provider(id: "chatgpt-plan", name: "chatgpt-plan", state: .unknown)
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
    private var successDismissTask: Task<Void, Never>?

    public init(rpc: RPCClient) {
        self.rpc = rpc
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

    public func cancelLogin() async {
        guard let session = loginSession, !session.loginId.isEmpty else {
            loginSession = nil
            return
        }
        _ = try? await rpc.request(
            method: RPCMethod.providerCancelLogin,
            params: ProviderCancelLoginParams(loginId: session.loginId),
            as: ProviderCancelLoginResult.self
        )
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
            successDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.dismissLoginSession()
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
        // Merge by id; preserve seed entries that the sidecar didn't enumerate
        // (this round there is exactly one, but the merge is shape-safe).
        var byId: [String: Provider] = [:]
        for p in providers { byId[p.id] = p }
        for info in result.providers {
            let mapped: State = (info.state == .ready) ? .ready : .unauthenticated
            byId[info.id] = Provider(id: info.id, name: info.name, state: mapped)
        }
        providers = byId.values.sorted { $0.id < $1.id }
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
