import SwiftUI
import OSSenseKit

enum PermissionSettingsStatus: Equatable {
    case granted
    case disabled
    case opensSettings
}

/// One row per permission inside the Permissions sub-page. Reads the
/// live `denied` set; tap opens the matching Privacy pane in System Settings.
struct PermissionStatusRow: View {
    let permission: Permission
    let status: PermissionSettingsStatus
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PermissionGlyph(permission: permission, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.displayName)
                    .notchFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.95))
                Text(status.label)
                    .notchFont(size: 11)
                    .foregroundStyle(status.tint)
            }

            Spacer(minLength: 8)

            Button(action: onOpenSettings) {
                Text(status.buttonTitle)
                    .notchFont(size: 11, weight: .semibold)
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

extension PermissionSettingsStatus {
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
