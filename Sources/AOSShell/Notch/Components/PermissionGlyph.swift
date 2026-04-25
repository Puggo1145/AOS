import SwiftUI
import AOSOSSenseKit

// MARK: - PermissionGlyph
//
// Shared visual for a TCC permission across onboard + settings.
// Re-draws what System Settings paints in its Privacy & Security pane:
// a flat colored squircle with a single white glyph. The actual
// Settings icons live in private IconServices entries (e.g.
// `com.apple.graphic-icon.screen-recording`) inside the
// `SecurityPrivacyExtension.appex` bundle and are not loadable via a
// stable public API across macOS versions, so we redraw rather than
// risk a private name disappearing on the next OS update.
//
// Visual tuning:
//   - cornerRadius is 22% of side (matches the rounded-rect ratio Apple
//     uses for these badges in Sonoma/Sequoia/Tahoe Settings panes)
//   - symbol is centered and sized to ~58% of side
//   - background uses the system color so Dark/Light Mode tracks the
//     real Settings appearance automatically

struct PermissionGlyph: View {
    let permission: Permission
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(permission.badgeColor)
            permission.glyph(size: size)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Permission UI metadata (shared across views)

extension Permission {
    var displayName: String {
        switch self {
        case .accessibility:    return "Accessibility"
        case .screenRecording:  return "Screen Recording"
        case .automation:       return "Automation"
        }
    }

    /// Solid background color for the glyph badge. Matches the System
    /// Settings Privacy pane: red for Screen Recording, blue for
    /// Accessibility.
    var badgeColor: Color {
        switch self {
        case .screenRecording:  return .red
        case .accessibility:    return .blue
        case .automation:       return .gray
        }
    }

    /// Centered white glyph. Returns a view rather than a symbol name so
    /// Screen Recording can use a plain filled circle (the system icon
    /// is a record indicator, not an SF Symbol) while Accessibility
    /// uses the matching SF Symbol.
    @ViewBuilder
    func glyph(size: CGFloat) -> some View {
        switch self {
        case .screenRecording:
            // Record indicator: outer ring + inner filled dot. Matches
            // the System Settings "Screen & System Audio Recording"
            // glyph (a stylized REC button).
            ZStack {
                Circle()
                    .strokeBorder(lineWidth: size * 0.06)
                    .frame(width: size * 0.56, height: size * 0.56)
                Circle()
                    .frame(width: size * 0.30, height: size * 0.30)
            }
        case .accessibility:
            Image(systemName: "accessibility")
                .font(.system(size: size * 0.58, weight: .regular))
        case .automation:
            Image(systemName: "gearshape.2")
                .font(.system(size: size * 0.50, weight: .regular))
        }
    }
}
