import Observation
import RPCSchema

// MARK: - ApprovalPagerModel
//
// State machine for `BottomSectionPager`'s composer <-> approval paging.
// Owns exactly the three pieces of state that used to live in the view's
// `@State`: which request is currently displayed, whether the approval
// page is showing, and — via `dismissalToken` — whether an in-flight
// dismissal is still the authoritative one. Extracted so the transition
// logic (new request arrives / request clears / a newer request preempts
// an in-flight dismissal) is unit-testable independent of SwiftUI's
// animation machinery.
//
// This class intentionally knows nothing about `Animation` or
// `withAnimation` — the view drives those, calling `beginSync` inside its
// own `.notchChrome` transaction and `completeDismissal` from that
// transaction's completion callback (or synchronously, under Reduce
// Motion). That keeps the model a plain, deterministic state machine.
@MainActor
@Observable
final class ApprovalPagerModel {
    private(set) var displayedRequest: PermissionRequestApprovalParams?
    private(set) var showingApproval: Bool = false

    /// Bumped every time `beginSync` starts a new dismissal (or a new
    /// request preempts one). A `completeDismissal(token:)` call whose
    /// token no longer matches came from a dismissal that got superseded —
    /// it must no-op rather than clearing a request that's already
    /// showing again.
    private(set) var dismissalToken: Int = 0

    /// Seed initial state when the pager first appears — mirrors the old
    /// `.onAppear` behavior (no animation; the pager mounts already in
    /// whatever state the pending request implies).
    func onAppear(request: PermissionRequestApprovalParams?) {
        guard let request else { return }
        displayedRequest = request
        showingApproval = true
    }

    /// Reconcile displayed state with the latest `request`.
    ///
    /// - A non-nil `request` is adopted immediately and invalidates any
    ///   dismissal in flight (a new request arriving while the pager is
    ///   sliding back to the composer wins outright).
    /// - A nil `request` flips `showingApproval` to false and returns a
    ///   token the caller must pass back to `completeDismissal` once its
    ///   dismissal animation (or, under Reduce Motion, the caller itself)
    ///   reports done.
    @discardableResult
    func beginSync(request: PermissionRequestApprovalParams?) -> Int? {
        dismissalToken += 1
        if let request {
            displayedRequest = request
            showingApproval = true
            return nil
        }
        showingApproval = false
        return dismissalToken
    }

    /// Clear the displayed request once its dismissal is done, provided
    /// nothing preempted it in the meantime.
    func completeDismissal(token: Int) {
        guard token == dismissalToken, !showingApproval else { return }
        displayedRequest = nil
    }
}
