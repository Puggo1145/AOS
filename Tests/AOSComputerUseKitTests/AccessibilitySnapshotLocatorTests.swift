import Foundation
import Testing

@Suite("AccessibilitySnapshot locator performance")
struct AccessibilitySnapshotLocatorTests {

    @Test("app state tree walk does not recompute locator by walking ancestors per node")
    func treeWalkDoesNotCallAXElementLocatorReaderLocate() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent(
            "Sources/AOSComputerUseKit/AppState/AccessibilitySnapshot.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("AXElementLocatorReader.locate"))
    }
}
