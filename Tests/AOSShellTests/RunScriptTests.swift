import Testing
import Foundation

@Suite("Run script")
struct RunScriptTests {

    @Test("run.sh terminates an existing AOS process before opening the rebuilt app")
    func runScriptRelaunchesAOS() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("Scripts/run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let commandLines = script
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")

        let terminateRange = try #require(commandLines.range(of: "pkill -x AOS"))
        let openRange = try #require(commandLines.range(of: "open AOS.app"))
        #expect(terminateRange.lowerBound < openRange.lowerBound)
    }
}
