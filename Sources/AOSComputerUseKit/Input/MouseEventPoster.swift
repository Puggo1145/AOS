import AppKit
import CoreGraphics
import Darwin
import Foundation

public enum MouseClickPostStage: String, Sendable, Equatable {
    case afterMouseMoved
    case afterPrimerDown
    case afterPrimerUp
    case afterPrimerGap
    case afterTargetDown
    case afterTargetUp
}

public typealias MouseClickPostObserver = @Sendable (MouseClickPostStage) async throws -> Void

/// Mouse-event delivery route selected for a target process.
enum MouseClickDeliveryRoute: Sendable, Equatable {
    case appKit
    case chromiumElectron
}

/// Classifies targets that need the Chromium/Electron mouse delivery recipe.
struct MouseClickDeliveryClassifier: Sendable {
    typealias FileExists = @Sendable (String) -> Bool

    private let fileExists: FileExists

    init(fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) }) {
        self.fileExists = fileExists
    }

    func deliveryRoute(
        bundleIdentifier: String?,
        bundleURL: URL?
    ) -> MouseClickDeliveryRoute {
        if let bundleIdentifier,
           Self.chromiumFamilyBundleIdentifiers.contains(bundleIdentifier)
            || Self.knownElectronBundleIdentifiers.contains(bundleIdentifier)
        {
            return .chromiumElectron
        }

        if let bundleURL {
            let electronFrameworkPath = bundleURL
                .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
                .path
            if fileExists(electronFrameworkPath) {
                return .chromiumElectron
            }
        }

        return .appKit
    }

    private static let chromiumFamilyBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    private static let knownElectronBundleIdentifiers: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.discordapp.Discord",
        "notion.id",
        "com.figma.Desktop",
    ]
}

/// Posts pid-scoped mouse events through either the public AppKit route or the
/// Chromium/Electron SkyLight route.
///
/// Both routes construct NSEvent-bridged CGEvents, stamp window-local
/// coordinates and private SkyLight fields, and rely on the core to run the
/// active-state guard after observable post stages.
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

    func postLeftClick(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint,
        windowBounds: WindowBounds,
        deliveryRoute: MouseClickDeliveryRoute = .appKit,
        stageObserver: MouseClickPostObserver? = nil
    ) async throws {
        switch deliveryRoute {
        case .appKit:
            try await postAppKitLeftClick(
                pid: pid,
                windowId: windowId,
                point: point,
                windowBounds: windowBounds,
                stageObserver: stageObserver
            )
        case .chromiumElectron:
            try await postChromiumElectronLeftClick(
                pid: pid,
                windowId: windowId,
                point: point,
                windowBounds: windowBounds,
                stageObserver: stageObserver
            )
        }
    }

    private func postAppKitLeftClick(
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
            screenPoint: point,
            windowLocalPoint: windowLocalPoint
        )
        try stamp(
            down,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 3,
            screenPoint: point,
            windowLocalPoint: windowLocalPoint
        )
        try stamp(
            up,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 3,
            screenPoint: point,
            windowLocalPoint: windowLocalPoint
        )

        try postPublic(move, pid: pid)
        try await stageObserver?(.afterMouseMoved)
        sleep(15_000)
        try postPublic(down, pid: pid)
        try await stageObserver?(.afterTargetDown)
        sleep(1_000)
        try postPublic(up, pid: pid)
        try await stageObserver?(.afterTargetUp)
    }

    private func postChromiumElectronLeftClick(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint,
        windowBounds: WindowBounds,
        stageObserver: MouseClickPostObserver? = nil
    ) async throws {
        let targetWindowLocalPoint = CGPoint(
            x: point.x - windowBounds.x,
            y: point.y - windowBounds.y
        )
        let primerScreenPoint = CGPoint(
            x: windowBounds.x - 1,
            y: windowBounds.y + max(windowBounds.height - 1, 0)
        )
        let primerWindowLocalPoint = CGPoint(x: -1, y: max(windowBounds.height - 1, 0))
        let gestureTimestamp = uptimeSeconds()

        let move = try makeMouseEvent(type: .mouseMoved, windowId: windowId, clickCount: 0)
        let primerDown = try makeMouseEvent(type: .leftMouseDown, windowId: windowId, clickCount: 1)
        let primerUp = try makeMouseEvent(type: .leftMouseUp, windowId: windowId, clickCount: 1)
        let targetDown = try makeMouseEvent(type: .leftMouseDown, windowId: windowId, clickCount: 1)
        let targetUp = try makeMouseEvent(type: .leftMouseUp, windowId: windowId, clickCount: 1)

        try stamp(
            move,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 0,
            screenPoint: point,
            windowLocalPoint: targetWindowLocalPoint
        )
        try stamp(
            primerDown,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 1,
            screenPoint: primerScreenPoint,
            windowLocalPoint: primerWindowLocalPoint
        )
        try stamp(
            primerUp,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 2,
            screenPoint: primerScreenPoint,
            windowLocalPoint: primerWindowLocalPoint
        )
        try stamp(
            targetDown,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 1,
            screenPoint: point,
            windowLocalPoint: targetWindowLocalPoint
        )
        try stamp(
            targetUp,
            pid: pid,
            windowId: windowId,
            mouseEventNumber: 1,
            screenPoint: point,
            windowLocalPoint: targetWindowLocalPoint
        )

        try postSkyLight(move, pid: pid, timestamp: gestureTimestamp)
        try await stageObserver?(.afterMouseMoved)
        sleep(15_000)
        try postSkyLight(primerDown, pid: pid, timestamp: gestureTimestamp)
        try await stageObserver?(.afterPrimerDown)
        sleep(1_000)
        try postSkyLight(primerUp, pid: pid, timestamp: gestureTimestamp)
        try await stageObserver?(.afterPrimerUp)
        sleep(100_000)
        try await stageObserver?(.afterPrimerGap)
        try postSkyLight(targetDown, pid: pid, timestamp: gestureTimestamp)
        try await stageObserver?(.afterTargetDown)
        sleep(1_000)
        try postSkyLight(targetUp, pid: pid, timestamp: gestureTimestamp)
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
