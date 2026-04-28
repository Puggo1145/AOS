import Foundation
import AppKit
import AOSRPCSchema
import AOSOSSenseKit
import AOSComputerUseKit

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
    public let permissionsService: PermissionsService
    public let senseStore: SenseStore
    public let adapterRegistry: AdapterRegistry
    public let visualCapturePolicyStore: VisualCapturePolicyStore
    public let sidecarProcess: SidecarProcess
    public private(set) var rpcClient: RPCClient?
    public private(set) var computerUseService: ComputerUseService?
    public private(set) var computerUseHandlers: ComputerUseHandlers?
    public private(set) var computerUseDoctorService: ComputerUseDoctorService?
    public private(set) var agentService: AgentService?
    public private(set) var sessionService: SessionService?
    public private(set) var providerService: ProviderService?
    public private(set) var configService: ConfigService?
    public private(set) var devContextService: DevContextService?
    public private(set) var devModeWindowController: DevModeWindowController?
    private var devModeOpenObserver: NSObjectProtocol?
    public private(set) var notchWindowController: NotchWindowController?

    /// Latest fatal error surfaced during boot (e.g. handshake mismatch,
    /// bun missing). The OpenedPanelView reads `agentService.lastErrorMessage`
    /// for run-time errors; this property is for boot-time diagnostics.
    public private(set) var fatalBootError: String?

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
        self.visualCapturePolicyStore = VisualCapturePolicyStore()
        self.sidecarProcess = SidecarProcess()
    }

    public func start() async {
        // 1. SenseStore: starts WindowMirror + initial permissions probe.
        await senseStore.start()

        // 2. Spawn Bun sidecar; wire stdio to the RPC client.
        let pipes: SidecarPipes
        do {
            pipes = try sidecarProcess.spawn()
        } catch {
            FileHandle.standardError.write(
                Data("[shell] sidecar spawn failed: \(error)\n".utf8)
            )
            fatalBootError = "Sidecar failed to start: \(error)"
            mountWindow()
            return
        }
        let client = RPCClient(
            inbound: pipes.fromSidecar,
            outbound: pipes.toSidecar
        )
        client.start()
        self.rpcClient = client

        // Computer Use handlers — register `computerUse.*` methods on the
        // RPC client so the sidecar agent loop's tool calls land on the
        // in-process Kit. Per docs/designs/computer-use.md §"与 AOS 主进程
        // 的集成": Kit is a Swift dependency linked into Shell; handlers
        // run on independent Tasks and don't block the dispatcher.
        let cuService = ComputerUseService()
        // Visualize agent operations: software cursor overlay rides on every
        // background-pid click / drag / scroll via the Kit's MouseInput
        // observer hook. Frontmost HID-tap clicks (real cursor moves) are
        // skipped automatically. Disable at runtime with `AOS_VISUAL_CURSOR=0`.
        AOSComputerUseKit.installVisualCursor()
        let cuHandlers = ComputerUseHandlers(
            service: cuService, permissions: permissionsService
        )
        cuHandlers.register(on: client)
        self.computerUseService = cuService
        self.computerUseHandlers = cuHandlers
        // Doctor service: same in-process Kit handle as the RPC handlers, so
        // Dev Mode + the boot-time auto-probe both read truth without going
        // out over the wire. Auto-run is fired from NotchView once permissions
        // reach their settled state — see PermissionOnboardPanelView.
        let cuDoctor = ComputerUseDoctorService(
            service: cuService, permissions: permissionsService
        )
        self.computerUseDoctorService = cuDoctor

        // 3. Construct ProviderService (notification handler registration only,
        //    no RPC issued yet), ConfigService, and AgentService.
        let provider = ProviderService(rpc: client)
        self.providerService = provider
        let config = ConfigService(rpc: client)
        self.configService = config
        let session = SessionService(rpc: client)
        self.sessionService = session
        let store = SessionStore(rpc: client, sessionService: session)
        session.sessionStore = store
        let agent = AgentService(rpc: client, sessionStore: store)
        self.agentService = agent

        // Dev Mode is purely observational: the service subscribes to
        // `dev.context.changed` and the controller owns its own NSWindow.
        // Wire the "Dev Mode" button in Settings to the window via
        // NotificationCenter so the notch view tree stays unaware of it.
        let devContext = DevContextService(rpc: client)
        self.devContextService = devContext
        let devWindow = DevModeWindowController(
            contextService: devContext,
            sessionStore: store,
            doctorService: cuDoctor
        )
        self.devModeWindowController = devWindow
        self.devModeOpenObserver = NotificationCenter.default.addObserver(
            forName: .aosOpenDevMode,
            object: nil,
            queue: .main
        ) { [weak devWindow] _ in
            Task { @MainActor in devWindow?.show() }
        }

        // 4. Mount the notch window before awaiting handshake so the user
        //    sees the bar immediately. ProviderService starts in `unknown`
        //    state — onboard renders a loading affordance until step 6.
        mountWindow()

        // 5. Await handshake. MAJOR mismatch from the sidecar terminates it
        //    and surfaces a fatal error. Inbound rpc.hello path is handled
        //    inside RPCClient.
        do {
            _ = try await client.awaitHandshake(timeout: 5)
        } catch {
            FileHandle.standardError.write(
                Data("[shell] handshake failed: \(error)\n".utf8)
            )
            fatalBootError = "RPC handshake failed: \(error)"
            sidecarProcess.terminate()
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
        do {
            _ = try await session.create()
        } catch {
            FileHandle.standardError.write(
                Data("[shell] session.create bootstrap failed: \(error)\n".utf8)
            )
            let msg = "Session initialization failed: \(error.localizedDescription). Restart AOS to retry."
            sessionBootError = msg
            store.bootError = msg
        }

        // 7. After handshake: refresh provider status so the onboard panel
        //    can flip to either the "ready" branch (input panel) or the
        //    actual onboard cards. Failure is logged only — UI stays on the
        //    loading affordance, which is the right signal in that case.
        //    Pull config in parallel so the settings panel has data on first
        //    open (catalog snapshot + saved selection).
        async let providerRefresh: () = provider.refreshStatus()
        async let configRefresh: () = config.refresh()
        _ = await (providerRefresh, configRefresh)

        // 8. Start global event monitors (closed/popping/opened state machine).
        EventMonitors.shared.start()

        // 9. Auto-doctor: once Accessibility + Screen Recording are both
        //    granted (which may already be true from a prior run), probe the
        //    SkyLight SPI surface once and log a one-line warning if anything
        //    is missing. Plan Stage 5: "权限或 SPI 缺失直接给用户反馈".
        //    Detached from view lifecycle so it survives notch open/close.
        scheduleDoctorAutoRun(doctor: cuDoctor)
    }

    /// Poll `permissionsService.allGranted` until it flips true (or already
    /// is), then fire `ComputerUseDoctorService.runOnceIfNeeded`. We don't
    /// hold a reference to the task — it self-terminates after one
    /// successful run, and CompositionRoot.stop() drops the doctor service
    /// either way.
    private func scheduleDoctorAutoRun(doctor: ComputerUseDoctorService) {
        Task { [weak permissionsService] in
            while !Task.isCancelled {
                if permissionsService?.allGranted == true {
                    await doctor.runOnceIfNeeded()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
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
            screen: screen
        )
    }

    public func stop() {
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
        computerUseHandlers = nil
        computerUseService = nil
        computerUseDoctorService = nil
        providerService = nil
        configService = nil
        agentService = nil
        sessionService = nil
        sidecarProcess.terminate()
        senseStore.stop()
    }
}
