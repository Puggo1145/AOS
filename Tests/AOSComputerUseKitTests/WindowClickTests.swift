@testable import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation
import Testing

@Suite("ComputerUseCore background mouse events")
struct WindowClickTests {
    @Test("posts a background mouse event through the selected delivery route")
    func postsBackgroundMouseEventThroughSelectedDeliveryRoute() async throws {
        let recorder = BackgroundMouseEventRecorder()
        let routeRecorder = DeliveryRouteRecorder(route: .webContent)
        let target = Self.window(
            id: 456,
            pid: 123,
            owner: "Electron",
            zIndex: 1,
            bounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
        )
        let event = BackgroundMouseEvent.click(
            button: .left,
            point: CGPoint(x: 160, y: 70)
        )
        let core = ComputerUseCore(
            windowLookup: { windowId in
                windowId == target.id ? target : nil
            },
            mouseEventDeliveryRoute: { pid in
                routeRecorder.resolve(pid: pid)
            },
            focusWindowWithoutRaising: { _, _ in },
            deactivateWindowWithoutRaising: { _, _ in },
            postMouseEvent: { event, target, deliveryRoute, _ in
                await recorder.record(
                    event: event,
                    target: target,
                    deliveryRoute: deliveryRoute
                )
            }
        )

        let result = try await core.postMouseEvent(pid: 123, windowId: 456, event: event)

        #expect(result == WindowMouseEventResult(pid: 123, windowId: 456, event: event))
        #expect(routeRecorder.resolvedPIDs == [123])
        #expect(await recorder.events == [
            .post(
                event: event,
                target: BackgroundMouseEventTarget(
                    pid: 123,
                    windowId: 456,
                    windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
                ),
                deliveryRoute: .webContent
            ),
        ])
    }

    @Test("validates every screen point of a background mouse event before posting")
    func validatesEveryScreenPointOfBackgroundMouseEventBeforePosting() async {
        let recorder = BackgroundMouseEventRecorder()
        let core = ComputerUseCore(
            windowLookup: { windowId in
                guard windowId == 456 else { return nil }
                return WindowInfo(
                    id: 456,
                    pid: 123,
                    owner: "Target",
                    title: "Target",
                    bounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
                    zIndex: 1,
                    isOnScreen: true,
                    layer: 0
                )
            },
            focusWindowWithoutRaising: { _, _ in },
            deactivateWindowWithoutRaising: { _, _ in },
            postMouseEvent: { event, target, deliveryRoute, _ in
                await recorder.record(
                    event: event,
                    target: target,
                    deliveryRoute: deliveryRoute
                )
            }
        )

        await #expect(throws: ComputerUseError.self) {
            try await core.postMouseEvent(
                pid: 123,
                windowId: 456,
                event: .drag(
                    button: .left,
                    from: CGPoint(x: 160, y: 70),
                    to: CGPoint(x: 500, y: 70)
                )
            )
        }
        #expect(await recorder.events.isEmpty)
    }

    @Test("webContent delivery route supports every background mouse event kind")
    func webContentDeliveryRouteSupportsEveryBackgroundMouseEventKind() {
        #expect(BackgroundMouseEventDeliveryRoute.webContent.supports(
            .click(button: .left, point: CGPoint(x: 150, y: 50))
        ))
        #expect(BackgroundMouseEventDeliveryRoute.webContent.supports(
            .click(button: .right, point: CGPoint(x: 150, y: 50))
        ))
        #expect(BackgroundMouseEventDeliveryRoute.webContent.supports(
            .drag(button: .right, from: CGPoint(x: 150, y: 50), to: CGPoint(x: 170, y: 70))
        ))
    }

    @Test("appKit delivery route supports only left and right click")
    func appKitDeliveryRouteSupportsOnlyLeftAndRightClick() {
        #expect(BackgroundMouseEventDeliveryRoute.appKit.supports(
            .click(button: .left, point: CGPoint(x: 150, y: 50))
        ))
        #expect(BackgroundMouseEventDeliveryRoute.appKit.supports(
            .click(button: .right, point: CGPoint(x: 150, y: 50))
        ))
        #expect(!BackgroundMouseEventDeliveryRoute.appKit.supports(
            .drag(button: .left, from: CGPoint(x: 150, y: 50), to: CGPoint(x: 170, y: 70))
        ))
    }

    @Test("focuses the target then posts a left click at an explicit screen point")
    func focusesThenClicksExplicitScreenPoint() async throws {
        let recorder = ClickChainRecorder()
        let core = ComputerUseCore(
            windowLookup: { windowId in
                guard windowId == 456 else { return nil }
                return WindowInfo(
                    id: 456,
                    pid: 123,
                    owner: "Terminal",
                    title: "Shell",
                    bounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
                    zIndex: 1,
                    isOnScreen: true,
                    layer: 0
                )
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        let result = try await core.postTestClick(pid: 123, windowId: 456, point: CGPoint(x: 160, y: 70))

        #expect(result.pid == 123)
        #expect(result.windowId == 456)
        #expect(result.clickPoint == CGPoint(x: 160, y: 70))
        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .click(
                pid: 123,
                windowId: 456,
                point: CGPoint(x: 160, y: 70),
                windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
            ),
        ])
    }

    @Test("posts a left click at an explicit screen point through the same chain")
    func clicksExplicitScreenPoint() async throws {
        let recorder = ClickChainRecorder()
        let core = ComputerUseCore(
            windowLookup: { windowId in
                guard windowId == 456 else { return nil }
                return WindowInfo(
                    id: 456,
                    pid: 123,
                    owner: "Target",
                    title: "Target",
                    bounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
                    zIndex: 1,
                    isOnScreen: true,
                    layer: 0
                )
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        let result = try await core.postTestClick(
            pid: 123,
            windowId: 456,
            point: CGPoint(x: 32, y: 54)
        )

        #expect(result.clickPoint == CGPoint(x: 32, y: 54))
        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .click(
                pid: 123,
                windowId: 456,
                point: CGPoint(x: 32, y: 54),
                windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
            ),
        ])
    }

    @Test("supports injected routes that skip pre-click target focus")
    func supportsInjectedRoutesThatSkipPreClickTargetFocus() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Chrome", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            frontmostWindowLookup: {
                protected
            },
            requiresPreEventFocus: { _, _ in
                false
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            activateApplication: { pid in
                await recorder.recordActivate(pid: pid)
                return true
            },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .deactivate(pid: 30, windowId: 300),
            .activate(pid: 10),
        ])
    }

    @Test("resolves the click delivery route once per click and reuses it for posting")
    func resolvesClickDeliveryRouteOncePerClickAndReusesItForPosting() async throws {
        let recorder = ClickChainRecorder()
        let routeRecorder = DeliveryRouteRecorder(route: .webContent)
        let core = ComputerUseCore(
            windowLookup: { windowId in
                guard windowId == 456 else { return nil }
                return WindowInfo(
                    id: 456,
                    pid: 123,
                    owner: "Electron",
                    title: "Electron",
                    bounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
                    zIndex: 1,
                    isOnScreen: true,
                    layer: 0
                )
            },
            mouseEventDeliveryRoute: { pid in
                routeRecorder.resolve(pid: pid)
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            postMouseEvent: { event, target, deliveryRoute, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                #expect(deliveryRoute == .webContent)
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 123, windowId: 456, point: CGPoint(x: 160, y: 70))

        #expect(routeRecorder.resolvedPIDs == [123])
        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .click(
                pid: 123,
                windowId: 456,
                point: CGPoint(x: 160, y: 70),
                windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
            ),
        ])
    }

    @Test("rejects an explicit click point outside the target window")
    func rejectsExplicitPointOutsideWindow() async {
        let recorder = ClickChainRecorder()
        let core = ComputerUseCore(
            windowLookup: { _ in
                WindowInfo(
                    id: 456,
                    pid: 123,
                    owner: "Target",
                    title: "Target",
                    bounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
                    zIndex: 1,
                    isOnScreen: true,
                    layer: 0
                )
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        await #expect(throws: ComputerUseError.self) {
            try await core.postTestClick(
                pid: 123,
                windowId: 456,
                point: CGPoint(x: 500, y: 54)
            )
        }
        #expect(await recorder.events.isEmpty)
    }

    @Test("restores the original front window focus after posting the click")
    func restoresOriginalFrontWindowFocusAfterClick() async throws {
        let recorder = ClickChainRecorder()
        let core = ComputerUseCore(
            windowLookup: { windowId in
                switch windowId {
                case 456:
                    return WindowInfo(
                        id: 456,
                        pid: 123,
                        owner: "Calculator",
                        title: "Calculator",
                        bounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
                        zIndex: 2,
                        isOnScreen: true,
                        layer: 0
                    )
                case 789:
                    return WindowInfo(
                        id: 789,
                        pid: 777,
                        owner: "Ghostty",
                        title: "Shell",
                        bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
                        zIndex: 1,
                        isOnScreen: true,
                        layer: 0
                    )
                default:
                    return nil
                }
            },
            frontmostWindowLookup: {
                WindowInfo(
                    id: 789,
                    pid: 777,
                    owner: "Ghostty",
                    title: "Shell",
                    bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
                    zIndex: 1,
                    isOnScreen: true,
                    layer: 0
                )
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 123, windowId: 456, point: CGPoint(x: 160, y: 70))

        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .click(
                pid: 123,
                windowId: 456,
                point: CGPoint(x: 160, y: 70),
                windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
            ),
            .focus(pid: 777, windowId: 789),
        ])
    }

    @Test("deactivates the target window after completing the background click chain")
    func deactivatesTargetWindowAfterCompletingBackgroundClickChain() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 456, pid: 123, owner: "Calculator", zIndex: 2)
        let front = Self.window(id: 789, pid: 777, owner: "Ghostty", zIndex: 3)
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, front].first { $0.id == windowId }
            },
            frontmostWindowLookup: {
                front
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 123, windowId: 456, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .click(
                pid: 123,
                windowId: 456,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 777, windowId: 789),
            .deactivate(pid: 123, windowId: 456),
        ])
    }

    @Test("does not deactivate the target window when it was already the original front window")
    func doesNotDeactivateOriginalFrontTargetWindow() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 456, pid: 123, owner: "Calculator", zIndex: 3)
        let core = ComputerUseCore(
            windowLookup: { windowId in
                windowId == target.id ? target : nil
            },
            frontmostWindowLookup: {
                target
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 123, windowId: 456, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .click(
                pid: 123,
                windowId: 456,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
        ])
    }

    @Test("reactivates the original front application after target deactivation")
    func reactivatesOriginalFrontApplicationAfterTargetDeactivation() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 456, pid: 123, owner: "Chrome", zIndex: 2)
        let front = Self.window(id: 789, pid: 777, owner: "Ghostty", zIndex: 3)
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, front].first { $0.id == windowId }
            },
            frontmostWindowLookup: {
                front
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            activateApplication: { pid in
                await recorder.recordActivate(pid: pid)
                return true
            },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 123, windowId: 456, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .click(
                pid: 123,
                windowId: 456,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 777, windowId: 789),
            .deactivate(pid: 123, windowId: 456),
            .activate(pid: 777),
        ])
    }

    @Test("reactivates the original front application when delayed guard observes order drift")
    func reactivatesOriginalFrontApplicationWhenDelayedGuardObservesOrderDrift() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Chrome", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [protected, target],
            [target, protected],
            [protected, target],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            activateApplication: { pid in
                await recorder.recordActivate(pid: pid)
                return true
            },
            activeStateGuardDelays: [0],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .deactivate(pid: 30, windowId: 300),
            .activate(pid: 10),
            .focus(pid: 10, windowId: 100),
            .activate(pid: 10),
        ])
    }

    @Test("reactivates the original front application when delayed guard sees target still active")
    func reactivatesOriginalFrontApplicationWhenDelayedGuardSeesTargetStillActive() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Chrome", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [protected, target],
            [protected, target],
        ])
        let activeStates = ActiveStateScript([true])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            activateApplication: { pid in
                await recorder.recordActivate(pid: pid)
                return true
            },
            isApplicationActive: { _ in
                activeStates.next()
            },
            activeStateGuardDelays: [0],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .deactivate(pid: 30, windowId: 300),
            .activate(pid: 10),
            .activate(pid: 10),
        ])
    }

    @Test("restores original front focus when target deactivation triggers a late raise")
    func restoresOriginalFrontFocusWhenTargetDeactivationTriggersLateRaise() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Chrome", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [protected, target],
            [target, protected],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            activeStateGuardDelays: [0],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .deactivate(pid: 30, windowId: 300),
            .focus(pid: 10, windowId: 100),
        ])
    }

    @Test("runs post-dispatch cleanup before delayed active-state guard")
    func runsPostDispatchCleanupBeforeDelayedActiveStateGuard() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Chrome", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [protected, target],
            [protected, target],
            [target, protected],
            [protected, target],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            activateApplication: { pid in
                await recorder.recordActivate(pid: pid)
                return true
            },
            activeStateGuardDelays: [0, 1],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, stageObserver in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
                try await stageObserver?(.afterTargetUp)
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .deactivate(pid: 30, windowId: 300),
            .activate(pid: 10),
            .focus(pid: 10, windowId: 100),
            .activate(pid: 10),
        ])
    }

    @Test("uses the active-state guard cadence after post-dispatch cleanup")
    func usesActiveStateGuardCadenceAfterPostDispatchCleanup() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Chrome", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [protected, target],
            [protected, target],
            [protected, target],
            [target, protected],
            [protected, target],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            activateApplication: { pid in
                await recorder.recordActivate(pid: pid)
                return true
            },
            activeStateGuardDelays: [0, 1, 1],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, stageObserver in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
                try await stageObserver?(.afterTargetUp)
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .deactivate(pid: 30, windowId: 300),
            .activate(pid: 10),
            .focus(pid: 10, windowId: 100),
            .activate(pid: 10),
        ])
    }

    @Test("guards active state from a window-order notification before post-dispatch cleanup")
    func guardsActiveStateFromWindowOrderNotificationBeforePostDispatchCleanup() async throws {
        let recorder = ClickChainRecorder()
        let orderObserver = ManualWindowOrderChangeObserver()
        let target = Self.window(id: 300, pid: 30, owner: "Chrome", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [protected, target],
            [target, protected],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            activateApplication: { pid in
                await recorder.recordActivate(pid: pid)
                return true
            },
            windowOrderChangeObserver: orderObserver.observer,
            activeStateGuardDelays: [],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
                try await orderObserver.emit(windowId: windowId)
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(orderObserver.observedWindowIds == [300])
        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .activate(pid: 10),
            .focus(pid: 10, windowId: 100),
            .deactivate(pid: 30, windowId: 300),
            .activate(pid: 10),
        ])
    }

    @Test("trace records active-state guard ticks and post-guard settle samples")
    func traceRecordsActiveStateGuardTicksAndPostGuardSettleSamples() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Chrome", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [protected, target],
            [protected, target],
            [protected, target],
            [protected, target],
            [protected, target],
            [protected, target],
            [protected, target],
            [target, protected],
            [protected, target],
            [target, protected],
            [target, protected],
            [protected, target],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                await recorder.recordDeactivate(pid: pid, windowId: windowId)
            },
            activeStateGuardDelays: [0, 1],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        let trace = try await core.postTestClickTrace(
            pid: 30,
            windowId: 300,
            point: CGPoint(x: 150, y: 50)
        )
        let guardTicks = trace.snapshots.filter { $0.stage == .activeStateGuardTick }

        #expect(guardTicks.map(\.guardAttempt) == [0, 1])
        #expect(guardTicks.map(\.elapsedNanoseconds) == [0, 1])
        #expect(guardTicks.map(\.corrected) == [false, true])
        #expect(trace.snapshots.contains(where: { $0.stage == .afterTraceSettle50ms }))
        #expect(trace.snapshots.contains(where: { $0.stage == .afterTraceSettle200ms }))
        #expect(trace.snapshots.contains(where: { $0.stage == .afterTraceSettle1s }))
    }

    @Test("restores original front focus when the target crosses protected windows after a click")
    func restoresOriginalFrontFocusWhenTargetCrossesProtectedWindowsAfterClick() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Safari", zIndex: 1)
        let protectedFront = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 3)
        let protectedBack = Self.window(id: 200, pid: 20, owner: "WeChat", zIndex: 2)
        let belowTarget = Self.window(id: 400, pid: 40, owner: "Finder", zIndex: 0)
        let snapshots = WindowSnapshotScript([
            [protectedFront, protectedBack, target, belowTarget],
            [protectedFront, protectedBack, target, belowTarget],
            [target, protectedFront, protectedBack, belowTarget],
            [protectedFront, protectedBack, target, belowTarget],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protectedFront, protectedBack, belowTarget]
                    .first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protectedFront
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            activeStateGuardDelays: [0, 1],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .focus(pid: 10, windowId: 100),
        ])
    }

    @Test("restores original front focus immediately after a mouse post stage")
    func restoresOriginalFrontFocusImmediatelyAfterMousePostStage() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Safari", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [protected, target],
            [target, protected],
            [protected, target],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            activeStateGuardDelays: [0],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, stageObserver in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
                try await stageObserver?(.afterTargetDown)
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .focus(pid: 10, windowId: 100),
        ])
    }

    @Test("does not react to windows that were already below the target before clicking")
    func doesNotReactToWindowsOriginallyBelowTarget() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Safari", zIndex: 2)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 3)
        let belowTarget = Self.window(id: 400, pid: 40, owner: "Finder", zIndex: 1)
        let snapshots = WindowSnapshotScript([
            [protected, target, belowTarget],
            [protected, target, belowTarget],
            [target, protected, belowTarget],
            [protected, target, belowTarget],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protected, belowTarget].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            activeStateGuardDelays: [0, 1],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .focus(pid: 10, windowId: 100),
        ])
    }

    @Test("ignores non-overlapping windows during user-window protection")
    func ignoresNonOverlappingWindowsDuringUserWindowProtection() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Safari", zIndex: 1)
        let overlappingFront = Self.window(id: 100, pid: 10, owner: "WeChat", zIndex: 3)
        let nonOverlappingFront = Self.window(
            id: 200,
            pid: 20,
            owner: "Ghostty",
            zIndex: 2,
            bounds: WindowBounds(x: 500, y: 0, width: 300, height: 100)
        )
        let snapshots = WindowSnapshotScript([
            [overlappingFront, nonOverlappingFront, target],
            [overlappingFront, target, nonOverlappingFront],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, overlappingFront, nonOverlappingFront].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                nonOverlappingFront
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            activeStateGuardDelays: [0],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 20, windowId: 200),
        ])
    }

    @Test("does not fail the delayed guard when no protected windows exist and target disappears")
    func ignoresMissingTargetDuringDelayedGuardWhenNoProtectedWindowsExist() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Safari", zIndex: 1)
        let originalFront = Self.window(
            id: 100,
            pid: 10,
            owner: "Ghostty",
            zIndex: 2,
            bounds: WindowBounds(x: 500, y: 0, width: 300, height: 100)
        )
        let snapshots = WindowSnapshotScript([
            [originalFront, target],
            [originalFront],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, originalFront].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                originalFront
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            activeStateGuardDelays: [0],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
        ])
    }

    @Test("does not reorder a non-active cover when preserving the active window")
    func doesNotReorderNonActiveCoverWhenPreservingActiveWindow() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Chrome", zIndex: 1)
        let activeFront = Self.window(
            id: 100,
            pid: 10,
            owner: "Ghostty",
            zIndex: 3,
            bounds: WindowBounds(x: 500, y: 0, width: 300, height: 100)
        )
        let nonActiveCover = Self.window(id: 200, pid: 20, owner: "Finder", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [activeFront, nonActiveCover, target],
            [target, activeFront, nonActiveCover],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, activeFront, nonActiveCover].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                activeFront
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            activeStateGuardDelays: [0],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .focus(pid: 10, windowId: 100),
        ])
    }

    @Test("continues guarding active state when delayed target raise reappears")
    func continuesGuardingActiveStateWhenDelayedTargetRaiseReappears() async throws {
        let recorder = ClickChainRecorder()
        let target = Self.window(id: 300, pid: 30, owner: "Safari", zIndex: 1)
        let protectedFront = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 3)
        let protectedBack = Self.window(id: 200, pid: 20, owner: "WeChat", zIndex: 2)
        let snapshots = WindowSnapshotScript([
            [protectedFront, protectedBack, target],
            [target, protectedFront, protectedBack],
            [target, protectedFront, protectedBack],
            [protectedFront, protectedBack, target],
        ])
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, protectedFront, protectedBack].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                snapshots.next()
            },
            frontmostWindowLookup: {
                protectedFront
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            activeStateGuardDelays: [0, 1, 1],
            sleepForActiveStateGuard: { _ in },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postTestClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .focus(pid: 10, windowId: 100),
            .focus(pid: 10, windowId: 100),
        ])
    }

    @Test("does not post a click for a window owned by another pid")
    func rejectsMismatchedWindowOwnerBeforeClicking() async {
        let recorder = ClickChainRecorder()
        let core = ComputerUseCore(
            windowLookup: { _ in
                WindowInfo(
                    id: 456,
                    pid: 999,
                    owner: "Other",
                    title: "Shell",
                    bounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
                    zIndex: 1,
                    isOnScreen: true,
                    layer: 0
                )
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.recordFocus(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { _, _ in
            },
            postMouseEvent: { event, target, _, _ in
                guard case .click(_, let point) = event else {
                    throw ComputerUseError.mouseEventUnavailable("expected click event")
                }
                let pid = target.pid
                let windowId = target.windowId
                let windowBounds = target.windowBounds
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        await #expect(throws: ComputerUseError.self) {
            try await core.postTestClick(pid: 123, windowId: 456, point: CGPoint(x: 160, y: 70))
        }
        #expect(await recorder.events.isEmpty)
    }

    @Test("mouse poster uses public pid target move/down/up with rich window stamps")
    func mousePosterUsesPublicPidMoveDownUpWithRichWindowStamps() async throws {
        let recorder = MousePostRecorder()
        let poster = MouseEventPoster(
            postPublicEventToPID: { event, pid in
                recorder.recordPublicPost(event: event, pid: pid)
            },
            postSkyLightEventToPID: { event, pid in
                recorder.recordSkyLightPost(event: event, pid: pid)
            },
            setWindowLocation: { _, point in
                recorder.recordWindowLocation(point)
            },
            setIntegerField: { _, field, value in
                recorder.recordIntegerField(field: field, value: value)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        try await poster.postTestClick(
            pid: 123,
            windowId: 456,
            point: CGPoint(x: 160, y: 70),
            windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
            deliveryRoute: .appKit,
            stageObserver: { stage in
                recorder.recordStage(stage)
            }
        )

        #expect(recorder.skyLightPosts.isEmpty)
        #expect(recorder.publicPosts.map(\.pid) == [123, 123, 123])
        #expect(recorder.publicPosts.map(\.type) == [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
        ])
        #expect(recorder.publicPosts.map(\.location) == [
            CGPoint(x: 160, y: 70),
            CGPoint(x: 160, y: 70),
            CGPoint(x: 160, y: 70),
        ])
        #expect(recorder.windowLocations == [
            CGPoint(x: 150, y: 50),
            CGPoint(x: 150, y: 50),
            CGPoint(x: 150, y: 50),
        ])
        #expect(recorder.sleeps == [15_000, 1_000])
        #expect(recorder.integerFields.map(\.field) == [
            0, 40, 51, 91, 92,
            0, 40, 51, 91, 92,
            0, 40, 51, 91, 92,
        ])
        #expect(recorder.integerFields.filter { $0.field == 0 }.map(\.value) == [
            2, 3, 3,
        ])
        #expect(recorder.integerFields.filter { $0.field == 40 }.map(\.value) == [
            123, 123, 123,
        ])
        #expect(recorder.integerFields.filter { $0.field == 51 }.map(\.value) == [
            456, 456, 456,
        ])
        #expect(recorder.integerFields.filter { $0.field == 91 }.map(\.value) == [
            456, 456, 456,
        ])
        #expect(recorder.integerFields.filter { $0.field == 92 }.map(\.value) == [
            456, 456, 456,
        ])
        #expect(recorder.stages == [
            .afterMouseMoved,
            .afterTargetDown,
            .afterTargetUp,
        ])
    }

    @Test("mouse poster uses public pid target right-button move/down/up events")
    func mousePosterUsesPublicPidRightButtonMoveDownUpEvents() async throws {
        let recorder = MousePostRecorder()
        let poster = MouseEventPoster(
            postPublicEventToPID: { event, pid in
                recorder.recordPublicPost(event: event, pid: pid)
            },
            postSkyLightEventToPID: { event, pid in
                recorder.recordSkyLightPost(event: event, pid: pid)
            },
            setWindowLocation: { _, point in
                recorder.recordWindowLocation(point)
            },
            setIntegerField: { _, field, value in
                recorder.recordIntegerField(field: field, value: value)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        try await poster.post(
            .click(button: .right, point: CGPoint(x: 160, y: 70)),
            to: BackgroundMouseEventTarget(
                pid: 123,
                windowId: 456,
                windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
            ),
            deliveryRoute: .appKit,
            stageObserver: { stage in
                recorder.recordStage(stage)
            }
        )

        #expect(recorder.skyLightPosts.isEmpty)
        #expect(recorder.publicPosts.map(\.type) == [
            .mouseMoved,
            .rightMouseDown,
            .rightMouseUp,
        ])
        #expect(recorder.publicPosts.map(\.buttonNumber) == [1, 1, 1])
        #expect(recorder.windowLocations == [
            CGPoint(x: 150, y: 50),
            CGPoint(x: 150, y: 50),
            CGPoint(x: 150, y: 50),
        ])
        #expect(recorder.stages == [
            .afterMouseMoved,
            .afterTargetDown,
            .afterTargetUp,
        ])
    }

    @Test("mouse poster rejects AppKit drag without posting events")
    func mousePosterRejectsAppKitDragWithoutPostingEvents() async throws {
        let recorder = MousePostRecorder()
        let poster = MouseEventPoster(
            postPublicEventToPID: { event, pid in
                recorder.recordPublicPost(event: event, pid: pid)
            },
            postSkyLightEventToPID: { event, pid in
                recorder.recordSkyLightPost(event: event, pid: pid)
            },
            setWindowLocation: { _, point in
                recorder.recordWindowLocation(point)
            },
            setIntegerField: { _, field, value in
                recorder.recordIntegerField(field: field, value: value)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        await #expect(throws: ComputerUseError.self) {
            try await poster.post(
                .drag(
                    button: .left,
                    from: CGPoint(x: 160, y: 70),
                    to: CGPoint(x: 220, y: 90)
                ),
                to: BackgroundMouseEventTarget(
                    pid: 123,
                    windowId: 456,
                    windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
                ),
                deliveryRoute: .appKit,
                stageObserver: { stage in
                    recorder.recordStage(stage)
                }
            )
        }
        #expect(recorder.publicPosts.isEmpty)
        #expect(recorder.skyLightPosts.isEmpty)
        #expect(recorder.windowLocations.isEmpty)
        #expect(recorder.integerFields.isEmpty)
        #expect(recorder.sleeps.isEmpty)
        #expect(recorder.stages.isEmpty)
    }

    @Test("classifies browser web content targets for the webContent delivery route")
    func classifiesBrowserWebContentTargetsForWebContentDeliveryRoute() {
        let classifier = BackgroundMouseEventDeliveryClassifier(
            fileExists: { path in
                path == "/Applications/CustomElectron.app/Contents/Frameworks/Electron Framework.framework"
                    || path == "/Applications/CustomCEF.app/Contents/Frameworks/Chromium Embedded Framework.framework"
            },
            containsChromiumRuntimeResources: { _ in false }
        )

        #expect(classifier.classification(
            bundleIdentifier: "com.google.Chrome",
            bundleURL: nil
        ) == BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .chromiumBrowserBundleId))
        #expect(classifier.classification(
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil
        ) == BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .safariBundleId))
        #expect(classifier.classification(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            bundleURL: nil
        ) == BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .knownElectronBundleId))
        #expect(classifier.classification(
            bundleIdentifier: "dev.local.CustomElectron",
            bundleURL: URL(fileURLWithPath: "/Applications/CustomElectron.app")
        ) == BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .electronFramework))
        #expect(classifier.classification(
            bundleIdentifier: "dev.local.CustomCEF",
            bundleURL: URL(fileURLWithPath: "/Applications/CustomCEF.app")
        ) == BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .chromiumEmbeddedFramework))
        #expect(classifier.classification(
            bundleIdentifier: "com.tencent.qq",
            bundleURL: URL(fileURLWithPath: "/Applications/QQ.app")
        ) == BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .knownElectronBundleId))
        #expect(classifier.classification(
            bundleIdentifier: "com.apple.TextEdit",
            bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        ) == BackgroundMouseEventDeliveryClassification(route: .appKit, reason: .appKitDefault))
    }

    @Test("classifies arbitrary Chromium runtime resources without a bundle id whitelist")
    func classifiesArbitraryChromiumRuntimeResourcesWithoutBundleIDWhitelist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aos-chromium-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resources = root
            .appendingPathComponent("CustomChromium.app/Contents/Frameworks/CustomRuntime.framework/Versions/A/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for marker in ["chrome_100_percent.pak", "chrome_200_percent.pak", "icudtl.dat"] {
            try Data().write(to: resources.appendingPathComponent(marker))
        }

        let classifier = BackgroundMouseEventDeliveryClassifier()
        let appURL = root.appendingPathComponent("CustomChromium.app", isDirectory: true)

        #expect(classifier.classification(
            bundleIdentifier: "dev.local.NotWhitelisted",
            bundleURL: appURL
        ) == BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .chromiumRuntimeResources))
    }

    @Test("webContent delivery route matches Codex annotated mouse sequence")
    func webContentDeliveryRouteMatchesCodexAnnotatedMouseSequence() async throws {
        let recorder = MousePostRecorder()
        let poster = MouseEventPoster(
            postPublicEventToPID: { event, pid in
                recorder.recordPublicPost(event: event, pid: pid)
            },
            postSkyLightEventToPID: { event, pid in
                recorder.recordSkyLightPost(event: event, pid: pid)
            },
            setWindowLocation: { _, point in
                recorder.recordWindowLocation(point)
            },
            setIntegerField: { _, field, value in
                recorder.recordIntegerField(field: field, value: value)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        try await poster.postTestClick(
            pid: 123,
            windowId: 456,
            point: CGPoint(x: 160, y: 70),
            windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
            deliveryRoute: .webContent,
            stageObserver: { stage in
                recorder.recordStage(stage)
            }
        )

        #expect(recorder.publicPosts.isEmpty)
        #expect(recorder.skyLightPosts.map(\.pid) == [123, 123, 123, 123, 123])
        #expect(recorder.skyLightPosts.map(\.type) == [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDown,
            .leftMouseUp,
        ])
        #expect(recorder.skyLightPosts.map(\.location) == [
            CGPoint(x: 160, y: 70),
            CGPoint(x: 9, y: 119),
            CGPoint(x: 9, y: 119),
            CGPoint(x: 160, y: 70),
            CGPoint(x: 160, y: 70),
        ])
        #expect(recorder.windowLocations == [
            CGPoint(x: 150, y: 50),
            CGPoint(x: -1, y: 99),
            CGPoint(x: -1, y: 99),
            CGPoint(x: 150, y: 50),
            CGPoint(x: 150, y: 50),
        ])
        #expect(recorder.sleeps == [15_000, 1_000, 100_000, 1_000])
        #expect(recorder.integerFields.filter { $0.field == 0 }.map(\.value) == [
            0, 1, 2, 1, 1,
        ])
        #expect(recorder.integerFields.filter { $0.field == 40 }.map(\.value) == [
            123, 123, 123, 123, 123,
        ])
        #expect(recorder.integerFields.filter { $0.field == 51 }.map(\.value) == [
            456, 456, 456, 456, 456,
        ])
        #expect(recorder.integerFields.filter { $0.field == 91 }.map(\.value) == [
            456, 456, 456, 456, 456,
        ])
        #expect(recorder.integerFields.filter { $0.field == 92 }.map(\.value) == [
            456, 456, 456, 456, 456,
        ])
        let annotatedTimestamps = recorder.skyLightPosts.map(\.rawField58)
        #expect(annotatedTimestamps.count == 5)
        #expect(Set(annotatedTimestamps).count == 1)
        #expect(annotatedTimestamps.allSatisfy { $0 > 0 && $0 < 100_000_000_000 })
        #expect(recorder.stages == [
            .afterMouseMoved,
            .afterPrimerDown,
            .afterPrimerUp,
            .afterPrimerGap,
            .afterTargetDown,
            .afterTargetUp,
        ])
    }

    @Test("webContent delivery route posts right-click through SkyLight primer sequence")
    func webContentDeliveryRoutePostsRightClickThroughSkyLightPrimerSequence() async throws {
        let recorder = MousePostRecorder()
        let poster = MouseEventPoster(
            postPublicEventToPID: { event, pid in
                recorder.recordPublicPost(event: event, pid: pid)
            },
            postSkyLightEventToPID: { event, pid in
                recorder.recordSkyLightPost(event: event, pid: pid)
            },
            setWindowLocation: { _, point in
                recorder.recordWindowLocation(point)
            },
            setIntegerField: { _, field, value in
                recorder.recordIntegerField(field: field, value: value)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        try await poster.post(
            .click(button: .right, point: CGPoint(x: 160, y: 70)),
            to: BackgroundMouseEventTarget(
                pid: 123,
                windowId: 456,
                windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
            ),
            deliveryRoute: .webContent,
            stageObserver: { stage in
                recorder.recordStage(stage)
            }
        )

        #expect(recorder.publicPosts.isEmpty)
        #expect(recorder.skyLightPosts.map(\.type) == [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
        ])
        #expect(recorder.skyLightPosts.map(\.buttonNumber) == [1, 0, 0, 1, 1])
        #expect(recorder.skyLightPosts.map(\.location) == [
            CGPoint(x: 160, y: 70),
            CGPoint(x: 9, y: 119),
            CGPoint(x: 9, y: 119),
            CGPoint(x: 160, y: 70),
            CGPoint(x: 160, y: 70),
        ])
        #expect(recorder.windowLocations == [
            CGPoint(x: 150, y: 50),
            CGPoint(x: -1, y: 99),
            CGPoint(x: -1, y: 99),
            CGPoint(x: 150, y: 50),
            CGPoint(x: 150, y: 50),
        ])
        #expect(recorder.sleeps == [15_000, 1_000, 100_000, 1_000])
        #expect(recorder.stages == [
            .afterMouseMoved,
            .afterPrimerDown,
            .afterPrimerUp,
            .afterPrimerGap,
            .afterTargetDown,
            .afterTargetUp,
        ])
    }

    @Test("webContent delivery route posts drag through SkyLight primer sequence")
    func webContentDeliveryRoutePostsDragThroughSkyLightPrimerSequence() async throws {
        let recorder = MousePostRecorder()
        let poster = MouseEventPoster(
            postPublicEventToPID: { event, pid in
                recorder.recordPublicPost(event: event, pid: pid)
            },
            postSkyLightEventToPID: { event, pid in
                recorder.recordSkyLightPost(event: event, pid: pid)
            },
            setWindowLocation: { _, point in
                recorder.recordWindowLocation(point)
            },
            setIntegerField: { _, field, value in
                recorder.recordIntegerField(field: field, value: value)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        try await poster.post(
            .drag(
                button: .right,
                from: CGPoint(x: 160, y: 70),
                to: CGPoint(x: 220, y: 90)
            ),
            to: BackgroundMouseEventTarget(
                pid: 123,
                windowId: 456,
                windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100)
            ),
            deliveryRoute: .webContent,
            stageObserver: { stage in
                recorder.recordStage(stage)
            }
        )

        #expect(recorder.publicPosts.isEmpty)
        #expect(recorder.skyLightPosts.map(\.type) == [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseDragged,
            .rightMouseUp,
        ])
        #expect(recorder.skyLightPosts.map(\.buttonNumber) == [1, 0, 0, 1, 1, 1])
        #expect(recorder.skyLightPosts.map(\.location) == [
            CGPoint(x: 160, y: 70),
            CGPoint(x: 9, y: 119),
            CGPoint(x: 9, y: 119),
            CGPoint(x: 160, y: 70),
            CGPoint(x: 220, y: 90),
            CGPoint(x: 220, y: 90),
        ])
        #expect(recorder.windowLocations == [
            CGPoint(x: 150, y: 50),
            CGPoint(x: -1, y: 99),
            CGPoint(x: -1, y: 99),
            CGPoint(x: 150, y: 50),
            CGPoint(x: 210, y: 70),
            CGPoint(x: 210, y: 70),
        ])
        #expect(recorder.sleeps == [15_000, 1_000, 100_000, 1_000, 1_000])
        #expect(recorder.integerFields.filter { $0.field == 0 }.map(\.value) == [0, 1, 2, 1, 4, 4])
        #expect(recorder.stages == [
            .afterMouseMoved,
            .afterPrimerDown,
            .afterPrimerUp,
            .afterPrimerGap,
            .afterTargetDown,
            .afterTargetDragged,
            .afterTargetUp,
        ])
    }

    private static func window(
        id: CGWindowID,
        pid: pid_t,
        owner: String,
        zIndex: Int,
        bounds: WindowBounds = WindowBounds(x: 0, y: 0, width: 300, height: 100)
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid,
            owner: owner,
            title: owner,
            bounds: bounds,
            zIndex: zIndex,
            isOnScreen: true,
            layer: 0
        )
    }
}

private actor ClickChainRecorder {
    private var recordedEvents: [ClickChainEvent] = []

    var events: [ClickChainEvent] {
        recordedEvents
    }

    func recordFocus(pid: pid_t, windowId: CGWindowID) {
        recordedEvents.append(.focus(pid: pid, windowId: windowId))
    }

    func recordClick(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint,
        windowBounds: WindowBounds
    ) {
        recordedEvents.append(.click(
            pid: pid,
            windowId: windowId,
            point: point,
            windowBounds: windowBounds
        ))
    }

    func recordDeactivate(pid: pid_t, windowId: CGWindowID) {
        recordedEvents.append(.deactivate(pid: pid, windowId: windowId))
    }

    func recordActivate(pid: pid_t) {
        recordedEvents.append(.activate(pid: pid))
    }
}

private enum ClickChainEvent: Equatable {
    case focus(pid: pid_t, windowId: CGWindowID)
    case deactivate(pid: pid_t, windowId: CGWindowID)
    case activate(pid: pid_t)
    case click(pid: pid_t, windowId: CGWindowID, point: CGPoint, windowBounds: WindowBounds)
}

private actor BackgroundMouseEventRecorder {
    private var recordedEvents: [RecordedBackgroundMouseEvent] = []

    var events: [RecordedBackgroundMouseEvent] {
        recordedEvents
    }

    func record(
        event: BackgroundMouseEvent,
        target: BackgroundMouseEventTarget,
        deliveryRoute: BackgroundMouseEventDeliveryRoute
    ) {
        recordedEvents.append(.post(
            event: event,
            target: target,
            deliveryRoute: deliveryRoute
        ))
    }
}

private enum RecordedBackgroundMouseEvent: Equatable {
    case post(
        event: BackgroundMouseEvent,
        target: BackgroundMouseEventTarget,
        deliveryRoute: BackgroundMouseEventDeliveryRoute
    )
}

private extension ComputerUseCore {
    func postTestClick(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint
    ) async throws -> WindowMouseEventResult {
        try await postMouseEvent(
            pid: pid,
            windowId: windowId,
            event: .click(button: .left, point: point)
        )
    }

    func postTestClickTrace(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint
    ) async throws -> WindowMouseEventTraceResult {
        try await postMouseEventTrace(
            pid: pid,
            windowId: windowId,
            event: .click(button: .left, point: point)
        )
    }
}

private extension WindowMouseEventResult {
    var clickPoint: CGPoint? {
        guard case .click(_, let point) = event else {
            return nil
        }
        return point
    }
}

private extension MouseEventPoster {
    func postTestClick(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint,
        windowBounds: WindowBounds,
        deliveryRoute: BackgroundMouseEventDeliveryRoute = .appKit,
        stageObserver: BackgroundMouseEventPostObserver? = nil
    ) async throws {
        try await post(
            .click(button: .left, point: point),
            to: BackgroundMouseEventTarget(
                pid: pid,
                windowId: windowId,
                windowBounds: windowBounds
            ),
            deliveryRoute: deliveryRoute,
            stageObserver: stageObserver
        )
    }
}

private final class WindowSnapshotScript: @unchecked Sendable {
    private let snapshots: [[WindowInfo]]
    private let lock = NSLock()
    private var index = 0

    init(_ snapshots: [[WindowInfo]]) {
        self.snapshots = snapshots
    }

    func next() -> [WindowInfo] {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return snapshot
    }
}

private final class ActiveStateScript: @unchecked Sendable {
    private let states: [Bool]
    private let lock = NSLock()
    private var index = 0

    init(_ states: [Bool]) {
        self.states = states
    }

    func next() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let state = states[min(index, states.count - 1)]
        index += 1
        return state
    }
}

private final class DeliveryRouteRecorder: @unchecked Sendable {
    private let route: BackgroundMouseEventDeliveryRoute
    private let lock = NSLock()
    private var recordedPIDs: [pid_t] = []

    init(route: BackgroundMouseEventDeliveryRoute) {
        self.route = route
    }

    var resolvedPIDs: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPIDs
    }

    func resolve(pid: pid_t) -> BackgroundMouseEventDeliveryRoute {
        lock.lock()
        recordedPIDs.append(pid)
        lock.unlock()
        return route
    }
}

private final class ManualWindowOrderChangeObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedWindowIds: [CGWindowID] = []
    private var handler: (@Sendable (CGWindowID) async throws -> Void)?

    var observer: WindowOrderChangeObserver {
        WindowOrderChangeObserver { windowIds, handler in
            self.arm(windowIds: windowIds, handler: handler)
            return WindowOrderChangeObservation {}
        }
    }

    var observedWindowIds: [CGWindowID] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWindowIds
    }

    func emit(windowId: CGWindowID) async throws {
        guard let handler = handlerSnapshot() else {
            throw ComputerUseError.mouseEventUnavailable("window-order observer was not armed")
        }
        try await handler(windowId)
    }

    private func arm(
        windowIds: [CGWindowID],
        handler: @escaping @Sendable (CGWindowID) async throws -> Void
    ) {
        lock.lock()
        recordedWindowIds = windowIds
        self.handler = handler
        lock.unlock()
    }

    private func handlerSnapshot() -> (@Sendable (CGWindowID) async throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let handler = handler
        return handler
    }
}

private final class MousePostRecorder: @unchecked Sendable {
    struct Post: Sendable, Equatable {
        let type: CGEventType
        let pid: pid_t
        let location: CGPoint
        let windowUnderMousePointer: Int64
        let windowUnderMousePointerThatCanHandleThisEvent: Int64
        let buttonNumber: Int64
        let rawField58: Int64
    }

    struct IntegerField: Equatable {
        let field: UInt32
        let value: Int64
    }

    private let lock = NSLock()
    private var recordedPublicPosts: [Post] = []
    private var recordedSkyLightPosts: [Post] = []
    private var recordedWindowLocations: [CGPoint] = []
    private var recordedIntegerFields: [IntegerField] = []
    private var recordedSleeps: [useconds_t] = []
    private var recordedStages: [BackgroundMouseEventPostStage] = []

    var publicPosts: [Post] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPublicPosts
    }

    var skyLightPosts: [Post] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSkyLightPosts
    }

    var windowLocations: [CGPoint] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWindowLocations
    }

    var integerFields: [IntegerField] {
        lock.lock()
        defer { lock.unlock() }
        return recordedIntegerFields
    }

    var sleeps: [useconds_t] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSleeps
    }

    var stages: [BackgroundMouseEventPostStage] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStages
    }

    func recordPublicPost(event: CGEvent, pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        recordedPublicPosts.append(Post(
            type: event.type,
            pid: pid,
            location: event.location,
            windowUnderMousePointer: event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
            windowUnderMousePointerThatCanHandleThisEvent: event.getIntegerValueField(
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
            ),
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            rawField58: event.getIntegerValueField(CGEventField(rawValue: 58)!)
        ))
    }

    func recordSkyLightPost(event: CGEvent, pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        recordedSkyLightPosts.append(Post(
            type: event.type,
            pid: pid,
            location: event.location,
            windowUnderMousePointer: event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
            windowUnderMousePointerThatCanHandleThisEvent: event.getIntegerValueField(
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
            ),
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            rawField58: event.getIntegerValueField(CGEventField(rawValue: 58)!)
        ))
    }

    func recordWindowLocation(_ point: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        recordedWindowLocations.append(point)
    }

    func recordIntegerField(field: UInt32, value: Int64) {
        lock.lock()
        defer { lock.unlock() }
        recordedIntegerFields.append(IntegerField(field: field, value: value))
    }

    func recordSleep(_ interval: useconds_t) {
        lock.lock()
        defer { lock.unlock() }
        recordedSleeps.append(interval)
    }

    func recordStage(_ stage: BackgroundMouseEventPostStage) {
        lock.lock()
        defer { lock.unlock() }
        recordedStages.append(stage)
    }
}
