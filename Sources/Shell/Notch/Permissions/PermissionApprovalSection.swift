import RPCSchema
import SwiftUI

// MARK: - PermissionApprovalSection
//
// Bottom-panel section used by OpenedPanelView when the sidecar asks for a
// capability approval. Kept separate from LiveComposerSection so the composer
// remains only responsible for prompt input.
struct PermissionApprovalSection: View {
    let request: PermissionRequestApprovalParams
    let allow: () -> Void
    let deny: () -> Void
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        PermissionApprovalCard(
            request: request,
            allow: allow,
            deny: deny
        )
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: PermissionApprovalHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(PermissionApprovalHeightKey.self, perform: onHeightChange)
    }
}

private struct PermissionApprovalHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
