import SwiftUI
import RPCSchema

// MARK: - SettingsMainPage
//
// The Settings panel's landing page: header, provider/model/effort bento
// cards, the scrollable row list (API key / OAuth / permissions / MCP /
// permission level / display mode / dev mode), and the quit button.

struct SettingsMainPage: View {
    private let mainRowsScrollMaxHeight: CGFloat = 220

    let flow: SettingsFlowModel
    let topSafeInset: CGFloat
    @Binding var displayModeRaw: String
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayMode: ConversationDisplayMode {
        ConversationDisplayMode.from(raw: displayModeRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .notchFont(size: 13, weight: .semibold)
                        .notchForeground(.secondary)
                    Text("Settings")
                        .notchFont(size: 18, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.95))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if flow.configService.providers.isEmpty {
                placeholder
            } else {
                HStack(alignment: .top, spacing: 10) {
                    BentoPickerCard(
                        caption: "Provider",
                        valueTitle: flow.selectedProvider?.name ?? "—",
                        onTap: { flow.page = .provider }
                    )
                    BentoPickerCard(
                        caption: "Model",
                        valueTitle: flow.selectedModel?.name ?? "—",
                        isEnabled: !(flow.selectedProvider?.models.isEmpty ?? true),
                        onTap: { flow.page = .model }
                    )
                    BentoPickerCard(
                        caption: "Effort",
                        // Show "Unsupported" instead of a stale effort
                        // label when the current model has no reasoning
                        // capability — clearer than greying out a value
                        // the user can never reach.
                        valueTitle: flow.currentEffort?.label ?? "Unsupported",
                        isEnabled: flow.selectedModel?.reasoning ?? false,
                        onTap: { flow.page = .effort }
                    )
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // API key row appears only for apiKey-auth providers (e.g. DeepSeek).
                    // Hidden for OAuth providers — chatgpt-plan handles auth via the
                    // separate Onboard panel.
                    if let p = flow.currentRuntimeProvider, p.authMethod == .apiKey {
                        SettingsAPIKeyRow(provider: p) {
                            flow.openApiKeyPage(provider: p)
                        }
                    }

                    // OAuth row mirrors the apiKey row's contract: always present
                    // for OAuth-auth providers so the user can sign in (when not
                    // authed) or re-authenticate (when already signed in). Without
                    // a re-auth path, a stale token + no UI surface means the user
                    // has to nuke `~/.notch-agent/auth/` by hand.
                    if let p = flow.currentRuntimeProvider, p.authMethod == .oauth {
                        SettingsOAuthRow(
                            provider: p,
                            session: flow.oauthLoginSession(for: p.id),
                            canStartLogin: flow.providerService.canStartLogin,
                            onStartOrReauth: { flow.startOAuthFlow(provider: p) },
                            onCancel: { flow.cancelOAuthLogin() }
                        )
                    }

                    permissionsRow

                    mcpRow

                    permissionLevelRow

                    displayModeRow

                    devModeRow
                }
            }
            .frame(maxHeight: mainRowsScrollMaxHeight)

            quitButton
        }
        .padding(.top, topSafeInset)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var permissionsRow: some View {
        SettingsPermissionsSummaryRow(missingCount: flow.missingPermissions.count) {
            flow.page = .permissions
        }
    }

    private var mcpRow: some View {
        SettingsMcpSummaryRow(
            configuredCount: flow.mcpService.servers.count,
            connectedCount: flow.mcpService.servers.filter { $0.connectionState == .connected }.count
        ) {
            flow.page = .mcp
        }
    }

    private var permissionLevelRow: some View {
        SettingsPermissionLevelRow(permissionLevel: flow.configService.permissionLevel) {
            flow.page = .permissionLevel
        }
    }

    private var displayModeRow: some View {
        SettingsDisplayModeRow(displayMode: displayMode) {
            flow.page = .displayMode
        }
    }

    // MARK: - Dev Mode
    //
    // Posts `.notchOpenDevMode`; the CompositionRoot's DevModeWindowController
    // listens and presents the standalone Dev Mode window. We deliberately
    // do not pass a callback through the view tree — the dev surface stays
    // fully optional and decoupled from notch composition.
    private var devModeRow: some View {
        SettingsDevModeRow()
    }

    // MARK: - Quit
    //
    // Two-tap confirm: first tap arms the button (label flips to a red
    // "Confirm Quit?" state); second tap within 3s terminates the app.
    // Auto-disarms after the window so a stray click never quits.
    private var quitButton: some View {
        SettingsQuitButton(reduceMotion: reduceMotion)
    }

    private var placeholder: some View {
        Text(flow.configService.loaded ? "No providers available." : "Loading…")
            .notchFont(size: 12)
            .notchForeground(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }
}
