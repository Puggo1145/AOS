@testable import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation
import Testing

@Suite("ComputerUseCore coordinate left click")
struct WindowClickTests {
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
            postLeftClick: { pid, windowId, point, windowBounds, _ in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        let result = try await core.postLeftClick(pid: 123, windowId: 456, point: CGPoint(x: 160, y: 70))

        #expect(result.pid == 123)
        #expect(result.windowId == 456)
        #expect(result.point == CGPoint(x: 160, y: 70))
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
            postLeftClick: { pid, windowId, point, windowBounds, _ in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        let result = try await core.postLeftClick(
            pid: 123,
            windowId: 456,
            point: CGPoint(x: 32, y: 54)
        )

        #expect(result.point == CGPoint(x: 32, y: 54))
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
            postLeftClick: { pid, windowId, point, windowBounds, _ in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        await #expect(throws: ComputerUseError.self) {
            try await core.postLeftClick(
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
            postLeftClick: { pid, windowId, point, windowBounds, _ in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postLeftClick(pid: 123, windowId: 456, point: CGPoint(x: 160, y: 70))

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

    @Test("repairs protected windows when the target crosses them after a click")
    func repairsProtectedWindowsWhenTargetCrossesThemAfterClick() async throws {
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
            raiseWindowWithoutActivating: { window in
                await recorder.recordRaise(pid: window.pid, windowId: window.id)
            },
            orderRepairDelays: [0, 1],
            sleepForOrderRepair: { _ in },
            postLeftClick: { pid, windowId, point, windowBounds, _ in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postLeftClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .focus(pid: 10, windowId: 100),
            .raise(pid: 20, windowId: 200),
            .raise(pid: 10, windowId: 100),
            .focus(pid: 10, windowId: 100),
        ])
    }

    @Test("repairs protected windows immediately after a mouse post stage")
    func repairsProtectedWindowsImmediatelyAfterMousePostStage() async throws {
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
            raiseWindowWithoutActivating: { window in
                await recorder.recordRaise(pid: window.pid, windowId: window.id)
            },
            orderRepairDelays: [0],
            sleepForOrderRepair: { _ in },
            postLeftClick: { pid, windowId, point, windowBounds, stageObserver in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
                try await stageObserver?(.afterTargetDown)
            }
        )

        _ = try await core.postLeftClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events == [
            .focus(pid: 30, windowId: 300),
            .click(
                pid: 30,
                windowId: 300,
                point: CGPoint(x: 150, y: 50),
                windowBounds: WindowBounds(x: 0, y: 0, width: 300, height: 100)
            ),
            .raise(pid: 10, windowId: 100),
            .focus(pid: 10, windowId: 100),
            .focus(pid: 10, windowId: 100),
        ])
    }

    @Test("does not repair windows that were already below the target before clicking")
    func doesNotRepairWindowsOriginallyBelowTarget() async throws {
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
            raiseWindowWithoutActivating: { window in
                await recorder.recordRaise(pid: window.pid, windowId: window.id)
            },
            orderRepairDelays: [0, 1],
            sleepForOrderRepair: { _ in },
            postLeftClick: { pid, windowId, point, windowBounds, _ in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postLeftClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events.filter {
            if case .raise = $0 { return true }
            return false
        } == [
            .raise(pid: 10, windowId: 100),
        ])
    }

    @Test("does not repair non-overlapping windows that were globally above the target")
    func doesNotRepairNonOverlappingWindowsAboveTarget() async throws {
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
            [target, overlappingFront, nonOverlappingFront],
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
            raiseWindowWithoutActivating: { window in
                await recorder.recordRaise(pid: window.pid, windowId: window.id)
            },
            orderRepairDelays: [0],
            sleepForOrderRepair: { _ in },
            postLeftClick: { pid, windowId, point, windowBounds, _ in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postLeftClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events.filter {
            if case .raise = $0 { return true }
            return false
        } == [
            .raise(pid: 10, windowId: 100),
        ])
    }

    @Test("continues repairing when the delayed target raise reappears")
    func continuesRepairingWhenDelayedTargetRaiseReappears() async throws {
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
            raiseWindowWithoutActivating: { window in
                await recorder.recordRaise(pid: window.pid, windowId: window.id)
            },
            orderRepairDelays: [0, 1, 1],
            sleepForOrderRepair: { _ in },
            postLeftClick: { pid, windowId, point, windowBounds, _ in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        _ = try await core.postLeftClick(pid: 30, windowId: 300, point: CGPoint(x: 150, y: 50))

        #expect(await recorder.events.filter {
            if case .raise = $0 { return true }
            return false
        } == [
            .raise(pid: 20, windowId: 200),
            .raise(pid: 10, windowId: 100),
            .raise(pid: 20, windowId: 200),
            .raise(pid: 10, windowId: 100),
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
            postLeftClick: { pid, windowId, point, windowBounds, _ in
                await recorder.recordClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds
                )
            }
        )

        await #expect(throws: ComputerUseError.self) {
            try await core.postLeftClick(pid: 123, windowId: 456, point: CGPoint(x: 160, y: 70))
        }
        #expect(await recorder.events.isEmpty)
    }

    @Test("mouse poster uses public pid target move/down/up with rich window stamps")
    func mousePosterUsesPublicPidMoveDownUpWithRichWindowStamps() async throws {
        let recorder = MousePostRecorder()
        let poster = MouseEventPoster(
            postEventToPID: { event, pid in
                recorder.recordPost(event: event, pid: pid)
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

        try await poster.postLeftClick(
            pid: 123,
            windowId: 456,
            point: CGPoint(x: 160, y: 70),
            windowBounds: WindowBounds(x: 10, y: 20, width: 300, height: 100),
            stageObserver: { stage in
                recorder.recordStage(stage)
            }
        )

        #expect(recorder.posts.map(\.pid) == [123, 123, 123])
        #expect(recorder.posts.map(\.type) == [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
        ])
        #expect(recorder.posts.map(\.location) == [
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
            0, 40, 51, 58, 91, 92,
            0, 40, 51, 58, 91, 92,
            0, 40, 51, 58, 91, 92,
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
        let clickGroups = recorder.integerFields.filter { $0.field == 58 }.map(\.value)
        #expect(clickGroups.count == 3)
        #expect(Set(clickGroups).count == 1)
        #expect(recorder.stages == [
            .afterMouseMoved,
            .afterTargetDown,
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

    func recordRaise(pid: pid_t, windowId: CGWindowID) {
        recordedEvents.append(.raise(pid: pid, windowId: windowId))
    }
}

private enum ClickChainEvent: Equatable {
    case focus(pid: pid_t, windowId: CGWindowID)
    case raise(pid: pid_t, windowId: CGWindowID)
    case click(pid: pid_t, windowId: CGWindowID, point: CGPoint, windowBounds: WindowBounds)
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

private final class MousePostRecorder: @unchecked Sendable {
    struct Post: Sendable, Equatable {
        let type: CGEventType
        let pid: pid_t
        let location: CGPoint
    }

    struct IntegerField: Equatable {
        let field: UInt32
        let value: Int64
    }

    private let lock = NSLock()
    private var recordedPosts: [Post] = []
    private var recordedWindowLocations: [CGPoint] = []
    private var recordedIntegerFields: [IntegerField] = []
    private var recordedSleeps: [useconds_t] = []
    private var recordedStages: [MouseClickPostStage] = []

    var posts: [Post] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPosts
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

    var stages: [MouseClickPostStage] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStages
    }

    func recordPost(event: CGEvent, pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        recordedPosts.append(Post(type: event.type, pid: pid, location: event.location))
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

    func recordStage(_ stage: MouseClickPostStage) {
        lock.lock()
        defer { lock.unlock() }
        recordedStages.append(stage)
    }
}
