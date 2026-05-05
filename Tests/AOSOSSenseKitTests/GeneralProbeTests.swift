import Testing
import Foundation
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
}
