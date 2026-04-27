import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import os

// MARK: - ScreenMirror
//
// Per `docs/designs/os-sense.md` §"ScreenMirror（视觉兜底）" — but in this
// implementation the capture is **on demand**, not a 1 fps background stream.
// Rationale: a continuous capture loop is the single most expensive piece of
// background work in the read-side pipeline (TCC query + SCK frame + memory
// retain on every tick). Since the visual is only ever read at submit time,
// running it any earlier is wasted work. We capture exactly once when the
// user presses Send and the visual chip is selected.
//
// Trade-off vs. the design's continuous-stream phrasing: the captured frame
// is freshest possible (taken at submit), and there is zero idle cost. The
// downside is a small (~tens of ms) submit-time latency the first frame the
// stream would have already had ready — acceptable since submit goes through
// async RPC anyway.
//
// Permission gate is checked by the caller (SenseStore / Shell). This class
// assumes Screen Recording is granted and tolerates per-call failures (DRM,
// fullscreen game, window gone) by returning nil.

@MainActor
public final class ScreenMirror {
    public static let maxLongEdge: CGFloat = 1280

    private static let log = Logger(subsystem: "com.aos.AOSOSSenseKit", category: "ScreenMirror")

    public init() {}

    /// Single screenshot of the frontmost on-screen window owned by `pid`,
    /// downsampled so the long edge is ≤ `maxLongEdge`. Returns nil if no
    /// suitable window is found or the capture fails.
    public func captureNow(forPid pid: pid_t) async -> VisualMirror? {
        do {
            let content = try await SCShareableContent.current
            guard let window = Self.frontmostWindow(content: content, pid: pid) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let target = Self.downsampledSize(
                source: CGSize(width: window.frame.width, height: window.frame.height),
                maxLongEdge: Self.maxLongEdge
            )
            config.width = max(1, Int(target.width))
            config.height = max(1, Int(target.height))
            // Cursor / shadow off — the visual is for content comprehension,
            // not pixel-perfect screenshots, and stripping the cursor avoids
            // privacy leaks via cursor-position inference.
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return VisualMirror(
                latestFrame: cgImage,
                frameSize: CGSize(width: cgImage.width, height: cgImage.height),
                capturedAt: Date()
            )
        } catch {
            // The product semantics are best-effort — visual is allowed
            // to be absent (DRM, fullscreen game, window gone, SCK
            // permission revoked mid-flight). We keep returning nil so
            // the caller decides whether to fall back, but log the
            // underlying error so a dropped frame is diagnosable.
            // Privacy: pid is part of the error context, not user data.
            Self.log.error(
                """
                captureNow(forPid: \(pid, privacy: .public)) failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return nil
        }
    }

    // MARK: - Pure helpers (testable)

    /// Pick the frontmost (largest visible) window owned by `pid`. Filters
    /// out titlebar accessory windows / off-screen elements / sub-50px
    /// chrome that would otherwise win on z-order ties.
    internal nonisolated static func frontmostWindow(content: SCShareableContent, pid: pid_t) -> SCWindow? {
        let candidates = content.windows.filter { window in
            guard window.owningApplication?.processID == pid else { return false }
            guard window.isOnScreen else { return false }
            // Layer 0 is the user-window plane; menubar/cursor/dock live on
            // higher layers. Filtering by layer keeps us on the document
            // plane.
            guard window.windowLayer == 0 else { return false }
            return window.frame.width >= 50 && window.frame.height >= 50
        }
        return candidates.max(by: {
            ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
        })
    }

    /// Long edge ≤ `maxLongEdge`, aspect-ratio preserving. Returns at least
    /// 1×1 so SCStreamConfiguration doesn't reject the dimensions.
    internal nonisolated static func downsampledSize(source: CGSize, maxLongEdge: CGFloat) -> CGSize {
        let longEdge = max(source.width, source.height)
        guard longEdge > 0 else { return CGSize(width: 1, height: 1) }
        if longEdge <= maxLongEdge { return source }
        let scale = maxLongEdge / longEdge
        return CGSize(
            width: max(1, source.width * scale),
            height: max(1, source.height * scale)
        )
    }
}
