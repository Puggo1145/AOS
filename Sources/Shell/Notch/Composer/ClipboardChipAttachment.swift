import AppKit
import OSSenseKit

// MARK: - ClipboardChipAttachment + cell

/// `NSTextAttachment` carrying a single pasted `ClipboardItem`. The
/// attachment owns its own cell so storage, rendering, and identity stay in
/// lockstep. Copying/dragging the attributed text run moves the payload with
/// it; no side table is needed.
@MainActor
final class ClipboardChipAttachment: NSTextAttachment {
    let id = UUID()
    let item: ClipboardItem

    init(item: ClipboardItem) {
        self.item = item
        super.init(data: nil, ofType: nil)
        let cell = ClipboardChipCell()
        cell.attachment = self
        self.attachmentCell = cell
    }

    required init?(coder: NSCoder) { nil }
}

/// Self-drawing pill cell: leading clipboard icon + paste label + trailing X.
/// The X area is hit-tested in `trackMouse`; accessibility exposes the same
/// deletion path through `accessibilityPerformPress()`.
final class ClipboardChipCell: NSTextAttachmentCell {
    private static let cellHeight: CGFloat = 20
    private static let xSize: CGFloat = 14
    private static let leftPad: CGFloat = 8
    private static let rightPad: CGFloat = 4
    private static let innerSpacing: CGFloat = 4
    private static let iconSize: CGFloat = 12
    private static let outerMargin: CGFloat = 4

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9),
    ]

    private var labelString: NSAttributedString {
        let owner = (attachment as? ClipboardChipAttachment)?.item
        let text: String
        switch owner {
        case .text(let s):
            text = "Pasted \(s.count) chars"
        case .filePaths(let urls):
            text = urls.count == 1 ? "Pasted file" : "Pasted \(urls.count) files"
        case .image:
            text = "Pasted image"
        case nil:
            text = "Pasted"
        }
        return NSAttributedString(string: text, attributes: Self.labelAttributes)
    }

    private var labelSize: NSSize { labelString.size() }
    private weak var accessibilityTextView: NSTextView?
    private var accessibilityCharacterIndex: Int?

    private var pillWidth: CGFloat {
        Self.leftPad
            + Self.iconSize
            + Self.innerSpacing
            + ceil(labelSize.width)
            + Self.innerSpacing
            + Self.xSize
            + Self.rightPad
    }

    override func cellSize() -> NSSize {
        MainActor.assumeIsolated {
            NSSize(width: pillWidth + Self.outerMargin * 2, height: Self.cellHeight)
        }
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -4)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        accessibilityTextView = controlView as? NSTextView
        let pillFrame = pillRect(in: cellFrame)
        let path = NSBezierPath(roundedRect: pillFrame, xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.12).setFill()
        path.fill()

        let iconRect = NSRect(
            x: pillFrame.minX + Self.leftPad,
            y: cellFrame.midY - Self.iconSize / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        if let icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            let configured = icon.withSymbolConfiguration(cfg) ?? icon
            configured.isTemplate = true
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSColor.white.withAlphaComponent(0.9).setFill()
            iconRect.fill()
            configured.draw(
                in: iconRect,
                from: .zero,
                operation: .destinationIn,
                fraction: 1.0
            )
        }

        let label = labelString
        let labelOrigin = NSPoint(
            x: iconRect.maxX + Self.innerSpacing,
            y: cellFrame.midY - label.size().height / 2
        )
        label.draw(at: labelOrigin)

        let xRect = xButtonRect(in: cellFrame)
        let xPath = NSBezierPath()
        let inset: CGFloat = 4
        xPath.move(to: NSPoint(x: xRect.minX + inset, y: xRect.minY + inset))
        xPath.line(to: NSPoint(x: xRect.maxX - inset, y: xRect.maxY - inset))
        xPath.move(to: NSPoint(x: xRect.minX + inset, y: xRect.maxY - inset))
        xPath.line(to: NSPoint(x: xRect.maxX - inset, y: xRect.minY + inset))
        xPath.lineWidth = 1.2
        xPath.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.7).setStroke()
        xPath.stroke()
    }

    private func pillRect(in cellFrame: NSRect) -> NSRect {
        cellFrame.insetBy(dx: Self.outerMargin, dy: 0)
    }

    private func xButtonRect(in cellFrame: NSRect) -> NSRect {
        let pill = pillRect(in: cellFrame)
        return NSRect(
            x: pill.maxX - Self.rightPad - Self.xSize,
            y: pill.midY - Self.xSize / 2,
            width: Self.xSize,
            height: Self.xSize
        )
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        MainActor.assumeIsolated {
            accessibilityCharacterIndex = charIndex
        }
        return super.cellFrame(
            for: textContainer,
            proposedLineFragment: lineFrag,
            glyphPosition: position,
            characterIndex: charIndex
        )
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        switch (attachment as? ClipboardChipAttachment)?.item {
        case .text:
            return "Remove pasted text"
        case .filePaths(let urls):
            return urls.count == 1 ? "Remove pasted file" : "Remove pasted files"
        case .image:
            return "Remove pasted image"
        case nil:
            return "Remove paste"
        }
    }

    override func accessibilityHelp() -> String? {
        "Deletes this pasted clipboard chip from the prompt"
    }

    override func accessibilityPerformPress() -> Bool {
        guard let textView = accessibilityTextView,
              let charIndex = accessibilityCharacterIndex else { return false }
        deleteAttachment(from: textView, atCharacterIndex: charIndex)
        return true
    }

    override func trackMouse(
        with event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard let textView = controlView as? NSTextView else { return false }
        let local = textView.convert(event.locationInWindow, from: nil)
        guard xButtonRect(in: cellFrame).contains(local) else { return false }
        deleteAttachment(from: textView, atCharacterIndex: charIndex)
        return true
    }

    private func deleteAttachment(from textView: NSTextView, atCharacterIndex charIndex: Int) {
        guard let storage = textView.textStorage,
              charIndex >= 0,
              charIndex < storage.length else { return }
        storage.replaceCharacters(in: NSRange(location: charIndex, length: 1), with: "")
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
        textView.didChangeText()
    }
}
