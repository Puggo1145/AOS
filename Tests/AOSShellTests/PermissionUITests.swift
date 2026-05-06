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

    @Test("Settings missing permissions ignore Automation acknowledgement state")
    func settingsMissingPermissionsIgnoreAutomationAcknowledgementState() {
        #expect(SettingsPanelView.missingProbeablePermissions(denied: []) == [])
        #expect(SettingsPanelView.missingProbeablePermissions(denied: [.automation]) == [])
        #expect(SettingsPanelView.missingProbeablePermissions(denied: [.accessibility, .automation]) == [.accessibility])
    }

    @Test("Settings Automation row opens System Settings instead of using reviewed state")
    func settingsAutomationRowOpensSystemSettingsInsteadOfUsingReviewedState() {
        #expect(SettingsPanelView.permissionStatus(for: .automation, denied: []) == .opensSettings)
        #expect(SettingsPanelView.permissionStatus(for: .screenRecording, denied: []) == .granted)
        #expect(SettingsPanelView.permissionStatus(for: .screenRecording, denied: [.screenRecording]) == .disabled)
    }

    @Test("Automation uses Finder icon only during onboarding")
    func automationUsesFinderIconOnlyDuringOnboarding() {
        #expect(PermissionOnboardPanelView.automationIcon(for: .automation) == .finder)
        #expect(PermissionOnboardPanelView.automationIcon(for: .accessibility) == .gear)
        #expect(PermissionGlyph.defaultAutomationIcon == .gear)
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
