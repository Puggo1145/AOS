import Foundation
import AppKit
import AOSRPCSchema

// MARK: - ProviderService
//
// Per docs/plans/onboarding.md §"Shell — ProviderService + Onboard UI".
// Owns three pieces of UI-facing state:
//   1. `providers`: per-provider summary; seeded so the onboard card is
//      never blank during the first refreshStatus().
//   2. `statusLoaded`: gates `hasReadyProvider` so we never flip to opened
//      input panel before the first status query completes.
//   3. `loginSession`: in-progress OAuth login, drives the onboard sub-states.
//
// `unknown` is a Shell-LOCAL state ONLY — it never appears on the wire. The
// wire schema (`ProviderState`) has only `ready` and `unauthenticated`.
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

    /// Startup seed — onboard cards are immediately clickable. `provider.status`
    /// is a local disk check, so we treat "no provider configured" as the
    /// default until a refresh confirms `ready` (which then flips the UI to
    /// the input panel via `hasReadyProvider`).
    public private(set) var providers: [Provider] = [
        Provider(id: "chatgpt-plan",
                 name: "Codex Subscription",
                 state: .unauthenticated)
    ]
    public private(set) var loginSession: LoginSession?

    /// `ready` only after refreshStatus / statusChanged confirms it. Default
    /// (no token on disk) → false → onboard panel shows.
    public var hasReadyProvider: Bool {
        providers.contains { $0.state == .ready }
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
        } catch {
            FileHandle.standardError.write(
                Data("[provider] refreshStatus failed: \(error)\n".utf8)
            )
            // Keep `statusLoaded == false` so the onboard panel surfaces the
            // "still trying to talk to sidecar" loading affordance rather
            // than silently flipping to either branch.
        }
    }

    public func startLogin(providerId: String) async {
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
}
