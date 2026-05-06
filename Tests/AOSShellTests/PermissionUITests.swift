import Foundation
import Testing
import AOSOSSenseKit
@testable import AOSShell

@Suite("Permission UI metadata")
struct PermissionUITests {

    @Test("Settings permission list includes Automation")
    func settingsPermissionsIncludeAutomation() {
        #expect(Permission.settingsDisplayOrder == [
            .screenRecording,
            .accessibility,
            .automation,
        ])
    }

    @Test("Onboarding permission sequence includes Automation after probeable permissions")
    func onboardingPermissionsIncludeAutomation() {
        #expect(Permission.onboardingDisplayOrder == [
            .screenRecording,
            .accessibility,
            .automation,
        ])
    }

    @Test("Exact text selection behavior uses a text quote icon")
    func textSelectionUsesTextQuoteIcon() {
        let envelope = BehaviorEnvelope(
            kind: "general.textSelection",
            citationKey: "general.textSelection:42",
            displaySummary: "Selected text",
            payload: .object([:])
        )

        #expect(ContextChipsView.behaviorIcon(for: envelope) == "text.quote")
    }

    @Test("Finder file selection behavior uses a file icon")
    func finderFileSelectionUsesFileIcon() {
        let envelope = BehaviorEnvelope(
            kind: "finder.selection",
            citationKey: "finder.selection",
            displaySummary: "Report.pdf",
            payload: .object([
                "items": .array([
                    .object(["role": .string("file")]),
                ]),
            ])
        )

        #expect(ContextChipsView.behaviorIcon(for: envelope) == "doc")
    }

    @Test("Finder folder selection behavior uses a folder icon")
    func finderFolderSelectionUsesFolderIcon() {
        let envelope = BehaviorEnvelope(
            kind: "finder.selection",
            citationKey: "finder.selection",
            displaySummary: "Assets",
            payload: .object([
                "items": .array([
                    .object(["role": .string("folder")]),
                ]),
            ])
        )

        #expect(ContextChipsView.behaviorIcon(for: envelope) == "folder")
    }
}
