import SwiftUI

// MARK: - HeightReporting
//
// Shared "measure my rendered height and report it" plumbing. Before this,
// every panel that needed its intrinsic height re-invented the same
// GeometryReader-in-background + PreferenceKey scaffold, each with its own
// bespoke key type and its own copy of the rounding/`>0` guards. Those key
// types were never meant to be merged — SwiftUI's preference system flows
// values *up* through `reduce`, so nested measurements of the same key type
// would collide. This modifier sidesteps that entirely: the reporter closure
// is captured at the call site, so two `onHeightChange` usages nested inside
// one another never cross-talk, without needing a distinct PreferenceKey
// type per site.
extension View {
    /// Reports the view's rendered height whenever it changes.
    ///
    /// Policy (shared by every former call site so this collapses them
    /// without behavior drift):
    ///   - Rounded to integer points. SwiftUI re-lays-out per frame during
    ///     animated transitions (tray expand/collapse, panel swaps), which
    ///     produces sub-pixel jitter in the raw measured height. Since the
    ///     reported height commonly feeds an `.animation(value:)`-driven
    ///     frame (e.g. the notch silhouette), even a 0.5pt drift would
    ///     visibly nudge the panel every frame. Real content changes are
    ///     always >> 1pt and still flow through.
    ///   - Non-positive values are dropped. A height of 0 (or less) means
    ///     "not measured yet" / "transiently collapsed mid-layout", not a
    ///     genuine content height; callers that need to observe a
    ///     zero/pending state track that explicitly themselves rather than
    ///     through this reporter.
    ///   - Only fires when the rounded value actually changed, so callers
    ///     don't get repeated no-op writes on every layout pass.
    func onHeightChange(perform: @escaping (CGFloat) -> Void) -> some View {
        modifier(HeightReportingModifier(onMeasure: perform))
    }
}

private struct HeightReportingModifier: ViewModifier {
    let onMeasure: (CGFloat) -> Void

    @State private var lastReported: CGFloat?

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { report(geo.size.height) }
                    .onChange(of: geo.size.height) { _, height in
                        report(height)
                    }
            }
        )
    }

    private func report(_ height: CGFloat) {
        let rounded = height.rounded()
        guard rounded > 0 else { return }
        guard lastReported != rounded else { return }
        lastReported = rounded
        onMeasure(rounded)
    }
}
