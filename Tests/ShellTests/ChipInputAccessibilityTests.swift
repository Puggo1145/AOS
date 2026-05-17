import AppKit
import Testing
@testable import Shell
import OSSenseKit

@MainActor
@Suite("Chip input accessibility")
struct ChipInputAccessibilityTests {
    @Test("clipboard chip cell exposes a button action for assistive tech")
    func clipboardChipCellExposesButtonAction() throws {
        let attachment = ClipboardChipAttachment(item: .text("hello"))
        let cell = try #require(attachment.attachmentCell as? ClipboardChipCell)

        #expect(cell.isAccessibilityElement())
        #expect(cell.accessibilityRole() == .button)
        #expect(cell.accessibilityLabel() == "Remove pasted text")
    }
}
