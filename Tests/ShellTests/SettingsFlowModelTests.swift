import Foundation
import Testing
import RPCSchema
@testable import OSSenseKit
@testable import Shell

// MARK: - SettingsFlowModelTests
//
// Covers the seams the SettingsPanelView decomposition pulled out of the
// view: page navigation on the API-key and MCP-add flows, and the
// permission-settings action routing. Services are backed by the same
// cheap test doubles the existing suites use (closed-pipe RPCClient +
// scoped Keychain for ProviderService, McpService's closure-based test
// init, and PermissionsService's injectable openSystemSettings hook) so
// no RPC server or mock framework is needed.

@MainActor
@Suite("SettingsFlowModel")
struct SettingsFlowModelTests {

    @Test("openApiKeyPage preloads the stored key and navigates to the apiKey page")
    func openApiKeyPagePreloadsStoredKey() throws {
        let (flow, keychain) = try Self.makeFlow(providers: [
            ProviderService.Provider(id: "deepseek", name: "DeepSeek", authMethod: .apiKey, state: .ready),
        ])
        try keychain.saveApiKey(providerId: "deepseek", apiKey: "sk-existing")

        flow.openApiKeyPage(provider: ProviderService.Provider(
            id: "deepseek", name: "DeepSeek", authMethod: .apiKey, state: .ready
        ))

        #expect(flow.page == .apiKey)
        #expect(flow.apiKeyDraft == "sk-existing")
        #expect(flow.apiKeySaveError == nil)
    }

    @Test("saveApiKey surfaces the validation error and stays on the apiKey page when the provider is unknown")
    func saveApiKeyStaysOnPageOnFailure() async throws {
        let (flow, _) = try Self.makeFlow(providers: [
            ProviderService.Provider(id: "deepseek", name: "DeepSeek", authMethod: .apiKey, state: .ready),
        ])
        // Preload state as if the user had opened the page for a provider
        // id that no longer exists in the catalog by the time Save fires.
        flow.openApiKeyPage(provider: ProviderService.Provider(
            id: "unknown-provider", name: "Unknown", authMethod: .apiKey, state: .unauthenticated
        ))
        flow.apiKeyDraft = "sk-test"

        await flow.saveApiKey()

        #expect(flow.page == .apiKey)
        #expect(flow.apiKeySaveError != nil)
        #expect(flow.apiKeySaving == false)
    }

    @Test("saveMcpServer surfaces a validation error and does not navigate away on malformed JSON")
    func saveMcpServerSurfacesValidationError() async throws {
        let (flow, _) = try Self.makeFlow(providers: [])
        flow.page = .mcpAdd
        flow.mcpDraft.serverId = "filesystem"
        flow.mcpDraft.description = "Local filesystem tools"
        flow.mcpDraft.command = "npx"
        flow.mcpDraft.argsJSON = "not json"

        await flow.saveMcpServer()

        #expect(flow.page == .mcpAdd)
        #expect(flow.mcpAddError != nil)
    }

    @Test("resetMcpDraft clears the draft and any pending error")
    func resetMcpDraftClearsState() throws {
        let (flow, _) = try Self.makeFlow(providers: [])
        flow.mcpDraft.serverId = "filesystem"
        flow.mcpAddError = "boom"

        flow.resetMcpDraft()

        #expect(flow.mcpDraft == McpServerDraft())
        #expect(flow.mcpAddError == nil)
    }

    @Test("handlePermissionSettingsAction opens System Settings for accessibility and clears any prior error")
    func handlePermissionSettingsActionOpensSystemSettingsForAccessibility() throws {
        var openedPermissions: [Permission] = []
        let flow = try Self.makeFlow(
            providers: [],
            permissionsService: PermissionsService(
                userDefaults: Self.makeUserDefaults(),
                openSystemSettings: { openedPermissions.append($0) }
            )
        ).flow

        flow.handlePermissionSettingsAction(.accessibility)

        #expect(openedPermissions == [.accessibility])
        #expect(flow.permissionRequestError == nil)
    }

    @Test("permission navigation pops to main on ESC from any sub-page")
    func handleEscapePopsToMainFromSubPage() throws {
        let (flow, _) = try Self.makeFlow(providers: [])
        flow.page = .mcp
        var closed = false

        flow.handleEscape(onClose: { closed = true })

        #expect(flow.page == .main)
        #expect(closed == false)
    }

    @Test("permission navigation closes the panel on ESC from main")
    func handleEscapeClosesPanelFromMain() throws {
        let (flow, _) = try Self.makeFlow(providers: [])
        var closed = false

        flow.handleEscape(onClose: { closed = true })

        #expect(flow.page == .main)
        #expect(closed == true)
    }

    // MARK: - Fixture

    private static func makeUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: "notch-agent.tests.\(UUID().uuidString)")!
    }

    private static func makeFlow(
        providers: [ProviderService.Provider],
        permissionsService: PermissionsService? = nil
    ) throws -> (flow: SettingsFlowModel, keychain: KeychainService) {
        let configRPC = RPCClient(
            inbound: Pipe().fileHandleForReading,
            outbound: Pipe().fileHandleForWriting
        )
        let providerRPC = RPCClient(
            inbound: Pipe().fileHandleForReading,
            outbound: Pipe().fileHandleForWriting
        )
        let configService = ConfigService(rpc: configRPC)
        configService._testApply(providers: [], selection: nil)

        let keychain = KeychainService(service: "com.notch-agent.apikey.test.\(UUID().uuidString)")
        let providerService = ProviderService(rpc: providerRPC, keychain: keychain)
        providerService._testSetProviders(providers)
        providerService._testSetStatusLoaded(true)

        let mcpService = McpService(
            requestStatus: { McpStatusResult(servers: []) },
            requestConfig: { _ in
                Issue.record("unexpected mcp.getConfig request")
                return McpGetConfigResult(config: McpServerConfigInfo(
                    serverId: "unexpected",
                    description: "unexpected",
                    transportType: .stdio,
                    command: "node",
                    args: [],
                    env: [:]
                ))
            },
            requestAdd: { _ in
                Issue.record("unexpected mcp.add request")
                throw CancellationError()
            },
            requestUpdate: { _ in
                Issue.record("unexpected mcp.update request")
                throw CancellationError()
            },
            requestStartLogin: { _ in
                Issue.record("unexpected mcp.auth.startLogin request")
                throw CancellationError()
            },
            requestCancelLogin: { _ in
                Issue.record("unexpected mcp.auth.cancelLogin request")
                throw CancellationError()
            },
            requestConnect: { _ in
                Issue.record("unexpected mcp.connect request")
                throw CancellationError()
            },
            requestDisconnect: { _ in
                Issue.record("unexpected mcp.disconnect request")
                throw CancellationError()
            },
            requestDelete: { _ in
                Issue.record("unexpected mcp.delete request")
                throw CancellationError()
            }
        )

        let flow = SettingsFlowModel(
            configService: configService,
            providerService: providerService,
            mcpService: mcpService,
            permissionsService: permissionsService ?? PermissionsService(userDefaults: Self.makeUserDefaults())
        )
        return (flow, keychain)
    }
}
