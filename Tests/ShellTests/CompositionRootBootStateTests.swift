import Foundation
import Testing
@testable import Shell

@MainActor
@Suite("CompositionRoot boot state")
struct CompositionRootBootStateTests {
    @Test("new composition root starts idle")
    func newRootStartsIdle() {
        let root = CompositionRoot()
        #expect(root.bootState == .idle)
    }

    @Test("stop records explicit stopped boot state even before start")
    func stopRecordsStoppedState() {
        let root = CompositionRoot()
        root.stop()
        #expect(root.bootState == .stopped)
    }

    @Test("application termination stops composition root synchronously")
    func applicationTerminationStopsCompositionRootSynchronously() throws {
        let source = try Self.source("Sources/Shell/App/AppDelegate.swift")

        #expect(source.contains("func applicationWillTerminate"))
        #expect(source.contains("compositionRoot.stop()"))
        #expect(!source.contains("Task { @MainActor in compositionRoot.stop() }"))
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
