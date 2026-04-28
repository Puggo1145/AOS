import CoreGraphics
import Foundation

// MARK: - SpaceDetector
//
// Per `docs/designs/computer-use.md` §"Spaces 检测". Determines whether a
// target window is in the user's currently-foregrounded Space. Windows
// living in another Space have their AX subtree silently truncated to the
// menu bar by macOS — even when `SCShareableContent` still returns a
// stale backing-store screenshot. We surface that as `ErrWindowOffSpace`
// to the agent rather than silently returning a misleading empty tree.
//
// The Kit deliberately does **not** migrate windows between Spaces:
// `CGSMoveWindowsToManagedSpace` is a silent no-op for non-WindowServer
// clients on macOS 14+ (per the design's "不做的事" list).

public enum SpaceMembership: Sendable, Equatable {
    /// Window is on the active Space (or is a sticky window present on
    /// every Space).
    case onCurrentSpace
    /// Window lives only on Spaces other than the current one.
    case offCurrentSpace(currentSpaceID: UInt64, windowSpaceIDs: [UInt64])
    /// SkyLight Space SPIs unavailable. Treat as on-current-Space rather
    /// than blocking the operation — the worst case is a stale AX tree,
    /// which the snapshot path detects independently.
    case unknown
}

public enum SpaceDetector {
    /// Resolve a window's relationship to the active Space. Pure read,
    /// no side effects.
    public static func membership(forWindow windowID: CGWindowID) -> SpaceMembership {
        guard SkyLightEventPost.isSpacesAvailable else { return .unknown }
        guard let active = SkyLightEventPost.activeSpaceID() else { return .unknown }
        let memberships = SkyLightEventPost.spaceIDs(forWindow: windowID)
        if memberships.isEmpty {
            // Window not associated with any Space — typically a window
            // that was minimized into the Dock with no Mission Control
            // Space affinity. Treat as on-current-Space; the AX path will
            // surface its own staleness signal if needed.
            return .onCurrentSpace
        }
        if memberships.contains(active) {
            return .onCurrentSpace
        }
        return .offCurrentSpace(currentSpaceID: active, windowSpaceIDs: memberships)
    }
}
