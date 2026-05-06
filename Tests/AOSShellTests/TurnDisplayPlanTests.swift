import Foundation
import Testing
@testable import AOSShell
@testable import AOSRPCSchema

@Suite("Turn display planning")
@MainActor
struct TurnDisplayPlanTests {
    @Test("completed tool run before next reply collapses into one display segment")
    func completedToolRunBeforeReplyCollapses() {
        let t1 = tool(id: "A", name: "bash", status: .completed)
        let t2 = tool(id: "B", name: "computer_use_click_at", status: .completed)
        let reply = ReplySegment(text: "Finished.")
        let segments: [TurnSegment] = [
            .toolCall(id: "A"),
            .thinking(ThinkingSegment(text: "checking", startedAt: Date())),
            .toolCall(id: "B"),
            .thinking(ThinkingSegment(text: "done", startedAt: Date())),
            .reply(reply)
        ]

        let plan = TurnDisplayPlanner.plan(
            segments: segments,
            toolCallsById: ["A": t1, "B": t2]
        )

        #expect(plan.count == 2)
        guard case .toolRun(let run) = plan[0] else {
            Issue.record("expected first segment to be a collapsed tool run")
            return
        }
        #expect(run.toolCallIds == ["A", "B"])
        #expect(run.segments == Array(segments.prefix(4)))
        #expect(plan[1] == .segment(.reply(reply)))
    }

    @Test("running tool run remains expanded while live")
    func runningToolRunDoesNotCollapse() {
        let t1 = tool(id: "A", name: "bash", status: .completed)
        let t2 = tool(id: "B", name: "bash", status: .calling)
        let segments: [TurnSegment] = [
            .toolCall(id: "A"),
            .toolCall(id: "B")
        ]

        let plan = TurnDisplayPlanner.plan(
            segments: segments,
            toolCallsById: ["A": t1, "B": t2]
        )

        #expect(plan == segments.map(TurnDisplaySegment.segment))
    }

    @Test("completed tool run without a following reply remains expanded")
    func completedToolRunWithoutFollowingReplyDoesNotCollapse() {
        let t1 = tool(id: "A", name: "bash", status: .completed)
        let t2 = tool(id: "B", name: "computer_use_click_at", status: .completed)
        let segments: [TurnSegment] = [
            .toolCall(id: "A"),
            .thinking(ThinkingSegment(text: "checking", startedAt: Date())),
            .toolCall(id: "B")
        ]

        let plan = TurnDisplayPlanner.plan(
            segments: segments,
            toolCallsById: ["A": t1, "B": t2]
        )

        #expect(plan == segments.map(TurnDisplaySegment.segment))
    }

    @Test("summary groups repeated actions in first-use order")
    func summaryGroupsRepeatedActions() {
        let records = [
            tool(id: "A", name: "bash", status: .completed),
            tool(id: "B", name: "bash", status: .completed),
            tool(id: "C", name: "computer_use_click_element", status: .completed),
            tool(id: "D", name: "computer_use_click_at", status: .completed),
            tool(id: "E", name: "computer_use_click_at", status: .completed),
            tool(id: "F", name: "computer_use_type_text", status: .completed),
            tool(id: "G", name: "computer_use_type_text", status: .completed)
        ]

        #expect(ToolCallRunSummary.text(for: records) == "used 2 bash, clicked 3 times, typed 2 times")
    }

    @Test("summary uses registered presenter grammar for custom tools")
    func summaryUsesRegisteredPresenterGrammarForCustomTools() {
        ToolUIRegistry.register(
            name: "custom_polish_test",
            presenter: ToolUIPresenter(
                label: { _, isCalling in isCalling ? "polishing" : "polished" },
                callingBody: { _ in nil },
                resultBody: { _, output, _ in output },
                icon: "sparkles",
                summaryUnit: ToolUISummaryUnit(key: "custom_polish_test") { count in
                    count == 1 ? "polished once" : "polished \(count) times"
                }
            )
        )
        let records = [
            tool(id: "A", name: "custom_polish_test", status: .completed),
            tool(id: "B", name: "custom_polish_test", status: .completed)
        ]

        #expect(ToolCallRunSummary.text(for: records) == "polished 2 times")
    }

    private func tool(
        id: String,
        name: String,
        status: ToolCallRecord.Status
    ) -> ToolCallRecord {
        ToolCallRecord(
            id: id,
            name: name,
            args: .object([:]),
            status: status,
            isError: status == .completed ? false : nil,
            outputText: status == .completed ? "" : nil
        )
    }
}
