import SwiftUI
import AOSOSSenseKit

// MARK: - PermissionOnboardPanelView
//
// First leg of the onboard flow: gate the user through the runtime
// permissions OS Sense + Computer Use need (Screen Recording then
// Accessibility) before the provider sign-in step. Shown by NotchView
// when `!permissionsService.allGranted`.
//
// One permission card at a time. Tapping "Grant Access" triggers the
// system prompt + opens the matching Privacy pane in System Settings
// (the dual-trigger pattern from `playground/open-codex-computer-use` —
// macOS only fires the prompt the first time, opening Settings is the
// reliable fallback for stale-denied records). While the user is in
// Settings flipping the toggle, this view polls `refresh()` so the
// running probe values catch the change and the panel auto-advances
// to the next permission, then off the screen entirely.

struct PermissionOnboardPanelView: View {
    let permissionsService: PermissionsService
    let topSafeInset: CGFloat

    /// Order shown to the user. Screen Recording first because OS Sense
    /// (the read leg) is the first capability AOS uses; Accessibility
    /// follows for Computer Use.
    private static let order: [Permission] = [.screenRecording, .accessibility]

    private var current: Permission? {
        Self.order.first(where: { permissionsService.state.denied.contains($0) })
    }

    private var stepIndex: Int? {
        guard let current else { return nil }
        return Self.order.firstIndex(of: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current {
                PermissionCard(
                    permission: current,
                    stepIndex: stepIndex ?? 0,
                    totalSteps: Self.order.count,
                    onGrant: {
                        permissionsService.request(current)
                    }
                )
                .id(current)
                .transition(.blurReplace)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topSafeInset + 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.smooth(duration: 0.42, extraBounce: 0.05), value: current)
        .task(id: current) {
            // Poll while the user is granting. macOS does not push TCC
            // changes back to the running process, so we re-probe on a
            // 500ms cadence. The probe is intentionally async (see
            // PermissionsService — Screen Recording must go through
            // SCShareableContent.current, which queries TCC live, not
            // CGPreflightScreenCaptureAccess which caches per-process).
            while !Task.isCancelled {
                await permissionsService.refresh()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

// MARK: - PermissionCard

private struct PermissionCard: View {
    let permission: Permission
    let stepIndex: Int
    let totalSteps: Int
    let onGrant: () -> Void

    @State private var hovering: Bool = false
    @State private var pressed: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            iconBadge
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(permission.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    StepIndicator(index: stepIndex, total: totalSteps)
                }
                Text(permission.explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)

                Spacer(minLength: 6)

                grantButton
            }
        }
    }

    private var iconBadge: some View {
        PermissionGlyph(permission: permission, size: 64)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private var grantButton: some View {
        Button(action: onGrant) {
            Text("Grant Access")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(Color.accentColor.opacity(buttonOpacity))
                )
                .scaleEffect(pressed ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .animation(.snappy(duration: 0.16), value: pressed)
        .animation(.smooth(duration: 0.18), value: hovering)
    }

    /// Flat, single-tone fill per Apple HIG for primary buttons. Pressed
    /// → subtly darker; hover → subtly brighter; idle → solid accent.
    private var buttonOpacity: Double {
        if pressed { return 0.80 }
        if hovering { return 1.00 }
        return 0.92
    }
}

// MARK: - StepIndicator

/// Small dot row showing position in the multi-step flow. Only renders
/// when there are 2+ steps — single-step flows would be visual noise.
private struct StepIndicator: View {
    let index: Int
    let total: Int

    var body: some View {
        if total >= 2 {
            HStack(spacing: 5) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Color.white.opacity(0.85) : Color.white.opacity(0.22))
                        .frame(width: i == index ? 14 : 5, height: 5)
                        .animation(.smooth(duration: 0.32), value: index)
                }
            }
        }
    }
}

// MARK: - Permission UI metadata

private extension Permission {
    var explanation: String {
        switch self {
        case .accessibility:
            return "Lets AOS read and operate app interfaces in the background, without stealing focus."
        case .screenRecording:
            return "Lets AOS see what's on your screen so the agent stays grounded in your current task."
        case .automation:
            return "Lets AOS coordinate with other apps via Apple Events."
        }
    }
}
