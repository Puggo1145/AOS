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
// window without raising it. Output records the screenshot coordinate space
// alongside encoded image dimensions.

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
    public let coordinateSpace: ScreenshotCoordinateSpace
    /// When the image was downscaled to fit `ScreenshotPayloadPolicy`, the
    /// original width before resizing. nil when no resize happened.
    public let originalWidth: Int?
    public let originalHeight: Int?

    public init(
        imageData: Data,
        format: ImageFormat,
        width: Int,
        height: Int,
        scaleFactor: Double,
        coordinateSpace: ScreenshotCoordinateSpace,
        originalWidth: Int?,
        originalHeight: Int?
    ) {
        self.imageData = imageData
        self.format = format
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.coordinateSpace = coordinateSpace
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
    }
}

// MARK: - ScreenshotPayloadPolicy
//
// Business-level screenshot quality policy. Screenshot bytes are written to
// `.aos/tmp/` and referenced from RPC metadata, so JSON-RPC line limits do not
// define image compression behavior.
enum ScreenshotPayloadPolicy {
    /// Screenshots at or below this encoded byte size are returned untouched.
    /// Larger screenshots are resized from the same captured frame until the
    /// encoded image fits.
    public static let maxUncompressedBytes: Int = 1 * 1024 * 1024

    /// Last useful image side before failing loudly. Below this, coordinate
    /// intent becomes too coarse for reliable computer-use actions.
    public static let minDimension: Int = 256

    public static func nextResizeMaxDimension(currentMaxDimension: Int, currentBytes: Int) -> Int {
        let ratio = (Double(maxUncompressedBytes) / Double(currentBytes)).squareRoot()
        let next = Int(Double(currentMaxDimension) * ratio * 0.95)
        if next >= currentMaxDimension {
            return max(minDimension, currentMaxDimension - 1)
        }
        return max(minDimension, next)
    }
}

enum CaptureError: Error, Sendable, CustomStringConvertible {
    case noDisplay
    case permissionDenied
    case encodeFailed
    case payloadTooLarge(bytes: Int, limit: Int)
    case captureFailed(String)
    case windowNotFound(CGWindowID)

    public var description: String {
        switch self {
        case .noDisplay: return "no main display found"
        case .permissionDenied: return "Screen Recording permission not granted"
        case .encodeFailed: return "failed to encode CGImage"
        case .payloadTooLarge(let bytes, let limit):
            return "screenshot payload \(bytes) bytes exceeds raw limit \(limit) bytes after resize retries"
        case .captureFailed(let msg): return "capture failed: \(msg)"
        case .windowNotFound(let id): return "no shareable window with id \(id)"
        }
    }
}

actor WindowCapture {
    public init() {}

    /// Capture a single window by its `CGWindowID`. Returns PNG by
    /// default; pass `format: .jpeg` for ~10x smaller payloads when the
    /// caller (e.g. agent vision input) tolerates lossy.
    ///
    public func captureWindow(
        windowID: CGWindowID,
        format: ImageFormat = .png,
        quality: Int = 95
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
        guard let windowInfo = WindowEnumerator.window(forId: windowID) else {
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

        let encoded = try encodeWithResizePolicy(cgImage, format: format, quality: quality)
        let resized = encoded.image
        let didResize = resized.width != cgImage.width || resized.height != cgImage.height

        return Screenshot(
            imageData: encoded.data,
            format: format,
            width: resized.width,
            height: resized.height,
            scaleFactor: Double(scale),
            coordinateSpace: ScreenshotCoordinateSpace(
                windowFrame: WindowBounds(
                    x: window.frame.origin.x,
                    y: window.frame.origin.y,
                    width: window.frame.size.width,
                    height: window.frame.size.height
                ),
                windowBounds: windowInfo.bounds,
                pixelSize: CGSize(width: resized.width, height: resized.height)
            ),
            originalWidth: didResize ? cgImage.width : nil,
            originalHeight: didResize ? cgImage.height : nil
        )
    }

    // MARK: - Internals

    private func encodeWithResizePolicy(
        _ image: CGImage,
        format: ImageFormat,
        quality: Int
    ) throws -> (image: CGImage, data: Data) {
        var current = image
        var data = try encode(current, format: format, quality: quality)
        if data.count <= ScreenshotPayloadPolicy.maxUncompressedBytes {
            return (current, data)
        }

        for _ in 0..<8 {
            let nextMaxDim = ScreenshotPayloadPolicy.nextResizeMaxDimension(
                currentMaxDimension: max(current.width, current.height),
                currentBytes: data.count
            )
            current = try resize(current, maxDim: nextMaxDim)
            data = try encode(current, format: format, quality: quality)
            if data.count <= ScreenshotPayloadPolicy.maxUncompressedBytes {
                return (current, data)
            }
            if max(current.width, current.height) <= ScreenshotPayloadPolicy.minDimension {
                break
            }
        }

        throw CaptureError.payloadTooLarge(
            bytes: data.count,
            limit: ScreenshotPayloadPolicy.maxUncompressedBytes
        )
    }

    private func resize(_ image: CGImage, maxDim: Int) throws -> CGImage {
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
        ) else { throw CaptureError.encodeFailed }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let resized = ctx.makeImage() else {
            throw CaptureError.encodeFailed
        }
        return resized
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
