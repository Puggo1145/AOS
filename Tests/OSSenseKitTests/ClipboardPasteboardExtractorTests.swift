import Testing
import Foundation
import AppKit
@testable import OSSenseKit

// Pin the projection contract that used to live on `ClipboardWatcher`:
// type priority, verbatim text capture, image-metadata-only, empty → nil.
// Each test owns a uniquely-named NSPasteboard so the system pasteboard
// is never touched and parallel tests don't collide.

@Suite("ClipboardPasteboardExtractor — pasteboard projection")
struct ClipboardPasteboardExtractorTests {

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("notch-agent.test.\(UUID().uuidString)"))
    }

    @Test("Empty pasteboard projects to nil")
    func emptyReturnsNil() {
        let pb = makePasteboard()
        pb.clearContents()
        #expect(ClipboardPasteboardExtractor.extract(from: pb) == nil)
    }

    @Test("UTF-8 plain text is captured")
    func textCaptured() {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("hello clipboard", forType: .string)
        guard case let .text(s) = ClipboardPasteboardExtractor.extract(from: pb) else {
            Issue.record("expected .text projection")
            return
        }
        #expect(s == "hello clipboard")
    }

    @Test("Long text is captured verbatim — manual paste must not be truncated")
    func longTextCapturedVerbatim() {
        let pb = makePasteboard()
        pb.clearContents()
        let raw = String(repeating: "x", count: 64 * 1024)
        pb.setString(raw, forType: .string)
        guard case let .text(s) = ClipboardPasteboardExtractor.extract(from: pb) else {
            Issue.record("expected .text projection")
            return
        }
        #expect(s == raw)
    }

    @Test("File URLs win over coexisting plain text")
    func filePriorityOverText() throws {
        let pb = makePasteboard()
        pb.clearContents()
        let url = URL(fileURLWithPath: "/tmp/notch-agent-extractor-test.txt")
        pb.writeObjects([url as NSURL])
        // Add competing text — file URL must still win per design priority.
        pb.setString("should be ignored", forType: .string)
        guard case let .filePaths(paths) = ClipboardPasteboardExtractor.extract(from: pb) else {
            Issue.record("expected .filePaths projection")
            return
        }
        #expect(paths == [url])
    }

    @Test("Image projects to metadata only — never the pixels")
    func imageMetadataOnly() throws {
        let pb = makePasteboard()
        pb.clearContents()
        let size = NSSize(width: 8, height: 4)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )!
        let png = rep.representation(using: .png, properties: [:])!
        pb.setData(png, forType: .png)

        guard case let .image(metadata) = ClipboardPasteboardExtractor.extract(from: pb) else {
            Issue.record("expected .image projection")
            return
        }
        #expect(metadata.width == 8)
        #expect(metadata.height == 4)
        #expect(metadata.type == NSPasteboard.PasteboardType.png.rawValue)
    }
}
