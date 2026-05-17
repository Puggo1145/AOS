import Foundation
import Testing

@Suite("Dev Mode architecture")
struct DevModeArchitectureTests {
    @Test("dev mode exposes Computer Use through its dedicated service")
    func devModeExposesComputerUseThroughDedicatedService() throws {
        let panel = try Self.source("Sources/Shell/Dev/DevModePanelView.swift")
        let controller = try Self.source("Sources/Shell/Dev/DevModeWindowController.swift")
        let composition = try Self.source("Sources/Shell/App/CompositionRoot.swift")
        let service = try Self.source("Sources/Shell/Dev/DevComputerUseService.swift")

        #expect(panel.contains("Computer Use"))
        #expect(panel.contains("DevComputerUseSectionView"))
        #expect(!controller.contains("computerUseCore"))
        #expect(composition.contains("DevComputerUseService(client: shellComputerUseClient)"))
        #expect(service.contains("startAppSession"))
        #expect(service.contains("stopAppSession"))
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
