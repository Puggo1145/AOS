import ApplicationServices
import CoreGraphics
import Darwin

struct SkyLightWindowFocuser: Sendable {
    private static let eventRecordSize = 0xf8

    /// Makes a WindowServer window the key/focused window without changing
    /// its ordering. This mirrors yabai's CPS + synthetic-event path and
    /// intentionally never calls AXRaise or SLSOrderWindow.
    func focusWindowWithoutRaising(pid: pid_t, windowId: CGWindowID) throws {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.focusUnavailable(
                "Accessibility permission is required to post focus events without raising"
            )
        }

        let symbols = try SkyLightSymbols.load()

        var previousPSN = [UInt32](repeating: 0, count: 2)
        try previousPSN.withUnsafeMutableBytes { rawBuffer in
            try Self.assertStatus(
                symbols.getFrontProcess(rawBuffer.baseAddress!),
                "_SLPSGetFrontProcess failed"
            )
        }

        var targetPSN = [UInt32](repeating: 0, count: 2)
        try targetPSN.withUnsafeMutableBytes { rawBuffer in
            try Self.assertStatus(
                symbols.getProcessForPID(pid, rawBuffer.baseAddress!),
                "GetProcessForPID failed for pid \(pid)"
            )
        }

        try postFocusEvent(
            to: previousPSN,
            windowId: windowId,
            marker: .defocus,
            postEventRecordTo: symbols.postEventRecordTo
        )
        try postFocusEvent(
            to: targetPSN,
            windowId: windowId,
            marker: .focus,
            postEventRecordTo: symbols.postEventRecordTo
        )
    }

    private func postFocusEvent(
        to processSerialNumber: [UInt32],
        windowId: CGWindowID,
        marker: FocusEventMarker,
        postEventRecordTo: PostEventRecordTo
    ) throws {
        let eventBytes = Self.makeFocusEventBytes(windowId: windowId, marker: marker)
        try processSerialNumber.withUnsafeBytes { psnBuffer in
            try eventBytes.withUnsafeBufferPointer { eventBuffer in
                try Self.assertStatus(
                    postEventRecordTo(psnBuffer.baseAddress!, eventBuffer.baseAddress!),
                    "SLPSPostEventRecordTo failed for \(marker.description) event"
                )
            }
        }
    }

    enum FocusEventMarker: UInt8, Sendable {
        case focus = 0x01
        case defocus = 0x02

        var description: String {
            switch self {
            case .focus: return "focus"
            case .defocus: return "defocus"
            }
        }
    }

    static func makeFocusEventBytes(
        windowId: CGWindowID,
        marker: FocusEventMarker
    ) -> [UInt8] {
        var eventBytes = [UInt8](repeating: 0, count: eventRecordSize)
        eventBytes[0x04] = 0xf8
        eventBytes[0x08] = 0x0d
        eventBytes[0x8a] = marker.rawValue

        var rawWindowId = UInt32(windowId).littleEndian
        withUnsafeBytes(of: &rawWindowId) { rawBytes in
            for offset in rawBytes.indices {
                eventBytes[0x3c + offset] = rawBytes[offset]
            }
        }
        return eventBytes
    }
}

private typealias GetFrontProcess = @convention(c) (
    UnsafeMutableRawPointer
) -> OSStatus
private typealias GetProcessForPID = @convention(c) (
    pid_t,
    UnsafeMutableRawPointer
) -> OSStatus
private typealias PostEventRecordTo = @convention(c) (
    UnsafeRawPointer,
    UnsafePointer<UInt8>
) -> OSStatus

private struct SkyLightSymbols {
    let getFrontProcess: GetFrontProcess
    let getProcessForPID: GetProcessForPID
    let postEventRecordTo: PostEventRecordTo

    static func load() throws -> SkyLightSymbols {
        let handles = try PrivateFrameworkHandles.load()
        return SkyLightSymbols(
            getFrontProcess: try handles.symbol("_SLPSGetFrontProcess"),
            getProcessForPID: try handles.symbol("GetProcessForPID"),
            postEventRecordTo: try handles.symbol("SLPSPostEventRecordTo")
        )
    }
}

private extension SkyLightWindowFocuser {
    static func assertStatus(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else {
            throw ComputerUseError.focusUnavailable("\(message): OSStatus \(status)")
        }
    }
}

private struct PrivateFrameworkHandles {
    private let defaultHandle: UnsafeMutableRawPointer

    static func load() throws -> PrivateFrameworkHandles {
        let paths = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        ]
        for path in paths {
            guard dlopen(path, RTLD_LAZY) != nil else {
                throw ComputerUseError.focusUnavailable("failed to load private framework at \(path)")
            }
        }
        guard let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) else {
            throw ComputerUseError.focusUnavailable("failed to access RTLD_DEFAULT symbol scope")
        }
        return PrivateFrameworkHandles(defaultHandle: defaultHandle)
    }

    func symbol<T>(_ name: String) throws -> T {
        if let pointer = dlsym(defaultHandle, name) {
            return unsafeBitCast(pointer, to: T.self)
        }
        throw ComputerUseError.focusUnavailable("missing private symbol \(name)")
    }
}
