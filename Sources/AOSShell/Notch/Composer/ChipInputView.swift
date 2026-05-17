import SwiftUI
import AppKit
import AOSOSSenseKit

// MARK: - ChipInputView
//
// Rich-text composer input. Replaces the prior `PasteCapturingTextField`
// (which was a single-line `NSTextField` that surfaced paste as a chip
// rendered *outside* the field). The new model embraces the actual
// product intent: pastes are inline tokens that interleave with typed
// text, like Cursor's prompt input.
//
// ## Why NSTextView (not NSTextField)
//
// `NSTextField` only edits a flat `String`. We need an attributed text
// model so each paste can be represented by an `NSTextAttachment` whose
// custom cell draws the chip. NSTextView gives us that for free, plus:
//
//   - Backspace before an attachment deletes it as one atomic glyph
//     (AppKit's default attachment behavior — no extra code needed).
//   - Selection / cursor logic across mixed runs of text + attachments
//     just works.
//   - `NSTextStorage` is the canonical model we walk on submit.
//
// ## Wire serialization
//
// On submit, `ChipInputModel.snapshot()` walks the storage and produces:
//
//   - `prompt`: a plain string where every chip becomes the literal
//     marker `[[clipboard:N]]` (N is 0-based, matching position in the
//     clipboards array).
//   - `clipboards`: `[ClipboardItem]` in chip order.
//
// The sidecar (`prompt.ts`) expands the markers in the user message so
// the LLM sees the chip's content inline at the right position. Prompt
// position is *information* — "summarize <paste1> using <paste2>" reads
// differently from "summarize <paste2> using <paste1>".
//
// ## Cmd+V handling
//
// Same constraint as before: AOS is menu-bar-less, so the standard
// Edit→Paste path doesn't fire. We override `performKeyEquivalent(with:)`
// on the NSTextView subclass to intercept Cmd+V, snapshot the pasteboard,
// and insert a chip attachment at the current selection. We do NOT call
// `super.paste(_:)` — pasted *text* would defeat the chip model.

// MARK: - ChipInputModel
//
// Observable bridge between the NSTextView's storage and SwiftUI. Holds
// no model state of its own; each method delegates to the live text view.
// Kept observable only so the placeholder can react to "is the field
// effectively empty" without us re-publishing the entire attributed text.

@MainActor
@Observable
final class ChipInputModel {
    @ObservationIgnored fileprivate weak var textView: _ChipTextView?

    /// Authoritative attributed text. The NSTextView's storage mirrors
    /// this on creation and writes back to it on every change. Surviving
    /// the view's lifecycle here is what lets the input retain its
    /// content across notch close/reopen.
    @ObservationIgnored fileprivate var persistedStorage: NSAttributedString = NSAttributedString(string: "")

    /// Plain-text projection of the input — attachment characters are
    /// excluded. Drives the *send-button* gate: chips alone are not
    /// submittable, the user must type at least something.
    var displayText: String = ""

    /// True iff the storage holds zero glyphs of any kind (text or
    /// attachment). Drives the *placeholder* visibility — the moment a
    /// chip lands in the field, the placeholder must hide even though
    /// `displayText` is still empty.
    var isStorageEmpty: Bool = true

    /// Number of clipboard chip attachments currently in the storage.
    /// Maintained alongside `displayText` / `isStorageEmpty` so callers
    /// (e.g. the slash-command palette gate) can ask about chips
    /// without walking the attributed-string themselves.
    var attachmentCount: Int = 0

    /// Trimmed-text emptiness — the gate the send button uses. Kept
    /// separate from `isStorageEmpty` because the two answer different
    /// product questions (LLM contract vs. visual placeholder).
    var isTextEmpty: Bool {
        displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Insert a paste chip at the current selection. Used both by the
    /// view's Cmd+V handler and (potentially) by programmatic paths.
    func appendPaste(_ item: ClipboardItem) {
        textView?.insertChip(item: item)
    }

    /// Walk the storage into the wire-shaped pair. Order matters — the
    /// marker numbering must match the clipboards array index. Reads
    /// from the persisted snapshot so this works even if the view is
    /// momentarily gone (defense in depth — submit flow always has the
    /// view present).
    func snapshot() -> (prompt: String, clipboards: [ClipboardItem]) {
        let storage: NSAttributedString = textView?.textStorage ?? persistedStorage
        var prompt = ""
        var clips: [ClipboardItem] = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttributes(in: full) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? ClipboardChipAttachment {
                prompt += "[[clipboard:\(clips.count)]]"
                clips.append(attachment.item)
            } else {
                prompt += storage.attributedSubstring(from: range).string
            }
        }
        return (prompt, clips)
    }

    /// Reset the field after submit. Also clears `displayText` so the
    /// placeholder reappears synchronously (`textDidChange` won't fire
    /// for a programmatic `setAttributedString`).
    func clear() {
        textView?.textStorage?.setAttributedString(NSAttributedString(string: ""))
        persistedStorage = NSAttributedString(string: "")
        displayText = ""
        isStorageEmpty = true
        attachmentCount = 0
    }

    internal func _testSetPlainText(_ text: String) {
        let storage = NSAttributedString(string: text)
        textView?.textStorage?.setAttributedString(storage)
        persistedStorage = storage
        displayText = text
        isStorageEmpty = text.isEmpty
        attachmentCount = 0
    }

    /// Capture the live storage into the persisted snapshot. Called from
    /// the coordinator on every change so dropping the view (notch close)
    /// loses no content.
    fileprivate func capture(from storage: NSTextStorage) {
        persistedStorage = NSAttributedString(attributedString: storage)
    }
}

// MARK: - SwiftUI bridge

struct ChipInputView: NSViewRepresentable {
    let model: ChipInputModel
    var font: NSFont
    var textColor: NSColor
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void
    /// Optional palette routing. When provided and `paletteIsActive()`
    /// returns true at keystroke time:
    ///   - Up / Down arrows are intercepted and forwarded to the palette
    ///     instead of moving the text cursor.
    ///   - Enter routes through `paletteEnter()` first; if it returns
    ///     true (palette consumed it — typically by executing the
    ///     selected command), the default `onSubmit` is suppressed for
    ///     that keystroke.
    ///   - Escape calls `paletteEscape()` to deactivate the palette.
    /// Composers without a palette pass `nil` for these and the field
    /// behaves as before.
    var paletteIsActive: (() -> Bool)? = nil
    var paletteNavigate: ((CommandPaletteState.NavigationDirection) -> Void)? = nil
    var paletteEnter: (() -> Bool)? = nil
    var paletteEscape: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            onSubmit: onSubmit,
            onFocusChange: onFocusChange,
            paletteIsActive: paletteIsActive,
            paletteNavigate: paletteNavigate,
            paletteEnter: paletteEnter,
            paletteEscape: paletteEscape
        )
    }

    func makeNSView(context: Context) -> _ChipTextView {
        let textView = _ChipTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.font = font
        textView.textColor = textColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
        ]
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        model.textView = textView
        // Restore prior content (notch may have closed and reopened).
        // setAttributedString doesn't fire textDidChange, so refresh the
        // observable mirrors manually so the placeholder hides on restore.
        if model.persistedStorage.length > 0,
           let storage = textView.textStorage {
            storage.setAttributedString(model.persistedStorage)
            model.isStorageEmpty = storage.length == 0
            var plain = ""
            var chipCount = 0
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                if attrs[.attachment] == nil {
                    plain += storage.attributedSubstring(from: range).string
                } else {
                    chipCount += range.length
                }
            }
            model.displayText = plain
            model.attachmentCount = chipCount
            // Park the cursor at the end so the user keeps typing where
            // they left off.
            textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        }
        return textView
    }

    func updateNSView(_ tv: _ChipTextView, context: Context) {
        if tv.font != font { tv.font = font }
        if tv.textColor != textColor { tv.textColor = textColor }
        // Refresh typingAttributes so subsequent insertion picks up any
        // font/color changes from upstream.
        tv.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
        ]
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.paletteIsActive = paletteIsActive
        context.coordinator.paletteNavigate = paletteNavigate
        context.coordinator.paletteEnter = paletteEnter
        context.coordinator.paletteEscape = paletteEscape
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ChipInputModel
        var onSubmit: () -> Void
        var onFocusChange: (Bool) -> Void
        var paletteIsActive: (() -> Bool)?
        var paletteNavigate: ((CommandPaletteState.NavigationDirection) -> Void)?
        var paletteEnter: (() -> Bool)?
        var paletteEscape: (() -> Void)?

        init(
            model: ChipInputModel,
            onSubmit: @escaping () -> Void,
            onFocusChange: @escaping (Bool) -> Void,
            paletteIsActive: (() -> Bool)? = nil,
            paletteNavigate: ((CommandPaletteState.NavigationDirection) -> Void)? = nil,
            paletteEnter: (() -> Bool)? = nil,
            paletteEscape: (() -> Void)? = nil
        ) {
            self.model = model
            self.onSubmit = onSubmit
            self.onFocusChange = onFocusChange
            self.paletteIsActive = paletteIsActive
            self.paletteNavigate = paletteNavigate
            self.paletteEnter = paletteEnter
            self.paletteEscape = paletteEscape
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  let storage = tv.textStorage else { return }
            // Recompute the plain-text projection. We deliberately exclude
            // attachment runs — the placeholder is "is there typed text",
            // not "are there chips".
            var plain = ""
            var chipCount = 0
            let full = NSRange(location: 0, length: storage.length)
            storage.enumerateAttributes(in: full) { attrs, range, _ in
                if attrs[.attachment] == nil {
                    plain += storage.attributedSubstring(from: range).string
                } else {
                    // Each `.attachment` run contains one attachment
                    // character per glyph (range.length, conventionally 1).
                    chipCount += range.length
                }
            }
            model.displayText = plain
            model.isStorageEmpty = storage.length == 0
            model.attachmentCount = chipCount
            model.capture(from: storage)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Palette routing: Up / Down / Enter / Escape are
            // intercepted ONLY while the palette gate is active. Outside
            // command mode the field behaves exactly as before — Up /
            // Down move the cursor, Esc has no special meaning, Enter
            // submits.
            let paletteOn = paletteIsActive?() ?? false
            if paletteOn {
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    paletteNavigate?(.up)
                    return true
                }
                if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    paletteNavigate?(.down)
                    return true
                }
                if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    paletteEscape?()
                    return true
                }
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if paletteEnter?() == true {
                        // Palette consumed Enter (typically by executing
                        // the highlighted command). Don't fall through
                        // into the regular submit path.
                        return true
                    }
                    // Palette is open with no match (e.g. `/zzz`). Swallow
                    // Enter rather than calling onSubmit — the composer's
                    // submit gate only checks emptiness/busy and would
                    // otherwise ship the literal slash text to the agent.
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }

        func textDidBeginEditing(_ notification: Notification) {
            onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            onFocusChange(false)
        }
    }
}

// MARK: - _ChipTextView

/// NSTextView subclass that intercepts Cmd+V to insert a chip attachment
/// instead of pasted text. Public-internal so the SwiftUI representable
/// can return the concrete type.
final class _ChipTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Report the natural text height so SwiftUI can size us via
    /// `.fixedSize(vertical:)`. Without this the NSTextView gleefully
    /// accepts any height the parent offers — and the parent VStack's
    /// `maxHeight: .infinity` then stretches us to fill the panel,
    /// which feeds back into `composerContentHeight` and locks the
    /// notch open at the wrong height after settings closes.
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 28)
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let inset = textContainerInset
        let height = max(28, ceil(used.height + inset.height * 2))
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isPasteChord(event), window?.firstResponder === self {
            handlePaste()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func isPasteChord(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmd = mods == .command || mods == [.command, .shift]
        return isCmd && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    private func handlePaste() {
        guard let item = ClipboardPasteboardExtractor.extract(from: .general) else { return }
        insertChip(item: item)
    }

    /// Insert a clipboard chip at the current selection. Replaces any
    /// selected range, then advances the cursor past the chip so typing
    /// continues to its right.
    func insertChip(item: ClipboardItem) {
        guard let storage = textStorage else { return }
        let attachment = ClipboardChipAttachment(item: item)
        let attachmentString = NSAttributedString(attachment: attachment)
        let mutable = NSMutableAttributedString(attributedString: attachmentString)
        // Stamp typing attributes so the attachment glyph picks up our
        // font/color (affects baseline positioning of the cell).
        mutable.addAttributes(
            typingAttributes,
            range: NSRange(location: 0, length: mutable.length)
        )
        let target = selectedRange()
        storage.replaceCharacters(in: target, with: mutable)
        let newCursor = target.location + mutable.length
        setSelectedRange(NSRange(location: newCursor, length: 0))
        didChangeText()
    }
}
