import SwiftUI
import RPCSchema

// MARK: - OnboardPanelView
//
// Per docs/plans/onboarding.md §"NotchView 分流" + sub-state table.
// Shown in `.opened` when `providerService.hasReadyProvider == false`.
// Sub-states are derived from `providerService.statusLoaded` and
// `providerService.loginSession.state`. The view never owns navigation —
// flipping back to `OpenedPanelView` happens automatically once
// `hasReadyProvider` becomes true (success path: refreshStatus reply).

struct OnboardPanelView: View {
    let providerService: ProviderService
    let topSafeInset: CGFloat

    /// Inline API-key entry state — set when the user taps an apiKey-auth
    /// provider card. Replaces the provider list, mirroring how
    /// `loginSession` replaces it for OAuth providers. Lives in @State so
    /// the draft survives view re-renders driven by other observable changes
    /// (e.g. `statusChanged` for unrelated providers).
    @State private var apiKeyEntry: ApiKeyEntry?

    private struct ApiKeyEntry: Equatable {
        var providerId: String
        var providerName: String
        var draft: String
        var error: String?
        var saving: Bool
    }

    var body: some View {
        // No `Spacer` / `maxHeight: .infinity` — outer NotchView pins the
        // width and reads our intrinsic height via PreferenceKey. A flexing
        // child here would cause SwiftUI to re-measure during the tray's
        // expand animation and report 1–2pt drift, visibly nudging the
        // notch panel height every time the drawer toggles.
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .notchFont(size: 13, weight: .semibold)
                .foregroundStyle(.white.opacity(0.9))
            content
        }
        .padding(.top, topSafeInset + 4)
        .padding(.leading, 24)
        .padding(.trailing, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var headline: String {
        if let entry = apiKeyEntry {
            return "Enter \(entry.providerName) API key"
        }
        guard let session = providerService.loginSession else {
            if !providerService.statusLoaded {
                return providerService.statusError == nil
                    ? "Loading sign-in options…"
                    : "Couldn't reach sidecar"
            }
            return "Choose a sign-in method"
        }
        switch session.state {
        case .awaitingCallback: return "Waiting for browser"
        case .exchanging: return "Verifying"
        case .failed: return "Sign-in failed"
        case .success: return "Signed in"
        }
    }

    @ViewBuilder
    private var content: some View {
        if apiKeyEntry != nil {
            apiKeyEntryCard
        } else if let session = providerService.loginSession {
            inflightCard(session)
        } else {
            ForEach(providerService.providers) { p in
                ProviderCard(
                    name: p.name,
                    subtitle: subtitle(for: p),
                    style: cardStyle(for: p),
                    enabled: providerService.canStartLogin && p.state == .unauthenticated,
                    onTap: { handleProviderTap(p) }
                )
            }
        }
    }

    /// Route by `authMethod`: OAuth providers go through the existing
    /// `startLogin` flow; apiKey providers switch the panel into inline
    /// API-key entry mode.
    private func handleProviderTap(_ p: ProviderService.Provider) {
        switch p.authMethod {
        case .oauth:
            Task { await providerService.startLogin(providerId: p.id) }
        case .apiKey:
            do {
                apiKeyEntry = ApiKeyEntry(
                    providerId: p.id,
                    providerName: p.name,
                    draft: try providerService.peekApiKey(providerId: p.id) ?? "",
                    error: nil,
                    saving: false
                )
            } catch {
                apiKeyEntry = ApiKeyEntry(
                    providerId: p.id,
                    providerName: p.name,
                    draft: "",
                    error: ProviderService.message(for: error),
                    saving: false
                )
            }
        }
    }

    private func subtitle(for p: ProviderService.Provider) -> String {
        switch p.state {
        case .ready: return "Signed in"
        case .unauthenticated:
            guard providerService.canStartLogin else { return "Loading…" }
            switch p.authMethod {
            case .oauth:  return "Click to sign in"
            case .apiKey: return "Click to add API key"
            }
        case .unknown:
            // First-paint state before sidecar replies. Render a loading copy
            // rather than a clickable affordance.
            return providerService.statusError ?? "Loading…"
        }
    }

    private func cardStyle(for p: ProviderService.Provider) -> ProviderCard.Style {
        if !providerService.canStartLogin || p.state == .unknown {
            return .loading
        }
        return .normal
    }

    @ViewBuilder
    private func inflightCard(_ session: ProviderService.LoginSession) -> some View {
        let provider = providerService.providers.first(where: { $0.id == session.providerId })
        let name = provider?.name ?? session.providerId

        switch session.state {
        case .awaitingCallback:
            ProviderCard(
                name: name,
                subtitle: "Opened in browser, please complete the sign-in",
                style: .inflight,
                enabled: false,
                onTap: {}
            )
            cancelButton
        case .exchanging:
            ProviderCard(
                name: name,
                subtitle: "Verifying…",
                style: .inflight,
                enabled: false,
                onTap: {}
            )
            cancelButton
        case .failed:
            ProviderCard(
                name: name,
                subtitle: session.message ?? "Sign-in failed",
                style: .failed,
                enabled: false,
                onTap: {}
            )
            HStack(spacing: 8) {
                Button("Retry") {
                    Task {
                        providerService.dismissLoginSession()
                        await providerService.startLogin(providerId: session.providerId)
                    }
                }
                Button("Dismiss") {
                    providerService.dismissLoginSession()
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white.opacity(0.85))
            .notchFont(size: 12)
        case .success:
            ProviderCard(
                name: name,
                subtitle: "Signed in ✓",
                style: .success,
                enabled: false,
                onTap: {}
            )
        }
    }

    private var cancelButton: some View {
        Button("Cancel") {
            Task {
                do {
                    try await providerService.cancelLogin()
                } catch {
                    // ProviderService stamps the active login session as
                    // failed before throwing, so the inflight card updates.
                }
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white.opacity(0.85))
        .notchFont(size: 12)
    }

    // MARK: - API key entry card
    //
    // Mirrors the SecureField / Save / Cancel flow used in Settings, but
    // inline in the onboard panel. Once `saveApiKey` succeeds, the sidecar
    // emits `provider.statusChanged → ready`, `hasReadyProvider` flips, and
    // NotchView swaps this panel out for OpenedPanelView automatically — no
    // explicit navigation here.

    @ViewBuilder
    private var apiKeyEntryCard: some View {
        if let entry = apiKeyEntry {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stored locally in macOS Keychain.")
                    .notchFont(size: 11)
                    .notchForeground(.secondary)

                SecureField("sk-…", text: apiKeyDraftBinding)
                    .textFieldStyle(.plain)
                    .notchFont(size: 13, design: .monospaced)
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.06))
                    )

                if let err = entry.error {
                    Text(err)
                        .notchFont(size: 11)
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await commitApiKey() }
                    } label: {
                        Text(entry.saving ? "Saving…" : "Save")
                            .notchFont(size: 12, weight: .semibold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.9))
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(entry.saving || entry.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") {
                        apiKeyEntry = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.85))
                    .notchFont(size: 12)
                    .disabled(entry.saving)
                }
            }
        }
    }

    private var apiKeyDraftBinding: Binding<String> {
        Binding(
            get: { apiKeyEntry?.draft ?? "" },
            set: { newValue in
                guard var e = apiKeyEntry else { return }
                e.draft = newValue
                apiKeyEntry = e
            }
        )
    }

    private func commitApiKey() async {
        guard var entry = apiKeyEntry else { return }
        entry.saving = true
        entry.error = nil
        apiKeyEntry = entry
        do {
            try await providerService.saveApiKey(providerId: entry.providerId, apiKey: entry.draft)
            // Success — clear local state. The view swap is driven by
            // `hasReadyProvider` flipping via the sidecar's statusChanged.
            apiKeyEntry = nil
        } catch {
            entry.saving = false
            entry.error = ProviderService.message(for: error)
            apiKeyEntry = entry
        }
    }
}

// MARK: - ProviderCard

private struct ProviderCard: View {
    enum Style { case normal, loading, inflight, failed, success }

    let name: String
    let subtitle: String
    let style: Style
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        // Real `Button` so VoiceOver gets the button trait, Voice Control
        // can target by name, and keyboard activation works. The previous
        // `.onTapGesture` made the card invisible to assistive tech.
        Button(action: onTap) {
            HStack(spacing: 10) {
                if style == .loading || style == .inflight {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else if style == .success {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if style == .failed {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .notchFont(size: 13, weight: .medium)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .notchFont(size: 11)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(background)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.85)
        .accessibilityLabel(Text(name))
        .accessibilityHint(Text(subtitle))
    }

    private var background: Color {
        switch style {
        case .normal:    return .white.opacity(0.06)
        case .loading:   return .white.opacity(0.04)
        case .inflight:  return .white.opacity(0.10)
        case .failed:    return .red.opacity(0.12)
        case .success:   return .green.opacity(0.12)
        }
    }
}
