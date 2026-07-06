import SwiftUI

// MARK: - NotchControls
//
// Shared form and feedback components for the notch's Settings / Onboarding /
// Conversation surfaces. Each component is an extraction of a scaffold that
// was copy-pasted across pages — the styling values are the exact literals
// from the original call sites, so adopting a component is a visual no-op.

// MARK: - NotchTextField
//
// Text-entry scaffold: optional caption label above a plain-style
// TextField/SecureField on the shared `white.opacity(0.06)` rounded fill.
// Used by the Settings API-key page, the MCP add/edit form, and the
// onboarding inline API-key card.
struct NotchTextField: View {
    var label: String?
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var fontSize: CGFloat = 12
    var monospaced: Bool = false
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 8
    var cornerRadius: CGFloat = 8
    /// Settings pages draw `.continuous` corners; the onboarding API-key
    /// card historically used the default `.circular`. Parameterized so the
    /// extraction stays pixel-identical at every site.
    var cornerStyle: RoundedCornerStyle = .continuous
    var isEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let label {
                Text(label)
                    .notchFont(size: 11, weight: .medium)
                    .notchForeground(.secondary)
            }
            field
                .textFieldStyle(.plain)
                .notchFont(size: fontSize, design: monospaced ? .monospaced : .default)
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
                        .fill(Color.white.opacity(0.06))
                )
                .disabled(!isEnabled)
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

// MARK: - Action buttons
//
// The Save / Cancel pair shared by the Settings API-key and MCP edit forms.
// Primary fills the row with the accent tint; secondary is the muted
// white-fill companion. Disabled state stays at the call site (`.disabled`)
// because each form gates on its own validation + in-flight flags.

/// Full-width accent "Save"-style button.
struct NotchPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
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
    }
}

/// Hugging muted "Cancel"/"Clear"-style companion button.
struct NotchSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
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
    }
}

// MARK: - NotchErrorText
//
// Inline form/list error line — small red multi-line text. Repeated across
// the Settings pages (API key, MCP list/edit, permissions) and both
// onboarding panels.
struct NotchErrorText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .notchFont(size: 11)
            .foregroundStyle(.red.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - NotchErrorBanner
//
// Red-tinted rounded banner for session-level and per-turn errors in the
// conversation surface. Pass `onDismiss` to render the trailing xmark
// button (session-action errors); leave nil for non-dismissible banners.
struct NotchErrorBanner: View {
    let message: String
    var fontSize: CGFloat = 12
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 7
    var onDismiss: (() -> Void)?

    var body: some View {
        Group {
            if let onDismiss {
                HStack(alignment: .top, spacing: 6) {
                    messageText
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .notchFont(size: 10, weight: .semibold)
                            .notchForeground(.secondary)
                    }
                    .buttonStyle(.notchPressable)
                    .accessibilityLabel("Dismiss error")
                }
            } else {
                messageText
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(0.12))
        )
    }

    private var messageText: some View {
        Text(message)
            .notchFont(size: fontSize, weight: .medium)
            .foregroundStyle(.red.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
