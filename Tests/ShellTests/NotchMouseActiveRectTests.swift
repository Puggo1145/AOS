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
}
