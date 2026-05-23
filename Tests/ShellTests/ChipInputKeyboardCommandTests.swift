import AppKit
import Testing
@testable import Shell

@Suite("Chip input keyboard commands")
struct ChipInputKeyboardCommandTests {
    @Test("Shift Enter inserts a line break instead of submitting")
    func shiftEnterInsertsLineBreak() {
        #expect(ChipInputKeyboardCommand.shouldInsertLineBreak(
            commandSelector: #selector(NSResponder.insertNewline(_:)),
            modifierFlags: [.shift]
        ))
    }

    @Test("plain Enter remains a submit command")
    func plainEnterDoesNotInsertLineBreak() {
        #expect(!ChipInputKeyboardCommand.shouldInsertLineBreak(
            commandSelector: #selector(NSResponder.insertNewline(_:)),
            modifierFlags: []
        ))
    }

    @Test("non-newline Shift commands are not treated as line breaks")
    func nonNewlineShiftCommandDoesNotInsertLineBreak() {
        #expect(!ChipInputKeyboardCommand.shouldInsertLineBreak(
            commandSelector: #selector(NSResponder.moveUp(_:)),
            modifierFlags: [.shift]
        ))
    }
}
