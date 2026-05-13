import Foundation
import Testing

@Suite("AOSComputerUseCLI architecture")
struct ComputerUseCLIArchitectureTests {
    @Test("CLI source is split by responsibility")
    func cliSourceIsSplitByResponsibility() throws {
        let root = try Self.packageRoot()
        let cliRoot = root.appendingPathComponent("Sources/AOSComputerUseCLI")
        let expectedFiles = [
            "ComputerUseCLI.swift",
            "AppSessionPolicy.swift",
            "Types.swift",
            "Parser.swift",
            "Outputs.swift",
            "CoreAdapter.swift",
            "DiagnosticClients.swift",
            "Permissions.swift",
            "CoordinateTarget.swift",
            "InteractiveCommand.swift",
            "InteractiveRuntime.swift",
            "PostCursorRuntime.swift",
            "PostCursor.swift",
        ]

        for file in expectedFiles {
            #expect(FileManager.default.fileExists(atPath: cliRoot.appendingPathComponent(file).path), "\(file) is missing")
        }

        let facadeLineCount = try lineCount(cliRoot.appendingPathComponent("ComputerUseCLI.swift"))
        #expect(facadeLineCount < 450)
    }

    private static func packageRoot(file: String = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: file)
        while url.path != "/" {
            let package = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: package.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw ArchitectureTestError("Package.swift not found from \(file)")
    }

    private func lineCount(_ url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

private struct ArchitectureTestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}
