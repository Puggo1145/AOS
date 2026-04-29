import Testing
import Foundation
import CoreGraphics
import AppKit
import AOSOSSenseKit
import AOSRPCSchema
@testable import AOSShell

// MARK: - NotchTrayDismissalTests
//
// Covers the tray-item composition + dismissal state machine on
// `NotchViewModel`:
//   - `dismissTrayItem(id:)` records the id in `dismissedItemIds` and the
//     row drops out of `trayItems` on the next read.
//   - dismissing the last visible row resets `trayExpanded` so the next
//     row that arrives starts the drawer collapsed.
//   - non-dismissable rows (e.g. live agent state) ignore the dismiss
//     path even when the id is forced in.
//   - `registerTraySource(_:)` lets external callers contribute rows
//     without touching internal types.
//
// Built on top of real services initialized over closed pipes (no actual
// RPC traffic) — same pattern AgentServiceTests uses.

@MainActor
@Suite("Notch tray dismissal")
struct NotchTrayDismissalTests {

    private func makeViewModel() -> NotchViewModel {
        // Real RPCClient over a closed pipe pair — services keep references
        // for handler registration but never make a live request in these
        // tests; we mutate state directly via the public surface.
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

    @Test("freshly-initialised viewmodel surfaces the missing-provider row")
    func defaultStateHasMissingProviderRow() {
        let vm = makeViewModel()
        // statusLoaded is false until refreshStatus() succeeds, so the
        // tray's initial state is "no provider configured". Permissions
        // default to allGranted (denied is empty) and config is not
        // corrupted, so this is the only row.
        let ids = vm.trayItems.map(\.id)
        #expect(ids == [BuiltinTrayItemID.missingProvider])
    }

    @Test("dismissTrayItem records the id and the row disappears")
    func dismissRecordsId() {
        let vm = makeViewModel()
        vm.dismissTrayItem(id: BuiltinTrayItemID.missingProvider)
        #expect(vm.dismissedItemIds.contains(BuiltinTrayItemID.missingProvider))
        #expect(vm.trayItems.isEmpty)
    }

    @Test("dismissing the last row collapses the drawer")
    func dismissingLastRowCollapsesDrawer() {
        let vm = makeViewModel()
        // User had expanded the drawer to inspect the (single) row.
        vm.trayExpanded = true
        vm.dismissTrayItem(id: BuiltinTrayItemID.missingProvider)
        // Without the reset, the next inbound row would render
        // already-expanded — surprising the user with a side-panel-style
        // reveal instead of the intended drawer animation.
        #expect(vm.trayExpanded == false)
        #expect(vm.trayItems.isEmpty)
    }

    @Test("notchTraySize collapses to zero after dismissing the only row")
    func traySizeCollapsesAfterDismissal() {
        let vm = makeViewModel()
        // Pretend the layout pass has measured a non-trivial drawer height —
        // we want to prove the size reads from `trayItems.count`, not from
        // a stale measurement.
        vm.trayContentHeight = 120
        #expect(vm.notchTraySize.height > 0)

        vm.dismissTrayItem(id: BuiltinTrayItemID.missingProvider)
        #expect(vm.notchTraySize.height == 0)
    }

    // MARK: - s03 todoProgress live-state row

    @Test("in_progress todo appears as a non-dismissable tray row with done/total badge")
    func todoProgressRowAppears() {
        let vm = makeViewModel()
        // Drop the missing-provider notice so the todo row is the only
        // remaining tray member — keeps the assertion focused on shape.
        vm.dismissTrayItem(id: BuiltinTrayItemID.missingProvider)
        vm.agentService.handleTodo(UITodoParams(sessionId: "S", items: [
            TodoItemWire(id: "1", text: "draft section", status: .completed),
            TodoItemWire(id: "2", text: "write code",     status: .inProgress),
            TodoItemWire(id: "3", text: "add tests",      status: .pending),
        ]))
        let items = vm.trayItems
        #expect(items.count == 1)
        let row = items[0]
        #expect(row.id == BuiltinTrayItemID.todoProgress)
        #expect(row.message == "write code")
        #expect(row.trailing == .badge("1/3"))
        #expect(row.dismissable == false)
        #expect(row.onTap == nil)
    }

    @Test("plan with no in_progress item produces no todo row")
    func todoProgressHiddenWithoutInProgress() {
        let vm = makeViewModel()
        vm.dismissTrayItem(id: BuiltinTrayItemID.missingProvider)
        // All pending — no current step to surface.
        vm.agentService.handleTodo(UITodoParams(sessionId: "S", items: [
            TodoItemWire(id: "1", text: "a", status: .pending),
            TodoItemWire(id: "2", text: "b", status: .pending),
        ]))
        #expect(vm.trayItems.isEmpty)
        // All completed — same: no active step.
        vm.agentService.handleTodo(UITodoParams(sessionId: "S", items: [
            TodoItemWire(id: "1", text: "a", status: .completed),
            TodoItemWire(id: "2", text: "b", status: .completed),
        ]))
        #expect(vm.trayItems.isEmpty)
    }

    @Test("dismissTrayItem is a no-op for non-dismissable rows")
    func dismissNonDismissableIsNoop() {
        let vm = makeViewModel()
        vm.dismissTrayItem(id: BuiltinTrayItemID.missingProvider)
        vm.agentService.handleTodo(UITodoParams(sessionId: "S", items: [
            TodoItemWire(id: "1", text: "x", status: .inProgress),
        ]))
        #expect(vm.trayItems.count == 1)
        // Calling dismiss for the live row must NOT enter the dismissed
        // set — we don't want a future render path that compares against
        // the set to silently drop the row.
        vm.dismissTrayItem(id: BuiltinTrayItemID.todoProgress)
        #expect(vm.dismissedItemIds.contains(BuiltinTrayItemID.todoProgress) == false)
        #expect(vm.trayItems.count == 1)
    }

    // MARK: - Custom source registration

    @Test("registerTraySource appends rows in registration order")
    func customSourceAppearsAfterBuiltins() {
        let vm = makeViewModel()
        // Default state has the missing-provider row from the system
        // notices source. A custom source registered now must appear AFTER
        // the built-in todoProgress slot — registration order is display
        // order.
        vm.registerTraySource {
            [TrayItem(
                id: "skill.demo",
                icon: "sparkles",
                tint: .blue,
                message: "demo plugin row",
                trailing: .badge("hi"),
                dismissable: true
            )]
        }
        let ids = vm.trayItems.map(\.id)
        #expect(ids == [BuiltinTrayItemID.missingProvider, "skill.demo"])
    }

    @Test("custom source row is dismissable through the same path as built-ins")
    func customSourceRowDismissable() {
        let vm = makeViewModel()
        vm.dismissTrayItem(id: BuiltinTrayItemID.missingProvider)
        vm.registerTraySource {
            [TrayItem(
                id: "skill.demo",
                icon: "sparkles",
                tint: .blue,
                message: "demo",
                dismissable: true
            )]
        }
        #expect(vm.trayItems.map(\.id) == ["skill.demo"])
        vm.dismissTrayItem(id: "skill.demo")
        #expect(vm.trayItems.isEmpty)
    }
}
