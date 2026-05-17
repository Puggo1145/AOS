import Foundation
import Testing

@Suite("Composer context switching")
struct ComposerContextSwitchTests {
    @Test("app context switches do not clear live composer input")
    func appContextSwitchesDoNotClearLiveComposerInput() throws {
        let source = try String(
            contentsOf: Self.sourceURL("Sources/Shell/Notch/Composer/AgentInputField.swift"),
            encoding: .utf8
        )

        #expect(!source.contains(".onChange(of: senseStore.context.app?.bundleId)"))
        #expect(!source.contains("inputModel.clear()\n            palette.deactivate()"))
    }

    private static func sourceURL(_ path: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // ShellTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(path)
    }
}
