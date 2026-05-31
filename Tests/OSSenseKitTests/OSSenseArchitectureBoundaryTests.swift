import Testing
import Foundation

@Suite("OS Sense architecture boundaries")
struct OSSenseArchitectureBoundaryTests {

    @Test("Core files do not reference concrete adapters")
    func coreDoesNotReferenceConcreteAdapters() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let core = root.appendingPathComponent("Sources/OSSenseKit/Core")
        let enumerator = try #require(FileManager.default.enumerator(
            at: core,
            includingPropertiesForKeys: nil
        ))

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(!source.contains("FinderAdapter"), "\(fileURL.path) references FinderAdapter")
            #expect(!source.contains("PreviewAdapter"), "\(fileURL.path) references PreviewAdapter")
            #expect(!source.contains("BrowserAdapter"), "\(fileURL.path) references BrowserAdapter")
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
        #expect(!source.contains("pdf.document"))
        #expect(!source.contains("pdfDocument"))
        #expect(!source.contains("PDFDocument"))
        #expect(!source.contains("browser.tab"))
        #expect(!source.contains("browserTab"))
        #expect(!source.contains("BrowserTab"))
    }
}
