import SwiftUI

// MARK: - ConfigCorruptionBanner
//
// One-shot notice rendered when the sidecar reports that
// `~/.aos/config.json` was malformed and reset to `{}` on startup. Without
// this banner the user would be silently bounced through onboarding and
// have to re-pick their provider/effort with no explanation. The banner
// is dismissible — there's no actionable step beyond "OK", we just owe
// the user an honest statement of what happened.

struct ConfigCorruptionBanner: View {
    let topSafeInset: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("Settings file was corrupt and has been reset.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss settings reset notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, topSafeInset + 6)
    }
}
