import Testing
import Foundation
@testable import OSSenseKit

@Suite("PermissionsService — denied set projection")
struct PermissionsServiceTests {

    @Test("All granted → empty denied set")
    func allGranted() {
        let denied = PermissionsService.computeDeniedSet(
            axTrusted: true,
            screenRecordingGranted: true
        )
        #expect(denied.isEmpty)
    }

    @Test("Accessibility denied only")
    func accessibilityDeniedOnly() {
        let denied = PermissionsService.computeDeniedSet(
            axTrusted: false,
            screenRecordingGranted: true
        )
        #expect(denied == [.accessibility])
    }

    @Test("Screen recording denied only")
    func screenRecordingDeniedOnly() {
        let denied = PermissionsService.computeDeniedSet(
            axTrusted: true,
            screenRecordingGranted: false
        )
        #expect(denied == [.screenRecording])
    }

    @Test("Both denied")
    func bothDenied() {
        let denied = PermissionsService.computeDeniedSet(
            axTrusted: false,
            screenRecordingGranted: false
        )
        #expect(denied == [.accessibility, .screenRecording])
    }

    @Test("Automation is never reported by Stage 0 (no probe)")
    func automationNeverReported() {
        for ax in [true, false] {
            for sr in [true, false] {
                let denied = PermissionsService.computeDeniedSet(
                    axTrusted: ax,
                    screenRecordingGranted: sr
                )
                #expect(!denied.contains(.automation))
                #expect(!denied.contains(.localFiles))
            }
        }
    }

    @MainActor
    @Test("Default state is empty until refresh()")
    func defaultStateEmpty() {
        let svc = PermissionsService()
        #expect(svc.state.denied.isEmpty)
    }

    @MainActor
    @Test("Non-preflight onboarding acknowledgements are persisted separately from probed permissions")
    func nonPreflightAcknowledgementsPersistSeparately() {
        let suiteName = "notch-agent.permissions.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let svc = PermissionsService(userDefaults: defaults)
        #expect(!svc.automationOnboardingAcknowledged)
        #expect(!svc.localFilesOnboardingAcknowledged)
        #expect(svc.allGranted)
        #expect(!svc.onboardingPermissionsComplete)

        svc.acknowledgeAutomationOnboarding()
        #expect(!svc.onboardingPermissionsComplete)
        svc.acknowledgeLocalFilesOnboarding()

        #expect(svc.automationOnboardingAcknowledged)
        #expect(svc.localFilesOnboardingAcknowledged)
        #expect(svc.allGranted)
        #expect(svc.onboardingPermissionsComplete)
        let restored = PermissionsService(userDefaults: defaults)
        #expect(restored.automationOnboardingAcknowledged)
        #expect(restored.localFilesOnboardingAcknowledged)
    }

    @MainActor
    @Test("Automation request acknowledges only after consent probe succeeds")
    func automationRequestAcknowledgesOnlyAfterConsentProbeSucceeds() async throws {
        let suiteName = "notch-agent.permissions.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let probeRecorder = ProbeRecorder()

        let svc = PermissionsService(
            userDefaults: defaults,
            automationConsentProbe: {
                await probeRecorder.record()
            },
            localFilesConsentProbe: {},
            openSystemSettings: { _ in }
        )

        try await svc.request(.automation)

        #expect(await probeRecorder.count == 1)
        #expect(svc.automationOnboardingAcknowledged)
        let restored = PermissionsService(userDefaults: defaults)
        #expect(restored.automationOnboardingAcknowledged)
    }

    @MainActor
    @Test("Local files request acknowledges only after user-folder probe succeeds")
    func localFilesRequestAcknowledgesOnlyAfterUserFolderProbeSucceeds() async throws {
        let suiteName = "notch-agent.permissions.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let probeRecorder = ProbeRecorder()

        let svc = PermissionsService(
            userDefaults: defaults,
            automationConsentProbe: {},
            localFilesConsentProbe: {
                await probeRecorder.record()
            },
            openSystemSettings: { _ in }
        )

        try await svc.request(.localFiles)

        #expect(await probeRecorder.count == 1)
        #expect(svc.localFilesOnboardingAcknowledged)
        let restored = PermissionsService(userDefaults: defaults)
        #expect(restored.localFilesOnboardingAcknowledged)
    }

    @MainActor
    @Test("Local files request does not acknowledge when user-folder probe fails")
    func localFilesRequestDoesNotAcknowledgeWhenUserFolderProbeFails() async {
        struct ProbeFailure: Error {}
        let suiteName = "notch-agent.permissions.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let svc = PermissionsService(
            userDefaults: defaults,
            automationConsentProbe: {},
            localFilesConsentProbe: {
                throw ProbeFailure()
            },
            openSystemSettings: { _ in }
        )

        await #expect(throws: ProbeFailure.self) {
            try await svc.request(.localFiles)
        }
        #expect(!svc.localFilesOnboardingAcknowledged)
        let restored = PermissionsService(userDefaults: defaults)
        #expect(!restored.localFilesOnboardingAcknowledged)
    }

    @MainActor
    @Test("Automation request does not acknowledge when consent probe fails")
    func automationRequestDoesNotAcknowledgeWhenConsentProbeFails() async {
        struct ProbeFailure: Error {}
        let suiteName = "notch-agent.permissions.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let svc = PermissionsService(
            userDefaults: defaults,
            automationConsentProbe: {
                throw ProbeFailure()
            },
            localFilesConsentProbe: {},
            openSystemSettings: { _ in }
        )

        await #expect(throws: ProbeFailure.self) {
            try await svc.request(.automation)
        }
        #expect(!svc.automationOnboardingAcknowledged)
        let restored = PermissionsService(userDefaults: defaults)
        #expect(!restored.automationOnboardingAcknowledged)
    }
}

private actor ProbeRecorder {
    private var callCount = 0

    var count: Int { callCount }

    func record() {
        callCount += 1
    }
}
