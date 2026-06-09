import Foundation
import Testing
import RPCSchema
@testable import Shell

@MainActor
@Suite("McpService")
struct McpServiceTests {
    @Test("refreshStatus requests status and applies configured servers")
    func refreshStatusLoadsServers() async {
        let server = Self.server(authState: .ready, authType: .oauth)
        var statusRequests = 0
        let service = Self.service(
            requestStatus: {
                statusRequests += 1
                return McpStatusResult(servers: [server])
            }
        )

        await service.refreshStatus()

        #expect(statusRequests == 1)
        #expect(service.loaded)
        #expect(service.servers == [server])
    }

    @Test("connect starts OAuth login before transport connection when auth is missing")
    func connectStartsOAuthLoginWhenUnauthenticated() async {
        var startLoginServerIds: [String] = []
        var transportConnects: [String] = []
        let service = Self.service(
            requestStartLogin: { serverId in
                startLoginServerIds.append(serverId)
                return McpAuthStartLoginResult(
                    loginId: "login-\(UUID().uuidString)",
                    authorizeUrl: "not a url"
                )
            },
            requestConnect: { serverId in
                transportConnects.append(serverId)
                return McpConnectResult(server: Self.server(authState: .ready, authType: .oauth))
            }
        )
        service._testSetServers([
            Self.server(authState: .unauthenticated, authType: .oauth),
        ])

        await service.connect(serverId: "linear")

        #expect(startLoginServerIds == ["linear"])
        #expect(transportConnects == [])
        #expect(service.loginSessions["linear"]?.state == .awaitingBrowser)
    }

    @Test("connect cancels an in-flight OAuth login before retrying")
    func connectCancelsInflightOAuthLoginBeforeRetrying() async {
        var cancelledLoginIds: [String] = []
        var startLoginServerIds: [String] = []
        var nextLoginCounter = 0
        let service = Self.service(
            requestStartLogin: { serverId in
                startLoginServerIds.append(serverId)
                nextLoginCounter += 1
                return McpAuthStartLoginResult(
                    loginId: "new-login-\(nextLoginCounter)",
                    authorizeUrl: "not a url"
                )
            },
            requestCancelLogin: { loginId in
                cancelledLoginIds.append(loginId)
                return McpAuthCancelLoginResult(cancelled: true)
            }
        )
        service._testSetServers([
            Self.server(authState: .authenticating, authType: .oauth),
        ])
        service._testSetLoginSession(McpAuthLoginStatusParams(
            loginId: "stuck-login",
            serverId: "linear",
            state: .awaitingCallback,
            authorizeUrl: "https://auth.example.com"
        ))

        await service.connect(serverId: "linear")

        #expect(cancelledLoginIds == ["stuck-login"])
        #expect(startLoginServerIds == ["linear"])
        #expect(service.loginSessions["linear"]?.loginId == "new-login-1")
        #expect(service.loginSessions["linear"]?.state == .awaitingBrowser)
    }

    @Test("add requests sidecar config write and inserts returned server")
    func addRequestsSidecarAndInsertsReturnedServer() async {
        var addParams: McpAddParams?
        let service = Self.service(
            requestAdd: { params in
                addParams = params
                return McpAddResult(
                    server: Self.server(
                        serverId: params.serverId,
                        description: params.description,
                        transportType: params.transportType,
                        authState: .notConfigured,
                        authType: .none
                    )
                )
            }
        )

        let saved = await service.add(McpAddParams(
            serverId: "filesystem",
            description: "Local files",
            transportType: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            env: [:]
        ))

        #expect(saved)
        #expect(addParams?.serverId == "filesystem")
        #expect(addParams?.command == "npx")
        #expect(service.loaded)
        #expect(service.servers.map(\.serverId) == ["filesystem"])
    }

    @Test("config requests editable sidecar config")
    func configRequestsEditableSidecarConfig() async throws {
        var requestedServerId: String?
        let service = Self.service(
            requestConfig: { serverId in
                requestedServerId = serverId
                return McpGetConfigResult(config: McpServerConfigInfo(
                    serverId: serverId,
                    description: "Local files",
                    transportType: .stdio,
                    command: "npx",
                    args: ["server.js"],
                    env: ["MCP_MODE": "test"]
                ))
            }
        )

        let config = try await service.config(serverId: "filesystem")

        #expect(requestedServerId == "filesystem")
        #expect(config.command == "npx")
        #expect(config.args == ["server.js"])
    }

    @Test("update requests sidecar config write and replaces returned server")
    func updateRequestsSidecarAndReplacesReturnedServer() async {
        var updateParams: McpUpdateParams?
        let service = Self.service(
            requestUpdate: { params in
                updateParams = params
                return McpUpdateResult(
                    server: Self.server(
                        serverId: params.serverId,
                        description: params.description,
                        transportType: params.transportType,
                        authState: .notConfigured,
                        authType: .none
                    )
                )
            }
        )
        service._testSetServers([
            Self.server(
                serverId: "filesystem",
                description: "Old files",
                transportType: .stdio,
                authState: .notConfigured,
                authType: .none
            ),
        ])

        let saved = await service.update(McpUpdateParams(
            serverId: "filesystem",
            description: "Edited files",
            transportType: .stdio,
            command: "node",
            args: ["server.js"],
            env: [:]
        ))

        #expect(saved)
        #expect(updateParams?.serverId == "filesystem")
        #expect(updateParams?.command == "node")
        #expect(service.servers.first?.description == "Edited files")
    }

    @Test("Sidecar-triggered OAuth login status opens authorize URL once")
    func loginStatusOpensAuthorizeURLOnce() async {
        var openedURLs: [URL] = []
        let service = Self.service(openURL: { openedURLs.append($0) })
        let status = McpAuthLoginStatusParams(
            loginId: "login-1",
            serverId: "linear",
            state: .awaitingBrowser,
            authorizeUrl: "https://auth.example.com/authorize"
        )

        service._testHandleLoginStatus(status)
        service._testHandleLoginStatus(status)

        #expect(openedURLs == [URL(string: "https://auth.example.com/authorize")!])
        #expect(service.loginSessions["linear"]?.loginId == "login-1")
    }

    private static func service(
        requestStatus: @escaping () async throws -> McpStatusResult = { McpStatusResult(servers: []) },
        requestConfig: @escaping (String) async throws -> McpGetConfigResult = { _ in
            Issue.record("unexpected mcp.getConfig request")
            return McpGetConfigResult(config: McpServerConfigInfo(
                serverId: "unexpected",
                description: "Unexpected",
                transportType: .stdio,
                command: "node",
                args: [],
                env: [:]
            ))
        },
        requestAdd: @escaping (McpAddParams) async throws -> McpAddResult = { _ in
            Issue.record("unexpected mcp.add request")
            return McpAddResult(server: Self.server(authState: .notConfigured, authType: .none))
        },
        requestUpdate: @escaping (McpUpdateParams) async throws -> McpUpdateResult = { _ in
            Issue.record("unexpected mcp.update request")
            return McpUpdateResult(server: Self.server(authState: .notConfigured, authType: .none))
        },
        requestStartLogin: @escaping (String) async throws -> McpAuthStartLoginResult = { _ in
            Issue.record("unexpected mcp.auth.startLogin request")
            return McpAuthStartLoginResult(loginId: "unexpected", authorizeUrl: "not a url")
        },
        requestCancelLogin: @escaping (String) async throws -> McpAuthCancelLoginResult = { _ in
            Issue.record("unexpected mcp.auth.cancelLogin request")
            return McpAuthCancelLoginResult(cancelled: false)
        },
        requestConnect: @escaping (String) async throws -> McpConnectResult = { _ in
            Issue.record("unexpected mcp.connect request")
            return McpConnectResult(server: Self.server(authState: .notConfigured, authType: .none))
        },
        requestDisconnect: @escaping (String) async throws -> McpDisconnectResult = { _ in
            Issue.record("unexpected mcp.disconnect request")
            return McpDisconnectResult(server: Self.server(authState: .notConfigured, authType: .none))
        },
        requestDelete: @escaping (String) async throws -> McpDeleteResult = { _ in
            Issue.record("unexpected mcp.delete request")
            return McpDeleteResult(deleted: true)
        },
        openURL: @escaping (URL) -> Void = { _ in }
    ) -> McpService {
        McpService(
            requestStatus: requestStatus,
            requestConfig: requestConfig,
            requestAdd: requestAdd,
            requestUpdate: requestUpdate,
            requestStartLogin: requestStartLogin,
            requestCancelLogin: requestCancelLogin,
            requestConnect: requestConnect,
            requestDisconnect: requestDisconnect,
            requestDelete: requestDelete,
            openURL: openURL
        )
    }

    private static func server(
        serverId: String = "linear",
        description: String = "Issue tracker",
        transportType: McpTransportType = .streamableHttp,
        authState: McpAuthServerState,
        authType: McpAuthType
    ) -> McpServerStatusInfo {
        McpServerStatusInfo(
            serverId: serverId,
            name: serverId,
            description: description,
            transportType: transportType,
            connectionState: .disconnected,
            authState: authState,
            authType: authType
        )
    }
}
