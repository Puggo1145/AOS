import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation

public struct WindowOrderObservationRequest: Sendable, Equatable {
    public let pid: pid_t
    public let windowId: CGWindowID
    public let durationMilliseconds: Int
    public let intervalMilliseconds: Int

    public init(
        pid: pid_t,
        windowId: CGWindowID,
        durationMilliseconds: Int,
        intervalMilliseconds: Int
    ) {
        self.pid = pid
        self.windowId = windowId
        self.durationMilliseconds = durationMilliseconds
        self.intervalMilliseconds = intervalMilliseconds
    }
}

public protocol WindowOrderObservationClient: Sendable {
    func observe(_ request: WindowOrderObservationRequest) async throws -> [WindowOrderObservationSample]
}

public enum MouseEventTapLocation: String, Sendable, Equatable, Encodable {
    case hid
    case session
    case annotated
    case all

    fileprivate var observedLocations: [MouseEventTapLocation] {
        switch self {
        case .hid, .session, .annotated:
            return [self]
        case .all:
            return [.hid, .session, .annotated]
        }
    }

    fileprivate var cgEventTapLocation: CGEventTapLocation {
        switch self {
        case .hid:
            return .cghidEventTap
        case .session:
            return .cgSessionEventTap
        case .annotated:
            return .cgAnnotatedSessionEventTap
        case .all:
            preconditionFailure("all is not a concrete CGEvent tap location")
        }
    }
}

public struct MouseEventObservationRequest: Sendable, Equatable {
    public let pid: pid_t?
    public let windowId: CGWindowID?
    public let durationMilliseconds: Int
    public let tapLocation: MouseEventTapLocation

    public init(
        pid: pid_t?,
        windowId: CGWindowID?,
        durationMilliseconds: Int,
        tapLocation: MouseEventTapLocation = .all
    ) {
        self.pid = pid
        self.windowId = windowId
        self.durationMilliseconds = durationMilliseconds
        self.tapLocation = tapLocation
    }
}

public struct MouseEventObservationSample: Sendable, Equatable, Encodable {
    public let tapLocation: MouseEventTapLocation
    public let elapsedNanoseconds: UInt64
    public let typeRawValue: UInt32
    public let typeName: String
    public let location: CGPoint
    public let sourcePID: pid_t
    public let targetPID: pid_t
    public let buttonNumber: Int64
    public let clickState: Int64
    public let subtype: Int64
    public let windowUnderMousePointer: Int64
    public let windowUnderMousePointerThatCanHandleThisEvent: Int64
    public let rawField0: Int64
    public let rawField40: Int64
    public let rawField51: Int64
    public let rawField58: Int64
    public let rawField91: Int64
    public let rawField92: Int64
    public let matchesRequestedTarget: Bool

    public init(
        tapLocation: MouseEventTapLocation,
        elapsedNanoseconds: UInt64,
        typeRawValue: UInt32,
        typeName: String,
        location: CGPoint,
        sourcePID: pid_t,
        targetPID: pid_t,
        buttonNumber: Int64,
        clickState: Int64,
        subtype: Int64,
        windowUnderMousePointer: Int64,
        windowUnderMousePointerThatCanHandleThisEvent: Int64,
        rawField0: Int64,
        rawField40: Int64,
        rawField51: Int64,
        rawField58: Int64,
        rawField91: Int64,
        rawField92: Int64,
        matchesRequestedTarget: Bool
    ) {
        self.tapLocation = tapLocation
        self.elapsedNanoseconds = elapsedNanoseconds
        self.typeRawValue = typeRawValue
        self.typeName = typeName
        self.location = location
        self.sourcePID = sourcePID
        self.targetPID = targetPID
        self.buttonNumber = buttonNumber
        self.clickState = clickState
        self.subtype = subtype
        self.windowUnderMousePointer = windowUnderMousePointer
        self.windowUnderMousePointerThatCanHandleThisEvent = windowUnderMousePointerThatCanHandleThisEvent
        self.rawField0 = rawField0
        self.rawField40 = rawField40
        self.rawField51 = rawField51
        self.rawField58 = rawField58
        self.rawField91 = rawField91
        self.rawField92 = rawField92
        self.matchesRequestedTarget = matchesRequestedTarget
    }
}

public protocol MouseEventObservationClient: Sendable {
    func observe(_ request: MouseEventObservationRequest) async throws -> [MouseEventObservationSample]
}

public struct LiveWindowOrderObservationClient: WindowOrderObservationClient {
    private let diagnostics: ComputerUseDiagnosticsClient

    public init(diagnostics: ComputerUseDiagnosticsClient) {
        self.diagnostics = diagnostics
    }

    public func observe(_ request: WindowOrderObservationRequest) async throws -> [WindowOrderObservationSample] {
        try await diagnostics.observeWindowOrder(
            pid: request.pid,
            windowId: request.windowId,
            durationMilliseconds: request.durationMilliseconds,
            intervalMilliseconds: request.intervalMilliseconds
        )
    }
}

public struct LiveMouseEventObservationClient: MouseEventObservationClient {
    public init() {}

    public func observe(_ request: MouseEventObservationRequest) async throws -> [MouseEventObservationSample] {
        try MouseEventTapRecorder(request: request).observe()
    }
}

/// Listen-only mouse event tap used to compare AOS and Codex event stamps.
/// It deliberately records raw fields instead of interpreting them so browser
/// delivery diagnostics can fail loudly when the event path changes.
private final class MouseEventTapRecorder {
    private static let observedTypes: [CGEventType] = [
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged,
        .scrollWheel,
    ]

    private let request: MouseEventObservationRequest
    private let startNanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    private let lock = NSLock()
    private var samples: [MouseEventObservationSample] = []

    init(request: MouseEventObservationRequest) {
        self.request = request
    }

    func observe() throws -> [MouseEventObservationSample] {
        let mask = Self.observedTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
        let activeTaps = try request.tapLocation.observedLocations.map { location in
            try makeTap(location: location, mask: mask)
        }

        let runLoop = CFRunLoopGetCurrent()
        for activeTap in activeTaps {
            CFRunLoopAddSource(runLoop, activeTap.source, .commonModes)
            CGEvent.tapEnable(tap: activeTap.tap, enable: true)
        }
        defer {
            for activeTap in activeTaps {
                CGEvent.tapEnable(tap: activeTap.tap, enable: false)
                CFRunLoopRemoveSource(runLoop, activeTap.source, .commonModes)
                activeTap.context.release()
            }
        }

        runLoopUntilDeadline()

        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func makeTap(location: MouseEventTapLocation, mask: CGEventMask) throws -> ActiveMouseEventTap {
        let context = Unmanaged.passRetained(MouseEventTapContext(recorder: self, tapLocation: location))
        guard let tap = CGEvent.tapCreate(
            tap: location.cgEventTapLocation,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: context.toOpaque()
        ) else {
            context.release()
            throw MouseEventObservationError(
                "failed to create \(location.rawValue) mouse event tap; grant Accessibility/Input Monitoring to the terminal running AOSComputerUseCLI"
            )
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            context.release()
            throw MouseEventObservationError("failed to create run loop source for \(location.rawValue) mouse event tap")
        }

        return ActiveMouseEventTap(tap: tap, source: source, context: context)
    }

    private func runLoopUntilDeadline() {
        let duration = TimeInterval(request.durationMilliseconds) / 1_000
        let deadline = Date().addingTimeInterval(duration)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return
            }
            CFRunLoopRunInMode(.defaultMode, min(remaining, 0.05), false)
        }
    }

    private func record(tapLocation: MouseEventTapLocation, type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return
        }

        let sample = makeSample(tapLocation: tapLocation, type: type, event: event)
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    private func makeSample(tapLocation: MouseEventTapLocation, type: CGEventType, event: CGEvent) -> MouseEventObservationSample {
        let sourcePID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let windowUnderMousePointer = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let windowUnderMousePointerThatCanHandleThisEvent = event.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        let rawField0 = Self.rawField(event, 0)
        let rawField40 = Self.rawField(event, 40)
        let rawField51 = Self.rawField(event, 51)
        let rawField58 = Self.rawField(event, 58)
        let rawField91 = Self.rawField(event, 91)
        let rawField92 = Self.rawField(event, 92)
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNanoseconds
        let matchesPID = request.pid.map {
            sourcePID == $0 || targetPID == $0 || rawField40 == Int64($0)
        } ?? true
        let matchesWindow = request.windowId.map {
            let rawWindowID = Int64($0)
            return windowUnderMousePointer == rawWindowID
                || windowUnderMousePointerThatCanHandleThisEvent == rawWindowID
                || rawField51 == rawWindowID
                || rawField91 == rawWindowID
                || rawField92 == rawWindowID
        } ?? true

        return MouseEventObservationSample(
            tapLocation: tapLocation,
            elapsedNanoseconds: elapsed,
            typeRawValue: UInt32(type.rawValue),
            typeName: Self.name(for: type),
            location: event.location,
            sourcePID: sourcePID,
            targetPID: targetPID,
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            clickState: event.getIntegerValueField(.mouseEventClickState),
            subtype: event.getIntegerValueField(.mouseEventSubtype),
            windowUnderMousePointer: windowUnderMousePointer,
            windowUnderMousePointerThatCanHandleThisEvent: windowUnderMousePointerThatCanHandleThisEvent,
            rawField0: rawField0,
            rawField40: rawField40,
            rawField51: rawField51,
            rawField58: rawField58,
            rawField91: rawField91,
            rawField92: rawField92,
            matchesRequestedTarget: matchesPID && matchesWindow
        )
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let context = Unmanaged<MouseEventTapContext>.fromOpaque(refcon).takeUnretainedValue()
        context.recorder.record(tapLocation: context.tapLocation, type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private static func rawField(_ event: CGEvent, _ field: UInt32) -> Int64 {
        guard let eventField = CGEventField(rawValue: field) else {
            preconditionFailure("invalid CGEventField raw value \(field)")
        }
        return event.getIntegerValueField(eventField)
    }

    private static func name(for type: CGEventType) -> String {
        switch type {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .mouseMoved: return "mouseMoved"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        case .scrollWheel: return "scrollWheel"
        default: return "event-\(type.rawValue)"
        }
    }
}

private struct ActiveMouseEventTap {
    let tap: CFMachPort
    let source: CFRunLoopSource
    let context: Unmanaged<MouseEventTapContext>
}

private final class MouseEventTapContext {
    let recorder: MouseEventTapRecorder
    let tapLocation: MouseEventTapLocation

    init(recorder: MouseEventTapRecorder, tapLocation: MouseEventTapLocation) {
        self.recorder = recorder
        self.tapLocation = tapLocation
    }
}

private struct MouseEventObservationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}
