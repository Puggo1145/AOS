import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RPCSchema
import OSSenseKit

// MARK: - SenseContext → CitedContext projection
//
// Lives at the Shell composition seam per docs/designs/os-sense.md §"依赖
// 方向（核心契约）" — OS Sense never imports the wire schema; the Shell is
// the place that translates between the live model (NSImage / CGImage etc.)
// and the wire schema (base64 PNG, structured strings).
//
// Selection contract: the user can deselect *behavior* chips before
// submit; deselected envelopes are filtered out HERE so they never travel
// over the wire. App / window are always projected (basic identity).
//
// Clipboard and visual are no longer selection-based:
//
// - Clipboard arrives as an explicit `[ClipboardItem]` array — one entry
//   per paste the user performed into the composer this turn (paste-driven
//   model per `docs/designs/os-sense.md` §"Clipboard capture"). The
//   composer accumulates pastes as inline chips so users can stage
//   multiple snippets within a single prompt.
// - Visual arrives as an explicit `VisualMirror?` parameter — present iff
//   the per-app capture toggle is on AND a snapshot was successfully
//   captured (per design §"ScreenMirror" — capture policy is Shell-side).
//
// "Don't include it" in both cases is expressed by passing `nil`. There's
// no `.visualSelected` / `.clipboardSelected` flag because the call site
// already decides by deciding whether to capture.

public struct CitedSelection: Sendable {
    /// Behavior `citationKey`s the user has deselected.
    public let deselectedBehaviors: Set<String>

    public init(deselectedBehaviors: Set<String> = []) {
        self.deselectedBehaviors = deselectedBehaviors
    }

    public static let all = CitedSelection()
}

enum CitedContextProjection {
    /// Maximum size for the encoded icon PNG, per rpc-protocol.md §"二进制
    /// payload 规则" (`citedContext.visual.frame` is 400KB; the icon shares
    /// that ceiling so a single CitedContext stays well below 2MB).
    static let maxIconPNGBytes = 400 * 1024
    /// Per design "ScreenMirror — 引用时才 PNG 编码 + 体积约束（≤ 400KB，超
    /// 限继续降采样）". Same hard ceiling; one extra pass of 50% downsample.
    static let maxVisualPNGBytes = 400 * 1024

    /// Project the live `SenseContext` onto the wire schema.
    ///
    /// `visual` and `clipboard` are passed in explicitly because neither
    /// is a live field on `SenseContext`:
    ///
    /// - `visual` is captured on demand by the Shell at submit time
    ///   (`SenseStore.captureVisualSnapshot()`), gated by the per-app
    ///   capture-policy toggle.
    /// - `clipboards` is captured at user-paste time inside the composer
    ///   and held as `pendingPastes` until the next submit. Each paste
    ///   appends a new entry; the user removes individual entries via the
    ///   chip's X affordance.
    ///
    /// Pass `nil` (visual) or `[]` (clipboards) to omit from the wire payload.
    static func project(
        from sense: SenseContext,
        selection: CitedSelection = .all,
        visual: VisualMirror? = nil,
        clipboards: [ClipboardItem] = []
    ) -> CitedContext {
        let app = sense.app.flatMap { project(app: $0) }
        let window = sense.window.map { project(window: $0) }

        let projectedBehaviors: [RPCSchema.BehaviorEnvelope]? = {
            let kept = sense.behaviors.filter {
                !selection.deselectedBehaviors.contains($0.citationKey)
            }
            guard !kept.isEmpty else { return nil }
            return kept.map { project(envelope: $0) }
        }()

        let projectedVisual: CitedVisual? = visual.flatMap { project(visual: $0) }
        let projectedClipboards: [CitedClipboard]? = clipboards.isEmpty
            ? nil
            : clipboards.map { project(clipboard: $0) }

        return CitedContext(
            app: app,
            window: window,
            behaviors: projectedBehaviors,
            visual: projectedVisual,
            clipboards: projectedClipboards
        )
    }

    private static func project(app: AppIdentity) -> CitedApp {
        let iconPNG = app.icon.flatMap { encodeIcon($0) }
        return CitedApp(
            bundleId: app.bundleId,
            name: app.name,
            pid: Int(app.pid),
            iconPNG: iconPNG
        )
    }

    private static func project(window: WindowIdentity) -> CitedWindow {
        CitedWindow(
            title: window.title,
            windowId: window.windowId.map { Int($0) }
        )
    }

    /// Project a live envelope to its wire equivalent. The two types share a
    /// shape but live in different packages on purpose (read-side never
    /// imports wire); this is the one place that bridges them.
    private static func project(envelope: OSSenseKit.BehaviorEnvelope) -> RPCSchema.BehaviorEnvelope {
        RPCSchema.BehaviorEnvelope(
            kind: envelope.kind,
            citationKey: envelope.citationKey,
            displaySummary: envelope.displaySummary,
            payload: convert(envelope.payload)
        )
    }

    /// JSONValue is intentionally duplicated across packages (read-side ↔
    /// wire-side). Recursive structural conversion is the bridge.
    private static func convert(_ value: OSSenseKit.JSONValue) -> RPCSchema.JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .int(let i):
            return .int(i)
        case .double(let d):
            return .double(d)
        case .string(let s):
            return .string(s)
        case .array(let arr):
            return .array(arr.map { convert($0) })
        case .object(let dict):
            return .object(dict.mapValues { convert($0) })
        }
    }

    /// Encode the visual frame to base64 PNG, downsampling further if the
    /// 400KB ceiling is breached. Returns nil if even the smallest pass
    /// can't fit; SenseStore's downsample to ≤1280px is the upstream cap,
    /// this is the wire-time safety net.
    private static func project(visual: VisualMirror) -> CitedVisual? {
        let candidates: [CGFloat] = [1.0, 0.6, 0.4, 0.25]
        for scale in candidates {
            guard let data = pngData(visual.latestFrame, scale: scale) else { continue }
            if fitsBase64Budget(data, limit: maxVisualPNGBytes) {
                let scaled = CGSize(
                    width: visual.frameSize.width * scale,
                    height: visual.frameSize.height * scale
                )
                return CitedVisual(
                    frame: data.base64EncodedString(),
                    frameSize: CitedVisualSize(
                        width: max(1, Int(scaled.width)),
                        height: max(1, Int(scaled.height))
                    ),
                    capturedAt: ISO8601DateFormatter().string(from: visual.capturedAt)
                )
            }
        }
        return nil
    }

    private static func project(clipboard: ClipboardItem) -> CitedClipboard {
        switch clipboard {
        case .text(let s):
            return .text(s)
        case .filePaths(let urls):
            return .filePaths(urls.map { $0.path })
        case .image(let metadata):
            return .image(metadata: CitedClipboardImageMetadata(
                width: metadata.width,
                height: metadata.height,
                type: metadata.type
            ))
        }
    }

    /// Encode an NSImage to base64 PNG, downsampling progressively if the
    /// resulting payload would exceed `maxIconPNGBytes`. Apple icons are
    /// typically 1024×1024 — usually one downsample to 256 is enough.
    private static func encodeIcon(_ image: NSImage) -> String? {
        let candidates: [CGFloat] = [1.0, 0.5, 0.25, 0.125]
        for scale in candidates {
            guard let data = pngData(image, scale: scale) else { continue }
            if fitsBase64Budget(data, limit: maxIconPNGBytes) {
                return data.base64EncodedString()
            }
        }
        return nil
    }

    /// Wire payload is base64-encoded, so the byte budget bites the encoded
    /// string, not the raw PNG. base64 inflates by ~4/3 (3 bytes → 4 chars).
    /// Both icon and visual paths share this rule.
    internal static func fitsBase64Budget(_ data: Data, limit: Int) -> Bool {
        data.count * 4 / 3 <= limit
    }

    private static func pngData(_ image: NSImage, scale: CGFloat) -> Data? {
        let targetSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        guard targetSize.width >= 16, targetSize.height >= 16 else { return nil }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        return rep.representation(using: .png, properties: [:])
    }

    /// CGImage → PNG, with optional downsample. Used for the visual fallback;
    /// the live frame is already ≤1280px so `scale==1.0` is the common path,
    /// but we keep the hook for the wire-time 400KB enforcement.
    private static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))

        let resized: CGImage
        if scale == 1.0 {
            resized = image
        } else {
            guard let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let out = ctx.makeImage() else { return nil }
            resized = out
        }

        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, resized, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
