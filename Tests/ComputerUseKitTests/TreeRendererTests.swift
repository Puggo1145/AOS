import Testing
@testable import ComputerUseKit

@Suite("TreeRenderer")
struct TreeRendererTests {

    @Test("lines use Codex-style readable AX labels without legacy locator ids")
    func linesUseCodexStyleReadableAXLabelsWithoutLegacyLocatorIds() {
        let line = TreeRenderer.renderLine(
            depth: 1,
            elementIndex: 12,
            role: "AXTextField",
            subrole: nil,
            title: nil,
            value: "",
            description: "smart search field",
            identifier: "email",
            help: nil,
            placeholder: "Search or enter website name",
            enabled: true,
            selected: nil,
            valueSettable: true,
            actions: ["AXPress"]
        )

        #expect(line.contains("\t12 text field (settable, string)"))
        #expect(line.contains("Description: smart search field"))
        #expect(line.contains("Placeholder: Search or enter website name"))
        #expect(line.contains("ID: email"))
        #expect(!line.contains("locator="))
        #expect(!line.contains("AXTextField"))
    }

    @Test("secondary actions are normalized for model selection")
    func secondaryActionsAreNormalizedForModelSelection() {
        let line = TreeRenderer.renderLine(
            depth: 0,
            elementIndex: 2,
            role: "AXScrollArea",
            subrole: nil,
            title: nil,
            value: nil,
            description: nil,
            identifier: "_NS:21",
            help: nil,
            placeholder: nil,
            enabled: true,
            selected: nil,
            valueSettable: false,
            actions: ["AXScrollUpByPage", "AXScrollDownByPage", "AXScrollToVisible"]
        )

        #expect(line == "2 scroll area Secondary Actions: Scroll Up, Scroll Down")
    }

    @Test("static text value is not repeated as an attribute")
    func staticTextValueIsNotRepeatedAsAnAttribute() {
        let line = TreeRenderer.renderLine(
            depth: 1,
            elementIndex: 88,
            role: "AXStaticText",
            subrole: nil,
            title: nil,
            value: "Safari prevents trackers from profiling you.",
            description: nil,
            identifier: nil,
            help: nil,
            placeholder: nil,
            enabled: true,
            selected: nil,
            valueSettable: false,
            actions: []
        )

        #expect(line == "\t88 text Safari prevents trackers from profiling you.")
    }

    @Test("menu buttons and window controls use separated role names")
    func menuButtonsAndWindowControlsUseSeparatedRoleNames() {
        let menuButton = TreeRenderer.renderLine(
            depth: 0,
            elementIndex: 102,
            role: "AXMenuButton",
            subrole: nil,
            title: nil,
            value: nil,
            description: "Tab Group picker",
            identifier: nil,
            help: nil,
            placeholder: nil,
            enabled: true,
            selected: nil,
            valueSettable: false,
            actions: ["AXShowMenu"]
        )
        let close = TreeRenderer.renderLine(
            depth: 0,
            elementIndex: 116,
            role: "AXButton",
            subrole: "AXCloseButton",
            title: nil,
            value: nil,
            description: nil,
            identifier: nil,
            help: nil,
            placeholder: nil,
            enabled: true,
            selected: nil,
            valueSettable: false,
            actions: []
        )

        #expect(menuButton.contains("102 menu button"))
        #expect(close == "116 close button")
    }

    @Test("semantic identifiers become names for structural nodes")
    func semanticIdentifiersBecomeNamesForStructuralNodes() {
        let collection = TreeRenderer.renderLine(
            depth: 0,
            elementIndex: 4,
            role: "AXList",
            subrole: "AXCollectionList",
            title: nil,
            value: nil,
            description: nil,
            identifier: "StartPageCollectionView",
            help: nil,
            placeholder: nil,
            enabled: true,
            selected: nil,
            valueSettable: false,
            actions: ["AXShowMenu"]
        )
        let menuBarItem = TreeRenderer.renderLine(
            depth: 0,
            elementIndex: 106,
            role: "AXMenuBarItem",
            subrole: nil,
            title: "Safari",
            value: nil,
            description: nil,
            identifier: "_NS:1085",
            help: nil,
            placeholder: nil,
            enabled: true,
            selected: nil,
            valueSettable: false,
            actions: ["AXCancel", "AXPick"]
        )

        #expect(collection == "4 collection StartPageCollectionView")
        #expect(menuBarItem == "106 Safari")
    }

    @Test("noisy implementation actions are suppressed")
    func noisyImplementationActionsAreSuppressed() {
        let line = TreeRenderer.renderLine(
            depth: 0,
            elementIndex: 96,
            role: "AXTextField",
            subrole: nil,
            title: nil,
            value: nil,
            description: "smart search field",
            identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
            help: nil,
            placeholder: nil,
            enabled: true,
            selected: nil,
            valueSettable: true,
            actions: ["AXShowMenu", "AXConfirm", "ShowDefaultUI", "ShowAlternateUI"]
        )

        #expect(line == "96 text field (settable, string) Description: smart search field, ID: WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD")
    }
}
