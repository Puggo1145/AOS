import Foundation
import AppKit

// MARK: - SenseContext live model
//
// Per `docs/designs/os-sense.md` §"SenseContext 数据结构".
// This is the **live** in-process mirror of OS state. It is NOT the wire
// schema — wire-side equivalents (CitedApp / CitedWindow / CitedClipboard /
// CitedVisual) live in `RPCSchema`. Per design "依赖方向（核心契约）",
// OS Sense never imports `RPCSchema`; the Shell composition root projects
// from this live model to the wire schema at submit time.

/// Identity of the frontmost app, sourced from `NSWorkspace`.
///
/// `Equatable` intentionally compares only `bundleId` / `name` / `pid`;
/// `icon` (an `NSImage`) is excluded because `NSImage` lacks meaningful
/// value-equality and is not itself `Sendable`. The `@unchecked Sendable`
/// conformance is sound here because all writes flow through `SenseStore`
/// which is `@MainActor`-isolated; the icon is treated as effectively
/// immutable once handed to us by `NSRunningApplication`.
public struct AppIdentity: Hashable, @unchecked Sendable {
    public let bundleId: String
    public let name: String
    public let pid: pid_t
    public let icon: NSImage?

    public init(bundleId: String, name: String, pid: pid_t, icon: NSImage?) {
        self.bundleId = bundleId
        self.name = name
        self.pid = pid
        self.icon = icon
    }

    public static func == (lhs: AppIdentity, rhs: AppIdentity) -> Bool {
        lhs.bundleId == rhs.bundleId && lhs.name == rhs.name && lhs.pid == rhs.pid
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleId)
        hasher.combine(name)
        hasher.combine(pid)
    }
}

/// Identity of the focused window. Stage 0 produces this from
/// `NSRunningApplication.localizedName` only — `windowId` is always nil
/// because AX-driven window title / `_AXUIElementGetWindow` resolution
/// belongs to OS Sense Stage 1 (AXObserverHub).
public struct WindowIdentity: Hashable, Sendable {
    public let title: String
    public let windowId: CGWindowID?

    public init(title: String, windowId: CGWindowID?) {
        self.title = title
        self.windowId = windowId
    }
}

/// A single selected item (row, file, list entry) inside the frontmost app.
public struct SelectedItem: Hashable, Sendable {
    public let role: String
    public let label: String
    public let identifier: String?

    public init(role: String, label: String, identifier: String?) {
        self.role = role
        self.label = label
        self.identifier = identifier
    }
}

/// Metadata for an image clipboard item. Per design, **never** the pixels.
///
/// `ClipboardItem` is no longer a live `SenseContext` field — the Shell
/// composer captures it once at user-paste time (see
/// `docs/designs/os-sense.md` §"Clipboard capture"). This type still
/// lives here because the wire-side projection and the pasteboard
/// extractor both belong to OS Sense's projection contract.
public struct ImageMetadata: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let type: String

    public init(width: Int, height: Int, type: String) {
        self.width = width
        self.height = height
        self.type = type
    }
}

/// One pasted clipboard payload, projected per the design priority
/// (`public.file-url` > `public.utf8-plain-text` > `public.image`).
public enum ClipboardItem: Equatable, Sendable {
    case text(String)
    case filePaths([URL])
    case image(metadata: ImageMetadata)
}

/// Visual fallback frame. `CGImage` is not `Sendable`; the
/// `@unchecked Sendable` conformance is sound because writes are serialized
/// through `SenseStore` (`@MainActor`).
public struct VisualMirror: @unchecked Sendable, Equatable {
    public let latestFrame: CGImage
    public let frameSize: CGSize
    public let capturedAt: Date

    public init(latestFrame: CGImage, frameSize: CGSize, capturedAt: Date) {
        self.latestFrame = latestFrame
        self.frameSize = frameSize
        self.capturedAt = capturedAt
    }

    /// Equality intentionally ignores raw pixels: comparing `CGImage` byte
    /// buffers on every Observable diff would be prohibitive. Frame size +
    /// capture timestamp is sufficient to detect "this is a new frame".
    public static func == (lhs: VisualMirror, rhs: VisualMirror) -> Bool {
        lhs.frameSize == rhs.frameSize && lhs.capturedAt == rhs.capturedAt
    }
}

/// Runtime permissions consulted by OS Sense. Automation is included for
/// schema completeness even though Stage 0 does not probe it (no caller).
public enum Permission: Hashable, Sendable, CaseIterable {
    case accessibility
    case screenRecording
    case localFiles
    case automation
}

public struct PermissionState: Equatable, Sendable {
    public let denied: Set<Permission>

    public init(denied: Set<Permission>) {
        self.denied = denied
    }
}

/// The single source of OS truth held by `SenseStore`. `app` is `Optional`
/// because at process boot we may briefly lack a frontmost-app determination
/// (no `NSWorkspace` activation event has fired yet). Once a frontmost app
/// is observed, `app` is populated and the live-mirror invariant holds.
///
/// Two payloads that the chip row also surfaces are deliberately **absent**
/// here:
///
/// - Visual fallback: capturing a screen frame is expensive and only ever
///   needed at submit time, so it's fetched on demand via
///   `SenseStore.captureVisualSnapshot()`. The decision of *when* to
///   capture (e.g. per-app "always capture" toggle) lives in the Shell.
/// - Clipboard: no longer a live OS mirror — the Shell composer captures
///   one item at user-paste time and attaches it to the next submit.
public struct SenseContext: Equatable, Sendable {
    public let app: AppIdentity?
    public let window: WindowIdentity?
    public let behaviors: [BehaviorEnvelope]
    public let permissions: PermissionState

    public init(
        app: AppIdentity?,
        window: WindowIdentity?,
        behaviors: [BehaviorEnvelope],
        permissions: PermissionState
    ) {
        self.app = app
        self.window = window
        self.behaviors = behaviors
        self.permissions = permissions
    }

    public static let empty = SenseContext(
        app: nil,
        window: nil,
        behaviors: [],
        permissions: PermissionState(denied: [])
    )
}
