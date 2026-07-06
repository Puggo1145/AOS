// MARK: - Permission approval intents
//
// The bottom pager only renders the approval page while
// `permissionApprovalService.pendingRequest` is non-nil, so a nil service
// here means the view and viewmodel disagree about that invariant — fail
// fast rather than silently no-op.

extension NotchViewModel {
    func allowPendingPermission() {
        guard let permissionApprovalService else {
            preconditionFailure("permission approval service is required for approval actions")
        }
        permissionApprovalService.allowPendingRequest()
    }

    func denyPendingPermission() {
        guard let permissionApprovalService else {
            preconditionFailure("permission approval service is required for approval actions")
        }
        permissionApprovalService.denyPendingRequest()
    }
}
