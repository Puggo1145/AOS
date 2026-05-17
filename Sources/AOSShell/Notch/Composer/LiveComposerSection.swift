import SwiftUI
import AOSOSSenseKit

// MARK: - LiveComposerSection
//
// Pinned-at-bottom composer. Wraps `ComposerCard` with the bindings the
// notch panel owns and forwards the rendered height back to the
// view model so the panel can size itself.
struct LiveComposerSection: View {
    let viewModel: NotchViewModel

    var body: some View {
        ComposerCard(
            viewModel: viewModel,
            inputModel: viewModel.composerInputModel,
            inputFocused: Binding(
                get: { viewModel.inputFocused },
                set: { viewModel.inputFocused = $0 }
            )
        )
        .disabled(!viewModel.composerSubmitEnabled)
        .opacity(viewModel.composerSubmitEnabled ? 1.0 : 0.55)
        // Pin to natural height — without this the inner NSTextView accepts
        // the parent's `maxHeight: .infinity` offer and inflates
        // `composerContentHeight`.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ComposerHeightKey.self) { h in
            viewModel.composerContentHeight = h
        }
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
