import Foundation
import AppKit

// MARK: - ClipboardPasteboardExtractor
//
// Pure projection of an `NSPasteboard` snapshot into a `ClipboardItem`.
//
// Replaces the former `ClipboardWatcher` actor that used to live in OS
// Sense Core. Per `docs/designs/os-sense.md` §"Clipboard capture", the
// clipboard is no longer treated as live OS state — the Shell composer
// captures it once at user-paste time. This file is the residual API
// that survives the migration: pasteboard-priority logic + image-
// metadata-only rule, exposed as a stateless static.
//
// Text is captured in full: a manual paste is an explicit user act and
// the whole content must reach the model. The only exception is the
// `PayloadSizeGuard` cap (≈ 1 MiB UTF-8) which exists solely to keep the
// stdio JSON-RPC transport from overflowing its 2 MiB line limit; in that
// extreme case the truncation is marked explicitly, never silent.
//
// Lives in `OSSenseKit` (not the Shell) because the projection rules
// (priority order, "never the pixels") are part of the OS Sense
// contract — anyone who wants to materialize a `ClipboardItem` from a
// pasteboard should obey them.

public enum ClipboardPasteboardExtractor {
    /// Snapshot the given pasteboard once and project to a
    /// `ClipboardItem`. Returns nil for clipboards we can't represent
    /// (empty, or only types we don't surface).
    ///
    /// Type priority (per design): file URL > UTF-8 plain text > image.
    /// Text is surfaced verbatim. Images are reported by metadata only;
    /// pixel data never leaves this function.
    public static func extract(from pasteboard: NSPasteboard) -> ClipboardItem? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return .filePaths(urls)
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(PayloadSizeGuard.clamp(text))
        }

        if let images = pasteboard.readObjects(
            forClasses: [NSImage.self],
            options: nil
        ) as? [NSImage], let image = images.first {
            return projectImage(image, pasteboard: pasteboard)
        }

        return nil
    }

    /// Pure projection of an `NSImage` clipboard entry into image
    /// metadata. `pasteboard` is consulted only to detect the source UTI
    /// (PNG / TIFF / JPEG) — pixel data never leaves this function.
    internal static func projectImage(
        _ image: NSImage,
        pasteboard: NSPasteboard
    ) -> ClipboardItem? {
        let pixelSize = pixelSize(of: image)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return .image(metadata: ImageMetadata(
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            type: imageType(pasteboard: pasteboard)
        ))
    }

    private static func pixelSize(of image: NSImage) -> CGSize {
        // `NSImage.size` is in points; for pasted bitmaps we want pixels
        // so a Retina screenshot reports 2880×1800 instead of 1440×900.
        if let rep = image.representations.first as? NSBitmapImageRep {
            return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        return image.size
    }

    private static func imageType(pasteboard: NSPasteboard) -> String {
        let priorities: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in priorities {
            if pasteboard.availableType(from: [type]) != nil {
                return type.rawValue
            }
        }
        if let any = pasteboard.types?.first(where: {
            $0.rawValue.contains("image") || $0.rawValue.contains("png") || $0.rawValue.contains("tiff")
        }) {
            return any.rawValue
        }
        return "public.image"
    }
}
