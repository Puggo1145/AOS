import SwiftUI

// MARK: - BentoPickerCard
//
// Apple-style bento card. No border, just a subtle filled surface — relies
// on the squircle and tonal contrast for affordance, like macOS / iOS
// Settings tiles. Tapping pushes the parent to a separate menu page; this
// card is purely a tap target.

struct BentoOption: Identifiable, Hashable {
    let id: String
    let title: String
}

struct BentoPickerCard: View {
    let caption: String
    let valueTitle: String
    let isOpen: Bool
    let isEnabled: Bool
    let onTap: () -> Void

    init(
        caption: String,
        valueTitle: String,
        isOpen: Bool = false,
        isEnabled: Bool = true,
        onTap: @escaping () -> Void
    ) {
        self.caption = caption
        self.valueTitle = valueTitle
        self.isOpen = isOpen
        self.isEnabled = isEnabled
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(caption)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                    .tracking(0.4)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(valueTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isOpen ? Color.white.opacity(0.10) : Color.white.opacity(0.06))
            )
            .opacity(isEnabled ? 1.0 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - BentoOptionsList
//
// Reusable row list used by the menu page. Pure radio rows: bullet +
// title. No trailing badges — keeps rows skim-able and consistent with
// Apple's Settings-style minimalism.

struct BentoOptionsList: View {
    let options: [BentoOption]
    let selectedId: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(options) { opt in
                row(opt)
            }
        }
    }

    private func row(_ opt: BentoOption) -> some View {
        let isSelected = opt.id == selectedId
        return Button {
            onSelect(opt.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.35))
                Text(opt.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
