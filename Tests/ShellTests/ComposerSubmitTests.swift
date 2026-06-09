import Foundation
import Testing
import CoreGraphics
import RPCSchema
@testable import OSSenseKit
@testable import Shell

@MainActor
@Suite("Composer submit orchestration")
struct ComposerSubmitTests {
    @Test("view model owns composer submit orchestration and clears input after reserving turn")
    func viewModelSubmitsComposerPrompt() async throws {
        let harness = RPCServerHarness()
        harness.client.start()
        defer { harness.client.stop() }
        let vm = await makeViewModel(rpc: harness.client)
        vm.providerService._testSetProviders([
            ProviderService.Provider(
                id: "deepseek",
                name: "DeepSeek",
                authMethod: .apiKey,
                state: .ready
            ),
        ])
        vm.providerService._testSetStatusLoaded(true)
        vm.configService._testApply(
            providers: [
                ConfigProviderEntry(
                    id: "deepseek",
                    name: "DeepSeek",
                    defaultModelId: "deepseek-chat",
                    models: [
                        ConfigModelEntry(
                            id: "deepseek-chat",
                            name: "DeepSeek Chat",
                            supportedEfforts: [],
                            defaultEffort: nil,
                            supportsVision: false
                        ),
                    ]
                ),
            ],
            selection: ConfigSelection(providerId: "deepseek", modelId: "deepseek-chat")
        )
        vm.composerInputModel._testSetPlainText("Summarize this")

        let server = Task {
            let line = try await harness.readRequest(timeout: 2)
            let probe = try JSONDecoder().decode(RequestProbe.self, from: line)
            #expect(probe.method == RPCMethod.agentSubmit)
            let request = try JSONDecoder().decode(RPCRequest<AgentSubmitParams>.self, from: line)
            #expect(request.params.sessionId == "S")
            #expect(request.params.prompt == "Summarize this")
            #expect(UUID(uuidString: request.params.turnId) != nil)
            let response = RPCResponse(id: request.id, result: AgentSubmitResult(accepted: true))
            try harness.write(response)
        }

        await vm.submitComposer(deselectedBehaviorKeys: [])
        try await server.value

        #expect(vm.composerInputModel.isStorageEmpty)
        #expect(vm.composerInputModel.displayText == "")
    }

    @Test("submit refreshes OS Sense before projecting citedContext")
    func submitRefreshesOSSenseBeforeProjection() async throws {
        let adapter = SubmitRefreshAdapter()
        let harness = RPCServerHarness()
        harness.client.start()
        defer { harness.client.stop() }
        let vm = await makeViewModel(rpc: harness.client, adapters: [adapter])
        vm.providerService._testSetProviders([
            ProviderService.Provider(
                id: "deepseek",
                name: "DeepSeek",
                authMethod: .apiKey,
                state: .ready
            ),
        ])
        vm.providerService._testSetStatusLoaded(true)
        vm.configService._testApply(
            providers: [
                ConfigProviderEntry(
                    id: "deepseek",
                    name: "DeepSeek",
                    defaultModelId: "deepseek-chat",
                    models: [
                        ConfigModelEntry(
                            id: "deepseek-chat",
                            name: "DeepSeek Chat",
                            supportedEfforts: [],
                            defaultEffort: nil,
                            supportsVision: false
                        ),
                    ]
                ),
            ],
            selection: ConfigSelection(providerId: "deepseek", modelId: "deepseek-chat")
        )
        vm.senseStore._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.submit-refresh", name: "Preview", pid: 900, icon: nil),
            window: WindowIdentity(title: "Preview", windowId: nil)
        )
        await vm.senseStore._awaitPendingAdapterSwapForTesting()
        vm.composerInputModel._testSetPlainText("What page am I on?")

        let server = Task {
            let line = try await harness.readRequest(timeout: 2)
            let request = try JSONDecoder().decode(RPCRequest<AgentSubmitParams>.self, from: line)
            #expect(request.params.turnId.isEmpty == false)
            #expect(request.params.citedContext.behaviors?.contains {
                $0.citationKey == "mock.signal:fresh" && $0.displaySummary == "Fresh page 18"
            } == true)
            let response = RPCResponse(id: request.id, result: AgentSubmitResult(accepted: true))
            try harness.write(response)
        }

        await vm.submitComposer(deselectedBehaviorKeys: [])
        try await server.value
    }

    private func makeViewModel(
        rpc: RPCClient,
        adapters: [any SenseAdapter] = []
    ) async -> NotchViewModel {
        let permissions = PermissionsService()
        let registry = AdapterRegistry()
        for adapter in adapters {
            await registry.register(adapter)
        }
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
        session.sessionStore = store
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
}

private actor SubmitRefreshAdapter: SenseAdapter {
    static let id: AdapterID = "submit-refresh"
    static var supportedBundleIds: Set<String> = ["com.test.submit-refresh"]
    nonisolated let requiredPermissions: Set<Permission> = []

    private var continuation: AsyncStream<[_OSSenseBehaviorEnvelope]>.Continuation?

    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[_OSSenseBehaviorEnvelope]> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func detach() async {
        continuation?.finish()
        continuation = nil
    }

    func refresh() async -> [_OSSenseBehaviorEnvelope] {
        [
            _OSSenseBehaviorEnvelope(
                kind: "mock.signal",
                citationKey: "mock.signal:fresh",
                displaySummary: "Fresh page 18",
                payload: .object([:])
            ),
        ]
    }
}

private typealias _OSSenseBehaviorEnvelope = OSSenseKit.BehaviorEnvelope

private final class RPCServerHarness: @unchecked Sendable {
    let client: RPCClient
    private let serverToClient: Pipe
    private let clientToServer: Pipe

    init() {
        serverToClient = Pipe()
        clientToServer = Pipe()
        client = RPCClient(
            inbound: serverToClient.fileHandleForReading,
            outbound: clientToServer.fileHandleForWriting
        )
        let fd = clientToServer.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    func readRequest(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        let fd = clientToServer.fileHandleForReading.fileDescriptor
        var scratch = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            if let nl = buffer.firstIndex(of: 0x0A) {
                return buffer.subdata(in: buffer.startIndex..<nl)
            }
            let n = scratch.withUnsafeMutableBufferPointer { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                buffer.append(scratch, count: n)
                continue
            }
            if n == 0 {
                throw RPCClientError.connectionClosed
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RPCClientError.timeout(method: "test:readRequest")
    }

    func write<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try serverToClient.fileHandleForWriting.write(contentsOf: data)
    }
}

private struct RequestProbe: Decodable {
    let id: RPCId
    let method: String
}
