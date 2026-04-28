import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

// MARK: - SkyLightEventPost
//
// Bridge to SkyLight's private per-pid event-post + focus-without-raise +
// window-local stamping SPIs. Per `docs/designs/computer-use.md`
// §"事件投递路径" the SPIs are resolved once via `dlopen` + `dlsym`,
// cached, and any missing symbol degrades the caller to the next layer.
// No entitlements required.
//
// Two-layer story for Chromium / Electron:
//
//   1. **Post path** — `SLEventPostToPid` wraps `SLEventPostToPSN` →
//      `CGSTickleActivityMonitor` → `SLSUpdateSystemActivityWithLocation`
//      → `IOHIDPostEvent`. The public `CGEventPostToPid` skips the
//      activity-monitor tickle, so events reach the target's mach port
//      but don't register as live input — Chromium's user-activation gate
//      ignores them.
//   2. **Authentication** — on macOS 14+, WindowServer gates synthetic
//      keyboard events against Chromium-like targets on an attached
//      `SLSEventAuthenticationMessage`. Mouse events deliberately skip
//      the envelope: attaching it forks `SLEventPostToPid` onto a
//      direct-mach delivery path that bypasses the
//      `cgAnnotatedSessionEventTap` Chromium subscribes to. See the
//      `attachAuthMessage` doc on `postToPid` for the fully-traced
//      reasoning.
public enum SkyLightEventPost {
    // MARK: - Function-pointer typedefs

    /// `void SLEventPostToPid(pid_t, CGEventRef)`
    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
    /// `void SLEventSetAuthenticationMessage(CGEventRef, id)`
    private typealias SetAuthMessageFn = @convention(c) (CGEvent, AnyObject) -> Void
    /// `void SLEventSetIntegerValueField(CGEventRef, uint32_t, int64_t)`.
    /// Reaches the private SkyLight raw-field indexes (f0/f3/f7/f51/f58/f91/f92)
    /// the public `CGEventSetIntegerValueField` rejects. Required by the
    /// 5-event background click recipe — Chromium consults f51/f91/f92
    /// (per-session stamp candidates) on the inbound side.
    private typealias SetIntFieldFn = @convention(c) (CGEvent, UInt32, Int64) -> Void
    /// `CGSConnectionID CGSMainConnectionID(void)` — Skylight's main
    /// connection handle for the current process. Source for the per-session
    /// id stamped into mouse-event fields f51/f91/f92.
    private typealias ConnectionIDFn = @convention(c) () -> UInt32
    /// `void CGEventSetWindowLocation(CGEventRef, CGPoint)` — stamps a
    /// window-local point onto the event so WindowServer's hit-test uses
    /// it directly instead of re-projecting from screen space.
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
    /// `objc_msgSend` specialised for
    /// `+[SLSEventAuthenticationMessage messageWithEventRecord:pid:version:]`:
    /// `(Class, SEL, SLSEventRecord *, int32_t, uint32_t) -> id`.
    private typealias FactoryMsgSendFn = @convention(c) (
        AnyObject, Selector, UnsafeMutableRawPointer, Int32, UInt32
    ) -> AnyObject?

    /// `OSStatus SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes)`.
    /// Posts a 248-byte synthetic event record into the target process's
    /// Carbon event queue. Used by the focus-without-raise recipe.
    private typealias PostEventRecordToFn = @convention(c) (
        UnsafeRawPointer, UnsafePointer<UInt8>
    ) -> Int32
    /// `OSStatus _SLPSGetFrontProcess(ProcessSerialNumber *psn)`.
    private typealias GetFrontProcessFn = @convention(c) (
        UnsafeMutableRawPointer
    ) -> Int32
    /// `OSStatus GetProcessForPID(pid_t, ProcessSerialNumber *)`.
    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t, UnsafeMutableRawPointer
    ) -> Int32

    /// `CGError SLSGetActiveSpace(CGSConnectionID, uint64_t *spaceID)`.
    private typealias GetActiveSpaceFn = @convention(c) (UInt32, UnsafeMutablePointer<UInt64>) -> Int32
    /// `CFArrayRef SLSCopySpacesForWindows(CGSConnectionID, int mask, CFArrayRef windowIDs)`.
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?

    // MARK: - dlopen helper

    /// Resolves `name` in the SkyLight framework. SkyLight is `dlopen`'d
    /// once with `RTLD_LAZY` so its symbols + ObjC classes are guaranteed
    /// resident even on processes that don't link it transitively. The
    /// symbol lookup uses `RTLD_DEFAULT` (`bitPattern: -2`) — that way any
    /// caller who already linked the framework directly is also covered.
    private static let skylightHandle: UnsafeMutableRawPointer? = {
        return dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
    }()

    private static func resolve<T>(_ name: String, as _: T.Type) -> T? {
        _ = skylightHandle  // touch the lazy to ensure dlopen ran
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(p, to: T.self)
    }

    // MARK: - Resolved handles

    private struct AuthSignedPostResolved {
        let postToPid: PostToPidFn
        let setAuthMessage: SetAuthMessageFn
        let msgSendFactory: FactoryMsgSendFn
        let messageClass: AnyClass
        let factorySelector: Selector
    }

    private static let authSignedPost: AuthSignedPostResolved? = {
        guard
            let postToPid = resolve("SLEventPostToPid", as: PostToPidFn.self),
            let setAuth = resolve("SLEventSetAuthenticationMessage", as: SetAuthMessageFn.self),
            let msgSend = resolve("objc_msgSend", as: FactoryMsgSendFn.self),
            let messageClass = NSClassFromString("SLSEventAuthenticationMessage")
        else { return nil }
        return AuthSignedPostResolved(
            postToPid: postToPid,
            setAuthMessage: setAuth,
            msgSendFactory: msgSend,
            messageClass: messageClass,
            factorySelector: NSSelectorFromString("messageWithEventRecord:pid:version:")
        )
    }()

    /// `SLEventPostToPid` resolved alone — needed for the mouse path that
    /// posts without the auth envelope. Distinct from the
    /// `authSignedPost` bundle so that a missing
    /// `SLSEventAuthenticationMessage` class does not also disable the
    /// unsigned post path.
    private static let postToPidFn: PostToPidFn? = resolve("SLEventPostToPid", as: PostToPidFn.self)
    private static let setIntFieldFn: SetIntFieldFn? = resolve("SLEventSetIntegerValueField", as: SetIntFieldFn.self)
    private static let connectionIDFn: ConnectionIDFn? = resolve("CGSMainConnectionID", as: ConnectionIDFn.self)
    private static let setWindowLocationFn: SetWindowLocationFn? = resolve("CGEventSetWindowLocation", as: SetWindowLocationFn.self)
    private static let postEventRecordToFn: PostEventRecordToFn? = resolve("SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
    private static let getFrontProcessFn: GetFrontProcessFn? = resolve("_SLPSGetFrontProcess", as: GetFrontProcessFn.self)
    private static let getProcessForPIDFn: GetProcessForPIDFn? = resolve("GetProcessForPID", as: GetProcessForPIDFn.self)
    private static let getActiveSpaceFn: GetActiveSpaceFn? = resolve("SLSGetActiveSpace", as: GetActiveSpaceFn.self)
    private static let copySpacesForWindowsFn: CopySpacesForWindowsFn? = resolve("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)

    // MARK: - Availability flags (consumed by `doctor`)

    /// Aggregate availability of every SPI consumed by the Kit. Wired
    /// straight into the `computerUse.doctor` response so the agent /
    /// onboarding flow can preflight before issuing any operation.
    public struct Availability: Sendable, Equatable {
        public let postToPid: Bool
        public let authMessage: Bool
        public let focusWithoutRaise: Bool
        public let windowLocation: Bool
        public let spaces: Bool
    }

    public static var availability: Availability {
        Availability(
            postToPid: postToPidFn != nil,
            authMessage: authSignedPost != nil,
            focusWithoutRaise:
                getFrontProcessFn != nil
                && getProcessForPIDFn != nil
                && postEventRecordToFn != nil,
            windowLocation: setWindowLocationFn != nil,
            spaces: getActiveSpaceFn != nil && copySpacesForWindowsFn != nil
        )
    }

    public static var isAuthSignedPostAvailable: Bool { authSignedPost != nil }
    public static var isFocusWithoutRaiseAvailable: Bool {
        getFrontProcessFn != nil && getProcessForPIDFn != nil && postEventRecordToFn != nil
    }
    public static var isWindowLocationAvailable: Bool { setWindowLocationFn != nil }
    public static var isSpacesAvailable: Bool { getActiveSpaceFn != nil && copySpacesForWindowsFn != nil }

    // MARK: - Post

    /// Post `event` to `pid` via `SLEventPostToPid`.
    ///
    /// `attachAuthMessage` controls whether an `SLSEventAuthenticationMessage`
    /// is attached before posting:
    ///
    /// - `true` (keyboard path): attaches the auth envelope so Chromium
    ///   accepts synthetic keyboard events as trusted input on macOS 14+.
    /// - `false` (mouse path): skips the envelope so the event routes via
    ///   `SLEventPostToPid → SLEventPostToPSN → IOHIDPostEvent` and flows
    ///   through the `cgAnnotatedSessionEventTap` pipeline that Chromium's
    ///   window event handler subscribes to. Attaching the message forks
    ///   the post onto a direct-mach delivery path that bypasses the tap
    ///   — verified by comparing tap streams with/without the envelope.
    ///
    /// Returns `true` when the SPI resolved and the post was attempted;
    /// `false` when anything in the chain is missing (caller falls back
    /// to `CGEvent.postToPid`).
    @discardableResult
    public static func postToPid(
        _ pid: pid_t, event: CGEvent, attachAuthMessage: Bool = true
    ) -> Bool {
        if attachAuthMessage {
            guard let r = authSignedPost else { return false }
            if let record = extractEventRecord(from: event),
               let msg = r.msgSendFactory(
                   r.messageClass as AnyObject,
                   r.factorySelector,
                   record,
                   pid,
                   0
               )
            {
                r.setAuthMessage(event, msg)
            }
            // On nil auth message we still attempt the post — the unsigned
            // path is valid on older OS releases and worth a try before the
            // public-API fallback.
            r.postToPid(pid, event)
            return true
        } else {
            guard let fn = postToPidFn else { return false }
            fn(pid, event)
            return true
        }
    }

    /// Stamp `value` onto `event` at the raw SkyLight field index `field`.
    /// Returns `false` when the SPI didn't resolve.
    @discardableResult
    public static func setIntegerField(
        _ event: CGEvent, field: UInt32, value: Int64
    ) -> Bool {
        guard let fn = setIntFieldFn else { return false }
        fn(event, field, value)
        return true
    }

    /// SkyLight main connection ID for the current process — the per-session
    /// stamp candidate consumed by mouse-event fields f51/f91/f92.
    public static var mainConnectionID: UInt32? {
        guard let fn = connectionIDFn else { return nil }
        return fn()
    }

    /// Stamp a window-local `point` onto `event`. Caller still sets the
    /// screen-space location via `CGEventSetLocation`; the window-local
    /// stamp is what WindowServer hit-tests against on the post.
    @discardableResult
    public static func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        guard let fn = setWindowLocationFn else { return false }
        fn(event, point)
        return true
    }

    // MARK: - Focus-without-raise SPIs

    /// Copy the current frontmost process's PSN into the provided 8-byte
    /// buffer. `false` when `_SLPSGetFrontProcess` isn't resolvable.
    public static func getFrontProcess(_ psnBuffer: UnsafeMutableRawPointer) -> Bool {
        guard let fn = getFrontProcessFn else { return false }
        return fn(psnBuffer) == 0
    }

    /// Resolve `pid` to its PSN via `GetProcessForPID`, writing 8 bytes
    /// into `psnBuffer`. `false` when the SPI isn't resolvable or the call
    /// failed.
    public static func getProcessPSN(forPid pid: pid_t, into psnBuffer: UnsafeMutableRawPointer) -> Bool {
        guard let fn = getProcessForPIDFn else { return false }
        return fn(pid, psnBuffer) == 0
    }

    /// Post a 248-byte synthetic event record via `SLPSPostEventRecordTo`.
    /// Caller is responsible for building the buffer with the correct
    /// focus/defocus marker and target window id (see `FocusWithoutRaise`).
    @discardableResult
    public static func postEventRecordTo(
        psn: UnsafeRawPointer, bytes: UnsafePointer<UInt8>
    ) -> Bool {
        guard let fn = postEventRecordToFn else { return false }
        return fn(psn, bytes) == 0
    }

    // MARK: - Spaces

    /// Active Space ID (the user's currently-foregrounded Mission Control
    /// Space). `nil` when the SPI didn't resolve or returned non-zero.
    public static func activeSpaceID() -> UInt64? {
        guard let fn = getActiveSpaceFn, let cid = connectionIDFn?() else { return nil }
        var spaceID: UInt64 = 0
        let result = fn(cid, &spaceID)
        return result == 0 ? spaceID : nil
    }

    /// Space IDs the given window is associated with. A window may be tied
    /// to multiple Spaces (sticky windows, all-Spaces apps); `currentSpaceID()`
    /// must be checked against this set.
    public static func spaceIDs(forWindow windowID: CGWindowID) -> [UInt64] {
        guard let fn = copySpacesForWindowsFn, let cid = connectionIDFn?() else { return [] }
        // Mask 0x07: union of user/system/visible Space sets — yabai's choice
        // for "every Space the window is currently a member of".
        let array = [UInt32(windowID)] as CFArray
        guard let cfArray = fn(cid, 0x07, array)?.takeRetainedValue() else { return [] }
        let count = CFArrayGetCount(cfArray)
        var ids: [UInt64] = []
        ids.reserveCapacity(count)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cfArray, i) else { continue }
            // Each array element is a CFNumber wrapping the space id.
            let cfNumber = unsafeBitCast(raw, to: CFNumber.self)
            var value: UInt64 = 0
            if CFNumberGetValue(cfNumber, .sInt64Type, &value) {
                ids.append(value)
            }
        }
        return ids
    }

    // MARK: - Internals

    /// Extract the embedded `SLSEventRecord *` from a `CGEvent`. The
    /// layout exposed by SkyLight's ObjC type encodings is
    /// `{CFRuntimeBase, uint32_t, SLSEventRecord *}` — on 64-bit that puts
    /// the record pointer at offset 24 (CFRuntimeBase=16 + uint32=4 + 4
    /// bytes of pointer-alignment padding). We probe a few adjacent
    /// offsets for resilience across OS revisions.
    private static func extractEventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset).assumingMemoryBound(
                to: UnsafeMutableRawPointer?.self)
            if let p = slot.pointee { return p }
        }
        return nil
    }
}
