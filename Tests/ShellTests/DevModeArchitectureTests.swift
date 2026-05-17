import Foundation
import Testing

@Suite("Dev Mode architecture")
struct DevModeArchitectureTests {
    @Test("dev mode does not expose Computer Use diagnostics")
    func devModeDoesNotExposeComputerUseDiagnostics() throws {
        let panel = try Self.source("Sources/Shell/Dev/DevModePanelView.swift")
        let controller = try Self.source("Sources/Shell/Dev/DevModeWindowController.swift")
        let composition = try Self.source("Sources/Shell/App/CompositionRoot.swift")

        #expect(!panel.contains("ComputerUseKit"))
        #expect(!panel.contains("computerUse"))
        #expect(!panel.contains("Computer Use"))
        #expect(!controller.contains("ComputerUseKit"))
        #expect(!controller.contains("computerUseCore"))
        #expect(!composition.contains("computerUseCore: computerUseCore"))
    }

    private static func source(_ path: String, file: String = #filePath) throws -> String {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
