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

    @Test("Settings permission management does not use Automation reviewed state")
    func settingsPermissionManagementDoesNotUseAutomationReviewedState() throws {
        let source = try String(
            contentsOfFile: "Sources/AOSShell/Notch/Components/SettingsPanelView.swift",
            encoding: .utf8
        )

        #expect(!source.contains("automationOnboardingAcknowledged"))
        #expect(!source.contains("acknowledgeAutomationOnboarding"))
        #expect(!source.contains("needsReview"))
        #expect(!source.contains("reviewed"))
    }

    @Test("Reset user data script clears all app state and permissions")
    func resetUserDataScriptClearsAllAppStateAndPermissions() throws {
        let script = try String(
            contentsOfFile: "Scripts/reset-user-data.sh",
            encoding: .utf8
        )

        #expect(script.contains("APIKEY_SERVICE=\"com.aos.apikey\""))
        #expect(script.contains("security delete-generic-password -s \"${APIKEY_SERVICE}\""))
        #expect(script.contains("defaults delete \"${BUNDLE_ID}\""))
        #expect(script.contains("AppleEvents"))
    }

    @Test("Automation uses Finder icon only during onboarding")
    func automationUsesFinderIconOnlyDuringOnboarding() throws {
        let onboardingSource = try String(
            contentsOfFile: "Sources/AOSShell/Notch/Components/PermissionOnboardPanelView.swift",
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOfFile: "Sources/AOSShell/Notch/Components/SettingsPanelView.swift",
            encoding: .utf8
        )

        #expect(onboardingSource.contains("PermissionGlyph(permission: permission, size: 64, automationIcon: .finder)"))
        #expect(settingsSource.contains("PermissionGlyph(permission: permission, size: 28)"))
        #expect(!settingsSource.contains("automationIcon: .finder"))
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
