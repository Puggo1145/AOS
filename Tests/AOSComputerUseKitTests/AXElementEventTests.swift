@testable import AOSComputerUseKit
import AOSAXSupport
import ApplicationServices
import CoreGraphics
import Darwin
import Testing

@Suite("ComputerUseCore AX element events")
struct AXElementEventTests {
    @Test("postEventToAXElement requires an active app session")
    func postEventToAXElementRequiresAnActiveAppSession() async throws {
        let cache = StateCache(ttlSeconds: 30)
        let element = AXUIElementCreateSystemWide()
        let stateId = await cache.store(pid: 123, windowId: 456, elements: [7: element])
        let core = ComputerUseCore(
            cache: cache,
            windowLookup: { windowId in
                windowId == 456 ? Self.window(id: 456, pid: 123) : nil
            },
            focusWindowWithoutRaising: { _, _ in },
            deactivateWindowWithoutRaising: { _, _ in },
            postAXElementEvent: { _, _ in
                Issue.record("AX events must not post without an active app session")
            }
        )

        await #expect(throws: ComputerUseError.self) {
            try await core.postEventToAXElement(
                windowId: 456,
                stateId: stateId,
                elementIndex: 7,
                event: .action(.press)
            )
        }
    }

    @Test("postEventToAXElement resolves cached state and bypasses coordinate focus")
    func postEventToAXElementResolvesCachedStateAndBypassesCoordinateFocus() async throws {
        guard StateCache.isElementAlive(Self.aliveElement()) else { return }
        let recorder = AXElementEventRecorder()
        let cache = StateCache(ttlSeconds: 30)
        let element = Self.aliveElement()
        let stateId = await cache.store(pid: 123, windowId: 456, elements: [7: element])
        let target = Self.window(id: 456, pid: 123)
        let core = ComputerUseCore(
            cache: cache,
            windowLookup: { windowId in
                windowId == target.id ? target : nil
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.record(.coordinateFocus(pid: pid, windowId: windowId))
            },
            deactivateWindowWithoutRaising: { _, _ in },
            postAXElementEvent: { event, target in
                await recorder.record(.ax(event: event, target: target))
            }
        )

        _ = try await core.startAppSession(pid: 123, windowId: 456)
        await recorder.removeAll()
        let result = try await core.postEventToAXElement(
            windowId: 456,
            stateId: stateId,
            elementIndex: 7,
            event: .action(.press)
        )

        #expect(result == AXElementEventResult(
            pid: 123,
            windowId: 456,
            stateId: stateId,
            elementIndex: 7,
            event: .action(.press)
        ))
        #expect(await recorder.events == [
            .ax(
                event: .action(.press),
                target: AXElementEventTarget(
                    pid: 123,
                    windowId: 456,
                    stateId: stateId,
                    elementIndex: 7,
                    element: element
                )
            ),
        ])
    }

    @Test("postEventToAXElement supports semantic page scroll")
    func postEventToAXElementSupportsSemanticPageScroll() async throws {
        guard StateCache.isElementAlive(Self.aliveElement()) else { return }
        let recorder = AXElementEventRecorder()
        let cache = StateCache(ttlSeconds: 30)
        let element = Self.aliveElement()
        let stateId = await cache.store(pid: 123, windowId: 456, elements: [0: element])
        let core = ComputerUseCore(
            cache: cache,
            windowLookup: { windowId in
                windowId == 456 ? Self.window(id: 456, pid: 123) : nil
            },
            focusWindowWithoutRaising: { _, _ in },
            deactivateWindowWithoutRaising: { _, _ in },
            postAXElementEvent: { event, target in
                await recorder.record(.ax(event: event, target: target))
            }
        )

        _ = try await core.startAppSession(pid: 123, windowId: 456)
        await recorder.removeAll()
        _ = try await core.postEventToAXElement(
            windowId: 456,
            stateId: stateId,
            elementIndex: 0,
            event: .scroll(direction: .down, pages: 0.8)
        )

        #expect(await recorder.events == [
            .ax(
                event: .scroll(direction: .down, pages: 0.8),
                target: AXElementEventTarget(
                    pid: 123,
                    windowId: 456,
                    stateId: stateId,
                    elementIndex: 0,
                    element: element
                )
            ),
        ])
    }

    @Test("postEventToAXElement does not use coordinate raise suppression")
    func postEventToAXElementDoesNotUseCoordinateRaiseSuppression() async throws {
        let recorder = AXElementEventRecorder()
        let coordinateRecorder = AXPosterRecorder()
        let cache = StateCache(ttlSeconds: 30)
        let element = AXUIElementCreateSystemWide()
        let stateId = await cache.store(pid: 30, windowId: 300, elements: [7: element])
        let target = Self.window(id: 300, pid: 30, owner: "Safari", zIndex: 1)
        let protected = Self.window(id: 100, pid: 10, owner: "Ghostty", zIndex: 2)
        let snapshots = AXWindowSnapshotScript([
            [protected, target],
            [target, protected],
            [protected, target],
        ])
        let activeStates = AXActiveStateScript([true])
        let core = ComputerUseCore(
            cache: cache,
            windowLookup: { windowId in
                [target, protected].first { $0.id == windowId }
            },
            visibleWindowsLookup: {
                coordinateRecorder.record(.coordinateGuardProbe)
                return snapshots.next()
            },
            frontmostWindowLookup: {
                protected
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.record(.coordinateFocus(pid: pid, windowId: windowId))
            },
            deactivateWindowWithoutRaising: { _, _ in },
            activateApplication: { pid in
                await recorder.record(.activate(pid: pid))
                return true
            },
            isApplicationActive: { _ in
                activeStates.next()
            },
            activeStateGuardDelays: [0],
            sleepForActiveStateGuard: { _ in },
            postAXElementEvent: { event, target in
                await recorder.record(.ax(event: event, target: target))
            }
        )

        _ = try await core.startAppSession(pid: 30, windowId: 300)
        await recorder.removeAll()
        _ = try await core.postEventToAXElement(
            windowId: 300,
            stateId: stateId,
            elementIndex: 7,
            event: .action(.press)
        )

        #expect(coordinateRecorder.events == [])
        #expect(await recorder.events == [
            .ax(
                event: .action(.press),
                target: AXElementEventTarget(
                    pid: 30,
                    windowId: 300,
                    stateId: stateId,
                    elementIndex: 7,
                    element: element
                )
            ),
        ])
    }

    @Test("AX poster arms CUA focus-steal suppression around AX actions")
    func axPosterArmsCUAFocusStealSuppressionAroundAXActions() async throws {
        let element = Self.aliveElement()
        let recorder = AXPosterRecorder()
        let poster = AXElementEventPoster(
            webAccessibilityActivator: Self.disabledActivator(),
            copyActionNames: { _, names in
                names.pointee = ["AXPress"] as CFArray
                return .success
            },
            performAction: { _, action in
                recorder.record(.performAction(action as String))
                return .success
            },
            isProcessTrusted: { true },
            focusStealSuppression: AXFocusStealSuppression(
                begin: { targetPid, restorePid in
                    recorder.record(.beginSuppression(targetPid: targetPid, restorePid: restorePid))
                    return AXFocusSuppressionHandle(rawValue: 7)
                },
                end: { handle in
                    recorder.record(.endSuppression(handle: handle))
                }
            ),
            frontmostApplicationPID: { 10 },
            isApplicationActive: { _ in false },
            sleepAfterAXAction: { _ in }
        )

        try await poster.post(
            .action(.press),
            to: AXElementEventTarget(
                pid: 123,
                windowId: 456,
                stateId: StateID("state"),
                elementIndex: 0,
                element: element
            )
        )

        #expect(recorder.events == [
            .beginSuppression(targetPid: 123, restorePid: 10),
            .performAction("AXPress"),
            .endSuppression(handle: AXFocusSuppressionHandle(rawValue: 7)),
        ])
    }

    @Test("AX focus steal preventer restores the prior front app on target activation")
    func axFocusStealPreventerRestoresPriorFrontAppOnTargetActivation() async {
        let recorder = AXPosterRecorder()
        let activation = AXActivationScript()
        let preventer = AXFocusStealPreventer(
            addActivationObserver: { handler in
                recorder.record(.observerAdded)
                activation.setHandler(handler)
                return {
                    recorder.record(.observerRemoved)
                }
            },
            activateApplication: { pid in
                recorder.record(.restoreApplication(pid: pid))
                return true
            },
            sleep: { _ in }
        )

        let handle = await preventer.beginSuppression(targetPid: 123, restorePid: 10)
        activation.emit(pid: 999)
        activation.emit(pid: 123)
        await preventer.endSuppression(handle)

        #expect(recorder.events == [
            .observerAdded,
            .observerRemoved,
            .restoreApplication(pid: 10),
        ])
    }

    @Test("AX poster performs advertised page scroll action")
    func axPosterPerformsAdvertisedPageScrollAction() async throws {
        let element = Self.aliveElement()
        let recorder = AXPosterRecorder()
        let poster = AXElementEventPoster(
            webAccessibilityActivator: Self.disabledActivator(),
            copyActionNames: { target, names in
                guard CFEqual(target, element) else { return .failure }
                names.pointee = ["AXScrollDownByPage"] as CFArray
                return .success
            },
            performAction: { target, action in
                guard CFEqual(target, element) else { return .failure }
                recorder.recordAction(action as String)
                return .success
            },
            isProcessTrusted: { true }
        )

        try await poster.post(
            .scroll(direction: .down, pages: 0.8),
            to: AXElementEventTarget(
                pid: 123,
                windowId: 456,
                stateId: StateID("state"),
                elementIndex: 0,
                element: element
            )
        )

        #expect(recorder.actions == ["AXScrollDownByPage"])
    }

    @Test("AX poster scroll writes scrollbar value when no scroll action is advertised")
    func axPosterScrollWritesScrollbarValueWhenNoScrollActionIsAdvertised() async throws {
        let element = Self.aliveElement()
        let scrollBar = AXUIElementCreateSystemWide()
        let recorder = AXPosterRecorder()
        let poster = AXElementEventPoster(
            webAccessibilityActivator: Self.disabledActivator(),
            copyAttribute: { target, attribute, value in
                let name = attribute as String
                if CFEqual(target, element), name == "AXVerticalScrollBar" {
                    value.pointee = scrollBar
                    return .success
                }
                if CFEqual(target, scrollBar) {
                    switch name {
                    case "AXRole":
                        value.pointee = "AXScrollBar" as CFTypeRef
                    case "AXOrientation":
                        value.pointee = "AXVerticalOrientation" as CFTypeRef
                    case "AXValue":
                        value.pointee = 0.2 as CFTypeRef
                    case "AXMinValue":
                        value.pointee = 0.0 as CFTypeRef
                    case "AXMaxValue":
                        value.pointee = 1.0 as CFTypeRef
                    default:
                        return .attributeUnsupported
                    }
                    return .success
                }
                return .attributeUnsupported
            },
            setAttribute: { target, attribute, value in
                if CFEqual(target, scrollBar), (attribute as String) == "AXValue" {
                    recorder.recordSetValue(value as! NSNumber)
                }
                return .success
            },
            copyActionNames: { _, names in
                names.pointee = [] as CFArray
                return .success
            },
            isProcessTrusted: { true }
        )

        try await poster.post(
            .scroll(direction: .down, pages: 0.6),
            to: AXElementEventTarget(
                pid: 123,
                windowId: 456,
                stateId: StateID("state"),
                elementIndex: 0,
                element: element
            )
        )

        #expect(recorder.setValues == [0.8])
    }

    @Test("AX poster scroll skips invalid target scrollbar and writes ancestor scrollbar")
    func axPosterScrollSkipsInvalidTargetScrollbarAndWritesAncestorScrollbar() async throws {
        let element = AXUIElementCreateApplication(1_001)
        let parent = AXUIElementCreateApplication(1_002)
        let ancestorScrollBar = AXUIElementCreateApplication(1_003)
        let recorder = AXPosterRecorder()
        let poster = AXElementEventPoster(
            webAccessibilityActivator: Self.disabledActivator(),
            copyAttribute: { target, attribute, value in
                let name = attribute as String
                if CFEqual(target, element) {
                    switch name {
                    case "AXRole":
                        value.pointee = "AXScrollBar" as CFTypeRef
                    case "AXOrientation":
                        value.pointee = "AXVerticalOrientation" as CFTypeRef
                    case "AXValue", "AXMinValue", "AXMaxValue":
                        value.pointee = 0.0 as CFTypeRef
                    case "AXParent":
                        value.pointee = parent
                    default:
                        return .attributeUnsupported
                    }
                    return .success
                }
                if CFEqual(target, parent), name == "AXVerticalScrollBar" {
                    value.pointee = ancestorScrollBar
                    return .success
                }
                if CFEqual(target, ancestorScrollBar) {
                    switch name {
                    case "AXRole":
                        value.pointee = "AXScrollBar" as CFTypeRef
                    case "AXOrientation":
                        value.pointee = "AXVerticalOrientation" as CFTypeRef
                    case "AXValue":
                        value.pointee = 0.25 as CFTypeRef
                    case "AXMinValue":
                        value.pointee = 0.0 as CFTypeRef
                    case "AXMaxValue":
                        value.pointee = 1.0 as CFTypeRef
                    default:
                        return .attributeUnsupported
                    }
                    return .success
                }
                return .attributeUnsupported
            },
            setAttribute: { target, attribute, value in
                if CFEqual(target, ancestorScrollBar), (attribute as String) == "AXValue" {
                    recorder.recordSetValue(value as! NSNumber)
                }
                return .success
            },
            copyActionNames: { _, names in
                names.pointee = [] as CFArray
                return .success
            },
            isProcessTrusted: { true }
        )

        try await poster.post(
            .scroll(direction: .down, pages: 0.5),
            to: AXElementEventTarget(
                pid: 123,
                windowId: 456,
                stateId: StateID("state"),
                elementIndex: 0,
                element: element
            )
        )

        #expect(recorder.setValues == [0.75])
    }

    @Test("AX poster scroll writes normalized scrollbar value when min max range is invalid")
    func axPosterScrollWritesNormalizedScrollbarValueWhenMinMaxRangeIsInvalid() async throws {
        let element = AXUIElementCreateApplication(1_101)
        let scrollBar = AXUIElementCreateApplication(1_102)
        let recorder = AXPosterRecorder()
        let poster = AXElementEventPoster(
            webAccessibilityActivator: Self.disabledActivator(),
            copyAttribute: { target, attribute, value in
                let name = attribute as String
                if CFEqual(target, element), name == "AXVerticalScrollBar" {
                    value.pointee = scrollBar
                    return .success
                }
                if CFEqual(target, scrollBar) {
                    switch name {
                    case "AXRole":
                        value.pointee = "AXScrollBar" as CFTypeRef
                    case "AXOrientation":
                        value.pointee = "AXVerticalOrientation" as CFTypeRef
                    case "AXValue":
                        value.pointee = 0.0 as CFTypeRef
                    case "AXMinValue", "AXMaxValue":
                        value.pointee = 0.0 as CFTypeRef
                    default:
                        return .attributeUnsupported
                    }
                    return .success
                }
                return .attributeUnsupported
            },
            setAttribute: { target, attribute, value in
                if CFEqual(target, scrollBar), (attribute as String) == "AXValue" {
                    recorder.recordSetValue(value as! NSNumber)
                }
                return .success
            },
            copyActionNames: { _, names in
                names.pointee = [] as CFArray
                return .success
            },
            isProcessTrusted: { true }
        )

        try await poster.post(
            .scroll(direction: .down, pages: 0.4),
            to: AXElementEventTarget(
                pid: 123,
                windowId: 456,
                stateId: StateID("state"),
                elementIndex: 0,
                element: element
            )
        )

        #expect(recorder.setValues == [0.4])
    }

    private static func aliveElement() -> AXUIElement {
        AXUIElementCreateApplication(getpid())
    }

    private static func disabledActivator() -> AXWebAccessibilityActivator {
        AXWebAccessibilityActivator(
            writeAttribute: { _, _, _ in .success },
            observerRegistrar: .disabledForTesting,
            webContentProbe: { _ in true }
        )
    }

    private static func window(
        id: CGWindowID,
        pid: pid_t,
        owner: String = "Target",
        zIndex: Int = 1
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid,
            owner: owner,
            title: owner,
            bounds: WindowBounds(x: 0, y: 0, width: 400, height: 300),
            zIndex: zIndex,
            isOnScreen: true,
            layer: 0
        )
    }
}

private final class AXPosterRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedActions: [String] = []
    private var recordedSetValues: [Double] = []
    private var recordedEvents: [AXPosterEvent] = []

    var actions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedActions
    }

    var setValues: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSetValues
    }

    var events: [AXPosterEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func recordAction(_ action: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedActions.append(action)
    }

    func recordSetValue(_ value: NSNumber) {
        lock.lock()
        defer { lock.unlock() }
        recordedSetValues.append(value.doubleValue)
    }

    func record(_ event: AXPosterEvent) {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
    }
}

private actor AXElementEventRecorder {
    private var recordedEvents: [AXElementEventRecord] = []

    var events: [AXElementEventRecord] {
        recordedEvents
    }

    func record(_ event: AXElementEventRecord) {
        recordedEvents.append(event)
    }

    func removeAll() {
        recordedEvents.removeAll()
    }
}

private enum AXElementEventRecord: Equatable {
    case coordinateFocus(pid: pid_t, windowId: CGWindowID)
    case activate(pid: pid_t)
    case ax(event: AXElementEvent, target: AXElementEventTarget)
}

private enum AXPosterEvent: Equatable {
    case beginSuppression(targetPid: pid_t, restorePid: pid_t)
    case coordinateGuardProbe
    case endSuppression(handle: AXFocusSuppressionHandle)
    case observerAdded
    case observerRemoved
    case performAction(String)
    case restoreApplication(pid: pid_t)
}

private final class AXActivationScript: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (pid_t) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (pid_t) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func emit(pid: pid_t) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(pid)
    }
}

private final class AXWindowSnapshotScript: @unchecked Sendable {
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

private final class AXActiveStateScript: @unchecked Sendable {
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
