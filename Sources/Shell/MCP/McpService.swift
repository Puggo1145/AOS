import Foundation
import AppKit
import RPCSchema

// MARK: - McpService
//
// Shell-facing MCP Host service. The Sidecar owns MCP protocol sessions and
// `~/.notch-agent/mcp.json`; Settings reads this service and never calls RPC
// directly. OAuth is treated as part of "Connect": an unauthenticated OAuth
// server starts browser login and, on success, continues to MCP transport
// connection.

@MainActor
@Observable
public final class McpService {
    public private(set) var servers: [McpServerStatusInfo] = []
    public private(set) var loaded: Bool = false
    public private(set) var statusError: String?
    public private(set) var addSaving: Bool = false
    public private(set) var actionServerIds: Set<String> = []
    public private(set) var loginSessions: [String: McpAuthLoginStatusParams] = [:]

    private let requestStatus: () async throws -> McpStatusResult
    private let requestConfig: (String) async throws -> McpGetConfigResult
    private let requestAdd: (McpAddParams) async throws -> McpAddResult
    private let requestUpdate: (McpUpdateParams) async throws -> McpUpdateResult
    private let requestStartLogin: (String) async throws -> McpAuthStartLoginResult
    private let requestCancelLogin: (String) async throws -> McpAuthCancelLoginResult
    private let requestConnect: (String) async throws -> McpConnectResult
    private let requestDisconnect: (String) async throws -> McpDisconnectResult
    private let requestDelete: (String) async throws -> McpDeleteResult
    private let openURL: (URL) -> Void
    private var pendingConnectAfterLogin: Set<String> = []
    private var openedLoginIds: Set<String> = []

    public init(rpc: RPCClient) {
        self.requestStatus = {
            try await rpc.request(
                method: RPCMethod.mcpStatus,
                params: McpStatusParams(),
                as: McpStatusResult.self
            )
        }
        self.requestConfig = { serverId in
            try await rpc.request(
                method: RPCMethod.mcpGetConfig,
                params: McpGetConfigParams(serverId: serverId),
                as: McpGetConfigResult.self
            )
        }
        self.requestAdd = { params in
            try await rpc.request(
                method: RPCMethod.mcpAdd,
                params: params,
                as: McpAddResult.self
            )
        }
        self.requestUpdate = { params in
            try await rpc.request(
                method: RPCMethod.mcpUpdate,
                params: params,
                as: McpUpdateResult.self
            )
        }
        self.requestStartLogin = { serverId in
            try await rpc.request(
                method: RPCMethod.mcpAuthStartLogin,
                params: McpAuthStartLoginParams(serverId: serverId),
                as: McpAuthStartLoginResult.self
            )
        }
        self.requestCancelLogin = { loginId in
            try await rpc.request(
                method: RPCMethod.mcpAuthCancelLogin,
                params: McpAuthCancelLoginParams(loginId: loginId),
                as: McpAuthCancelLoginResult.self
            )
        }
        self.requestConnect = { serverId in
            try await rpc.request(
                method: RPCMethod.mcpConnect,
                params: McpConnectParams(serverId: serverId),
                as: McpConnectResult.self
            )
        }
        self.requestDisconnect = { serverId in
            try await rpc.request(
                method: RPCMethod.mcpDisconnect,
                params: McpDisconnectParams(serverId: serverId),
                as: McpDisconnectResult.self
            )
        }
        self.requestDelete = { serverId in
            try await rpc.request(
                method: RPCMethod.mcpDelete,
                params: McpDeleteParams(serverId: serverId),
                as: McpDeleteResult.self
            )
        }
        self.openURL = { NSWorkspace.shared.open($0) }
        registerHandlers(rpc: rpc)
    }

    internal init(
        requestStatus: @escaping () async throws -> McpStatusResult,
        requestConfig: @escaping (String) async throws -> McpGetConfigResult,
        requestAdd: @escaping (McpAddParams) async throws -> McpAddResult,
        requestUpdate: @escaping (McpUpdateParams) async throws -> McpUpdateResult,
        requestStartLogin: @escaping (String) async throws -> McpAuthStartLoginResult,
        requestCancelLogin: @escaping (String) async throws -> McpAuthCancelLoginResult,
        requestConnect: @escaping (String) async throws -> McpConnectResult,
        requestDisconnect: @escaping (String) async throws -> McpDisconnectResult,
        requestDelete: @escaping (String) async throws -> McpDeleteResult,
        openURL: @escaping (URL) -> Void = { _ in }
    ) {
        self.requestStatus = requestStatus
        self.requestConfig = requestConfig
        self.requestAdd = requestAdd
        self.requestUpdate = requestUpdate
        self.requestStartLogin = requestStartLogin
        self.requestCancelLogin = requestCancelLogin
        self.requestConnect = requestConnect
        self.requestDisconnect = requestDisconnect
        self.requestDelete = requestDelete
        self.openURL = openURL
    }

    public func refreshStatus() async {
        do {
            let result = try await requestStatus()
            servers = result.servers
            loaded = true
            statusError = nil
        } catch {
            statusError = Self.message(for: error)
        }
    }

    @discardableResult
    public func add(_ params: McpAddParams) async -> Bool {
        addSaving = true
        defer { addSaving = false }
        do {
            let result = try await requestAdd(params)
            upsert(result.server)
            loaded = true
            statusError = nil
            return true
        } catch {
            statusError = Self.message(for: error)
            return false
        }
    }

    public func config(serverId: String) async throws -> McpServerConfigInfo {
        do {
            let result = try await requestConfig(serverId)
            statusError = nil
            return result.config
        } catch {
            statusError = Self.message(for: error)
            throw error
        }
    }

    @discardableResult
    public func update(_ params: McpUpdateParams) async -> Bool {
        addSaving = true
        defer { addSaving = false }
        do {
            let result = try await requestUpdate(params)
            upsert(result.server)
            loaded = true
            statusError = nil
            return true
        } catch {
            statusError = Self.message(for: error)
            return false
        }
    }

    public func connect(serverId: String) async {
        guard let server = servers.first(where: { $0.serverId == serverId }) else {
            statusError = "Unknown MCP server: \(serverId)"
            return
        }
        actionServerIds.insert(serverId)
        defer { actionServerIds.remove(serverId) }

        if server.authType == .oauth, server.authState != .ready {
            do {
                try await cancelActiveLoginIfNeeded(serverId: serverId)
            } catch {
                pendingConnectAfterLogin.remove(serverId)
                statusError = Self.message(for: error)
                return
            }
            pendingConnectAfterLogin.insert(serverId)
            await startLogin(serverId: serverId)
            return
        }
        await connectTransport(serverId: serverId)
    }

    public func disconnect(serverId: String) async {
        actionServerIds.insert(serverId)
        defer { actionServerIds.remove(serverId) }
        do {
            let result = try await requestDisconnect(serverId)
            upsert(result.server)
            statusError = nil
        } catch {
            statusError = Self.message(for: error)
        }
    }

    public func delete(serverId: String) async {
        actionServerIds.insert(serverId)
        defer { actionServerIds.remove(serverId) }
        do {
            _ = try await requestDelete(serverId)
            servers.removeAll { $0.serverId == serverId }
            loginSessions.removeValue(forKey: serverId)
            pendingConnectAfterLogin.remove(serverId)
            statusError = nil
        } catch {
            statusError = Self.message(for: error)
        }
    }

    public static func message(for error: Error) -> String {
        if let clientError = error as? RPCClientError,
           case let .server(rpcError) = clientError {
            return rpcError.message
        }
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription {
            return message
        }
        return String(describing: error)
    }

    private func registerHandlers(rpc: RPCClient) {
        rpc.registerNotificationHandler(method: RPCMethod.mcpStatusChanged) { [weak self] (params: McpStatusChangedParams) in
            await self?.handleStatusChanged(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.mcpAuthStatusChanged) { [weak self] (params: McpAuthStatusChangedParams) in
            await self?.handleAuthStatusChanged(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.mcpAuthLoginStatus) { [weak self] (params: McpAuthLoginStatusParams) in
            await self?.handleLoginStatus(params)
        }
    }

    private func startLogin(serverId: String) async {
        do {
            let result = try await requestStartLogin(serverId)
            loginSessions[serverId] = McpAuthLoginStatusParams(
                loginId: result.loginId,
                serverId: serverId,
                state: .awaitingBrowser,
                authorizeUrl: result.authorizeUrl
            )
            if let url = URL(string: result.authorizeUrl) {
                openAuthorizeURLOnce(loginId: result.loginId, url: url)
            }
            statusError = nil
        } catch {
            pendingConnectAfterLogin.remove(serverId)
            statusError = Self.message(for: error)
        }
    }

    private func cancelActiveLoginIfNeeded(serverId: String) async throws {
        guard let session = loginSessions[serverId], session.isActiveLogin else {
            return
        }
        _ = try await requestCancelLogin(session.loginId)
        loginSessions.removeValue(forKey: serverId)
    }

    private func connectTransport(serverId: String) async {
        do {
            let result = try await requestConnect(serverId)
            upsert(result.server)
            statusError = nil
        } catch {
            statusError = Self.message(for: error)
        }
    }

    private func handleStatusChanged(_ params: McpStatusChangedParams) {
        upsert(params.server)
    }

    private func handleAuthStatusChanged(_ params: McpAuthStatusChangedParams) {
        guard let idx = servers.firstIndex(where: { $0.serverId == params.serverId }) else { return }
        let current = servers[idx]
        servers[idx] = McpServerStatusInfo(
            serverId: current.serverId,
            name: current.name,
            description: current.description,
            transportType: current.transportType,
            connectionState: current.connectionState,
            authState: params.state,
            authType: current.authType,
            message: params.message ?? current.message
        )
    }

    private func handleLoginStatus(_ params: McpAuthLoginStatusParams) {
        loginSessions[params.serverId] = params
        switch params.state {
        case .awaitingBrowser:
            if let rawURL = params.authorizeUrl,
               let url = URL(string: rawURL) {
                openAuthorizeURLOnce(loginId: params.loginId, url: url)
            }
        case .success:
            Task { [weak self] in
                guard let self else { return }
                await self.refreshStatus()
                if self.pendingConnectAfterLogin.remove(params.serverId) != nil {
                    await self.connectTransport(serverId: params.serverId)
                }
                self.openedLoginIds.remove(params.loginId)
            }
        case .failed, .cancelled:
            pendingConnectAfterLogin.remove(params.serverId)
            openedLoginIds.remove(params.loginId)
        case .starting, .awaitingCallback, .exchanging:
            break
        }
    }

    private func openAuthorizeURLOnce(loginId: String, url: URL) {
        guard openedLoginIds.insert(loginId).inserted else { return }
        openURL(url)
    }

    private func upsert(_ server: McpServerStatusInfo) {
        if let idx = servers.firstIndex(where: { $0.serverId == server.serverId }) {
            servers[idx] = server
        } else {
            servers.append(server)
            servers.sort { $0.serverId < $1.serverId }
        }
    }

    // MARK: - Test seams

    internal func _testSetServers(_ value: [McpServerStatusInfo]) {
        servers = value
        loaded = true
    }

    internal func _testSetLoginSession(_ value: McpAuthLoginStatusParams) {
        loginSessions[value.serverId] = value
    }

    internal func _testHandleLoginStatus(_ value: McpAuthLoginStatusParams) {
        handleLoginStatus(value)
    }
}

private extension McpAuthLoginStatusParams {
    var isActiveLogin: Bool {
        switch state {
        case .starting, .awaitingBrowser, .awaitingCallback, .exchanging:
            return true
        case .success, .failed, .cancelled:
            return false
        }
    }
}
