import Testing
@testable import AOSComputerUseKit

@Suite("TreeRenderer")
struct TreeRendererTests {

    @Test("Interactive lines include locator id")
    func interactiveLinesIncludeLocatorId() {
        let line = TreeRenderer.renderLine(
            depth: 1,
            elementIndex: 12,
            locatorId: "axloc_deadbeef",
            role: "AXTextField",
            subrole: nil,
            title: "Email",
            value: "",
            description: nil,
            identifier: "email",
            help: nil,
            enabled: true,
            actions: ["AXPress"]
        )

        #expect(line.contains("[12] AXTextField"))
        #expect(line.contains("id=email"))
        #expect(line.contains("locator=axloc_deadbeef"))
    }
}
