import SwiftUI
import AOSRPCSchema

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            content
            Spacer(minLength: 0)
        }
        .padding(.top, topSafeInset + 4)
        .padding(.leading, 24)
        .padding(.trailing, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headline: String {
        guard let session = providerService.loginSession else {
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
        if let session = providerService.loginSession {
            inflightCard(session)
        } else {
            ForEach(providerService.providers) { p in
                ProviderCard(
                    name: p.name,
                    subtitle: subtitle(for: p),
                    style: .normal,
                    enabled: p.state == .unauthenticated,
                    onTap: {
                        Task { await providerService.startLogin(providerId: p.id) }
                    }
                )
            }
        }
    }

    private func subtitle(for p: ProviderService.Provider) -> String {
        switch p.state {
        case .ready: return "Signed in"
        case .unauthenticated: return "Click to sign in"
        }
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
            .font(.system(size: 12))
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
            Task { await providerService.cancelLogin() }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white.opacity(0.85))
        .font(.system(size: 12))
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
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
        .onTapGesture { if enabled { onTap() } }
        .opacity(enabled ? 1.0 : 0.85)
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
