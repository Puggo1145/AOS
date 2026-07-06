import SwiftUI

// MARK: - SettingsApiKeyPage

struct SettingsApiKeyPage: View {
    @Bindable var flow: SettingsFlowModel
    let topSafeInset: CGFloat

    var body: some View {
        SettingsPickerPageChrome(
            title: "\(providerName) API Key",
            topSafeInset: topSafeInset,
            onBack: { flow.pop() }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stored locally in macOS Keychain. Never written to disk by the agent process.")
                    .notchFont(size: 11)
                    .notchForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                NotchTextField(
                    placeholder: "sk-…",
                    text: $flow.apiKeyDraft,
                    isSecure: true,
                    fontSize: 13,
                    monospaced: true,
                    horizontalPadding: 12,
                    verticalPadding: 10,
                    cornerRadius: 10
                )

                if let err = flow.apiKeySaveError {
                    NotchErrorText(err)
                }

                HStack(spacing: 8) {
                    NotchPrimaryButton(title: flow.apiKeySaving ? "Saving…" : "Save") {
                        Task { await flow.saveApiKey() }
                    }
                    .disabled(flow.apiKeySaving || flow.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if flow.currentRuntimeProvider?.state == .ready {
                        NotchSecondaryButton(title: "Clear") {
                            Task { await flow.clearApiKey() }
                        }
                        .disabled(flow.apiKeySaving)
                    }
                }
            }
        }
    }

    private var providerName: String {
        flow.currentRuntimeProvider?.name ?? "Provider"
    }
}
