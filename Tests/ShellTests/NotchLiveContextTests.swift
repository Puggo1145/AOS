import Testing
import Foundation
import CoreGraphics
import RPCSchema
@testable import OSSenseKit
@testable import Shell

@MainActor
@Suite("Notch live context")
struct NotchLiveContextTests {
    private func makeViewModel() -> NotchViewModel {
        let inbound = Pipe()
        let outbound = Pipe()
        let rpc = RPCClient(
            inbound: inbound.fileHandleForReading,
            outbound: outbound.fileHandleForWriting
        )
        let permissions = PermissionsService()
        let registry = AdapterRegistry()
        let sense = SenseStore(permissionsService: permissions, registry: registry)
        let session = SessionService(rpc: rpc)
        let store = SessionStore(rpc: rpc, sessionService: session)
        store.adoptCreated(SessionListItem(
            id: "S",
            title: "test",
            createdAt: 0,
            turnCount: 0,
            lastActivityAt: 0
        ))
        let agent = AgentService(rpc: rpc, sessionStore: store)
        let provider = ProviderService(rpc: rpc)
        let config = ConfigService(rpc: rpc)
        let mcp = McpService(rpc: rpc)
        return NotchViewModel(
            senseStore: sense,
            agentService: agent,
            sessionService: session,
            providerService: provider,
            configService: config,
            mcpService: mcp,
            permissionsService: permissions,
            visualCapturePolicyStore: VisualCapturePolicyStore(),
            screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
            deviceNotchRect: CGRect(x: 620, y: 868, width: 200, height: 32)
        )
    }

    @Test("notchOpen keeps SenseStore context live after real app switches")
    func notchOpenKeepsContextLive() {
        let vm = makeViewModel()
        let editor = AppIdentity(bundleId: "com.example.editor", name: "Editor", pid: 123, icon: nil)
        let finder = AppIdentity(bundleId: "com.apple.finder", name: "Finder", pid: 456, icon: nil)
        let currentInput = BehaviorEnvelope(
            kind: "general.currentInput",
            citationKey: "general.currentInput:123",
            displaySummary: "Current input",
            payload: OSSenseKit.JSONValue.object(["value": OSSenseKit.JSONValue.string("draft")])
        )

        vm.senseStore._applyFrontmostForTesting(
            app: editor,
            window: WindowIdentity(title: "Draft", windowId: nil)
        )
        vm.senseStore._applyBehaviorsForTesting(source: "general", envelopes: [currentInput])
        vm.notchOpen()
        vm.senseStore._applyFrontmostForTesting(
            app: finder,
            window: WindowIdentity(title: "Downloads", windowId: nil)
        )

        #expect(vm.senseStore.context.app == finder)
        #expect(vm.senseStore.context.window?.title == "Downloads")
        #expect(vm.senseStore.context.behaviors.isEmpty)
    }
}
