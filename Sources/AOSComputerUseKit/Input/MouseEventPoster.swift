import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Posts pid-scoped mouse events through either the public AppKit route or the
/// web-content SkyLight route.
///
/// Routes create CGEvents, stamp window-local coordinates and private SkyLight
/// fields, and rely on the core to run the active-state guard after observable
/// post stages.
struct MouseEventPoster: Sendable {
    typealias PostEventToPID = @Sendable (CGEvent, pid_t) throws -> Void
    typealias SetWindowLocation = @Sendable (CGEvent, CGPoint) throws -> Void
    typealias SetIntegerField = @Sendable (CGEvent, UInt32, Int64) throws -> Void
    typealias UptimeSeconds = @Sendable () -> UInt64
    typealias Sleep = @Sendable (useconds_t) -> Void

    private let postPublicEventToPID: PostEventToPID
    private let postSkyLightEventToPID: PostEventToPID
    private let setWindowLocation: SetWindowLocation
    private let setIntegerField: SetIntegerField
    private let uptimeSeconds: UptimeSeconds
    private let sleep: Sleep

    init(
        postPublicEventToPID: @escaping PostEventToPID = { event, pid in event.postToPid(pid) },
        postSkyLightEventToPID: @escaping PostEventToPID,
        setWindowLocation: @escaping SetWindowLocation,
        setIntegerField: @escaping SetIntegerField,
        uptimeSeconds: @escaping UptimeSeconds = { UInt64(ProcessInfo.processInfo.systemUptime) },
        sleep: @escaping Sleep = { usleep($0) }
    ) {
        self.postPublicEventToPID = postPublicEventToPID
        self.postSkyLightEventToPID = postSkyLightEventToPID
        self.setWindowLocation = setWindowLocation
        self.setIntegerField = setIntegerField
        self.uptimeSeconds = uptimeSeconds
        self.sleep = sleep
    }

    static func live() -> MouseEventPoster {
        MouseEventPoster(
            postSkyLightEventToPID: { event, pid in
                let symbols = try SkyLightMouseEventPostSymbols.load()
                symbols.postEventToPID(event, pid)
            },
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

    func post(
        _ event: BackgroundMouseEvent,
        to target: BackgroundMouseEventTarget,
        deliveryRoute: BackgroundMouseEventDeliveryRoute = .appKit,
        stageObserver: BackgroundMouseEventPostObserver? = nil
    ) async throws {
        switch (deliveryRoute, event) {
        case (.appKit, .click(let button, let point, let count)):
            try await postAppKitClick(
                button: button,
                target: target,
                point: point,
                count: count,
                stageObserver: stageObserver
            )
        case (.appKit, .drag):
            throw ComputerUseError.mouseEventUnavailable("appKit route does not support \(event)")
        case (.webContent, .click(let button, let point, let count)):
            try await postWebContentClick(
                button: button,
                target: target,
                point: point,
                count: count,
                stageObserver: stageObserver
            )
        case (.webContent, .drag(let button, let start, let end)):
            try await postWebContentDrag(
                button: button,
                target: target,
                start: start,
                end: end,
                stageObserver: stageObserver
            )
        }
    }

    private func postAppKitClick(
        button: BackgroundMouseButton,
        target: BackgroundMouseEventTarget,
        point: CGPoint,
        count: Int,
        stageObserver: BackgroundMouseEventPostObserver? = nil
    ) async throws {
        guard count > 0 else {
            throw ComputerUseError.mouseEventUnavailable("click count must be greater than 0")
        }
        let windowLocalPoint = target.windowLocalPoint(for: point)
        let move = try makeMouseEvent(
            type: .mouseMoved,
            windowId: target.windowId,
            clickCount: 0
        )

        try stamp(
            move,
            pid: target.pid,
            windowId: target.windowId,
            button: button,
            clickState: 0,
            mouseEventNumber: 2,
            screenPoint: point,
            windowLocalPoint: windowLocalPoint
        )

        try postPublic(move, pid: target.pid)
        try await stageObserver?(.afterMouseMoved)
        sleep(15_000)
        for clickState in 1...count {
            let down = try makeMouseEvent(
                type: button.downEventType,
                windowId: target.windowId,
                clickCount: clickState
            )
            let up = try makeMouseEvent(
                type: button.upEventType,
                windowId: target.windowId,
                clickCount: clickState
            )
            try stamp(
                down,
                pid: target.pid,
                windowId: target.windowId,
                button: button,
                clickState: clickState,
                mouseEventNumber: 3,
                screenPoint: point,
                windowLocalPoint: windowLocalPoint
            )
            try stamp(
                up,
                pid: target.pid,
                windowId: target.windowId,
                button: button,
                clickState: clickState,
                mouseEventNumber: 3,
                screenPoint: point,
                windowLocalPoint: windowLocalPoint
            )
            try postPublic(down, pid: target.pid)
            try await stageObserver?(.afterTargetDown)
            sleep(1_000)
            try postPublic(up, pid: target.pid)
            try await stageObserver?(.afterTargetUp)
        }
    }

    private func postWebContentClick(
        button: BackgroundMouseButton,
        target: BackgroundMouseEventTarget,
        point: CGPoint,
        count: Int,
        stageObserver: BackgroundMouseEventPostObserver? = nil
    ) async throws {
        guard count > 0 else {
            throw ComputerUseError.mouseEventUnavailable("click count must be greater than 0")
        }
        let primer = try makeWebContentPrimer(target: target)
        let targetWindowLocalPoint = target.windowLocalPoint(for: point)
        let gestureTimestamp = uptimeSeconds()

        let move = try makeMouseEvent(type: .mouseMoved, windowId: target.windowId, clickCount: 0)

        try stamp(
            move,
            pid: target.pid,
            windowId: target.windowId,
            button: button,
            clickState: 0,
            mouseEventNumber: 0,
            screenPoint: point,
            windowLocalPoint: targetWindowLocalPoint
        )
        try stampWebContentPrimer(primer, target: target)

        try postSkyLight(move, pid: target.pid, timestamp: gestureTimestamp)
        try await stageObserver?(.afterMouseMoved)
        try await postWebContentPrimer(primer, pid: target.pid, timestamp: gestureTimestamp, stageObserver: stageObserver)
        for clickState in 1...count {
            let targetDown = try makeMouseEvent(
                type: button.downEventType,
                windowId: target.windowId,
                clickCount: clickState
            )
            let targetUp = try makeMouseEvent(
                type: button.upEventType,
                windowId: target.windowId,
                clickCount: clickState
            )
            try stamp(
                targetDown,
                pid: target.pid,
                windowId: target.windowId,
                button: button,
                clickState: clickState,
                mouseEventNumber: 1,
                screenPoint: point,
                windowLocalPoint: targetWindowLocalPoint
            )
            try stamp(
                targetUp,
                pid: target.pid,
                windowId: target.windowId,
                button: button,
                clickState: clickState,
                mouseEventNumber: 1,
                screenPoint: point,
                windowLocalPoint: targetWindowLocalPoint
            )
            try postSkyLight(targetDown, pid: target.pid, timestamp: gestureTimestamp)
            try await stageObserver?(.afterTargetDown)
            sleep(1_000)
            try postSkyLight(targetUp, pid: target.pid, timestamp: gestureTimestamp)
            try await stageObserver?(.afterTargetUp)
        }
    }

    private func postWebContentDrag(
        button: BackgroundMouseButton,
        target: BackgroundMouseEventTarget,
        start: CGPoint,
        end: CGPoint,
        stageObserver: BackgroundMouseEventPostObserver? = nil
    ) async throws {
        let primer = try makeWebContentPrimer(target: target)
        let startWindowLocalPoint = target.windowLocalPoint(for: start)
        let endWindowLocalPoint = target.windowLocalPoint(for: end)
        let gestureTimestamp = uptimeSeconds()

        let move = try makeMouseEvent(type: .mouseMoved, windowId: target.windowId, clickCount: 0)
        let targetDown = try makeMouseEvent(type: button.downEventType, windowId: target.windowId, clickCount: 1)
        let targetDragged = try makeMouseEvent(type: button.draggedEventType, windowId: target.windowId, clickCount: 1)
        let targetUp = try makeMouseEvent(type: button.upEventType, windowId: target.windowId, clickCount: 1)

        try stamp(
            move,
            pid: target.pid,
            windowId: target.windowId,
            button: button,
            clickState: 0,
            mouseEventNumber: 0,
            screenPoint: start,
            windowLocalPoint: startWindowLocalPoint
        )
        try stampWebContentPrimer(primer, target: target)
        try stamp(
            targetDown,
            pid: target.pid,
            windowId: target.windowId,
            button: button,
            mouseEventNumber: 1,
            screenPoint: start,
            windowLocalPoint: startWindowLocalPoint
        )
        try stamp(
            targetDragged,
            pid: target.pid,
            windowId: target.windowId,
            button: button,
            mouseEventNumber: 4,
            screenPoint: end,
            windowLocalPoint: endWindowLocalPoint
        )
        try stamp(
            targetUp,
            pid: target.pid,
            windowId: target.windowId,
            button: button,
            mouseEventNumber: 4,
            screenPoint: end,
            windowLocalPoint: endWindowLocalPoint
        )

        try postSkyLight(move, pid: target.pid, timestamp: gestureTimestamp)
        try await stageObserver?(.afterMouseMoved)
        try await postWebContentPrimer(primer, pid: target.pid, timestamp: gestureTimestamp, stageObserver: stageObserver)
        try postSkyLight(targetDown, pid: target.pid, timestamp: gestureTimestamp)
        try await stageObserver?(.afterTargetDown)
        sleep(1_000)
        try postSkyLight(targetDragged, pid: target.pid, timestamp: gestureTimestamp)
        try await stageObserver?(.afterTargetDragged)
        sleep(1_000)
        try postSkyLight(targetUp, pid: target.pid, timestamp: gestureTimestamp)
        try await stageObserver?(.afterTargetUp)
    }

    private func makeWebContentPrimer(target: BackgroundMouseEventTarget) throws -> WebContentPrimer {
        let primerDown = try makeMouseEvent(type: .leftMouseDown, windowId: target.windowId, clickCount: 1)
        let primerUp = try makeMouseEvent(type: .leftMouseUp, windowId: target.windowId, clickCount: 1)
        return WebContentPrimer(
            down: primerDown,
            up: primerUp,
            screenPoint: CGPoint(
                x: target.windowBounds.x - 1,
                y: target.windowBounds.y + max(target.windowBounds.height - 1, 0)
            ),
            windowLocalPoint: CGPoint(x: -1, y: max(target.windowBounds.height - 1, 0))
        )
    }

    private func stampWebContentPrimer(
        _ primer: WebContentPrimer,
        target: BackgroundMouseEventTarget
    ) throws {
        try stamp(
            primer.down,
            pid: target.pid,
            windowId: target.windowId,
            button: .left,
            mouseEventNumber: 1,
            screenPoint: primer.screenPoint,
            windowLocalPoint: primer.windowLocalPoint
        )
        try stamp(
            primer.up,
            pid: target.pid,
            windowId: target.windowId,
            button: .left,
            mouseEventNumber: 2,
            screenPoint: primer.screenPoint,
            windowLocalPoint: primer.windowLocalPoint
        )
    }

    private func postWebContentPrimer(
        _ primer: WebContentPrimer,
        pid: pid_t,
        timestamp: CGEventTimestamp,
        stageObserver: BackgroundMouseEventPostObserver? = nil
    ) async throws {
        sleep(15_000)
        try postSkyLight(primer.down, pid: pid, timestamp: timestamp)
        try await stageObserver?(.afterPrimerDown)
        sleep(1_000)
        try postSkyLight(primer.up, pid: pid, timestamp: timestamp)
        try await stageObserver?(.afterPrimerUp)
        sleep(100_000)
        try await stageObserver?(.afterPrimerGap)
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
            throw ComputerUseError.mouseEventUnavailable("failed to create \(type) NSEvent")
        }
        guard let event = nsEvent.cgEvent else {
            throw ComputerUseError.mouseEventUnavailable("failed to bridge \(type) NSEvent to CGEvent")
        }
        return event
    }

    private func stamp(
        _ event: CGEvent,
        pid: pid_t,
        windowId: CGWindowID,
        button: BackgroundMouseButton,
        clickState: Int = 1,
        mouseEventNumber: Int64,
        screenPoint: CGPoint,
        windowLocalPoint: CGPoint
    ) throws {
        event.setIntegerValueField(.mouseEventButtonNumber, value: button.buttonNumber)
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        try stampWindowTarget(
            event,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: mouseEventNumber,
            screenPoint: screenPoint,
            windowLocalPoint: windowLocalPoint
        )
    }

    private func stampWindowTarget(
        _ event: CGEvent,
        pid: pid_t,
        windowId: CGWindowID,
        mouseEventNumber: Int64,
        screenPoint: CGPoint,
        windowLocalPoint: CGPoint
    ) throws {
        let rawWindowId = Int64(windowId)
        event.location = screenPoint
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: rawWindowId)
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: rawWindowId
        )
        try setWindowLocation(event, windowLocalPoint)
        try setIntegerField(event, 0, mouseEventNumber)
        try setIntegerField(event, 40, Int64(pid))
        try setIntegerField(event, 51, rawWindowId)
        try setIntegerField(event, 91, rawWindowId)
        try setIntegerField(event, 92, rawWindowId)
    }

    private func postPublic(_ event: CGEvent, pid: pid_t) throws {
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try postPublicEventToPID(event, pid)
    }

    private func postSkyLight(_ event: CGEvent, pid: pid_t, timestamp: CGEventTimestamp? = nil) throws {
        event.timestamp = timestamp ?? clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try postSkyLightEventToPID(event, pid)
    }
}

private struct WebContentPrimer {
    let down: CGEvent
    let up: CGEvent
    let screenPoint: CGPoint
    let windowLocalPoint: CGPoint
}

private extension BackgroundMouseButton {
    var buttonNumber: Int64 {
        switch self {
        case .left:
            return 0
        case .right:
            return 1
        }
    }

    var downEventType: NSEvent.EventType {
        switch self {
        case .left:
            return .leftMouseDown
        case .right:
            return .rightMouseDown
        }
    }

    var upEventType: NSEvent.EventType {
        switch self {
        case .left:
            return .leftMouseUp
        case .right:
            return .rightMouseUp
        }
    }

    var draggedEventType: NSEvent.EventType {
        switch self {
        case .left:
            return .leftMouseDragged
        case .right:
            return .rightMouseDragged
        }
    }
}

private typealias SLEventPostToPid = @convention(c) (pid_t, CGEvent) -> Void
private typealias CGEventSetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
private typealias SLEventSetIntegerValueField = @convention(c) (CGEvent, UInt32, Int64) -> Void

private struct SkyLightMouseEventPostSymbols {
    let postEventToPID: (CGEvent, pid_t) -> Void

    static func load() throws -> SkyLightMouseEventPostSymbols {
        let handles = try MouseEventPrivateFrameworkHandles.load()
        let postToPid: SLEventPostToPid = try handles.symbol("SLEventPostToPid")
        return SkyLightMouseEventPostSymbols(
            postEventToPID: { event, pid in postToPid(pid, event) }
        )
    }
}

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
            throw ComputerUseError.mouseEventUnavailable("failed to load private framework at \(path)")
        }
        guard let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) else {
            throw ComputerUseError.mouseEventUnavailable("failed to access RTLD_DEFAULT symbol scope")
        }
        return MouseEventPrivateFrameworkHandles(defaultHandle: defaultHandle)
    }

    func symbol<T>(_ name: String) throws -> T {
        if let pointer = dlsym(defaultHandle, name) {
            return unsafeBitCast(pointer, to: T.self)
        }
        throw ComputerUseError.mouseEventUnavailable("missing private symbol \(name)")
    }
}
