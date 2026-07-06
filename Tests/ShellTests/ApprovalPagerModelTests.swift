import RPCSchema
import Testing

@testable import Shell

// MARK: - ApprovalPagerModelTests
//
// Covers the paging state machine extracted from `BottomSectionPager`
// (Sources/Shell/Notch/Chrome/OpenedPanelView.swift). These tests exercise
// the model's pure transitions directly — no SwiftUI animation machinery
// involved — since the view drives `withAnimation`'s completion callback
// into `completeDismissal(token:)` itself.

@MainActor
@Suite("ApprovalPagerModel transitions")
struct ApprovalPagerModelTests {
    private func makeRequest(toolCallId: String) -> PermissionRequestApprovalParams {
        PermissionRequestApprovalParams(
            sessionId: "S",
            turnId: "T",
            toolCallId: toolCallId,
            toolName: "bash",
            title: "Allow command?",
            message: "Agent wants to run a shell command.",
            risk: .high,
            capabilities: []
        )
    }

    @Test("a request appearing shows the approval page")
    func requestAppearsShowsApproval() {
        let model = ApprovalPagerModel()
        let request = makeRequest(toolCallId: "tc_1")

        model.beginSync(request: request)

        #expect(model.displayedRequest == request)
        #expect(model.showingApproval)
    }

    @Test("a cleared request only clears displayedRequest once the dismissal completes")
    func clearedRequestDismissalCompletes() {
        let model = ApprovalPagerModel()
        let request = makeRequest(toolCallId: "tc_1")
        model.beginSync(request: request)

        let token = model.beginSync(request: nil)
        #expect(!model.showingApproval)
        // Still displayed — the slide-out animation hasn't reported done yet.
        #expect(model.displayedRequest == request)

        guard let token else {
            Issue.record("beginSync(request: nil) must return a dismissal token")
            return
        }
        model.completeDismissal(token: token)
        #expect(model.displayedRequest == nil)
    }

    @Test("a new request arriving during dismissal wins over the stale completion")
    func newRequestDuringDismissalWins() {
        let model = ApprovalPagerModel()
        let first = makeRequest(toolCallId: "tc_1")
        let second = makeRequest(toolCallId: "tc_2")
        model.beginSync(request: first)

        let staleToken = model.beginSync(request: nil)
        guard let staleToken else {
            Issue.record("beginSync(request: nil) must return a dismissal token")
            return
        }

        // A new request preempts the dismissal before it completes.
        model.beginSync(request: second)
        #expect(model.displayedRequest == second)
        #expect(model.showingApproval)

        // The stale dismissal's completion callback fires late — it must
        // not clear the new request.
        model.completeDismissal(token: staleToken)
        #expect(model.displayedRequest == second)
        #expect(model.showingApproval)
    }

    @Test("onAppear seeds an already-pending request without requiring a sync")
    func onAppearSeedsPendingRequest() {
        let model = ApprovalPagerModel()
        let request = makeRequest(toolCallId: "tc_1")

        model.onAppear(request: request)

        #expect(model.displayedRequest == request)
        #expect(model.showingApproval)
    }

    @Test("onAppear with no pending request leaves the composer page displayed")
    func onAppearWithNoRequestStaysOnComposer() {
        let model = ApprovalPagerModel()

        model.onAppear(request: nil)

        #expect(model.displayedRequest == nil)
        #expect(!model.showingApproval)
    }
}
