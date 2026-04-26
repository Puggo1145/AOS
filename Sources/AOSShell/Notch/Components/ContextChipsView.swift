import SwiftUI
import AppKit
import AOSOSSenseKit

// MARK: - ContextChipsView
//
// Live chip row driven by `SenseStore.context`. Per
// docs/designs/os-sense.md §"Notch UI 渲染契约":
//
//   chips = behaviors[] + clipboard? + visual? + app
//
// The frontmost-app chip is the basic identity and is always included in
// the wire projection. Behavior / clipboard / visual chips are user-
// selectable: tapping toggles inclusion in the next submit. Deselected
// chips dim but stay in the row so the user can re-select them; the
// design's "未勾选 chip 永不离开 Shell" rule is enforced at projection
// time (see `CitedContextProjection`).

/// Stable pseudo citation keys for the non-behavior chips. Used as the
/// key in `deselectedKeys` so all chip slots share one selection set.
public enum ContextChipKey {
    public static let clipboard = "__os.clipboard"
    public static let visual = "__os.visual"
}

struct ContextChipsView: View {
    let senseStore: SenseStore
    @Binding var deselectedKeys: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let app = senseStore.context.app {
                    appChip(name: app.name, icon: app.icon)
                }
                ForEach(senseStore.context.behaviors, id: \.id) { envelope in
                    selectableChip(
                        key: envelope.citationKey,
                        label: envelope.displaySummary,
                        leading: nil
                    )
                }
                // Visual is on-demand: the chip indicates that pressing send
                // will attach a fresh window snapshot. Capture itself only
                // happens at submit, not while the chip is on screen, so no
                // background screenshot loop runs.
                if senseStore.visualSnapshotAvailable
                    && senseStore.context.behaviors.isEmpty {
                    selectableChip(
                        key: ContextChipKey.visual,
                        label: "Window snapshot",
                        leading: AnyView(Image(systemName: "rectangle.dashed")
                            .font(.system(size: 11, weight: .semibold)))
                    )
                }
                if let clip = senseStore.context.clipboard {
                    selectableChip(
                        key: ContextChipKey.clipboard,
                        label: clipboardSummary(clip),
                        leading: AnyView(Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .semibold)))
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 32)
        .onChange(of: senseStore.context.app?.bundleId) { _, _ in
            // App switch invalidates per-app chip identities; reset any
            // pending toggles so the user starts each app session fresh.
            deselectedKeys.removeAll()
        }
    }

    // MARK: - Chip variants

    /// App identity chip — non-toggleable. Always projected.
    @ViewBuilder
    private func appChip(name: String, icon: NSImage?) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    /// Toggleable chip. Selected → bright fill; deselected → dimmed outline
    /// so the user can clearly read which chips will travel to the LLM.
    @ViewBuilder
    private func selectableChip(
        key: String,
        label: String,
        leading: AnyView?
    ) -> some View {
        let selected = !deselectedKeys.contains(key)
        Button {
            if selected {
                deselectedKeys.insert(key)
            } else {
                deselectedKeys.remove(key)
            }
        } label: {
            HStack(spacing: 6) {
                if let leading {
                    leading
                        .foregroundStyle(.white.opacity(selected ? 0.85 : 0.4))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 0.9 : 0.45))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.12 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(selected ? 0 : 0.18),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(selected ? "selected" : "deselected"))
    }

    /// One-line summary for the clipboard chip. Long text truncated for the
    /// display; the wire payload still carries the (already-2KB-truncated)
    /// content faithfully.
    private func clipboardSummary(_ item: ClipboardItem) -> String {
        switch item {
        case .text(let s):
            let collapsed = s.replacingOccurrences(of: "\n", with: " ")
            if collapsed.count <= 10 { return collapsed }
            return String(collapsed.prefix(10)) + "…"
        case .filePaths(let urls):
            if urls.count == 1 { return urls[0].lastPathComponent }
            return "\(urls.count) files"
        case .image(let metadata):
            return "Image \(metadata.width)×\(metadata.height)"
        }
    }
}
