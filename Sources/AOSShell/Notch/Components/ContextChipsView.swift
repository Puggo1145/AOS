import SwiftUI
import AOSOSSenseKit

// MARK: - ContextChipsView
//
// Pure SwiftUI projection of `SenseStore.context` per notch-ui.md
// §"Context chips 区契约":
//
//   chips = behaviors[] + windowChip
//
// In Stage 0 the `behaviors` list is always empty (no GeneralProbe / no
// adapters registered yet), so the only rendered chip is the frontmost
// app chip — its icon + the app's display name in a borderless rounded
// rect. Window titles are intentionally omitted; the icon already carries
// the app identity and dropping the title keeps the row compact.

struct ContextChipsView: View {
    let senseStore: SenseStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(senseStore.context.behaviors, id: \.id) { envelope in
                    textChip(text: envelope.displaySummary)
                }
                if let app = senseStore.context.app {
                    appChip(name: app.name, icon: app.icon)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 32)
    }

    /// App identity chip: 16pt icon + app name, no border, soft fill.
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

    /// Generic text chip used for behavior envelopes from later stages.
    @ViewBuilder
    private func textChip(text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .lineLimit(1)
    }
}
