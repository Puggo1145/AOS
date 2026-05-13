import Foundation
import Testing

@Suite("Computer Use background mouse event architecture")
struct MouseEventArchitectureTests {
    @Test("core exposes mouse events, not left-click compatibility wrappers")
    func coreExposesMouseEventsNotLeftClickWrappers() throws {
        let source = try Self.source("Sources/AOSComputerUseKit/ComputerUseCore.swift")

        #expect(!source.contains("postLeftClick"))
        #expect(!source.contains("WindowClickResult"))
        #expect(!source.contains("WindowClickTrace"))
        #expect(!source.contains("MouseClick"))
    }

    @Test("mouse event model is separate from the poster implementation")
    func mouseEventModelIsSeparateFromPosterImplementation() throws {
        let source = try Self.source("Sources/AOSComputerUseKit/Input/MouseEventPoster.swift")

        #expect(!source.contains("public enum BackgroundMouseEvent"))
        #expect(!source.contains("struct BackgroundMouseEventDeliveryClassifier"))
        #expect(!source.contains("typealias MouseClick"))
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
