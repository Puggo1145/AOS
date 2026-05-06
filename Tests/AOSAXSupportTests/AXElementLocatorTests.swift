import Testing
@testable import AOSAXSupport

@Suite("AXElementLocator")
struct AXElementLocatorTests {

    @Test("Duplicate inputs with the same AXIdentifier get distinct locator ids")
    func duplicateInputsGetDistinctLocatorIds() {
        let first = AXElementLocator(
            pid: 42,
            bundleId: "com.example.Form",
            windowId: 7,
            windowTitle: "Profile",
            pathFromWindow: [
                AXElementLocator.PathComponent(role: "AXGroup", siblingOrdinal: 0),
                AXElementLocator.PathComponent(
                    role: "AXTextField",
                    identifier: "email",
                    title: "Email",
                    siblingOrdinal: 0
                ),
            ],
            frame: AXElementLocator.Frame(x: 10, y: 20, width: 200, height: 24)
        )
        let second = AXElementLocator(
            pid: 42,
            bundleId: "com.example.Form",
            windowId: 7,
            windowTitle: "Profile",
            pathFromWindow: [
                AXElementLocator.PathComponent(role: "AXGroup", siblingOrdinal: 0),
                AXElementLocator.PathComponent(
                    role: "AXTextField",
                    identifier: "email",
                    title: "Email",
                    siblingOrdinal: 1
                ),
            ],
            frame: AXElementLocator.Frame(x: 10, y: 60, width: 200, height: 24)
        )

        #expect(first.locatorId != second.locatorId)
        #expect(first.pathFromWindow.last?.siblingOrdinal == 0)
        #expect(second.pathFromWindow.last?.siblingOrdinal == 1)
    }

    @Test("Locator id is deterministic for the same element signature")
    func locatorIdIsDeterministic() {
        let path = [
            AXElementLocator.PathComponent(role: "AXGroup", siblingOrdinal: 2),
            AXElementLocator.PathComponent(role: "AXTextArea", identifier: "body", siblingOrdinal: 0),
        ]
        let first = AXElementLocator(
            pid: 100,
            bundleId: "com.example.Editor",
            windowId: 200,
            windowTitle: "Draft",
            pathFromWindow: path,
            frame: AXElementLocator.Frame(x: 1.2, y: 3.8, width: 400, height: 80)
        )
        let second = AXElementLocator(
            pid: 100,
            bundleId: "com.example.Editor",
            windowId: 200,
            windowTitle: "Draft",
            pathFromWindow: path,
            frame: AXElementLocator.Frame(x: 1.2, y: 3.8, width: 400, height: 80)
        )

        #expect(first.locatorId == second.locatorId)
    }

    @Test("Locator id is stable across screen-frame changes")
    func locatorIdIgnoresFrameChanges() {
        let path = [
            AXElementLocator.PathComponent(role: "AXTextField", identifier: "search", siblingOrdinal: 0),
        ]
        let beforeMove = AXElementLocator(
            pid: 100,
            bundleId: "com.example.Search",
            windowId: 200,
            windowTitle: "Search",
            pathFromWindow: path,
            frame: AXElementLocator.Frame(x: 10, y: 20, width: 300, height: 24)
        )
        let afterMove = AXElementLocator(
            pid: 100,
            bundleId: "com.example.Search",
            windowId: 200,
            windowTitle: "Search",
            pathFromWindow: path,
            frame: AXElementLocator.Frame(x: 510, y: 720, width: 300, height: 24)
        )

        #expect(beforeMove.locatorId == afterMove.locatorId)
    }

    @Test("Locator id is stable across window title changes")
    func locatorIdIgnoresWindowTitleChanges() {
        let path = [
            AXElementLocator.PathComponent(role: "AXTextArea", identifier: "body", siblingOrdinal: 0),
        ]
        let cleanTitle = AXElementLocator(
            pid: 100,
            bundleId: "com.example.Editor",
            windowId: 200,
            windowTitle: "Document.md",
            pathFromWindow: path
        )
        let dirtyTitle = AXElementLocator(
            pid: 100,
            bundleId: "com.example.Editor",
            windowId: 200,
            windowTitle: "Document.md — Edited",
            pathFromWindow: path
        )

        #expect(cleanTitle.locatorId == dirtyTitle.locatorId)
        #expect(cleanTitle.windowTitle != dirtyTitle.windowTitle)
    }
}
