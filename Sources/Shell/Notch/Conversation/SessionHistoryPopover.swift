import SwiftUI
import RPCSchema

// MARK: - SessionHistoryPanelView
//
// In-panel session history — replaces the full Notch content while
// `viewModel.showHistory` is true (mirrors the SettingsPanelView pattern).
// Per docs/designs/session-management.md non-goal "不持久化": the subtitle
// is intentionally explicit — these sessions only live for this app launch.
//
// The list is owned by SessionStore. The history button refreshes the list
// before flipping `showHistory`; the visible state thereafter is read
// straight from the @Observable store.

struct SessionHistoryPanelView: View {
    let sessionStore: SessionStore
    let sessionService: SessionService
    let topSafeInset: CGFloat
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .notchFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.65))
                    Text("History")
                        .notchFont(size: 18, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.95))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("This launch only — cleared when Notch Agent quits.")
                .notchFont(size: 11)
                .notchForeground(.secondary)

            if let actionError = sessionStore.lastActionError {
                HStack(alignment: .top, spacing: 6) {
                    Text(actionError.message)
                        .notchFont(size: 11, weight: .medium)
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        sessionStore.setActionError(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .notchFont(size: 9, weight: .semibold)
                            .notchForeground(.secondary)
                    }
                    .buttonStyle(.notchPressable)
                    .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.12))
                )
            }

            if sessionStore.list.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        // Newest first — `list` is in creation order, so reverse.
                        ForEach(sessionStore.list.reversed(), id: \.id) { item in
                            row(for: item)
                        }
                    }
                }
            }
        }
        .padding(.top, topSafeInset)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onExitCommand(perform: onClose)
    }

    private var emptyState: some View {
        Text("No conversations yet")
            .notchFont(size: 12)
            .notchForeground(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }

    @ViewBuilder
    private func row(for item: SessionListItem) -> some View {
        let isActive = item.id == sessionStore.activeId
        Button {
            if isActive {
                onClose()
                return
            }
            // Keep the panel open across the await so a failed activate has
            // somewhere to render its banner — closing on click made errors
            // indistinguishable from a successful switch.
            Task {
                do {
                    _ = try await sessionService.activate(sessionId: item.id)
                    onClose()
                } catch {
                    sessionStore.setActionError(SessionActionError(
                        kind: .activate,
                        message: "Failed to switch to “\(item.title)”: \(error.localizedDescription)",
                        sessionId: item.id
                    ))
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .notchFont(size: 13, weight: isActive ? .semibold : .regular)
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                    Text(subtitle(for: item))
                        .notchFont(size: 10)
                        .notchForeground(.tertiary)
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .notchFont(size: 10, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.10) : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for item: SessionListItem) -> String {
        let when = relativeLabel(forMillis: item.lastActivityAt)
        let count = item.turnCount
        let countLabel = count == 1 ? "1 turn" : "\(count) turns"
        return "\(when) · \(countLabel)"
    }

    private func relativeLabel(forMillis ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
