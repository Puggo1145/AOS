import ApplicationServices
import CoreGraphics
import Darwin

/// Prepares a WindowServer window for pid-routed input without raising it,
/// without triggering Space follow, and without deactivating any other
/// process's currently active window.
///
/// Background — why we diverge from yabai's
/// `window_manager_focus_window_without_raise`:
///
/// yabai posts a `focus` event-record with marker `0x02` (defocus) to the
/// *previously* focused PSN when switching windows inside the same app, and
/// then relies on `_SLPSSetFrontProcessWithOptions(kCPSUserGenerated)` to
/// re-key the new front app for cross-app switches. AOS intentionally skips
/// `_SLPSSetFrontProcessWithOptions` because both of its useful flags either
/// raise the window / follow Space (`kCPSUserGenerated`) or break input
/// activation gates in apps like Chrome (`kCPSNoWindows`).
///
/// In our previous implementation we still posted the defocus event to the
/// previous front PSN unconditionally. That single event is what flipped the
/// user's original window from active to inactive: it tells WindowServer the
/// previous front lost focus, without anything coming back to re-key it.
/// WindowServer is otherwise perfectly willing to hold two cross-app windows
/// in an active key-window state at once (the user can verify this by
/// manually clicking back into the original window after a raise; both
/// windows then sit in an active state simultaneously).
///
/// Therefore this focuser:
///   - Never resolves the previous front process and never posts any event
///     against it. The previous window keeps its key/active state.
///   - Posts only target-side records:
///       1. `focus` event-record (marker `0x01`)
///       2. `key-window begin` event-record
///       3. `key-window end` event-record
///   - Keeps the target-side `defocus` event as a low-level diagnostic
///     primitive. `ComputerUseCore` does not use it for app-session cleanup:
///     live validation showed it can leave the user-facing target window
///     unable to recover normal mouse interaction after the session ends.
///   - Still deliberately omits `_SLPSSetFrontProcessWithOptions`,
///     `AXRaise`, and `SLSOrderWindow`.
struct SkyLightWindowFocuser: Sendable {
    /// Pair of `UInt32`s matching the WindowServer / HIServices
    /// `ProcessSerialNumber` struct (high, low).
    typealias ProcessSerialNumber = [UInt32]
    typealias ResolveProcessPSN = @Sendable (pid_t) throws -> ProcessSerialNumber
    typealias PostEventRecord = @Sendable (ProcessSerialNumber, [UInt8]) throws -> Void

    private static let eventRecordSize = 0xf8

    private let resolveProcessPSN: ResolveProcessPSN
    private let postEventRecord: PostEventRecord

    init(
        resolveProcessPSN: @escaping ResolveProcessPSN,
        postEventRecord: @escaping PostEventRecord
    ) {
        self.resolveProcessPSN = resolveProcessPSN
        self.postEventRecord = postEventRecord
    }

    /// Production wiring backed by the private SkyLight / HIServices
    /// symbols. dlsym resolution is lazy: it happens on the first focus call,
    /// and the OS caches the handle for subsequent ones.
    static func live() -> SkyLightWindowFocuser {
        SkyLightWindowFocuser(
            resolveProcessPSN: { pid in try liveResolveProcessPSN(pid) },
            postEventRecord: { psn, bytes in try livePostEventRecord(psn, bytes) }
        )
    }

    func focusWindowWithoutRaising(pid: pid_t, windowId: CGWindowID) throws {
        let targetPSN = try resolveProcessPSN(pid)
        try postEventRecord(targetPSN, Self.makeFocusEventBytes(windowId: windowId))
        try postEventRecord(
            targetPSN,
            Self.makeKeyWindowEventBytes(windowId: windowId, phase: .begin)
        )
        try postEventRecord(
            targetPSN,
            Self.makeKeyWindowEventBytes(windowId: windowId, phase: .end)
        )
    }

    func deactivateWindowWithoutRaising(pid: pid_t, windowId: CGWindowID) throws {
        let targetPSN = try resolveProcessPSN(pid)
        try postEventRecord(
            targetPSN,
            Self.makeFocusEventBytes(windowId: windowId, marker: .defocus)
        )
    }

    /// SLPS focus event-record. AOS only posts the target-side `.focus`
    /// marker from app-session business paths. `.defocus` remains available
    /// for diagnostics; posting it to another PSN deactivates the user's
    /// current window, and posting it to the target at session end can leave
    /// that target stuck inactive for real user input.
    static func makeFocusEventBytes(
        windowId: CGWindowID,
        marker: FocusEventMarker = .focus
    ) -> [UInt8] {
        var eventBytes = [UInt8](repeating: 0, count: eventRecordSize)
        eventBytes[0x04] = 0xf8
        eventBytes[0x08] = 0x0d
        eventBytes[0x8a] = marker.rawValue
        writeWindowId(windowId, into: &eventBytes)
        return eventBytes
    }

    enum FocusEventMarker: UInt8, Sendable {
        case focus = 0x01
        case defocus = 0x02
    }

    enum KeyWindowEventPhase: UInt8, Sendable {
        case begin = 0x01
        case end = 0x02
    }

    /// SLPS key-window event-record, target-side only. This complements the
    /// focus marker for AppKit windows whose active chrome does not update
    /// from the focus record alone.
    static func makeKeyWindowEventBytes(
        windowId: CGWindowID,
        phase: KeyWindowEventPhase
    ) -> [UInt8] {
        var eventBytes = [UInt8](repeating: 0, count: eventRecordSize)
        eventBytes[0x04] = 0xf8
        eventBytes[0x08] = phase.rawValue
        eventBytes[0x3a] = 0x10
        for offset in 0x20..<0x30 {
            eventBytes[offset] = 0xff
        }
        writeWindowId(windowId, into: &eventBytes)
        return eventBytes
    }

    private static func writeWindowId(_ windowId: CGWindowID, into eventBytes: inout [UInt8]) {
        var rawWindowId = UInt32(windowId).littleEndian
        withUnsafeBytes(of: &rawWindowId) { rawBytes in
            for offset in rawBytes.indices {
                eventBytes[0x3c + offset] = rawBytes[offset]
            }
        }
    }
}

// MARK: - Live symbol bindings

private typealias GetProcessForPID = @convention(c) (
    pid_t,
    UnsafeMutableRawPointer
) -> OSStatus
private typealias PostEventRecordTo = @convention(c) (
    UnsafeRawPointer,
    UnsafePointer<UInt8>
) -> OSStatus
private struct SkyLightSymbols {
    let getProcessForPID: GetProcessForPID
    let postEventRecordTo: PostEventRecordTo

    static func load() throws -> SkyLightSymbols {
        let handles = try PrivateFrameworkHandles.load()
        return SkyLightSymbols(
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

    static func liveResolveProcessPSN(_ pid: pid_t) throws -> ProcessSerialNumber {
        let symbols = try SkyLightSymbols.load()
        var psn = ProcessSerialNumber(repeating: 0, count: 2)
        try psn.withUnsafeMutableBytes { rawBuffer in
            try assertStatus(
                symbols.getProcessForPID(pid, rawBuffer.baseAddress!),
                "GetProcessForPID failed for pid \(pid)"
            )
        }
        return psn
    }

    static func livePostEventRecord(
        _ psn: ProcessSerialNumber,
        _ bytes: [UInt8]
    ) throws {
        let symbols = try SkyLightSymbols.load()
        try psn.withUnsafeBytes { psnBuffer in
            try bytes.withUnsafeBufferPointer { eventBuffer in
                try assertStatus(
                    symbols.postEventRecordTo(psnBuffer.baseAddress!, eventBuffer.baseAddress!),
                    "SLPSPostEventRecordTo failed"
                )
            }
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
