import AppKit
import SwiftUI
import OSSenseKit

// MARK: - NotchHeaderStripsView
//
// Two strips flanking the hardware notch cutout, hosting the global
// controls (settings, new conversation, history). NotchShape paints
// them black so they read as part of the notch silhouette.
//
//   ┌──────────┐ ╲╱ ┌──────────┐
//   │   ⚙      │ ── │  +  ⏱    │
//   └──────────┘    └──────────┘
struct NotchHeaderStripsView: View {
    let viewModel: NotchViewModel

    private let notchGap: CGFloat = 8

    var body: some View {
        let stripWidth = max(0, (viewModel.notchOpenedSize.width - viewModel.deviceNotchRect.width) / 2)
        let bandHeight = viewModel.deviceNotchRect.height

        HStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                gearButton
                    .padding(.trailing, notchGap)
            }
            .frame(width: stripWidth, height: bandHeight)

            Spacer(minLength: 0)
                .frame(width: viewModel.deviceNotchRect.width, height: bandHeight)

            HStack(spacing: 6) {
                newConversationButton
                    .padding(.leading, notchGap)
                historyButton
                moveButton
                Spacer(minLength: 0)
            }
            .frame(width: stripWidth, height: bandHeight)
        }
    }

    // MARK: - Buttons

    private var gearButton: some View {
        Button {
            viewModel.showSettings = true
        } label: {
            headerIcon("gearshape.fill")
        }
        .buttonStyle(.notchPressable)
        .accessibilityLabel(Text("Settings"))
    }

    private var newConversationButton: some View {
        Button {
            let store = viewModel.agentService.sessionStore
            guard store.canCreateNewConversation else { return }
            // SessionService.create auto-activates via SessionStore.adoptCreated
            // so the mirror + activeId flip atomically before SwiftUI reads them.
            Task {
                do {
                    _ = try await viewModel.sessionService.create()
                } catch {
                    store.setActionError(
                        SessionActionError(
                            kind: .create,
                            message: "Failed to start a new conversation: \(error.localizedDescription)",
                            sessionId: nil
                        )
                    )
                }
            }
        } label: {
            headerIcon("plus")
        }
        .buttonStyle(.notchPressable)
        .disabled(!viewModel.agentService.sessionStore.canCreateNewConversation)
        .accessibilityLabel(Text("New conversation"))
    }

    private var historyButton: some View {
        Button {
            // Refresh first so turnCount / lastActivityAt are current, then
            // open regardless of outcome — the panel renders the cached list
            // and surfaces a banner if refresh failed.
            Task {
                let store = viewModel.agentService.sessionStore
                do {
                    _ = try await store.refreshList()
                } catch {
                    store.setActionError(SessionActionError(
                        kind: .list,
                        message: "Failed to refresh sessions: \(error.localizedDescription)",
                        sessionId: nil
                    ))
                }
                viewModel.showHistory = true
            }
        } label: {
            headerIcon("clock.arrow.circlepath")
        }
        .buttonStyle(.notchPressable)
        .accessibilityLabel(Text("Conversation history"))
    }

    private var moveButton: some View {
        Button {} label: {
            headerIcon("arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.notchPressable)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    viewModel.startDetachDrag(pointer: NSEvent.mouseLocation)
                }
        )
        .accessibilityLabel(Text("Move Notch"))
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .notchFont(size: 13, weight: .semibold)
            .notchForeground(.secondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.06))
            )
    }
}
