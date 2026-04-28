import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - WindowCapture
//
// Per `docs/designs/computer-use.md` §"截图". `SCStream` +
// `SCContentFilter(desktopIndependentWindow:)` captures a single layer-0
// window without raising it. Output sized as `bounds × backingScale` so
// pixel coordinates map cleanly back to the AX point coordinates the
// click path consumes.

public enum ImageFormat: String, Sendable {
    case png
    case jpeg
}

public struct Screenshot: Sendable {
    public let imageData: Data
    public let format: ImageFormat
    public let width: Int
    public let height: Int
    public let scaleFactor: Double
    /// When the image was downscaled by `maxImageDimension`, the original
    /// width before resizing. nil when no resize happened.
    public let originalWidth: Int?
    public let originalHeight: Int?
}

// MARK: - ScreenshotPayloadPolicy
//
// Pure decision helper for `ComputerUseService.getAppState`'s capture
// retry loop. Lives here (next to `WindowCapture`) so the retry policy
// is co-located with the encoder it controls.
//
// The wire cap is on base64 size (`docs/designs/rpc-protocol.md` §"二进
// 制 payload 规则": 1 MB per screenshot, 2 MB per NDJSON line). base64
// inflates by ~4/3, so the raw-byte budget the encoder must hit is
// `ceil(base64Limit * 3/4)`. We keep a safety margin below that.
//
// PNG/JPEG file size scales roughly with pixel count = dimension². So
// the next target dimension is `currentDim × √(budget/currentBytes)`
// with a 0.85 fudge factor to absorb non-quadratic compression behavior.
public enum ScreenshotPayloadPolicy {
    /// 1 MB base64 cap from the wire protocol, minus headroom. Leaves
    /// room for the rest of the JSON envelope (axTree + bookkeeping).
    public static let defaultRawByteBudget: Int = 700_000

    /// Smallest side we'll downscale to before giving up. A 256×256
    /// thumbnail is still useful for the model; below that the image
    /// stops carrying actionable detail.
    public static let minDimension: Int = 256

    /// Returns the next `maxImageDimension` to retry the capture at.
    /// `nil` means the current encoding already fits — caller should
    /// stop. `0` means even a capture at `minDim` was already attempted
    /// and didn't fit — caller should give up and throw `payloadTooLarge`.
    ///
    /// Floor handling: when the computed ratio target falls below
    /// `minDim` we still return `minDim` **as long as the current capture
    /// wasn't already at `minDim`**. A 256×256 PNG is typically tens of
    /// KB, well under any reasonable budget, so we always prove it
    /// doesn't fit before giving up. Only when the previous attempt was
    /// already at the floor do we return 0.
    public static func nextMaxDim(
        currentBytes: Int,
        currentMaxDim: Int,
        rawByteBudget: Int = defaultRawByteBudget,
        minDim: Int = minDimension
    ) -> Int? {
        if currentBytes <= rawByteBudget { return nil }
        guard currentMaxDim > 0 else { return 0 }
        if currentMaxDim <= minDim { return 0 }
        let ratio = (Double(rawByteBudget) / Double(currentBytes)).squareRoot()
        let next = Int(Double(currentMaxDim) * ratio * 0.85)
        if next < minDim { return minDim }
        if next >= currentMaxDim { return max(minDim, currentMaxDim - 1) }
        return next
    }
}

public enum CaptureError: Error, Sendable, CustomStringConvertible {
    case noDisplay
    case permissionDenied
    case encodeFailed
    case captureFailed(String)
    case windowNotFound(CGWindowID)

    public var description: String {
        switch self {
        case .noDisplay: return "no main display found"
        case .permissionDenied: return "Screen Recording permission not granted"
        case .encodeFailed: return "failed to encode CGImage"
        case .captureFailed(let msg): return "capture failed: \(msg)"
        case .windowNotFound(let id): return "no shareable window with id \(id)"
        }
    }
}

public actor WindowCapture {
    public init() {}

    /// Capture a single window by its `CGWindowID`. Returns PNG by
    /// default; pass `format: .jpeg` for ~10x smaller payloads when the
    /// caller (e.g. agent vision input) tolerates lossy.
    ///
    /// `maxImageDimension > 0` proportionally downscales so neither side
    /// exceeds the limit — essential for keeping the wire response under
    /// the 1MB cap from `docs/designs/rpc-protocol.md` §"二进制 payload 规则".
    public func captureWindow(
        windowID: CGWindowID,
        format: ImageFormat = .png,
        quality: Int = 95,
        maxImageDimension: Int = 0
    ) async throws -> Screenshot {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw classify(error)
        }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = ScreenInfo.backingScale(for: window.frame)
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            throw classify(error)
        }

        let origW = cgImage.width
        let origH = cgImage.height
        let resized = resizeIfNeeded(cgImage, maxDim: maxImageDimension)
        let didResize = resized.width != origW || resized.height != origH

        let data = try encode(resized, format: format, quality: quality)
        return Screenshot(
            imageData: data,
            format: format,
            width: resized.width,
            height: resized.height,
            scaleFactor: Double(scale),
            originalWidth: didResize ? origW : nil,
            originalHeight: didResize ? origH : nil
        )
    }

    // MARK: - Internals

    private func resizeIfNeeded(_ image: CGImage, maxDim: Int) -> CGImage {
        let w = image.width, h = image.height
        guard maxDim > 0, max(w, h) > maxDim else { return image }
        let scale = Double(maxDim) / Double(max(w, h))
        let newW = max(1, Int(Double(w) * scale))
        let newH = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    private func classify(_ error: Error) -> CaptureError {
        let ns = error as NSError
        let msg = ns.localizedDescription.lowercased()
        if msg.contains("permission") || msg.contains("not authorized")
            || msg.contains("declined") || msg.contains("denied")
        {
            return .permissionDenied
        }
        return .captureFailed(ns.localizedDescription)
    }

    private func encode(_ image: CGImage, format: ImageFormat, quality: Int) throws -> Data {
        let utType: CFString
        switch format {
        case .png: utType = UTType.png.identifier as CFString
        case .jpeg: utType = UTType.jpeg.identifier as CFString
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, utType, 1, nil) else {
            throw CaptureError.encodeFailed
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            let clamped = max(0.01, min(1.0, Double(quality) / 100.0))
            properties[kCGImageDestinationLossyCompressionQuality] = clamped
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.encodeFailed
        }
        return buffer as Data
    }
}
