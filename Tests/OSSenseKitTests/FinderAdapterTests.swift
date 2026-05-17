import Testing
import Foundation
@testable import OSSenseKit

@Suite("FinderAdapter")
struct FinderAdapterTests {

    @Test("AppleScript file and folder rows project to final finder.selection payload")
    func appleScriptRowsProjectToPayload() throws {
        let items = try [
            AppleScriptFinderSelectionReader.makeSelectionItem(
                posixPath: "/Users/puggo/Documents/Report.pdf",
                finderClass: "document file"
            ),
            AppleScriptFinderSelectionReader.makeSelectionItem(
                posixPath: "/Users/puggo/Documents/Assets/",
                finderClass: "folder"
            ),
        ]

        let envelopes = FinderAdapter.makeEnvelopes(from: items)

        #expect(envelopes.count == 1)
        let envelope = try #require(envelopes.first)
        #expect(envelope.kind == "finder.selection")
        #expect(envelope.citationKey == "finder.selection")
        #expect(envelope.displaySummary == "Report.pdf + 1")

        guard case let .object(payload) = envelope.payload,
              case let .array(projectedItems)? = payload["items"] else {
            Issue.record("expected payload.items array")
            return
        }
        #expect(projectedItems == [
            .object([
                "role": .string("file"),
                "label": .string("Report.pdf"),
                "identifier": .string("file:///Users/puggo/Documents/Report.pdf"),
            ]),
            .object([
                "role": .string("folder"),
                "label": .string("Assets"),
                "identifier": .string("file:///Users/puggo/Documents/Assets/"),
            ]),
        ])
    }

    @Test("Single selection display summary uses the item label")
    func singleSelectionDisplaySummary() {
        let item = FinderSelectionItem(
            role: .file,
            label: "Report.pdf",
            fileURL: URL(fileURLWithPath: "/Users/puggo/Documents/Report.pdf")
        )

        let envelope = FinderAdapter.makeEnvelopes(from: [item]).first

        #expect(envelope?.displaySummary == "Report.pdf")
    }

    @Test("Multiple selection display summary counts remaining items")
    func multipleSelectionDisplaySummary() {
        let items = [
            FinderSelectionItem(
                role: .file,
                label: "Report.pdf",
                fileURL: URL(fileURLWithPath: "/Users/puggo/Documents/Report.pdf")
            ),
            FinderSelectionItem(
                role: .folder,
                label: "Assets",
                fileURL: URL(fileURLWithPath: "/Users/puggo/Documents/Assets/", isDirectory: true)
            ),
            FinderSelectionItem(
                role: .alias,
                label: "Shortcut",
                fileURL: URL(fileURLWithPath: "/Users/puggo/Documents/Shortcut")
            ),
        ]

        let envelope = FinderAdapter.makeEnvelopes(from: items).first

        #expect(envelope?.displaySummary == "Report.pdf + 2")
    }

    @Test("Empty selection emits no envelope so SenseStore removes the finder chip")
    func emptySelectionEmitsNoEnvelope() {
        #expect(FinderAdapter.makeEnvelopes(from: []).isEmpty)
    }

    @Test("FinderAdapter declares Finder routing and attach-time permissions")
    func adapterContract() {
        #expect(FinderAdapter.id == "finder")
        #expect(FinderAdapter.supportedBundleIds == ["com.apple.finder"])
        #expect(FinderAdapter().requiredPermissions == [.accessibility, .automation])
    }

    @Test("AppleScript execution is not MainActor isolated")
    func appleScriptExecutionDoesNotBlockMainActor() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Sources/OSSenseKit/Adapters/FinderAdapter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("@MainActor\n    private static func executeSelectionScript"))
    }
}
