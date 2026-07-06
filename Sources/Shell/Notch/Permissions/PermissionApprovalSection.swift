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
        .onHeightChange(perform: onHeightChange)
    }
}
