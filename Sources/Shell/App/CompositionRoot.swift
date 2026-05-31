import Foundation
import AppKit
import ComputerUseKit
import RPCSchema
import OSSenseKit

// MARK: - CompositionRoot
//
// The single object responsible for instantiating + wiring the Shell's live
// graph. Per docs/designs/notch-ui.md "数据流图":
//
//   PermissionsService ─┐
//                       ├─▶ SenseStore ─┐
//   AdapterRegistry  ───┘               ├─▶ NotchWindowController
//   SidecarProcess  ─▶ RPCClient ─▶ AgentService ─┘
//
// `start()` boots in the order required by the design (SenseStore first so
// the chip row has data on the first frame; sidecar handshake before the
// AgentService can submit). `rebuildWindow()` recreates the NotchWindow
// stack on screen-parameter changes. `stop()` is the inverse for clean
// app termination.

@MainActor
public final class CompositionRoot {
    public enum BootState: Equatable, Sendable {
        case idle
        case starting
        case sidecarLaunching
        case handshaking
        case mountingUI
        case bootstrappingSession
        case refreshingServices
        case running
        case stopping
        case stopped
        case fatal(String)
    }

    public let permissionsService: PermissionsService
    public let senseStore: SenseStore
    public let computerUseCore: ComputerUseCore
    public let adapterRegistry: AdapterRegistry
    public let visualCapturePolicyStore: VisualCapturePolicyStore
    public let sidecarProcess: SidecarProcess
    public let sidecarSupervisor: SidecarSupervisor
    public private(set) var rpcClient: RPCClient?
    public private(set) var agentService: AgentService?
    public private(set) var sessionService: SessionService?
    public private(set) var providerService: ProviderService?
    public private(set) var configService: ConfigService?
    private(set) var computerUseRPCService: ComputerUseRPCService?
    private(set) var permissionApprovalService: PermissionApprovalService?
    public private(set) var devContextService: DevContextService?
    private(set) var devComputerUseService: DevComputerUseService?
    public private(set) var devModeWindowController: DevModeWindowController?
    private var devModeOpenObserver: NSObjectProtocol?
    public private(set) var notchWindowController: NotchWindowController?
    public private(set) var bootState: BootState = .idle

    /// Latest fatal error surfaced during boot (e.g. handshake mismatch,
    /// bun missing). The OpenedPanelView reads `agentService.lastErrorMessage`
    /// for run-time errors; this property is for boot-time diagnostics.
    public private(set) var fatalBootError: String?
    private var fatalBootAlertPresented: Bool = false

    /// Bootstrap session.create failure — distinct from `fatalBootError`
    /// because the sidecar handshake succeeded; only the initial session
    /// allocation failed. The composer uses this to disable input + show
    /// a precise message rather than silently no-op'ing on submit.
    public private(set) var sessionBootError: String?

    public init() {
        self.permissionsService = PermissionsService()
        self.adapterRegistry = AdapterRegistry()
        self.senseStore = SenseStore(
            permissionsService: permissionsService,
            registry: adapterRegistry
        )
        self.computerUseCore = ComputerUseCore()
        self.visualCapturePolicyStore = VisualCapturePolicyStore()
        let sidecarProcess = SidecarProcess()
        self.sidecarProcess = sidecarProcess
        self.sidecarSupervisor = SidecarSupervisor(process: sidecarProcess)
        self.sidecarSupervisor.setFatalHandler { [weak self] message in
            self?.handleUnexpectedSidecarExit(message: message)
        }
    }

    public func start() async {
        bootState = .starting
        await Self.registerBuiltinSenseAdapters(into: adapterRegistry)

        // 1. SenseStore: starts WindowMirror + initial permissions probe.
        await senseStore.start()

        // 2. Spawn Bun sidecar; wire stdio to the RPC client.
        let pipes: SidecarPipes
        bootState = .sidecarLaunching
        sidecarSupervisor.beginLaunch()
        do {
            pipes = try sidecarProcess.spawn()
            sidecarSupervisor.didLaunch()
        } catch {
            sidecarSupervisor.didFailLaunch()
            FileHandle.standardError.write(
                Data("[shell] sidecar spawn failed: \(error)\n".utf8)
            )
            enterFatalBootState("Sidecar failed to start: \(error)")
            return
        }
        let client = RPCClient(
            inbound: pipes.fromSidecar,
            outbound: pipes.toSidecar
        )
        client.start()
        self.rpcClient = client

        // 3. Construct ProviderService (notification handler registration only,
        //    no RPC issued yet), ConfigService, and AgentService.
        let provider = ProviderService(rpc: client)
        self.providerService = provider
        let config = ConfigService(rpc: client)
        self.configService = config
        let shellComputerUseClient = LiveShellComputerUseClient(core: computerUseCore)
        self.computerUseRPCService = ComputerUseRPCService(
            rpc: client,
            core: shellComputerUseClient
        )
        self.permissionApprovalService = PermissionApprovalService(rpc: client)
        let session = SessionService(rpc: client)
        self.sessionService = session
        let store = SessionStore(rpc: client, sessionService: session)
        session.sessionStore = store
        let agent = AgentService(
            rpc: client,
            sessionStore: store,
            stopComputerUseAppSessionAfterManualAbort: { [computerUseCore] in
                do {
                    _ = try await computerUseCore.currentAppSession()
                } catch ComputerUseError.appSessionUnavailable {
                    return
                }
                _ = try await computerUseCore.stopAppSession()
            }
        )
        self.agentService = agent
        ComputerUseWindowHighlightControls.setStopHandler { [weak agent] in
            Task { @MainActor in
                await agent?.cancel()
            }
        }

        // Dev Mode owns its own services and NSWindow. Context/OS Sense stay
        // read-only; Computer Use gets a separate diagnostic adapter that
        // starts and stops only the app session selected inside the panel.
        // Wire the Settings entry through NotificationCenter so the notch
        // view tree stays unaware of the debug surface.
        let devContext = DevContextService(rpc: client)
        self.devContextService = devContext
        let devComputerUse = DevComputerUseService(client: shellComputerUseClient)
        self.devComputerUseService = devComputerUse
        let devWindow = DevModeWindowController(
            contextService: devContext,
            senseStore: senseStore,
            computerUseService: devComputerUse,
            sessionStore: store
        )
        self.devModeWindowController = devWindow
        self.devModeOpenObserver = NotificationCenter.default.addObserver(
            forName: .notchOpenDevMode,
            object: nil,
            queue: .main
        ) { [weak devWindow] _ in
            Task { @MainActor in devWindow?.show() }
        }

        // 4. Mount the notch window before awaiting handshake so the user
        //    sees the bar immediately. ProviderService starts in `unknown`
        //    state — onboard renders a loading affordance until step 6.
        bootState = .mountingUI
        mountWindow()

        // 5. Await handshake. MAJOR mismatch from the sidecar terminates it
        //    and surfaces a fatal error. Inbound rpc.hello path is handled
        //    inside RPCClient.
        bootState = .handshaking
        do {
            _ = try await client.awaitHandshake(timeout: 5)
        } catch {
            FileHandle.standardError.write(
                Data("[shell] handshake failed: \(error)\n".utf8)
            )
            sidecarProcess.terminate()
            enterFatalBootState("RPC handshake failed: \(error)")
            EventMonitors.shared.start()
            return
        }

        // 6. Bootstrap session: explicit `session.create` per
        //    docs/designs/session-management.md — manager starts empty so
        //    every `agent.*` call must carry a sessionId. `SessionService.create`
        //    drives `SessionStore.adoptCreated` from the response, atomically
        //    flipping `activeId` so the rest of boot — and any UI already
        //    mounted in step 4 — observes the active session before the next
        //    async hop. Failure here is recorded as `sessionBootError` so the
        //    composer can disable input and surface a precise message instead
        //    of pretending submit will work.
        bootState = .bootstrappingSession
        do {
            _ = try await session.create()
        } catch {
            FileHandle.standardError.write(
                Data("[shell] session.create bootstrap failed: \(error)\n".utf8)
            )
            let msg = "Session initialization failed: \(error.localizedDescription). Restart Notch Agent to retry."
            sessionBootError = msg
            store.bootError = msg
        }

        // 7. After handshake: refresh provider status so the onboard panel
        //    can flip to either the "ready" branch (input panel) or the
        //    actual onboard cards. Failure is logged only — UI stays on the
        //    loading affordance, which is the right signal in that case.
        //    Pull config in parallel so the settings panel has data on first
        //    open (catalog snapshot + saved selection).
        bootState = .refreshingServices
        async let providerRefresh: () = provider.refreshStatus()
        async let configRefresh: () = config.refresh()
        _ = await (providerRefresh, configRefresh)

        // 8. Start global event monitors (closed/popping/opened state machine).
        EventMonitors.shared.start()
        bootState = .running

    }

    /// Registers Shell-owned OS Sense adapters at the composition boundary.
    /// Core stays typed only to `SenseAdapter`; concrete adapters are created
    /// here where app wiring belongs.
    internal static func registerBuiltinSenseAdapters(into registry: AdapterRegistry) async {
        await registry.register(FinderAdapter())
        await registry.register(PreviewAdapter())
        await registry.register(BrowserAdapter())
    }

    /// Rebuild the notch window stack on screen change. Per
    /// notch-dev-guide.md §3.4 we destroy fully and rebuild on the (new)
    /// built-in display.
    public func rebuildWindow() {
        notchWindowController?.destroy()
        notchWindowController = nil
        mountWindow()
    }

    private func mountWindow() {
        guard let screen = NSScreen.buildin else {
            FileHandle.standardError.write(
                Data("[shell] no built-in display detected; refusing to show NotchWindow\n".utf8)
            )
            return
        }
        guard screen.notchSize != .zero else {
            FileHandle.standardError.write(
                Data("[shell] built-in display has no notch; refusing to show NotchWindow\n".utf8)
            )
            return
        }
        guard let agent = agentService,
              let session = sessionService,
              let provider = providerService,
              let config = configService else {
            // mountWindow may be called before agent/provider/config services are
            // built (sidecar failed to spawn). Skip rather than partially
            // render — the boot path surfaces the error via fatalBootError.
            return
        }
        notchWindowController = NotchWindowController(
            senseStore: senseStore,
            agentService: agent,
            sessionService: session,
            providerService: provider,
            configService: config,
            permissionsService: permissionsService,
            visualCapturePolicyStore: visualCapturePolicyStore,
            permissionApprovalService: permissionApprovalService,
            screen: screen
        )
    }

    private func handleUnexpectedSidecarExit(status: Int32) {
        handleUnexpectedSidecarExit(message: SidecarSupervisor.unexpectedExitMessage(status: status))
    }

    private func handleUnexpectedSidecarExit(message: String) {
        FileHandle.standardError.write(
            Data("[shell] \(message)\n".utf8)
        )
        bootState = .fatal(message)
        fatalBootError = message
        rpcClient?.stop()
        EventMonitors.shared.start()
        presentFatalBootError(message)
    }

    private func enterFatalBootState(_ message: String) {
        bootState = .fatal(message)
        fatalBootError = message
        presentFatalBootError(message)
    }

    private func presentFatalBootError(_ message: String) {
        guard !fatalBootAlertPresented else { return }
        fatalBootAlertPresented = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Notch Agent failed to start"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit Notch Agent")
        alert.addButton(withTitle: "Keep Open")
        let response = notchWindowController?.withSystemModalPresentation {
            alert.runModal()
        } ?? alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    public func stop() {
        bootState = .stopping
        EventMonitors.shared.stop()
        if let token = devModeOpenObserver {
            NotificationCenter.default.removeObserver(token)
            devModeOpenObserver = nil
        }
        devModeWindowController?.close()
        devModeWindowController = nil
        devContextService = nil
        notchWindowController?.destroy()
        notchWindowController = nil
        rpcClient?.stop()
        rpcClient = nil
        providerService = nil
        configService = nil
        computerUseRPCService = nil
        permissionApprovalService?.failAllPendingRequests(message: "permission approval service stopped")
        permissionApprovalService = nil
        ComputerUseWindowHighlightControls.setStopHandler(nil)
        agentService = nil
        sessionService = nil
        sidecarSupervisor.expectTermination()
        sidecarProcess.terminate()
        senseStore.stop()
        bootState = .stopped
    }
}
