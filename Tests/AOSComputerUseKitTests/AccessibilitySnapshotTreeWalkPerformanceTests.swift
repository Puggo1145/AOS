import Foundation
import Testing

@Suite("AccessibilitySnapshot tree walk performance")
struct AccessibilitySnapshotTreeWalkPerformanceTests {

    @Test("app state tree walk does not walk ancestors per rendered node")
    func treeWalkDoesNotUseAncestorReaderPerNode() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent(
            "Sources/AOSComputerUseKit/AppState/AccessibilitySnapshot.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("AXElementLocatorReader.locate"))
    }

    @Test("collapsed static text does not short-circuit mixed child rendering")
    func collapsedStaticTextDoesNotShortCircuitMixedChildRendering() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent(
            "Sources/AOSComputerUseKit/AppState/AccessibilitySnapshot.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("if renderCollapsedStaticTextChildren("))
    }
}
