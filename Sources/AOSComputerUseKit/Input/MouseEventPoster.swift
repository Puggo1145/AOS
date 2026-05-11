import AppKit
import CoreGraphics
import Darwin
import Foundation

public enum MouseClickPostStage: String, Sendable, Equatable {
    case afterMouseMoved
    case afterTargetDown
    case afterTargetUp
}

public typealias MouseClickPostObserver = @Sendable (MouseClickPostStage) async throws -> Void

/// Posts pid-scoped mouse events for the general, non-Chromium path through
/// the public cursor-neutral per-pid mouse route.
///
/// The event shape intentionally mirrors the CUA/Codex probe observations:
/// AppKit receives an NSEvent-bridged CGEvent, WindowServer gets an explicit
/// window-local coordinate, and SkyLight private fields carry the pid, window
/// id, and gesture grouping metadata. `CGEvent.postToPid` is used exactly once
/// per event because it is the route AppKit reliably drains; the core repairs
/// WindowServer order immediately after each post stage.
struct MouseEventPoster: Sendable {
    typealias PostEventToPID = @Sendable (CGEvent, pid_t) throws -> Void
    typealias SetWindowLocation = @Sendable (CGEvent, CGPoint) throws -> Void
    typealias SetIntegerField = @Sendable (CGEvent, UInt32, Int64) throws -> Void
    typealias Sleep = @Sendable (useconds_t) -> Void

    private let postEventToPID: PostEventToPID
    private let setWindowLocation: SetWindowLocation
    private let setIntegerField: SetIntegerField
    private let sleep: Sleep

    init(
        postEventToPID: @escaping PostEventToPID = { event, pid in event.postToPid(pid) },
        setWindowLocation: @escaping SetWindowLocation,
        setIntegerField: @escaping SetIntegerField,
        sleep: @escaping Sleep = { usleep($0) }
    ) {
        self.postEventToPID = postEventToPID
        self.setWindowLocation = setWindowLocation
        self.setIntegerField = setIntegerField
        self.sleep = sleep
    }

    static func live() -> MouseEventPoster {
        MouseEventPoster(
            setWindowLocation: { event, point in
                let symbols = try SkyLightMouseEventSymbols.load()
                symbols.setWindowLocation(event, point)
            },
            setIntegerField: { event, field, value in
                let symbols = try SkyLightMouseEventSymbols.load()
                symbols.setIntegerField(event, field, value)
            }
        )
    }

    func postLeftClick(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint,
        windowBounds: WindowBounds,
        stageObserver: MouseClickPostObserver? = nil
    ) async throws {
        let windowLocalPoint = CGPoint(
            x: point.x - windowBounds.x,
            y: point.y - windowBounds.y
        )
        let clickGroup = Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) & 0x7fff_ffff)

        let move = try makeMouseEvent(
            type: .mouseMoved,
            windowId: windowId,
            clickCount: 0
        )
        let down = try makeMouseEvent(
            type: .leftMouseDown,
            windowId: windowId,
            clickCount: 1
        )
        let up = try makeMouseEvent(
            type: .leftMouseUp,
            windowId: windowId,
            clickCount: 1
        )

        try stamp(
            move,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 2,
            clickGroup: clickGroup,
            screenPoint: point,
            windowLocalPoint: windowLocalPoint
        )
        try stamp(
            down,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 3,
            clickGroup: clickGroup,
            screenPoint: point,
            windowLocalPoint: windowLocalPoint
        )
        try stamp(
            up,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 3,
            clickGroup: clickGroup,
            screenPoint: point,
            windowLocalPoint: windowLocalPoint
        )

        try post(move, pid: pid)
        try await stageObserver?(.afterMouseMoved)
        sleep(15_000)
        try post(down, pid: pid)
        try await stageObserver?(.afterTargetDown)
        sleep(1_000)
        try post(up, pid: pid)
        try await stageObserver?(.afterTargetUp)
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        windowId: CGWindowID,
        clickCount: Int
    ) throws -> CGEvent {
        guard
            let nsEvent = NSEvent.mouseEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: Int(windowId),
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1.0
            )
        else {
            throw ComputerUseError.clickUnavailable("failed to create \(type) NSEvent")
        }
        guard let event = nsEvent.cgEvent else {
            throw ComputerUseError.clickUnavailable("failed to bridge \(type) NSEvent to CGEvent")
        }
        return event
    }

    private func stamp(
        _ event: CGEvent,
        pid: pid_t,
        windowId: CGWindowID,
        mouseEventNumber: Int64,
        clickGroup: Int64,
        screenPoint: CGPoint,
        windowLocalPoint: CGPoint
    ) throws {
        let rawWindowId = Int64(windowId)
        event.location = screenPoint
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: rawWindowId)
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: rawWindowId
        )
        try setWindowLocation(event, windowLocalPoint)
        try setIntegerField(event, 0, mouseEventNumber)
        try setIntegerField(event, 40, Int64(pid))
        try setIntegerField(event, 51, rawWindowId)
        try setIntegerField(event, 58, clickGroup)
        try setIntegerField(event, 91, rawWindowId)
        try setIntegerField(event, 92, rawWindowId)
    }

    private func post(_ event: CGEvent, pid: pid_t) throws {
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try postEventToPID(event, pid)
    }
}

private typealias CGEventSetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
private typealias SLEventSetIntegerValueField = @convention(c) (CGEvent, UInt32, Int64) -> Void

private struct SkyLightMouseEventSymbols {
    let setWindowLocation: CGEventSetWindowLocation
    let setIntegerField: SLEventSetIntegerValueField

    static func load() throws -> SkyLightMouseEventSymbols {
        let handles = try MouseEventPrivateFrameworkHandles.load()
        return SkyLightMouseEventSymbols(
            setWindowLocation: try handles.symbol("CGEventSetWindowLocation"),
            setIntegerField: try handles.symbol("SLEventSetIntegerValueField")
        )
    }
}

private struct MouseEventPrivateFrameworkHandles {
    private let defaultHandle: UnsafeMutableRawPointer

    static func load() throws -> MouseEventPrivateFrameworkHandles {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard dlopen(path, RTLD_LAZY) != nil else {
            throw ComputerUseError.clickUnavailable("failed to load private framework at \(path)")
        }
        guard let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) else {
            throw ComputerUseError.clickUnavailable("failed to access RTLD_DEFAULT symbol scope")
        }
        return MouseEventPrivateFrameworkHandles(defaultHandle: defaultHandle)
    }

    func symbol<T>(_ name: String) throws -> T {
        if let pointer = dlsym(defaultHandle, name) {
            return unsafeBitCast(pointer, to: T.self)
        }
        throw ComputerUseError.clickUnavailable("missing private symbol \(name)")
    }
}
