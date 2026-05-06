import Testing
import Foundation
import AOSAXSupport
@testable import AOSOSSenseKit

@Suite("GeneralProbe — pure helpers")
struct GeneralProbeTests {

    @Test("selectedText envelope has stable per-pid citationKey")
    func selectedTextStableKey() {
        let env1 = GeneralProbe.makeSelectedTextEnvelope(text: "first", pid: 42)
        let env2 = GeneralProbe.makeSelectedTextEnvelope(text: "second", pid: 42)
        #expect(env1.citationKey == env2.citationKey)
        #expect(env1.kind == "general.selectedText")
        #expect(env1.citationKey == "general.selectedText:42")
    }

    @Test("currentInput envelope kind + citationKey are distinct from selectedText")
    func currentInputDistinct() {
        let txt = GeneralProbe.makeSelectedTextEnvelope(text: "a", pid: 1)
        let inp = GeneralProbe.makeCurrentInputEnvelope(value: "a", pid: 1)
        #expect(txt.kind != inp.kind)
        #expect(txt.citationKey != inp.citationKey)
    }

    @Test("selectedItems display summary is single label for one item, count otherwise")
    func selectedItemsSummary() {
        let single = GeneralProbe.makeSelectedItemsEnvelope(
            items: [SelectedItem(role: "AXRow", label: "Report.pdf", identifier: nil)],
            pid: 7
        )
        #expect(single.displaySummary == "Report.pdf")

        let multi = GeneralProbe.makeSelectedItemsEnvelope(
            items: [
                SelectedItem(role: "AXRow", label: "a", identifier: nil),
                SelectedItem(role: "AXRow", label: "b", identifier: nil),
                SelectedItem(role: "AXRow", label: "c", identifier: nil),
            ],
            pid: 7
        )
        #expect(multi.displaySummary == "3 items")
    }

    @Test("selected item projection unwraps unlabeled Finder groups")
    func selectedItemProjectionUnwrapsFinderGroup() {
        let item = GeneralProbe.projectSelectedItem(
            GeneralProbe.SelectedItemAXSnapshot(
                role: "AXGroup",
                title: nil,
                value: nil,
                identifier: nil,
                description: nil,
                filename: nil,
                children: [
                    GeneralProbe.SelectedItemAXSnapshot(
                        role: "AXStaticText",
                        title: "Quarterly Report.pdf",
                        value: nil,
                        identifier: nil,
                        description: nil,
                        filename: nil
                    ),
                ]
            )
        )

        #expect(item?.role == "AXGroup")
        #expect(item?.label == "Quarterly Report.pdf")
    }

    @Test("selected item projection uses identifier before falling back to role")
    func selectedItemProjectionUsesIdentifierAsLabel() {
        let item = GeneralProbe.projectSelectedItem(
            GeneralProbe.SelectedItemAXSnapshot(
                role: "AXGroup",
                title: nil,
                value: nil,
                identifier: "friend_accommodation_confirmation_letter",
                description: nil,
                filename: nil
            )
        )

        #expect(item?.label == "friend_accommodation_confirmation_letter")
        #expect(item?.identifier == "friend_accommodation_confirmation_letter")
    }

    @Test("selectedText payload carries the full content (no truncation)")
    func selectedTextPayloadShape() {
        let raw = String(repeating: "x", count: 64 * 1024)
        let env = GeneralProbe.makeSelectedTextEnvelope(text: raw, pid: 1)
        guard case let .object(obj) = env.payload,
              case let .string(content)? = obj["content"] else {
            Issue.record("expected .object with .string content")
            return
        }
        #expect(content == raw)
    }

    @Test("selectedText / currentInput chips show fixed labels, not content")
    func fixedDisplaySummary() {
        let sel = GeneralProbe.makeSelectedTextEnvelope(text: "anything goes here", pid: 1)
        let inp = GeneralProbe.makeCurrentInputEnvelope(value: "half-typed text", pid: 1)
        #expect(sel.displaySummary == "Selected text")
        #expect(inp.displaySummary == "Current input")
    }

    @Test("focused editable empty field still emits currentInput")
    func emptyEditableFieldEmitsCurrentInput() {
        #expect(GeneralProbe.shouldEmitCurrentInput(selectedText: nil, value: "", editable: true))
        #expect(GeneralProbe.shouldEmitCurrentInput(selectedText: nil, value: nil, editable: true))
    }

    @Test("currentInput payload carries locator target when provided")
    func currentInputPayloadCarriesLocatorTarget() {
        let locator = AXElementLocator(
            pid: 5,
            bundleId: "com.example.Editor",
            windowId: 9,
            windowTitle: "Draft",
            pathFromWindow: [
                AXElementLocator.PathComponent(role: "AXGroup", siblingOrdinal: 0),
                AXElementLocator.PathComponent(role: "AXTextField", identifier: "body", siblingOrdinal: 1),
            ],
            frame: AXElementLocator.Frame(x: 10, y: 20, width: 300, height: 24)
        )
        let env = GeneralProbe.makeCurrentInputEnvelope(value: "hello", pid: 5, target: locator)

        guard case let .object(payload) = env.payload,
              case let .object(target)? = payload["target"],
              case let .string(locatorId)? = target["locatorId"],
              case let .array(path)? = target["pathFromWindow"],
              case let .object(lastPath)? = path.last,
              case let .int(siblingOrdinal)? = lastPath["siblingOrdinal"] else {
            Issue.record("expected currentInput target locator payload")
            return
        }

        #expect(locatorId == locator.locatorId)
        #expect(siblingOrdinal == 1)
    }

    @Test("missing AX focus is retained when Notch owns keyboard focus")
    func missingAXFocusRetainsPriorInputWhileNotchIsKey() {
        #expect(GeneralProbe.shouldRetainFocusedElementWhenFocusReadFails(
            hasFocusedElement: true,
            targetPid: 42,
            frontmostPid: 42,
            appHasKeyWindow: true
        ))

        #expect(!GeneralProbe.shouldRetainFocusedElementWhenFocusReadFails(
            hasFocusedElement: true,
            targetPid: 42,
            frontmostPid: 42,
            appHasKeyWindow: false
        ))
    }

    @Test("missing AX focus is retained after the source app deactivates")
    func missingAXFocusRetainsPriorInputAfterSourceAppDeactivates() {
        #expect(GeneralProbe.shouldRetainFocusedElementWhenFocusReadFails(
            hasFocusedElement: true,
            targetPid: 42,
            frontmostPid: 99,
            appHasKeyWindow: false
        ))

        #expect(!GeneralProbe.shouldRetainFocusedElementWhenFocusReadFails(
            hasFocusedElement: false,
            targetPid: 42,
            frontmostPid: 99,
            appHasKeyWindow: true
        ))
    }
}
