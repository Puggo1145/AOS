import SwiftUI
import AOSRPCSchema
import AOSOSSenseKit

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
    @State private var quitConfirming: Bool = false
    @State private var quitConfirmTask: Task<Void, Never>? = nil
    @State private var apiKeyDraft: String = ""
    @State private var apiKeySaveError: String? = nil
    @State private var apiKeySaving: Bool = false

    private enum Page: Equatable {
        case main
        case provider
        case model
        case effort
        case permissions
        case apiKey
    }

    var body: some View {
        ZStack {
            switch page {
            case .main:
                mainPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            case .provider:
                providerPickerPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .model:
                modelPickerPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .effort:
                effortPickerPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .permissions:
                permissionsPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .apiKey:
                apiKeyPage
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
        .animation(.notchChrome, value: page)
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Text("Settings")
                        .font(.system(size: 18, weight: .semibold))
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
                apiKeyRow(provider: p)
            }

            // OAuth row mirrors the apiKey row's contract: always present
            // for OAuth-auth providers so the user can sign in (when not
            // authed) or re-authenticate (when already signed in). Without
            // a re-auth path, a stale token + no UI surface means the user
            // has to nuke `~/.aos/auth/` by hand.
            if let p = currentRuntimeProvider, p.authMethod == .oauth {
                signInRow(provider: p)
            }

            permissionsRow

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

    private func apiKeyRow(provider: ProviderService.Provider) -> some View {
        Button {
            // Pre-load the existing key into the draft so the field reads
            // "ready to edit" rather than asking the user to re-type. We
            // round-trip through Keychain explicitly — the sidecar's in-memory
            // copy is not a source the UI can read back.
            apiKeyDraft = (try? providerService.peekApiKey(providerId: provider.id)) ?? ""
            apiKeySaveError = nil
            page = .apiKey
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text("API Key")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                // SF Symbol + color: state is conveyed by glyph shape, not
                // only hue, so the row reads correctly for color-blind users
                // and in increased-contrast mode.
                if provider.state == .ready {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.85))
                        .accessibilityHidden(true)
                    Text("Saved")
                        .font(.system(size: 11))
                        .notchForeground(.secondary)
                        .accessibilityLabel(Text("API key saved"))
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .accessibilityHidden(true)
                    Text("Required")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.9))
                        .accessibilityLabel(Text("API key required"))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .notchForeground(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var apiKeyPage: some View {
        let providerName = currentRuntimeProvider?.name ?? "Provider"
        let providerId = currentRuntimeProvider?.id ?? ""
        return pickerPage(title: "\(providerName) API Key") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stored locally in macOS Keychain. Never written to disk by the agent process.")
                    .font(.system(size: 11))
                    .notchForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("sk-…", text: $apiKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                if let err = apiKeySaveError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await saveApiKey(providerId: providerId) }
                    } label: {
                        Text(apiKeySaving ? "Saving…" : "Save")
                            .font(.system(size: 12, weight: .semibold))
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
                                .font(.system(size: 12, weight: .semibold))
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
        let err = await providerService.saveApiKey(providerId: providerId, apiKey: apiKeyDraft)
        apiKeySaving = false
        if let err {
            apiKeySaveError = err
        } else {
            page = .main
        }
    }

    private func clearApiKey(providerId: String) async {
        apiKeySaving = true
        apiKeySaveError = nil
        let err = await providerService.clearApiKey(providerId: providerId)
        apiKeySaving = false
        if let err {
            apiKeySaveError = err
        } else {
            apiKeyDraft = ""
            page = .main
        }
    }

    // MARK: - OAuth sign-in row
    //
    // Surfaces the same `providerService.startLogin` path that the Onboard
    // panel uses, so a user who skipped (or unselected) an OAuth provider
    // during onboarding can still sign in later. The row mirrors the
    // active `loginSession` for this provider so the in-flight states
    // (awaiting / verifying / failed) are visible without jumping back to
    // Onboard.

    private func signInRow(provider: ProviderService.Provider) -> some View {
        let session = providerService.loginSession.flatMap {
            $0.providerId == provider.id ? $0 : nil
        }
        let isReady = provider.state == .ready
        // Single button. Label + status text both flip on auth state; tap
        // either signs in OR re-auths (logout + startLogin) — the user
        // never has to choose between two near-identical actions.
        // SF Symbol pairs with the color so colorblind / increased-contrast
        // users see a distinct shape per state, not just a hue swap.
        let (statusText, statusColor, statusGlyph, isInflight): (String, Color, String, Bool) = {
            if let s = session {
                switch s.state {
                case .awaitingCallback: return ("Opened in browser…", Color.white.opacity(0.6), "hourglass", true)
                case .exchanging:       return ("Verifying…",         Color.white.opacity(0.6), "hourglass", true)
                case .failed:           return (s.message ?? "Sign-in failed", Color.red.opacity(0.85), "exclamationmark.circle.fill", false)
                case .success:          return ("Signed in",          Color.green.opacity(0.85), "checkmark.circle.fill", false)
                }
            }
            if isReady { return ("Signed in", Color.green.opacity(0.85), "checkmark.circle.fill", false) }
            return ("Required", Color.red.opacity(0.85), "exclamationmark.circle.fill", false)
        }()
        let rowTitle = isReady ? "Re-authenticate \(provider.name)" : "Sign in to \(provider.name)"
        let onTap: () -> Void = {
            guard providerService.canStartLogin, !isInflight else { return }
            Task {
                if session?.state == .failed {
                    providerService.dismissLoginSession()
                }
                if isReady {
                    _ = await providerService.logout(providerId: provider.id)
                }
                await providerService.startLogin(providerId: provider.id)
            }
        }

        return VStack(alignment: .leading, spacing: 6) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 16)
                    Text(rowTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer(minLength: 8)
                    Image(systemName: statusGlyph)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .notchForeground(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isInflight || !providerService.canStartLogin)

            if isInflight {
                Button("Cancel") {
                    Task { await providerService.cancelLogin() }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white.opacity(0.85))
                .font(.system(size: 11))
                .padding(.leading, 12)
            }
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
        Permission.settingsDisplayOrder.filter { permissionsService.state.denied.contains($0) }
    }

    private var permissionsRow: some View {
        Button {
            page = .permissions
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text("Permissions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                if missingPermissions.isEmpty {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.7))
                        .accessibilityHidden(true)
                    Text("All granted")
                        .font(.system(size: 11))
                        .notchForeground(.secondary)
                } else {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .accessibilityHidden(true)
                    Text("\(missingPermissions.count) missing")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.9))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .notchForeground(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var permissionsPage: some View {
        pickerPage(title: "Permissions") {
            VStack(spacing: 8) {
                ForEach(Permission.settingsDisplayOrder, id: \.self) { p in
                    PermissionStatusRow(
                        permission: p,
                        status: permissionStatus(for: p),
                        onOpenSettings: {
                            permissionsService.openSystemSettings(for: p)
                        }
                    )
                }
            }
        }
    }

    private func permissionStatus(for permission: Permission) -> PermissionStatusRow.Status {
        switch permission {
        case .screenRecording, .accessibility:
            return permissionsService.state.denied.contains(permission) ? .disabled : .granted
        case .automation:
            return .opensSettings
        }
    }

    // MARK: - Dev Mode
    //
    // Posts `.aosOpenDevMode`; the CompositionRoot's DevModeWindowController
    // listens and presents the standalone Dev Mode window. We deliberately
    // do not pass a callback through the view tree — the dev surface stays
    // fully optional and decoupled from notch composition.

    private var devModeRow: some View {
        Button {
            NotificationCenter.default.post(name: .aosOpenDevMode, object: nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "hammer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text("Dev Mode")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 10, weight: .semibold))
                    .notchForeground(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quit
    //
    // Two-tap confirm: first tap arms the button (label flips to a red
    // "Confirm Quit?" state); second tap within 3s terminates the app.
    // Auto-disarms after the window so a stray click never quits.

    private var quitButton: some View {
        Button(action: handleQuitTap) {
            HStack(spacing: 6) {
                Image(systemName: quitConfirming ? "exclamationmark.triangle.fill" : "power")
                    .font(.system(size: 12, weight: .semibold))
                Text(quitConfirming ? "Confirm Quit?" : "Quit AOS")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(quitConfirming ? Color.white : Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(quitConfirming
                          ? Color.red.opacity(0.85)
                          : Color.white.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: quitConfirming)
    }

    private func handleQuitTap() {
        if quitConfirming {
            quitConfirmTask?.cancel()
            NSApp.terminate(nil)
            return
        }
        quitConfirming = true
        quitConfirmTask?.cancel()
        quitConfirmTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                quitConfirming = false
            }
        }
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
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
            .font(.system(size: 12))
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

// MARK: - PermissionStatusRow

/// One row per permission inside the Permissions sub-page. Reads the
/// live `denied` set; tap → opens the matching Privacy pane in System
/// Settings. The state pill mirrors the convention used elsewhere
/// (green check / red dot).
private struct PermissionStatusRow: View {
    enum Status {
        case granted
        case disabled
        case opensSettings
    }

    let permission: Permission
    let status: Status
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PermissionGlyph(permission: permission, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(status.label)
                    .font(.system(size: 11))
                    .foregroundStyle(status.tint)
            }

            Spacer(minLength: 8)

            Button(action: onOpenSettings) {
                Text(status.buttonTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(status.buttonFill)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private extension PermissionStatusRow.Status {
    var label: String {
        switch self {
        case .granted: return "Granted"
        case .disabled: return "Disabled"
        case .opensSettings: return "System Settings"
        }
    }

    var buttonTitle: String {
        switch self {
        case .granted: return "Manage"
        case .disabled, .opensSettings: return "Open Settings"
        }
    }

    var tint: Color {
        switch self {
        case .granted:
            return Color.green.opacity(0.85)
        case .disabled:
            return Color.red.opacity(0.85)
        case .opensSettings:
            return Color.white.opacity(0.58)
        }
    }

    var buttonFill: Color {
        switch self {
        case .granted, .opensSettings:
            return Color.white.opacity(0.10)
        case .disabled:
            return Color.accentColor.opacity(0.85)
        }
    }
}
