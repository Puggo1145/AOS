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
            "Types.swift",
            "Parser.swift",
            "Outputs.swift",
            "CoreClient.swift",
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

    @Test("CLI uses ComputerUseCore directly without a production adapter")
    func cliUsesComputerUseCoreDirectlyWithoutProductionAdapter() throws {
        let root = try Self.packageRoot()
        let cliRoot = root.appendingPathComponent("Sources/AOSComputerUseCLI")

        #expect(!FileManager.default.fileExists(atPath: cliRoot.appendingPathComponent("CoreAdapter.swift").path))

        for file in try swiftFiles(in: cliRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("ComputerUseCoreAdapter"), "\(file.lastPathComponent) still references ComputerUseCoreAdapter")
        }
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

    private func swiftFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return try enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "swift" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }
}

private struct ArchitectureTestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}
