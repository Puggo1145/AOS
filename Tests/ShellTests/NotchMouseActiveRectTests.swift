import AppKit
import CoreGraphics
import Foundation
import OSSenseKit
import RPCSchema
import Testing
@testable import Shell

@MainActor
@Suite("Notch mouse-active rect")
struct NotchMouseActiveRectTests {
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
        return NotchViewModel(
            senseStore: sense,
            agentService: agent,
            sessionService: session,
            providerService: provider,
            configService: config,
            permissionsService: permissions,
            visualCapturePolicyStore: VisualCapturePolicyStore(),
            screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
            deviceNotchRect: CGRect(x: 620, y: 868, width: 200, height: 32)
        )
    }

    private func configureReadyProvider(_ vm: NotchViewModel) {
        vm.providerService._testSetProviders([
            ProviderService.Provider(
                id: "deepseek",
                name: "DeepSeek",
                authMethod: .apiKey,
                state: .ready
            )
        ])
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
                        )
                    ]
                )
            ],
            selection: ConfigSelection(providerId: "deepseek", modelId: "deepseek-chat"),
            hasCompletedOnboarding: true
        )
    }

    private func waitForTransitionEnd(_ isActive: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if !isActive() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(isActive() == false)
    }

    private func waitForDetachMorphPhase(
        _ expected: NotchViewModel.DetachMorphPhase,
        viewModel: NotchViewModel
    ) async throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if viewModel.detachMorphPhase == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(viewModel.detachMorphPhase == expected)
    }

    @Test("second settings open with unchanged measured height ignores blank space")
    func secondSettingsOpenWithUnchangedMeasuredHeightIgnoresBlankSpace() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.showSettings = true
        vm.markSettingsMeasured(height: 120)
        vm.showSettings = false

        vm.showSettings = true
        vm.markSettingsMeasured(height: 120)

        let blankBelowActualUI = NSPoint(x: vm.screenRect.midX, y: vm.screenRect.maxY - 260)
        #expect(vm.visibleHotRect.contains(blankBelowActualUI) == false)
        #expect(NotchWindowController.shouldIgnoreMouseEvents(
            mouse: blankBelowActualUI,
            mouseActiveRect: vm.mouseActiveRect
        ))
    }

    @Test("second history open with unchanged measured height ignores blank space")
    func secondHistoryOpenWithUnchangedMeasuredHeightIgnoresBlankSpace() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.showHistory = true
        vm.markHistoryMeasured(height: 120)
        vm.showHistory = false

        vm.showHistory = true
        vm.markHistoryMeasured(height: 120)

        let blankBelowActualUI = NSPoint(x: vm.screenRect.midX, y: vm.screenRect.maxY - 260)
        #expect(vm.visibleHotRect.contains(blankBelowActualUI) == false)
        #expect(NotchWindowController.shouldIgnoreMouseEvents(
            mouse: blankBelowActualUI,
            mouseActiveRect: vm.mouseActiveRect
        ))
    }

    @Test("settings reopen stays mouse-active for newly taller content until measurement lands")
    func settingsReopenStaysMouseActiveForNewlyTallerContentUntilMeasurementLands() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.showSettings = true
        vm.markSettingsMeasured(height: 120)
        vm.showSettings = false

        vm.showSettings = true

        let newlyVisibleBeforeMeasurement = NSPoint(x: vm.screenRect.midX, y: vm.screenRect.maxY - 260)
        #expect(vm.visibleHotRect.contains(newlyVisibleBeforeMeasurement) == false)
        #expect(NotchWindowController.shouldIgnoreMouseEvents(
            mouse: newlyVisibleBeforeMeasurement,
            mouseActiveRect: vm.mouseActiveRect
        ) == false)

        vm.markSettingsMeasured(height: 260)
        #expect(vm.visibleHotRect.contains(newlyVisibleBeforeMeasurement))
    }

    @Test("history reopen stays mouse-active for newly taller content until measurement lands")
    func historyReopenStaysMouseActiveForNewlyTallerContentUntilMeasurementLands() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.showHistory = true
        vm.markHistoryMeasured(height: 120)
        vm.showHistory = false

        vm.showHistory = true

        let newlyVisibleBeforeMeasurement = NSPoint(x: vm.screenRect.midX, y: vm.screenRect.maxY - 260)
        #expect(vm.visibleHotRect.contains(newlyVisibleBeforeMeasurement) == false)
        #expect(NotchWindowController.shouldIgnoreMouseEvents(
            mouse: newlyVisibleBeforeMeasurement,
            mouseActiveRect: vm.mouseActiveRect
        ) == false)

        vm.markHistoryMeasured(height: 260)
        #expect(vm.visibleHotRect.contains(newlyVisibleBeforeMeasurement))
    }

    @Test("detach drag lifecycle keeps first press drag active through update and finish")
    func detachDragLifecycleKeepsFirstPressDragActiveThroughUpdateAndFinish() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.composerContentHeight = 80

        vm.startDetachDrag(pointer: CGPoint(x: 840, y: 884))
        guard case let .detached(startFrame) = vm.placement else {
            Issue.record("Expected detached placement after starting drag")
            return
        }
        vm.updateDetachDrag(pointer: CGPoint(x: 900, y: 700))

        guard case let .detached(frame) = vm.placement else {
            Issue.record("Expected detached placement while dragging")
            return
        }
        #expect(frame.minX == startFrame.minX + 60)
        #expect(frame.minY < startFrame.minY)

        vm.updateDetachDrag(pointer: CGPoint(x: 100, y: 700))
        guard case let .detached(edgeFrame) = vm.placement else {
            Issue.record("Expected detached placement at edge before finish")
            return
        }

        vm.finishDetachDrag(pointer: CGPoint(x: 900, y: 200))
        guard case let .edgeDock(
            edge: edge,
            hiddenFrame: hiddenFrame,
            revealFrame: revealFrame,
            triggerFrame: _,
            revealed: revealed
        ) = vm.placement else {
            Issue.record("Expected edge dock after finishing near edge")
            return
        }
        #expect(edge == .left)
        #expect(hiddenFrame.maxX == vm.screenRect.minX)
        #expect(revealFrame.minY == edgeFrame.minY)
        #expect(revealed == false)
    }

    @Test("finish detach drag ignores stale mouse-up pointer and keeps current frame")
    func finishDetachDragIgnoresStaleMouseUpPointerAndKeepsCurrentFrame() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.composerContentHeight = 80

        vm.startDetachDrag(pointer: CGPoint(x: 840, y: 884))
        vm.updateDetachDrag(pointer: CGPoint(x: 900, y: 700))
        guard case let .detached(frameBeforeMouseUp) = vm.placement else {
            Issue.record("Expected detached placement before finish")
            return
        }

        vm.finishDetachDrag(pointer: CGPoint(x: 1000, y: 100))

        #expect(vm.placement == .detached(frameBeforeMouseUp))
    }

    @Test("detached settings height changes keep panel top anchored before next drag")
    func detachedSettingsHeightChangesKeepPanelTopAnchoredBeforeNextDrag() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.showSettings = true
        vm.markSettingsMeasured(height: 120)
        let initialFrame = CGRect(
            x: 240,
            y: 360,
            width: vm.detachedTotalSize.width,
            height: vm.detachedTotalSize.height
        )
        vm.setPlacement(.detached(initialFrame))

        vm.markSettingsMeasured(height: 260)

        #expect(vm.placement == .detached(initialFrame))
        guard case let .detached(resizedFrame) = vm.currentPlacement else {
            Issue.record("Expected current detached placement after settings height change")
            return
        }
        #expect(resizedFrame.size == vm.detachedTotalSize)
        #expect(resizedFrame.minX == initialFrame.minX)
        #expect(resizedFrame.maxY == initialFrame.maxY)
    }

    @Test("detached content height changes derive the render frame without mutating placement state")
    func detachedContentHeightChangesDeriveRenderFrameWithoutMutatingPlacementState() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.showSettings = true
        vm.markSettingsMeasured(height: 120)
        let placementFrame = CGRect(
            x: 240,
            y: 360,
            width: vm.detachedTotalSize.width,
            height: vm.detachedTotalSize.height
        )
        vm.setPlacement(.detached(placementFrame))

        vm.markSettingsMeasured(height: 260)

        #expect(vm.placement == .detached(placementFrame))
        guard case let .detached(currentFrame) = vm.currentPlacement else {
            Issue.record("Expected current detached placement")
            return
        }
        #expect(currentFrame != placementFrame)
        #expect(currentFrame.maxY == placementFrame.maxY)
        #expect(currentFrame.size == vm.detachedTotalSize)
    }

    @Test("each detached content height change notifies window placement without mutating placement state")
    func eachDetachedContentHeightChangeNotifiesWindowPlacementWithoutMutatingPlacementState() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.showSettings = true
        vm.markSettingsMeasured(height: 120)
        let placementFrame = CGRect(
            x: 240,
            y: 360,
            width: vm.detachedTotalSize.width,
            height: vm.detachedTotalSize.height
        )
        vm.setPlacement(.detached(placementFrame))

        var placementNotificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .notchPlacementChanged,
            object: nil,
            queue: nil
        ) { _ in
            placementNotificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        vm.markSettingsMeasured(height: 260)

        #expect(placementNotificationCount == 1)
        #expect(vm.placement == .detached(placementFrame))
        guard case let .detached(tallerFrame) = vm.currentPlacement else {
            Issue.record("Expected current detached placement")
            return
        }
        #expect(tallerFrame.maxY == placementFrame.maxY)
        #expect(tallerFrame.size == vm.detachedTotalSize)

        vm.markSettingsMeasured(height: 180)

        #expect(placementNotificationCount == 2)
        #expect(vm.placement == .detached(placementFrame))
        guard case let .detached(shorterFrame) = vm.currentPlacement else {
            Issue.record("Expected current detached placement after the second height change")
            return
        }
        #expect(shorterFrame.maxY == placementFrame.maxY)
        #expect(shorterFrame.size == vm.detachedTotalSize)
    }

    @Test("detached settings open waits for first measurement instead of collapsing to compact height")
    func detachedSettingsOpenWaitsForFirstMeasurementInsteadOfCollapsingToCompactHeight() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        configureReadyProvider(vm)
        vm.composerContentHeight = 180
        let initialFrame = CGRect(
            x: 240,
            y: 360,
            width: vm.detachedTotalSize.width,
            height: vm.detachedTotalSize.height
        )
        vm.setPlacement(.detached(initialFrame))
        let sizeBeforeSettings = vm.detachedTotalSize

        vm.showSettings = true

        #expect(vm.detachedTotalSize == sizeBeforeSettings)
        #expect(vm.placement == .detached(initialFrame))

        vm.markSettingsMeasured(height: 260)
        #expect(vm.placement == .detached(initialFrame))
        guard case let .detached(measuredFrame) = vm.currentPlacement else {
            Issue.record("Expected current detached placement after settings measurement")
            return
        }
        #expect(measuredFrame.height == vm.detachedTotalSize.height)
        #expect(measuredFrame.maxY == initialFrame.maxY)
    }

    @Test("detached pending settings height uses opened surface state instead of placement frame")
    func detachedPendingSettingsHeightUsesOpenedSurfaceStateInsteadOfPlacementFrame() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        configureReadyProvider(vm)
        vm.composerContentHeight = 180
        let conversationHeight = vm.notchOpenedSize.height
        let oversizedPlacementFrame = CGRect(
            x: 240,
            y: 120,
            width: vm.detachedTotalSize.width,
            height: vm.detachedTotalSize.height + 260
        )
        vm.setPlacement(.detached(oversizedPlacementFrame))

        vm.showSettings = true

        #expect(vm.notchOpenedSize.height == conversationHeight)
        #expect(vm.notchOpenedSize.height != oversizedPlacementFrame.height - vm.detachedTopPadding)
    }

    @Test("detached settings reopen reuses cached measured height when SwiftUI emits no new equal measurement")
    func detachedSettingsReopenReusesCachedMeasuredHeightWhenSwiftUIEmitsNoNewEqualMeasurement() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        configureReadyProvider(vm)
        vm.showSettings = true
        vm.markSettingsMeasured(height: 260)
        let settingsHeight = vm.notchOpenedSize.height
        vm.showSettings = false
        vm.composerContentHeight = 80
        let conversationHeight = vm.notchOpenedSize.height
        #expect(settingsHeight > conversationHeight)
        let initialFrame = CGRect(
            x: 240,
            y: 360,
            width: vm.detachedTotalSize.width,
            height: vm.detachedTotalSize.height
        )
        vm.setPlacement(.detached(initialFrame))

        vm.showSettings = true

        #expect(vm.notchOpenedSize.height == settingsHeight)
        #expect(vm.placement == .detached(initialFrame))
        guard case let .detached(currentFrame) = vm.currentPlacement else {
            Issue.record("Expected current detached placement")
            return
        }
        #expect(currentFrame.height == vm.detachedTotalSize.height)
        #expect(currentFrame.maxY == initialFrame.maxY)
    }

    @Test("detached settings reopen uses cached measurement and updates when the new page measures")
    func detachedSettingsReopenUsesCachedMeasurementAndUpdatesWhenTheNewPageMeasures() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        configureReadyProvider(vm)
        vm.showSettings = true
        vm.markSettingsMeasured(height: 120)
        let cachedSettingsSize = vm.detachedTotalSize
        vm.showSettings = false
        vm.composerContentHeight = 180
        let initialFrame = CGRect(
            x: 240,
            y: 360,
            width: vm.detachedTotalSize.width,
            height: vm.detachedTotalSize.height
        )
        vm.setPlacement(.detached(initialFrame))

        vm.showSettings = true

        #expect(vm.detachedTotalSize == cachedSettingsSize)
        #expect(vm.placement == .detached(initialFrame))

        vm.markSettingsMeasured(height: 260)
        #expect(vm.placement == .detached(initialFrame))
        guard case let .detached(measuredFrame) = vm.currentPlacement else {
            Issue.record("Expected current detached placement after settings measurement")
            return
        }
        #expect(measuredFrame.height == vm.detachedTotalSize.height)
        #expect(measuredFrame.maxY == initialFrame.maxY)
    }

    @Test("first drag after each detached height change starts from the already resized frame")
    func firstDragAfterEachDetachedHeightChangeStartsFromAlreadyResizedFrame() {
        let vm = makeViewModel()
        vm.notchOpen(.click)
        vm.showSettings = true
        vm.markSettingsMeasured(height: 120)
        let initialFrame = CGRect(
            x: 240,
            y: 360,
            width: vm.detachedTotalSize.width,
            height: vm.detachedTotalSize.height
        )
        vm.setPlacement(.detached(initialFrame))

        vm.markSettingsMeasured(height: 260)
        assertFirstDragMovesFromCurrentFrame(viewModel: vm, dx: 40, dy: -20)

        vm.markSettingsMeasured(height: 180)
        assertFirstDragMovesFromCurrentFrame(viewModel: vm, dx: -30, dy: 18)
    }

    @Test("detached panel uses tighter corners and reserves top padding")
    func detachedPanelUsesTighterCornersAndReservesTopPadding() {
        let vm = makeViewModel()

        #expect(vm.detachedCornerRadius == 18)
        #expect(vm.detachedTopPadding == 10)
        #expect(vm.detachedTotalSize.width == vm.notchOpenedTotalSize.width)
        #expect(vm.detachedTotalSize.height == vm.notchOpenedTotalSize.height + 10)
    }

    @Test("starting detach drag activates a shape-only detach transition")
    func startingDetachDragActivatesShapeOnlyDetachTransition() async throws {
        let vm = makeViewModel()
        vm.notchOpen(.click)

        vm.startDetachDrag(pointer: CGPoint(x: 840, y: 884))

        #expect(vm.detachMorphPhase == .source)
        #expect(vm.isDetachTransitionActive)
        try await waitForDetachMorphPhase(.target, viewModel: vm)
        try await waitForTransitionEnd { vm.isDetachTransitionActive }
    }

    @Test("edge dock reveal and collapse do not resize or dim the panel")
    func edgeDockRevealAndCollapseDoNotResizeOrDimPanel() {
        let vm = makeViewModel()
        vm.setPlacement(.edgeDock(
            edge: .left,
            hiddenFrame: CGRect(x: -500, y: 300, width: 500, height: 300),
            revealFrame: CGRect(x: 0, y: 300, width: 500, height: 300),
            triggerFrame: CGRect(x: 0, y: 0, width: 8, height: 900),
            revealed: false
        ))

        vm.revealEdgeDock()
        #expect(vm.isEdgeRevealTransitionActive == false)

        vm.collapseEdgeDock()
        #expect(vm.isEdgeRevealTransitionActive == false)
    }

    private func assertFirstDragMovesFromCurrentFrame(
        viewModel vm: NotchViewModel,
        dx: CGFloat,
        dy: CGFloat
    ) {
        guard case let .detached(frameBeforeDrag) = vm.currentPlacement else {
            Issue.record("Expected detached placement before first drag")
            return
        }
        let pointer = CGPoint(
            x: frameBeforeDrag.minX + 120,
            y: frameBeforeDrag.maxY - 12
        )

        vm.startDetachDrag(pointer: pointer)
        #expect(vm.currentPlacement == .detached(frameBeforeDrag))

        vm.updateDetachDrag(pointer: CGPoint(x: pointer.x + dx, y: pointer.y + dy))
        guard case let .detached(movedFrame) = vm.placement else {
            Issue.record("Expected detached placement while dragging")
            return
        }
        #expect(movedFrame.minX == frameBeforeDrag.minX + dx)
        #expect(movedFrame.maxY == frameBeforeDrag.maxY + dy)
        vm.finishDetachDrag(pointer: CGPoint(x: pointer.x + dx, y: pointer.y + dy))
    }
}
