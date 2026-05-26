import SwiftUI
import RPCSchema
import OSSenseKit

// MARK: - SettingsPanelView
//
// Two-page navigation inside the same panel:
//
//   .main
//     Settings
//     ┌─ Provider ─┐  ┌─ Model ─┐
//     │  Codex…    │  │ GPT-5.5 │
//     └────────────┘  └─────────┘
//
//   .picker (provider | model)
//     ‹ Provider
//     ◉ Codex Subscription
//     ◯ ...
//
// Tap a card → push to picker page; tap a row → commit + pop back. The
// transition is a horizontal slide so it reads as page-level navigation
// instead of an in-place reveal. ESC pops one level (or closes settings
// if already on .main).

struct SettingsPanelView: View {
    let configService: ConfigService
    let providerService: ProviderService
    let permissionsService: PermissionsService
    let topSafeInset: CGFloat
    let onClose: () -> Void

    @State private var page: Page = .main
    @State private var apiKeyDraft: String = ""
    @State private var apiKeySaveError: String? = nil
    @State private var apiKeySaving: Bool = false
    @State private var permissionRequestError: String? = nil
    @AppStorage("notch-agent.conversationDisplayMode") private var displayModeRaw: String = ConversationDisplayMode.history.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Page: Equatable {
        case main
        case provider
        case model
        case effort
        case displayMode
        case permissions
        case apiKey
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch page {
            case .main:
                mainPage
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            case .provider:
                providerPickerPage
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .model:
                modelPickerPage
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .effort:
                effortPickerPage
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .displayMode:
                displayModePickerPage
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .permissions:
                permissionsPage
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .apiKey:
                apiKeyPage
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .task {
            // While Settings is open, poll so toggling in System
            // Settings is reflected immediately. The probe is async on
            // purpose — the screen recording arm uses
            // SCShareableContent.current, the only live source (see
            // PermissionsService).
            while !Task.isCancelled {
                await permissionsService.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .notchChrome, value: page)
        .onExitCommand {
            if page == .main { onClose() } else { page = .main }
        }
    }

    // MARK: - Main page

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .notchFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.65))
                    Text("Settings")
                        .notchFont(size: 18, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.95))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configService.providers.isEmpty {
                placeholder
            } else {
                HStack(alignment: .top, spacing: 10) {
                    BentoPickerCard(
                        caption: "Provider",
                        valueTitle: selectedProvider?.name ?? "—",
                        onTap: { page = .provider }
                    )
                    BentoPickerCard(
                        caption: "Model",
                        valueTitle: selectedModel?.name ?? "—",
                        isEnabled: !(selectedProvider?.models.isEmpty ?? true),
                        onTap: { page = .model }
                    )
                    BentoPickerCard(
                        caption: "Effort",
                        // Show "Unsupported" instead of a stale effort
                        // label when the current model has no reasoning
                        // capability — clearer than greying out a value
                        // the user can never reach.
                        valueTitle: currentEffort?.label ?? "Unsupported",
                        isEnabled: selectedModel?.reasoning ?? false,
                        onTap: { page = .effort }
                    )
                }
            }

            // API key row appears only for apiKey-auth providers (e.g. DeepSeek).
            // Hidden for OAuth providers — chatgpt-plan handles auth via the
            // separate Onboard panel.
            if let p = currentRuntimeProvider, p.authMethod == .apiKey {
                SettingsAPIKeyRow(provider: p) {
                    openApiKeyPage(provider: p)
                }
            }

            // OAuth row mirrors the apiKey row's contract: always present
            // for OAuth-auth providers so the user can sign in (when not
            // authed) or re-authenticate (when already signed in). Without
            // a re-auth path, a stale token + no UI surface means the user
            // has to nuke `~/.notch-agent/auth/` by hand.
            if let p = currentRuntimeProvider, p.authMethod == .oauth {
                SettingsOAuthRow(
                    provider: p,
                    providerService: providerService,
                    onError: { apiKeySaveError = $0 }
                )
            }

            permissionsRow

            displayModeRow

            devModeRow

            quitButton
        }
        .padding(.top, topSafeInset)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    // MARK: - API key row + page

    /// The runtime provider corresponding to the currently *selected* (catalog)
    /// provider id — joins the catalog-projection (`ConfigService.providers`)
    /// to the live state (`ProviderService.providers`). Returns `nil` if the
    /// runtime hasn't yet enumerated the selected provider.
    private var currentRuntimeProvider: ProviderService.Provider? {
        guard let selectedId = selectedProvider?.id else { return nil }
        return providerService.providers.first { $0.id == selectedId }
    }

    private func openApiKeyPage(provider: ProviderService.Provider) {
        // Pre-load the existing key into the draft so the field reads
        // "ready to edit" rather than asking the user to re-type. We
        // round-trip through Keychain explicitly — the sidecar's in-memory
        // copy is not a source the UI can read back.
        do {
            apiKeyDraft = try providerService.peekApiKey(providerId: provider.id) ?? ""
            apiKeySaveError = nil
            page = .apiKey
        } catch {
            apiKeyDraft = ""
            apiKeySaveError = ProviderService.message(for: error)
            page = .apiKey
        }
    }

    private var apiKeyPage: some View {
        let providerName = currentRuntimeProvider?.name ?? "Provider"
        let providerId = currentRuntimeProvider?.id ?? ""
        return pickerPage(title: "\(providerName) API Key") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stored locally in macOS Keychain. Never written to disk by the agent process.")
                    .notchFont(size: 11)
                    .notchForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("sk-…", text: $apiKeyDraft)
                    .textFieldStyle(.plain)
                    .notchFont(size: 13, design: .monospaced)
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                if let err = apiKeySaveError {
                    Text(err)
                        .notchFont(size: 11)
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await saveApiKey(providerId: providerId) }
                    } label: {
                        Text(apiKeySaving ? "Saving…" : "Save")
                            .notchFont(size: 12, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.9))
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(apiKeySaving || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if currentRuntimeProvider?.state == .ready {
                        Button {
                            Task { await clearApiKey(providerId: providerId) }
                        } label: {
                            Text("Clear")
                                .notchFont(size: 12, weight: .semibold)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                )
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .disabled(apiKeySaving)
                    }
                }
            }
        }
    }

    private func saveApiKey(providerId: String) async {
        apiKeySaving = true
        apiKeySaveError = nil
        do {
            try await providerService.saveApiKey(providerId: providerId, apiKey: apiKeyDraft)
            apiKeySaving = false
            page = .main
        } catch {
            apiKeySaving = false
            apiKeySaveError = ProviderService.message(for: error)
        }
    }

    private func clearApiKey(providerId: String) async {
        apiKeySaving = true
        apiKeySaveError = nil
        do {
            try await providerService.clearApiKey(providerId: providerId)
            apiKeySaving = false
            apiKeyDraft = ""
            page = .main
        } catch {
            apiKeySaving = false
            apiKeySaveError = ProviderService.message(for: error)
        }
    }

    // MARK: - Permissions row + page
    //
    // The settings main page surfaces a one-line permissions summary that
    // doubles as the entry point to the dedicated permissions sub-page.
    // A red dot lights up when a probeable permission is missing. Automation
    // has no safe status API here; its row is a direct jump to System
    // Settings.

    private var missingPermissions: [Permission] {
        Self.missingProbeablePermissions(denied: permissionsService.state.denied)
    }

    private var permissionsRow: some View {
        SettingsPermissionsSummaryRow(missingCount: missingPermissions.count) {
            page = .permissions
        }
    }

    private var permissionsPage: some View {
        pickerPage(title: "Permissions") {
            VStack(spacing: 8) {
                ForEach(Permission.settingsDisplayOrder, id: \.self) { p in
                    PermissionStatusRow(
                        permission: p,
                        status: permissionStatus(for: p),
                        onOpenSettings: {
                            handlePermissionSettingsAction(p)
                        }
                    )
                }
                if let permissionRequestError {
                    Text(permissionRequestError)
                        .notchFont(size: 11)
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func missingProbeablePermissions(denied: Set<Permission>) -> [Permission] {
        Permission.settingsDisplayOrder.filter { permission in
            switch permission {
            case .screenRecording, .accessibility:
                return denied.contains(permission)
            case .localFiles, .automation:
                return false
            }
        }
    }

    static func permissionStatus(
        for permission: Permission,
        denied: Set<Permission>
    ) -> PermissionSettingsStatus {
        switch permission {
        case .screenRecording, .accessibility:
            return denied.contains(permission) ? .disabled : .granted
        case .localFiles, .automation:
            return .opensSettings
        }
    }

    private func permissionStatus(for permission: Permission) -> PermissionSettingsStatus {
        switch permission {
        case .localFiles:
            return permissionsService.localFilesOnboardingAcknowledged ? .granted : .opensSettings
        case .accessibility, .screenRecording, .automation:
            return Self.permissionStatus(for: permission, denied: permissionsService.state.denied)
        }
    }

    private func handlePermissionSettingsAction(_ permission: Permission) {
        switch permission {
        case .localFiles:
            guard !permissionsService.localFilesOnboardingAcknowledged else {
                permissionsService.openSystemSettings(for: permission)
                return
            }
            Task {
                do {
                    permissionRequestError = nil
                    try await permissionsService.request(.localFiles)
                } catch {
                    permissionRequestError = "Permission request failed: \(error)"
                }
            }
        case .accessibility, .screenRecording, .automation:
            permissionRequestError = nil
            permissionsService.openSystemSettings(for: permission)
        }
    }

    // MARK: - Conversation display mode

    private var displayMode: ConversationDisplayMode {
        ConversationDisplayMode(rawValue: displayModeRaw)!
    }

    private var displayModeRow: some View {
        SettingsDisplayModeRow(displayMode: displayMode) {
            page = .displayMode
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

    // MARK: - Picker pages

    private var providerPickerPage: some View {
        pickerPage(title: "Provider") {
            BentoOptionsList(
                options: configService.providers.map {
                    BentoOption(id: $0.id, title: $0.name)
                },
                selectedId: selectedProvider?.id ?? "",
                onSelect: { newProviderId in
                    Task {
                        await handleProviderChange(newProviderId)
                        page = .main
                    }
                }
            )
        }
    }

    private var modelPickerPage: some View {
        pickerPage(title: "Model") {
            if let provider = selectedProvider {
                BentoOptionsList(
                    options: provider.models.map { BentoOption(id: $0.id, title: $0.name) },
                    selectedId: selectedModel?.id ?? "",
                    onSelect: { newModelId in
                        Task {
                            await configService.selectModel(providerId: provider.id, modelId: newModelId)
                            page = .main
                        }
                    }
                )
            }
        }
    }

    private var effortPickerPage: some View {
        pickerPage(title: "Effort") {
            BentoOptionsList(
                options: effortOptions,
                selectedId: currentEffort?.value ?? "",
                onSelect: { rawValue in
                    guard let value = selectedModel?.supportedEfforts.first(where: { $0.value == rawValue }) else { return }
                    Task {
                        await configService.selectEffort(value)
                        page = .main
                    }
                }
            )
        }
    }

    private var displayModePickerPage: some View {
        pickerPage(title: "Display Mode") {
            BentoOptionsList(
                options: ConversationDisplayMode.allCases.map {
                    BentoOption(id: $0.rawValue, title: $0.label)
                },
                selectedId: displayMode.rawValue,
                onSelect: { rawValue in
                    displayModeRaw = rawValue
                    page = .main
                }
            )
        }
    }

    /// Build effort rows from the sidecar-reported supported list.
    /// Each row's id/title come straight from the catalog — no local
    /// mapping table.
    private var effortOptions: [BentoOption] {
        let efforts = selectedModel?.supportedEfforts ?? []
        return efforts.map { e in BentoOption(id: e.value, title: e.label) }
    }

    private var currentEffort: ConfigEffort? {
        configService.effort(for: selectedModel)
    }

    @ViewBuilder
    private func pickerPage<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                page = .main
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .notchFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.65))
                    Text(title)
                        .notchFont(size: 18, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.95))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView {
                content()
            }
        }
        .padding(.top, topSafeInset)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var placeholder: some View {
        Text(configService.loaded ? "No providers available." : "Loading…")
            .notchFont(size: 12)
            .notchForeground(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    // MARK: - Selection helpers

    private var selectedProvider: ConfigProviderEntry? {
        guard let sel = configService.effectiveSelection else { return configService.providers.first }
        return configService.providers.first(where: { $0.id == sel.providerId }) ?? configService.providers.first
    }

    private var selectedModel: ConfigModelEntry? {
        guard let provider = selectedProvider else { return nil }
        let modelId = configService.effectiveSelection?.modelId ?? provider.defaultModelId
        return provider.models.first(where: { $0.id == modelId }) ?? provider.models.first
    }

    private func handleProviderChange(_ newProviderId: String) async {
        guard let target = configService.providers.first(where: { $0.id == newProviderId }) else { return }
        await configService.selectModel(providerId: target.id, modelId: target.defaultModelId)
    }
}
