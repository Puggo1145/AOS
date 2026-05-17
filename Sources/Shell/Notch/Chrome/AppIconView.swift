import SwiftUI
import AppKit

// MARK: - AppIconView
//
// Renders the frontmost app icon for the closed-bar's left square, or a
// neutral grayscale "?" placeholder when no icon is available. The
// placeholder is the **degraded path** described in notch-ui.md §"chip 区
// 契约" — there is no frontmost-app projection yet (e.g. before the first
// NSWorkspace activation event), so we render a glyph rather than an empty
// square. This is not a stub.

struct AppIconView: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(Text("Frontmost app icon"))
            } else {
                Text("?")
                    .notchFont(size: 14, weight: .bold, design: .monospaced)
                    .notchForeground(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text("No frontmost app"))
            }
        }
        .padding(4)
    }
}
