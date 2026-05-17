import SwiftUI

// MARK: - PromptWithChipsView
//
// Read-only mirror of the live composer's rich text: shows a past turn's
// prompt with `[[clipboard:N]]` markers replaced by chip pills that
// visually match the input field's chip cell (icon + label, capsule
// background) — minus the X button, since history rows aren't editable.
//
// Layout uses a tiny flow `Layout` so plain-text words and chip pills
// share one wrapping line. Splitting text into per-word subviews is what
// lets a chip wrap to the next row mid-sentence; rendering each text
// segment as a single Text would force chips onto their own line.

struct PromptWithChipsView: View {
    let prompt: String
    let clipboardLabels: [String]

    var body: some View {
        ChipFlowLayout(hSpacing: 4, vSpacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .word(let text):
                    Text(text)
                        .notchFont(size: 14, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.95))
                        .textSelection(.enabled)
                case .chip(let label):
                    HistoryChipPill(label: label)
                }
            }
        }
    }

    /// Split the prompt into a flow-friendly token stream:
    ///
    ///   - whitespace-separated words become `.word`
    ///   - `[[clipboard:N]]` markers become `.chip` (with the matching
    ///     label from `clipboardLabels`)
    ///   - out-of-range markers fall back to a literal `.word` so a
    ///     contract drift between Shell and sidecar stays visible
    ///     instead of silently swallowing characters
    private var tokens: [Token] {
        var out: [Token] = []
        let nsPrompt = prompt as NSString
        let regex = try? NSRegularExpression(pattern: "\\[\\[clipboard:(\\d+)\\]\\]")
        let matches = regex?.matches(
            in: prompt,
            range: NSRange(location: 0, length: nsPrompt.length)
        ) ?? []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let plain = nsPrompt.substring(with: NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                ))
                appendWords(plain, into: &out)
            }
            let idxStr = nsPrompt.substring(with: match.range(at: 1))
            let idx = Int(idxStr) ?? -1
            if idx >= 0, idx < clipboardLabels.count {
                out.append(.chip(clipboardLabels[idx]))
            } else {
                out.append(.word(nsPrompt.substring(with: match.range)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < nsPrompt.length {
            appendWords(nsPrompt.substring(from: cursor), into: &out)
        }
        return out
    }

    private func appendWords(_ s: String, into out: inout [Token]) {
        for word in s.split(whereSeparator: { $0.isWhitespace }) {
            out.append(.word(String(word)))
        }
    }

    private enum Token {
        case word(String)
        case chip(String)
    }
}

// MARK: - HistoryChipPill

/// Display-only twin of `ClipboardChipCell` (the input-side AppKit cell).
/// Geometry + colors match so the history row reads as the same artifact
/// the user composed; the X button is the only intentional omission.
private struct HistoryChipPill: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.on.clipboard")
                .notchFont(size: 11, weight: .semibold)
                .foregroundStyle(.white.opacity(0.9))
            Text(label)
                .notchFont(size: 12, weight: .medium)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.12))
        )
        .fixedSize()
    }
}

// MARK: - ChipFlowLayout
//
// Minimal left-to-right wrapping layout. Each subview keeps its natural
// size; when the next subview would overflow the proposed width, we
// break to a new row and continue. Subviews on the same row are
// vertically centered against the row's tallest item — keeps chip pills
// (~20pt) reading aligned with the text baseline (~18pt cap height).

private struct ChipFlowLayout: Layout {
    var hSpacing: CGFloat
    var vSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + vSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let rows = computeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            for item in row.items {
                let centerY = y + row.height / 2
                let originY = centerY - item.size.height / 2
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: originY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
            }
            y += row.height + vSpacing
        }
    }

    private struct RowItem {
        let index: Int
        let size: CGSize
        let x: CGFloat
    }
    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, sv) in subviews.enumerated() {
            let size = sv.sizeThatFits(.unspecified)
            let needsBreak = !current.items.isEmpty
                && current.width + hSpacing + size.width > maxWidth
            if needsBreak {
                rows.append(current)
                current = Row()
            }
            let x = current.items.isEmpty ? 0 : current.width + hSpacing
            current.items.append(RowItem(index: i, size: size, x: x))
            current.width = x + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
