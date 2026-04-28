import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - ComputerUseService
//
// Public façade per `docs/designs/computer-use.md` §"模块结构". Single
// in-process actor that orchestrates Focus + Input + Capture + Snapshot +
// Cache. Shell `ComputerUseHandlers` wraps this 1:1 with JSON-RPC
// methods.
//
// The service owns the long-lived collaborators (FocusGuard, snapshot
// cache, AX observers) so per-method handlers in the Shell stay
// stateless and concurrency-safe. The `walkOnMain` helper isolates the
// AccessibilitySnapshot run-loop pump on the Shell's main runloop —
// Chromium AX activation requires the observer to be attached to a
// CFRunLoop that's actively spinning, and the Shell's main loop is
// the only one in this process that fits.
//
// Operation degradation chain (per §"操作降级链路") is implemented in
// `clickByElement`: AX action → AX attribute → directed event posting,
// each layer gated by `FocusGuard.withFocusSuppressed`.

public struct AppStateBundle: Sendable {
    public let stateId: StateID?
    public let treeMarkdown: String?
    public let elementCount: Int?
    public let screenshot: Screenshot?
    public let bundleId: String?
    public let appName: String?
}

public enum CaptureMode: String, Sendable, Equatable {
    case som    // AX tree + screenshot (default)
    case vision // screenshot only — no AX permission required
    case ax     // AX tree only — no Screen Recording permission required
}

public enum ComputerUseError: Error, CustomStringConvertible, Sendable {
    /// `ownerPid` is the actual `(pid, windowId)` ownership conflict
    /// (CGWindowList disagrees with the caller's pid). `expectedWindowId`
    /// is the StateCache-side conflict — the supplied stateId belongs
    /// to a different window than the request targeted; both fields can
    /// be set when the source is the cache, only `ownerPid` when the
    /// source is `validateOwnership`.
    case windowMismatch(pid: pid_t, windowId: CGWindowID, ownerPid: pid_t?, expectedWindowId: CGWindowID?)
    case windowOffSpace(currentSpaceID: UInt64, windowSpaceIDs: [UInt64])
    case stateStale(reason: String, stateId: String)
    /// Caller passed an `elementIndex` that is not present in the snapshot
    /// addressed by `stateId`. Distinct from `stateStale`: the snapshot is
    /// fine, the *index* is wrong. Refreshing state and trying again with
    /// the same index will fail identically — the model needs to pick a
    /// different element.
    case invalidElementIndex(stateId: String, elementIndex: Int)
    case operationFailed(layers: [(name: String, status: String)])
    case captureUnavailable(String)
    /// Screenshot couldn't be reduced to fit the wire payload cap even
    /// after retrying with smaller `maxImageDimension`. Surfaces as
    /// `ErrPayloadTooLarge` per `docs/designs/rpc-protocol.md` so the
    /// agent treats it as a hard "give up on screenshot for this call"
    /// rather than retrying. `bytes` is the final encoded size that still
    /// exceeded the limit; `limit` is the budget in raw bytes.
    case payloadTooLarge(bytes: Int, limit: Int)
    /// Image-pixel coordinate is negative, NaN/Inf, or outside the
    /// reference screenshot dimensions for `(pid, windowId)`. Surfaces as
    /// `ErrInvalidParams` so the model fixes its input rather than
    /// retrying the same bogus point. `width`/`height` are 0 when the
    /// reference is unavailable (e.g. negative coords rejected before any
    /// size lookup).
    case coordOutOfBounds(point: CGPoint, width: Int, height: Int, label: String)
    /// Coordinate operation requested for `(pid, windowId)` but no
    /// screenshot has been recorded for that pair, so there is no
    /// trustworthy image-pixel coordinate space to interpret x/y in. The
    /// tool spec says coordinates are screenshot pixels — without a
    /// reference we'd be falling back to backing-scale math on whatever
    /// number the model passed and posting a real CGEvent at an arbitrary
    /// screen point. Surface as `invalidParams` so the model fixes the
    /// flow (call `getAppState` with `som`/`vision` first) instead of
    /// retrying the same coords.
    case noScreenshotReference(pid: pid_t, windowId: CGWindowID)
    case axNotAuthorized
    case windowNotFound(windowId: CGWindowID)
    case noElement(message: String)

    public var description: String {
        switch self {
        case .windowMismatch(let pid, let windowId, let ownerPid, let expectedWindowId):
            var detail = "windowId \(windowId) is not owned by pid \(pid)"
            if let owner = ownerPid {
                detail += " (actual owner: \(owner))"
            }
            if let expected = expectedWindowId {
                detail += " (stateId belongs to windowId \(expected))"
            }
            return detail
        case .windowOffSpace(let cur, let ws):
            return "window is off the active Space (active=\(cur), window spaces=\(ws))"
        case .stateStale(let reason, let stateId):
            return "stateId \(stateId) is stale: \(reason)"
        case .invalidElementIndex(let stateId, let elementIndex):
            return "elementIndex \(elementIndex) does not exist in stateId \(stateId) — pick a different element from the snapshot, refreshing state will not help"
        case .operationFailed(let layers):
            return "operation failed at all layers: " + layers.map { "\($0.name)=\($0.status)" }.joined(separator: ", ")
        case .captureUnavailable(let msg):
            return "capture unavailable: \(msg)"
        case .payloadTooLarge(let bytes, let limit):
            return "screenshot payload \(bytes) bytes exceeds wire limit \(limit) bytes after downscale retries"
        case .coordOutOfBounds(let point, let width, let height, let label):
            if width > 0, height > 0 {
                return "\(label) (\(point.x), \(point.y)) is outside the reference screenshot bounds (\(width)x\(height) px)"
            }
            return "\(label) (\(point.x), \(point.y)) is invalid (negative/NaN/non-finite or no reference screenshot dims)"
        case .noScreenshotReference(let pid, let windowId):
            return "no screenshot reference for (pid=\(pid), windowId=\(windowId)); call computer_use_get_app_state with captureMode 'som' or 'vision' before issuing coordinate operations — image-pixel coordinates have no defined space without a captured screenshot"
        case .axNotAuthorized:
            return "Accessibility permission required"
        case .windowNotFound(let id):
            return "no window with id \(id)"
        case .noElement(let msg):
            return msg
        }
    }
}

public actor ComputerUseService {
    private let enablement: AXEnablementAssertion
    private let enforcer: SyntheticAppFocusEnforcer
    private let preventer: SystemFocusStealPreventer
    private let focusGuard: FocusGuard
    private let snapshot: AccessibilitySnapshot
    private let cache: StateCache
    private let capture: WindowCapture

    public init() {
        let enablement = AXEnablementAssertion()
        let enforcer = SyntheticAppFocusEnforcer()
        let preventer = SystemFocusStealPreventer()
        self.enablement = enablement
        self.enforcer = enforcer
        self.preventer = preventer
        self.focusGuard = FocusGuard(
            enablement: enablement,
            enforcer: enforcer,
            systemPreventer: preventer
        )
        self.snapshot = AccessibilitySnapshot(enablement: enablement)
        self.cache = StateCache(ttlSeconds: 30)
        self.capture = WindowCapture()
    }

    // MARK: - Enumeration

    public func listApps() -> [AppInfo] {
        AppEnumerator.operableApps()
    }

    /// Layer-0 windows for `pid`, each annotated with its current
    /// Space membership so the agent can pre-filter to the active Space.
    public func listWindows(pid: pid_t) -> [(WindowInfo, onCurrentSpace: Bool)] {
        let windows = WindowEnumerator.appWindows(forPid: pid)
        return windows.map { info in
            let membership = SpaceDetector.membership(forWindow: info.id)
            let onCurrent: Bool
            switch membership {
            case .onCurrentSpace, .unknown: onCurrent = true
            case .offCurrentSpace: onCurrent = false
            }
            return (info, onCurrentSpace: onCurrent)
        }
    }

    // MARK: - State (snapshot + screenshot)

    public func getAppState(
        pid: pid_t,
        windowId: CGWindowID,
        captureMode: CaptureMode = .som,
        maxImageDimension: Int = 0
    ) async throws -> AppStateBundle {
        try validateOwnership(pid: pid, windowId: windowId)
        try validateOnSpace(windowId: windowId)

        let app = NSRunningApplication(processIdentifier: pid)
        let bundleId = app?.bundleIdentifier
        let appName = app?.localizedName

        var stateId: StateID? = nil
        var markdown: String? = nil
        var elementCount: Int? = nil
        if captureMode != .vision {
            let result = try await snapshot.walk(pid: pid, windowId: windowId)
            let id = await cache.store(pid: pid, windowId: windowId, elements: result.elements)
            stateId = id
            markdown = result.treeMarkdown
            elementCount = result.elements.count
        }

        var shot: Screenshot? = nil
        if captureMode != .ax {
            shot = try await captureWithPayloadCap(
                windowId: windowId,
                initialMaxImageDimension: maxImageDimension
            )
        }

        // Record the screenshot's actual pixel dimensions so subsequent
        // coord-mode clicks (which only carry x/y, no stateId) can convert
        // those pixels back to window-local points using the same ratio
        // the model saw — independent of maxImageDimension downscaling.
        if let shot {
            await cache.recordScreenshot(
                pid: pid,
                windowId: windowId,
                pixelSize: CGSize(width: shot.width, height: shot.height)
            )
        }

        return AppStateBundle(
            stateId: stateId,
            treeMarkdown: markdown,
            elementCount: elementCount,
            screenshot: shot,
            bundleId: bundleId,
            appName: appName
        )
    }

    // MARK: - Click (semantic)

    /// Element-indexed click. Implements the operation-degradation chain:
    ///
    ///   1. AX action — `AXUIElementPerformAction` with the requested
    ///      action name (defaults to `AXPress`). Gated by
    ///      `advertisedActionNames` so we don't fire on a no-op.
    ///   2. AX attribute — set `AXMain` / `AXFocused` / `AXValue`
    ///      depending on the element shape. Used when the element doesn't
    ///      advertise the requested action.
    ///   3. Coordinate event posting — convert AX center to a screen
    ///      point and dispatch a real mouse click.
    public func clickByElement(
        pid: pid_t,
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int,
        action: String = "AXPress"
    ) async throws -> (success: Bool, method: String) {
        try validateOwnership(pid: pid, windowId: windowId)
        try validateOnSpace(windowId: windowId)

        let element: AXUIElement
        do {
            element = try await cache.lookup(
                pid: pid, windowId: windowId, stateId: stateId, elementIndex: elementIndex
            )
        } catch let err as StateCacheLookupError {
            throw mapCacheError(err, requestPid: pid, requestWindowId: windowId)
        }

        var layerErrors: [(name: String, status: String)] = []

        // Layer 1 — AX action.
        let advertised = AXInput.advertisedActionNames(of: element)
        if advertised.contains(action) {
            do {
                try await focusGuard.withFocusSuppressed(pid: pid, element: element) {
                    try AXInput.performAction(action, on: element)
                }
                return (true, "axAction")
            } catch let err as AXInputError {
                layerErrors.append(("axAction", err.description))
            } catch {
                layerErrors.append(("axAction", "\(error)"))
            }
        } else {
            layerErrors.append(("axAction", "action \(action) not advertised"))
        }

        // Layer 2 — AX attribute (best-effort variants by action name).
        let attributeFallback: (attribute: String, value: CFTypeRef)? = {
            switch action {
            case "AXPress":   return ("AXFocused", kCFBooleanTrue)
            case "AXConfirm": return ("AXMain", kCFBooleanTrue)
            case "AXPick":    return ("AXSelected", kCFBooleanTrue)
            default: return nil
            }
        }()
        if let (attribute, value) = attributeFallback {
            do {
                try await focusGuard.withFocusSuppressed(pid: pid, element: element) {
                    try AXInput.setAttribute(attribute, on: element, value: value)
                }
                return (true, "axAttribute")
            } catch let err as AXInputError {
                layerErrors.append(("axAttribute", err.description))
            } catch {
                layerErrors.append(("axAttribute", "\(error)"))
            }
        }

        // Layer 3 — coordinate fallback. Resolve the element's screen
        // center (with hit-test self-calibration), translate to a
        // screen-point, dispatch via MouseInput.
        if let center = AXInput.screenCenter(of: element) {
            do {
                try await focusGuard.withFocusSuppressed(pid: pid, element: element) {
                    try MouseInput.click(
                        at: center, toPid: pid, windowId: windowId,
                        button: .left, count: 1
                    )
                }
                return (true, "eventPost")
            } catch {
                layerErrors.append(("eventPost", "\(error)"))
            }
        } else {
            layerErrors.append(("eventPost", "element has no resolvable screen center"))
        }

        throw ComputerUseError.operationFailed(layers: layerErrors)
    }

    // MARK: - Click (coordinates)

    public func clickByCoords(
        pid: pid_t,
        windowId: CGWindowID,
        x: Double,
        y: Double,
        count: Int,
        modifiers: [String]
    ) async throws -> (success: Bool, method: String) {
        try validateOwnership(pid: pid, windowId: windowId)
        try validateOnSpace(windowId: windowId)
        let referencePixelSize = try await requireReferencePixelSize(pid: pid, windowId: windowId)
        try validateImagePoint(
            CGPoint(x: x, y: y), label: "click point", against: referencePixelSize
        )
        let screenPoint = try WindowCoordinateSpace.screenPoint(
            fromImagePixel: CGPoint(x: x, y: y),
            forPid: pid, windowId: windowId,
            referenceImagePixelSize: referencePixelSize
        )
        try await focusGuard.withFocusSuppressed(pid: pid, element: nil) {
            try MouseInput.click(
                at: screenPoint, toPid: pid, windowId: windowId,
                button: .left, count: count, modifiers: modifiers
            )
        }
        return (true, "eventPost")
    }

    // MARK: - Drag / scroll

    public func drag(
        pid: pid_t,
        windowId: CGWindowID,
        from: CGPoint,
        to: CGPoint
    ) async throws -> Bool {
        try validateOwnership(pid: pid, windowId: windowId)
        try validateOnSpace(windowId: windowId)
        let referencePixelSize = try await requireReferencePixelSize(pid: pid, windowId: windowId)
        try validateImagePoint(from, label: "drag.from", against: referencePixelSize)
        try validateImagePoint(to, label: "drag.to", against: referencePixelSize)
        let fromScreen = try WindowCoordinateSpace.screenPoint(
            fromImagePixel: from, forPid: pid, windowId: windowId,
            referenceImagePixelSize: referencePixelSize
        )
        let toScreen = try WindowCoordinateSpace.screenPoint(
            fromImagePixel: to, forPid: pid, windowId: windowId,
            referenceImagePixelSize: referencePixelSize
        )
        try await focusGuard.withFocusSuppressed(pid: pid, element: nil) {
            try MouseInput.drag(
                from: fromScreen, to: toScreen, toPid: pid, windowId: windowId
            )
        }
        return true
    }

    public func scroll(
        pid: pid_t,
        windowId: CGWindowID,
        x: Double,
        y: Double,
        dx: Int32,
        dy: Int32
    ) async throws -> Bool {
        try validateOwnership(pid: pid, windowId: windowId)
        try validateOnSpace(windowId: windowId)
        let referencePixelSize = try await requireReferencePixelSize(pid: pid, windowId: windowId)
        try validateImagePoint(
            CGPoint(x: x, y: y), label: "scroll point", against: referencePixelSize
        )
        let screenPoint = try WindowCoordinateSpace.screenPoint(
            fromImagePixel: CGPoint(x: x, y: y),
            forPid: pid, windowId: windowId,
            referenceImagePixelSize: referencePixelSize
        )
        try await focusGuard.withFocusSuppressed(pid: pid, element: nil) {
            try MouseInput.scroll(
                at: screenPoint, dx: dx, dy: dy,
                toPid: pid, windowId: windowId
            )
        }
        return true
    }

    // MARK: - Keyboard

    public func typeText(pid: pid_t, windowId: CGWindowID, text: String) async throws -> Bool {
        try validateOwnership(pid: pid, windowId: windowId)
        try validateOnSpace(windowId: windowId)
        try await focusGuard.withFocusSuppressed(pid: pid, element: nil) {
            try KeyboardInput.typeText(text, toPid: pid)
        }
        return true
    }

    public func pressKey(
        pid: pid_t,
        windowId: CGWindowID,
        key: String,
        modifiers: [String]
    ) async throws -> Bool {
        try validateOwnership(pid: pid, windowId: windowId)
        try validateOnSpace(windowId: windowId)
        try await focusGuard.withFocusSuppressed(pid: pid, element: nil) {
            try KeyboardInput.press(key, modifiers: modifiers, toPid: pid)
        }
        return true
    }

    // MARK: - Doctor

    public func doctor(screenRecordingGranted: Bool) -> DoctorReport {
        Permissions.report(screenRecordingGranted: screenRecordingGranted)
    }

    // MARK: - Internals

    /// Hard contract: `windowId` must belong to `pid`. Cheap CGWindowList
    /// lookup; throws `windowMismatch` so the wire layer maps it onto
    /// `ErrWindowMismatch`.
    private func validateOwnership(pid: pid_t, windowId: CGWindowID) throws {
        guard let info = WindowEnumerator.window(forId: windowId) else {
            throw ComputerUseError.windowNotFound(windowId: windowId)
        }
        if info.pid != pid {
            throw ComputerUseError.windowMismatch(
                pid: pid, windowId: windowId, ownerPid: info.pid, expectedWindowId: nil
            )
        }
    }

    /// Look up the recorded screenshot dimensions for `(pid, windowId)`
    /// and reject the operation if there's no reference. Coordinate ops
    /// MUST run inside a known image-pixel space — see
    /// `ComputerUseError.noScreenshotReference` for why.
    private func requireReferencePixelSize(
        pid: pid_t, windowId: CGWindowID
    ) async throws -> CGSize {
        guard let size = await cache.screenshotPixelSize(pid: pid, windowId: windowId),
              size.width > 0, size.height > 0
        else {
            throw ComputerUseError.noScreenshotReference(pid: pid, windowId: windowId)
        }
        return size
    }

    /// Reject NaN/Inf, negatives, and anything outside `[0, width) x [0,
    /// height)`. Without this guard a model that passed e.g. a screen-coord
    /// by mistake or an off-by-one pixel-budget overflow would post a real
    /// CGEvent at an arbitrary screen location — the WindowCoordinateSpace
    /// conversion trusts its inputs to be in image pixels. Image-space is
    /// also the only space the model is allowed to operate in (see
    /// `computer_use_click_at` description).
    private func validateImagePoint(
        _ point: CGPoint,
        label: String,
        against pixelSize: CGSize
    ) throws {
        guard point.x.isFinite, point.y.isFinite else {
            throw ComputerUseError.coordOutOfBounds(
                point: point, width: 0, height: 0, label: label
            )
        }
        if point.x < 0 || point.y < 0 || point.x >= pixelSize.width || point.y >= pixelSize.height {
            throw ComputerUseError.coordOutOfBounds(
                point: point,
                width: Int(pixelSize.width),
                height: Int(pixelSize.height),
                label: label
            )
        }
    }

    private func validateOnSpace(windowId: CGWindowID) throws {
        let membership = SpaceDetector.membership(forWindow: windowId)
        switch membership {
        case .onCurrentSpace, .unknown: return
        case .offCurrentSpace(let cur, let ws):
            throw ComputerUseError.windowOffSpace(currentSpaceID: cur, windowSpaceIDs: ws)
        }
    }

    /// Capture the window and re-encode at smaller dimensions until the
    /// raw bytes fit `ScreenshotPayloadPolicy.defaultRawByteBudget`. The
    /// model's behavior shipped without ever setting `maxImageDimension`,
    /// so a 4K window could produce a multi-MB PNG that blew past the
    /// wire 1MB cap and (a) silently stalled codex `/responses` and (b)
    /// overflowed the sidecar's 2MB NDJSON line limit, killing the RPC
    /// channel entirely.
    private func captureWithPayloadCap(
        windowId: CGWindowID,
        initialMaxImageDimension: Int
    ) async throws -> Screenshot {
        return try await Self.capturePayloadLoop(
            initialMaxImageDimension: initialMaxImageDimension
        ) { [capture] dim in
            do {
                return try await capture.captureWindow(
                    windowID: windowId,
                    format: .png,
                    quality: 95,
                    maxImageDimension: dim
                )
            } catch let err as CaptureError {
                throw ComputerUseError.captureUnavailable(err.description)
            }
        }
    }

    /// Pure capture-retry orchestration, factored out for testability.
    /// `capture(dim)` is the side-effect arm — production calls
    /// `WindowCapture`, tests inject a stub that returns a `Screenshot`
    /// of a chosen size for each requested dim.
    ///
    /// `maxAttempts` is a safety bound, not the expected count: in
    /// production, shrinking dimension shrinks encoded bytes roughly
    /// quadratically, so 1–2 attempts almost always suffice. The high
    /// bound covers adversarial cases where the encoder doesn't follow
    /// the size assumption (e.g. heavy noise that defeats PNG
    /// compression at any dim) and lets us still reach `minDim` before
    /// throwing `payloadTooLarge`.
    static func capturePayloadLoop(
        initialMaxImageDimension: Int,
        maxAttempts: Int = 8,
        capture: (Int) async throws -> Screenshot
    ) async throws -> Screenshot {
        var maxDim = initialMaxImageDimension
        var lastBytes = 0
        for _ in 0..<maxAttempts {
            let shot = try await capture(maxDim)
            lastBytes = shot.imageData.count
            let currentDim = maxDim > 0 ? maxDim : max(shot.width, shot.height)
            guard let next = ScreenshotPayloadPolicy.nextMaxDim(
                currentBytes: lastBytes,
                currentMaxDim: currentDim
            ) else {
                return shot
            }
            if next == 0 { break }
            maxDim = next
        }
        throw ComputerUseError.payloadTooLarge(
            bytes: lastBytes,
            limit: ScreenshotPayloadPolicy.defaultRawByteBudget
        )
    }

    /// `requestPid`/`requestWindowId` are the args the agent sent on the
    /// failing call. The cache reports the *expected* pid/windowId (the
    /// owner of the supplied stateId) — the wire error needs both: the
    /// request side as the "what you asked for" pid/windowId, and the
    /// expected side as `ownerPid` / `expectedWindowId` so the agent
    /// knows which window the stateId actually targets.
    private func mapCacheError(
        _ err: StateCacheLookupError,
        requestPid: pid_t,
        requestWindowId: CGWindowID
    ) -> ComputerUseError {
        switch err {
        case .stale(let reason, let stateId):
            return .stateStale(reason: reason.rawValue, stateId: stateId)
        case .windowMismatch(_, let expectedPid, let expectedWindowId):
            return .windowMismatch(
                pid: requestPid,
                windowId: requestWindowId,
                ownerPid: expectedPid,
                expectedWindowId: expectedWindowId
            )
        case .invalidElementIndex(let stateId, let elementIndex):
            return .invalidElementIndex(stateId: stateId, elementIndex: elementIndex)
        }
    }
}

