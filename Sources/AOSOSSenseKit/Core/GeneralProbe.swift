import Foundation
import ApplicationServices

// MARK: - GeneralProbe
//
// Per `docs/designs/os-sense.md` §"Built-in kinds（GeneralProbe 输出）".
// Subscribes to AX notifications on the frontmost app via `AXObserverHub`
// and emits three built-in envelope kinds:
//
//   - general.selectedText  ← AXSelectedText, 50ms debounce
//   - general.selectedItems ← AXSelectedChildren / AXSelectedRows, 50ms debounce
//   - general.currentInput  ← focused element AXValue (editable only),
//                             250ms debounce, 2KB truncation
//
// Dedup rule (§"Built-in kinds"): when both selectedText and currentInput
// are derivable from the same focused element, only emit selectedText.
//
// Lifecycle:
//   1. `attach(pid:)` — subscribe `kAXFocusedUIElementChangedNotification`
//      on the application element. On every focus change (including the
//      first read at attach), unsubscribe the previous focused-element-bound
//      notifications and resubscribe on the new focused element.
//   2. Whenever any notification fires, debounce per the design and recompute
//      the full envelope set. Emit the set via the `onChange` callback.
//   3. `detach()` releases all subscriptions and emits an empty set so the
//      store clears the probe's slot.

@MainActor
public final class GeneralProbe {
    private let hub: AXObserverHub
    private let onChange: @MainActor ([BehaviorEnvelope]) -> Void

    private var pid: pid_t?
    private var appElement: AXUIElement?
    private var focusedElement: AXUIElement?

    /// Token for the app-level focused-element-changed subscription.
    private var focusToken: AXObserverHub.Token?
    /// Tokens for the focused-element-bound notification subscriptions.
    private var elementTokens: [AXObserverHub.Token] = []

    /// Debounce tasks per channel — kept separate so a fast-changing
    /// selectedText doesn't reset the slower currentInput timer.
    private var selectedTextDebounce: Task<Void, Never>?
    private var selectedItemsDebounce: Task<Void, Never>?
    private var currentInputDebounce: Task<Void, Never>?

    public init(
        hub: AXObserverHub,
        onChange: @escaping @MainActor ([BehaviorEnvelope]) -> Void
    ) {
        self.hub = hub
        self.onChange = onChange
    }

    public func attach(pid: pid_t) {
        detach()
        self.pid = pid
        let app = AXUIElementCreateApplication(pid)
        self.appElement = app
        focusToken = hub.subscribe(
            pid: pid,
            element: app,
            notification: kAXFocusedUIElementChangedNotification as String
        ) { [weak self] in
            self?.refocus()
        }
        // Read initial focus immediately so the chip row populates without
        // waiting for the first focus change.
        refocus()
    }

    /// Force an immediate re-read of the focused element. Use this when an
    /// external trigger (e.g. the Notch opening) needs the latest selection
    /// snapshot without waiting for the source app to fire an AX notification
    /// — many apps (terminals with custom Metal views, Electron, Figma)
    /// either don't emit `kAXSelectedTextChangedNotification` at all or emit
    /// it only after focus shifts, so passive subscription is unreliable.
    public func refresh() {
        recompute()
    }

    public func detach() {
        cancelDebounces()
        for token in elementTokens { hub.unsubscribe(token) }
        elementTokens.removeAll()
        if let token = focusToken { hub.unsubscribe(token) }
        focusToken = nil
        pid = nil
        appElement = nil
        focusedElement = nil
        // Notify the store the probe contributes nothing for this app.
        onChange([])
    }

    // MARK: - Focus tracking

    private func refocus() {
        guard let pid, let appElement else { return }
        for token in elementTokens { hub.unsubscribe(token) }
        elementTokens.removeAll()

        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &ref
        )
        guard err == .success, let value = ref else {
            focusedElement = nil
            recompute()
            return
        }
        let element = value as! AXUIElement
        focusedElement = element

        let notes: [String] = [
            kAXSelectedTextChangedNotification as String,
            kAXSelectedChildrenChangedNotification as String,
            kAXSelectedRowsChangedNotification as String,
            kAXValueChangedNotification as String,
        ]
        for note in notes {
            let token = hub.subscribe(
                pid: pid,
                element: element,
                notification: note,
                handler: { [weak self] in
                    self?.handleNotification(note)
                }
            )
            if let token {
                elementTokens.append(token)
            }
        }
        recompute()
    }

    // MARK: - Debounce dispatch

    private func handleNotification(_ name: String) {
        switch name {
        case kAXSelectedTextChangedNotification:
            scheduleSelectedTextDebounce()
        case kAXSelectedChildrenChangedNotification,
             kAXSelectedRowsChangedNotification:
            scheduleSelectedItemsDebounce()
        case kAXValueChangedNotification:
            scheduleCurrentInputDebounce()
        default:
            break
        }
    }

    private func scheduleSelectedTextDebounce() {
        selectedTextDebounce?.cancel()
        selectedTextDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
            self?.recompute()
        }
    }

    private func scheduleSelectedItemsDebounce() {
        selectedItemsDebounce?.cancel()
        selectedItemsDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
            self?.recompute()
        }
    }

    private func scheduleCurrentInputDebounce() {
        currentInputDebounce?.cancel()
        currentInputDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            self?.recompute()
        }
    }

    private func cancelDebounces() {
        selectedTextDebounce?.cancel()
        selectedItemsDebounce?.cancel()
        currentInputDebounce?.cancel()
        selectedTextDebounce = nil
        selectedItemsDebounce = nil
        currentInputDebounce = nil
    }

    // MARK: - Snapshot computation

    /// Re-read the focused element's attributes and emit the envelope set.
    /// Called both on debounced notifications and immediately at focus change
    /// so the initial state is populated.
    private func recompute() {
        guard let pid, let element = focusedElement else {
            onChange([])
            return
        }

        var envelopes: [BehaviorEnvelope] = []

        let selectedText = readString(element, attribute: kAXSelectedTextAttribute as CFString)
        let value = readString(element, attribute: kAXValueAttribute as CFString)
        let editable = isAttributeSettable(element, attribute: kAXValueAttribute as CFString)

        let hasSelectedText = !(selectedText ?? "").isEmpty
        // Dedup: skip currentInput when selectedText already covers this element.
        let currentInputApplies = Self.shouldEmitCurrentInput(
            selectedText: selectedText,
            value: value,
            editable: editable
        )

        if hasSelectedText, let s = selectedText {
            envelopes.append(Self.makeSelectedTextEnvelope(text: s, pid: pid))
        }
        if currentInputApplies {
            envelopes.append(Self.makeCurrentInputEnvelope(value: value ?? "", pid: pid))
        }

        let items = readSelectedItems(element)
        if !items.isEmpty {
            envelopes.append(Self.makeSelectedItemsEnvelope(items: items, pid: pid))
        }

        onChange(envelopes)
    }

    // MARK: - AX read helpers

    private func readString(_ element: AXUIElement, attribute: CFString) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard err == .success, let value = ref else { return nil }
        return value as? String
    }

    private func isAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return err == .success && settable.boolValue
    }

    /// Read AXSelectedChildren first (covers most lists / browsers); fall back
    /// to AXSelectedRows for table-style elements. Per design: don't recurse
    /// — only return the directly-selected layer.
    private func readSelectedItems(_ element: AXUIElement) -> [SelectedItem] {
        if let arr = readArray(element, attribute: kAXSelectedChildrenAttribute as CFString),
           !arr.isEmpty {
            return arr.compactMap { Self.projectSelectedItem($0) }
        }
        if let arr = readArray(element, attribute: kAXSelectedRowsAttribute as CFString),
           !arr.isEmpty {
            return arr.compactMap { Self.projectSelectedItem($0) }
        }
        return []
    }

    private func readArray(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard err == .success, let value = ref else { return nil }
        guard let arr = value as? [AXUIElement] else { return nil }
        return arr
    }

    /// Read role/title/value/identifier off a single selected element. `label`
    /// follows the macOS-conventional fallback (title → value → role) so the
    /// chip displays something user-recognizable even when AXTitle is empty.
    private nonisolated static func projectSelectedItem(_ element: AXUIElement) -> SelectedItem? {
        var roleRef: CFTypeRef?
        var titleRef: CFTypeRef?
        var valueRef: CFTypeRef?
        var identifierRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifierRef)

        let role = (roleRef as? String) ?? "AXUnknown"
        let title = titleRef as? String
        let value = valueRef as? String
        let identifier = identifierRef as? String

        let label: String
        if let title, !title.isEmpty {
            label = title
        } else if let value, !value.isEmpty {
            label = value
        } else {
            label = role
        }
        return SelectedItem(role: role, label: label, identifier: identifier)
    }

    // MARK: - Envelope construction
    //
    // citationKey is per-(pid, kind) so each chip slot has a stable identity
    // across content changes — the chip stays in the same position while the
    // selected text mutates. Bumping pid (app switch) replaces the slot.

    internal nonisolated static func makeSelectedTextEnvelope(text: String, pid: pid_t) -> BehaviorEnvelope {
        // Chip surface is fixed (icon + "Selected text"): the user's signal is
        // *that* something is selected, not the prefix of it. The full text
        // travels in payload.content for the LLM. Same rationale as the paste
        // chip — see docs/designs/os-sense.md §"Clipboard capture".
        BehaviorEnvelope(
            kind: "general.selectedText",
            citationKey: "general.selectedText:\(pid)",
            displaySummary: "Selected text",
            payload: .object(["content": .string(PayloadSizeGuard.clamp(text))])
        )
    }

    internal nonisolated static func makeCurrentInputEnvelope(value: String, pid: pid_t) -> BehaviorEnvelope {
        BehaviorEnvelope(
            kind: "general.currentInput",
            citationKey: "general.currentInput:\(pid)",
            displaySummary: "Current input",
            payload: .object(["value": .string(PayloadSizeGuard.clamp(value))])
        )
    }

    internal nonisolated static func shouldEmitCurrentInput(
        selectedText: String?,
        value: String?,
        editable: Bool
    ) -> Bool {
        let hasSelectedText = !(selectedText ?? "").isEmpty
        return !hasSelectedText && editable
    }

    internal nonisolated static func makeSelectedItemsEnvelope(items: [SelectedItem], pid: pid_t) -> BehaviorEnvelope {
        let summary: String
        if items.count == 1 {
            summary = items[0].label
        } else {
            summary = "\(items.count) items"
        }
        let payloadItems: [JSONValue] = items.map { item in
            var obj: [String: JSONValue] = [
                "role": .string(item.role),
                "label": .string(item.label),
            ]
            if let id = item.identifier {
                obj["identifier"] = .string(id)
            }
            return .object(obj)
        }
        return BehaviorEnvelope(
            kind: "general.selectedItems",
            citationKey: "general.selectedItems:\(pid)",
            displaySummary: summary,
            payload: .object(["items": .array(payloadItems)])
        )
    }

}
