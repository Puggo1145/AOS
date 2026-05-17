import Testing
import Foundation

@Suite("OS Sense architecture boundaries")
struct OSSenseArchitectureBoundaryTests {

    @Test("Core files do not reference concrete FinderAdapter")
    func coreDoesNotReferenceConcreteFinderAdapter() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let core = root.appendingPathComponent("Sources/OSSenseKit/Core")
        let enumerator = try #require(FileManager.default.enumerator(
            at: core,
            includingPropertiesForKeys: nil
        ))

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(!source.contains("FinderAdapter"), "\(fileURL.path) references FinderAdapter")
        }
    }

    @Test("Finder selection remains a behavior, not a SenseContext top-level field")
    func finderSelectionDoesNotEnterSenseContextTopLevel() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let senseContext = root.appendingPathComponent("Sources/OSSenseKit/Core/SenseContext.swift")
        let source = try String(contentsOf: senseContext, encoding: .utf8)

        #expect(!source.contains("finder.selection"))
        #expect(!source.contains("finderSelection"))
        #expect(!source.contains("FinderSelection"))
    }
}
