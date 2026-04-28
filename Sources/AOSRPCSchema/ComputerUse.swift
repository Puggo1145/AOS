import Foundation

// MARK: - computerUse.* — Bun → Shell namespace
//
// Per docs/designs/rpc-protocol.md §"computerUse.*" and
// docs/designs/computer-use.md §"RPC 方法". All requests originate in
// the sidecar agent loop and target the Shell-hosted `AOSComputerUseKit`.
//
// Common conventions:
//   - `pid` is `Int32` on the wire (matches macOS `pid_t`).
//   - `windowId` is `UInt32` (CGWindowID).
//   - All coordinates are window-local screenshot pixels (top-left origin
//     of the PNG returned by `getAppState`). The Kit translates internally.
//   - `(pid, windowId)` consistency is enforced by the Kit; mismatch →
//     `ErrWindowMismatch`.
//   - `stateId` TTL = 30s; expiry / element invalidation → `ErrStateStale`.
//
// Capture-mode behaviour (per `getAppState`):
//   - `som`     (default) — AX tree + screenshot
//   - `vision`            — screenshot only (no Accessibility required)
//   - `ax`                — AX tree only (no Screen Recording required)

// MARK: - Shared records

public struct ComputerUseAppInfo: Codable, Sendable, Equatable {
    public let pid: Int32
    public let bundleId: String?
    public let name: String
    public let active: Bool

    public init(pid: Int32, bundleId: String?, name: String, active: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.active = active
    }
}

public struct ComputerUseWindowBounds: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct ComputerUseWindowInfo: Codable, Sendable, Equatable {
    public let windowId: UInt32
    public let title: String
    public let bounds: ComputerUseWindowBounds
    public let isOnScreen: Bool
    public let onCurrentSpace: Bool
    public let layer: Int

    public init(
        windowId: UInt32, title: String, bounds: ComputerUseWindowBounds,
        isOnScreen: Bool, onCurrentSpace: Bool, layer: Int
    ) {
        self.windowId = windowId
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.onCurrentSpace = onCurrentSpace
        self.layer = layer
    }
}

public struct ComputerUseScreenshot: Codable, Sendable, Equatable {
    /// Base64 PNG (or JPEG depending on size budget). Capped at 1MB
    /// post-base64 by `docs/designs/rpc-protocol.md` §"二进制 payload".
    public let imageBase64: String
    public let format: String  // "png" | "jpeg"
    public let width: Int
    public let height: Int
    public let scaleFactor: Double
    public let originalWidth: Int?
    public let originalHeight: Int?

    public init(
        imageBase64: String, format: String, width: Int, height: Int,
        scaleFactor: Double, originalWidth: Int? = nil, originalHeight: Int? = nil
    ) {
        self.imageBase64 = imageBase64
        self.format = format
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
    }
}

// MARK: - listApps

public struct ComputerUseListAppsParams: Codable, Sendable, Equatable {
    public init() {}
}

public struct ComputerUseListAppsResult: Codable, Sendable, Equatable {
    public let apps: [ComputerUseAppInfo]
    public init(apps: [ComputerUseAppInfo]) { self.apps = apps }
}

// MARK: - listWindows

public struct ComputerUseListWindowsParams: Codable, Sendable, Equatable {
    public let pid: Int32
    public init(pid: Int32) { self.pid = pid }
}

public struct ComputerUseListWindowsResult: Codable, Sendable, Equatable {
    public let windows: [ComputerUseWindowInfo]
    public init(windows: [ComputerUseWindowInfo]) { self.windows = windows }
}

// MARK: - getAppState

public struct ComputerUseGetAppStateParams: Codable, Sendable, Equatable {
    public let pid: Int32
    public let windowId: UInt32
    /// `"som" | "vision" | "ax"` — defaults to `"som"` server-side when nil.
    public let captureMode: String?
    /// When > 0, screenshot is proportionally downscaled so neither side
    /// exceeds. Useful when the agent only needs a thumbnail.
    public let maxImageDimension: Int?

    public init(pid: Int32, windowId: UInt32, captureMode: String? = nil, maxImageDimension: Int? = nil) {
        self.pid = pid
        self.windowId = windowId
        self.captureMode = captureMode
        self.maxImageDimension = maxImageDimension
    }
}

public struct ComputerUseGetAppStateResult: Codable, Sendable, Equatable {
    public let stateId: String?
    public let bundleId: String?
    public let appName: String?
    public let axTree: String?
    public let elementCount: Int?
    public let screenshot: ComputerUseScreenshot?

    public init(
        stateId: String?, bundleId: String?, appName: String?,
        axTree: String?, elementCount: Int?, screenshot: ComputerUseScreenshot?
    ) {
        self.stateId = stateId
        self.bundleId = bundleId
        self.appName = appName
        self.axTree = axTree
        self.elementCount = elementCount
        self.screenshot = screenshot
    }
}

// MARK: - click (split into two methods)
//
// Click was historically one RPC method with two arms gated on which
// optional fields were present. The LLM kept filling both arms with
// placeholder dummies (`stateId: "unused"`, `elementIndex: -1`, plus real
// `x` / `y`) and the dispatcher would greedily pick element-mode, hit a
// non-existent stateId, and fail with `stateStale`. The model never even
// reached the coordinate path.
//
// Honest split per AGENTS.md "Single responsibility": each method has its
// own param type with the fields it actually requires. The schema is the
// guardrail — the LLM cannot conflate the two modes because they're
// physically different methods.

/// Element-indexed semantic click: address a specific AX element from a
/// snapshot. Use after `computerUse.getAppState` returns a `stateId`.
public struct ComputerUseClickByElementParams: Codable, Sendable, Equatable {
    public let pid: Int32
    public let windowId: UInt32
    public let stateId: String
    public let elementIndex: Int
    /// AX action name; defaults server-side to "AXPress" when nil.
    public let action: String?

    public init(
        pid: Int32,
        windowId: UInt32,
        stateId: String,
        elementIndex: Int,
        action: String? = nil
    ) {
        self.pid = pid
        self.windowId = windowId
        self.stateId = stateId
        self.elementIndex = elementIndex
        self.action = action
    }
}

/// Coordinate click: window-local screenshot pixels (top-left origin).
/// Use when no AX snapshot exists, or for vision-only flows.
public struct ComputerUseClickByCoordsParams: Codable, Sendable, Equatable {
    public let pid: Int32
    public let windowId: UInt32
    public let x: Double
    public let y: Double
    public let count: Int?
    public let modifiers: [String]?

    public init(
        pid: Int32,
        windowId: UInt32,
        x: Double,
        y: Double,
        count: Int? = nil,
        modifiers: [String]? = nil
    ) {
        self.pid = pid
        self.windowId = windowId
        self.x = x
        self.y = y
        self.count = count
        self.modifiers = modifiers
    }
}

public struct ComputerUseClickResult: Codable, Sendable, Equatable {
    public let success: Bool
    /// One of "axAction" | "axAttribute" | "eventPost" — tells the agent
    /// which layer of the degradation chain landed.
    public let method: String

    public init(success: Bool, method: String) {
        self.success = success
        self.method = method
    }
}

// MARK: - drag

public struct ComputerUseDragParams: Codable, Sendable, Equatable {
    public let pid: Int32
    public let windowId: UInt32
    public let from: ComputerUsePoint
    public let to: ComputerUsePoint

    public init(pid: Int32, windowId: UInt32, from: ComputerUsePoint, to: ComputerUsePoint) {
        self.pid = pid; self.windowId = windowId; self.from = from; self.to = to
    }
}

public struct ComputerUsePoint: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ComputerUseDragResult: Codable, Sendable, Equatable {
    public let success: Bool
    public init(success: Bool) { self.success = success }
}

// MARK: - typeText

public struct ComputerUseTypeTextParams: Codable, Sendable, Equatable {
    public let pid: Int32
    public let windowId: UInt32
    public let text: String

    public init(pid: Int32, windowId: UInt32, text: String) {
        self.pid = pid; self.windowId = windowId; self.text = text
    }
}

public struct ComputerUseTypeTextResult: Codable, Sendable, Equatable {
    public let success: Bool
    public init(success: Bool) { self.success = success }
}

// MARK: - pressKey

public struct ComputerUsePressKeyParams: Codable, Sendable, Equatable {
    public let pid: Int32
    public let windowId: UInt32
    public let key: String
    public let modifiers: [String]?

    public init(pid: Int32, windowId: UInt32, key: String, modifiers: [String]? = nil) {
        self.pid = pid; self.windowId = windowId; self.key = key; self.modifiers = modifiers
    }
}

public struct ComputerUsePressKeyResult: Codable, Sendable, Equatable {
    public let success: Bool
    public init(success: Bool) { self.success = success }
}

// MARK: - scroll

public struct ComputerUseScrollParams: Codable, Sendable, Equatable {
    public let pid: Int32
    public let windowId: UInt32
    public let x: Double
    public let y: Double
    /// Pixel-quantized horizontal / vertical scroll deltas. Positive y
    /// scrolls content up; positive x scrolls content right (CGEvent
    /// convention).
    public let dx: Int32
    public let dy: Int32

    public init(pid: Int32, windowId: UInt32, x: Double, y: Double, dx: Int32, dy: Int32) {
        self.pid = pid; self.windowId = windowId
        self.x = x; self.y = y; self.dx = dx; self.dy = dy
    }
}

public struct ComputerUseScrollResult: Codable, Sendable, Equatable {
    public let success: Bool
    public init(success: Bool) { self.success = success }
}

// MARK: - doctor

public struct ComputerUseDoctorParams: Codable, Sendable, Equatable {
    public init() {}
}

public struct ComputerUseSkyLightStatus: Codable, Sendable, Equatable {
    public let postToPid: Bool
    public let authMessage: Bool
    public let focusWithoutRaise: Bool
    public let windowLocation: Bool
    public let spaces: Bool
    public let getWindow: Bool

    public init(
        postToPid: Bool, authMessage: Bool, focusWithoutRaise: Bool,
        windowLocation: Bool, spaces: Bool, getWindow: Bool
    ) {
        self.postToPid = postToPid
        self.authMessage = authMessage
        self.focusWithoutRaise = focusWithoutRaise
        self.windowLocation = windowLocation
        self.spaces = spaces
        self.getWindow = getWindow
    }
}

public struct ComputerUseDoctorResult: Codable, Sendable, Equatable {
    public let accessibility: Bool
    public let screenRecording: Bool
    public let automation: Bool
    public let skyLightSPI: ComputerUseSkyLightStatus

    public init(
        accessibility: Bool, screenRecording: Bool, automation: Bool,
        skyLightSPI: ComputerUseSkyLightStatus
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.automation = automation
        self.skyLightSPI = skyLightSPI
    }
}
