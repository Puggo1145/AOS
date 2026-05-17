import Foundation
import Testing
@testable import AOSShell
@testable import AOSRPCSchema

@Suite("Turn display planning")
@MainActor
struct TurnDisplayPlanTests {
    @Test("compact display projects only the latest turn")
    func compactDisplayProjectsLatestTurn() {
        let first = turn(id: "first")
        let current = turn(id: "current")

        let projected = ConversationDisplayProjection.turns(
            [first, current],
            mode: .compact
        )

        #expect(projected.map(\.id) == ["current"])
    }

    @Test("history display preserves all turns in order")
    func historyDisplayPreservesAllTurns() {
        let first = turn(id: "first")
        let current = turn(id: "current")

        let projected = ConversationDisplayProjection.turns(
            [first, current],
            mode: .history
        )

        #expect(projected.map(\.id) == ["first", "current"])
    }

    @Test("latest message returns only the final reply after prior activity")
    func latestMessageReturnsFinalReply() {
        let t1 = tool(id: "A", name: "bash", status: .completed)
        let reply = ReplySegment(text: "Done.")
        let segments: [TurnSegment] = [
            .thinking(ThinkingSegment(text: "checking", startedAt: Date())),
            .toolCall(id: "A"),
            .reply(reply)
        ]

        let latest = TurnDisplayPlanner.latestMessage(
            segments: segments,
            toolCallsById: ["A": t1]
        )

        #expect(latest == .segment(.reply(reply)))
    }

    @Test("latest message returns the final tool call when no later reply exists")
    func latestMessageReturnsFinalToolCall() {
        let t1 = tool(id: "A", name: "bash", status: .completed)
        let t2 = tool(id: "B", name: "read", status: .calling)
        let segments: [TurnSegment] = [
            .thinking(ThinkingSegment(text: "checking", startedAt: Date())),
            .toolCall(id: "A"),
            .toolCall(id: "B")
        ]

        let latest = TurnDisplayPlanner.latestMessage(
            segments: segments,
            toolCallsById: ["A": t1, "B": t2]
        )

        #expect(latest == .segment(.toolCall(id: "B")))
    }

    @Test("compact plan preserves current prompt alongside latest agent message")
    func compactPlanPreservesPromptAlongsideLatestAgentMessage() {
        let reply = ReplySegment(text: "Done.")
        let current = turn(
            id: "current",
            prompt: "Keep this visible",
            segments: [.reply(reply)]
        )

        let plan = TurnDisplayPlanner.compactPlan(for: current)

        #expect(plan.turnId == "current")
        #expect(plan.prompt == "Keep this visible")
        #expect(plan.latestAgentMessage == .segment(.reply(reply)))
    }

    @Test("compact plan has no agent message before sidecar output")
    func compactPlanHasNoAgentMessageBeforeSidecarOutput() {
        let current = turn(
            id: "current",
            prompt: "Initial prompt",
            segments: []
        )

        let plan = TurnDisplayPlanner.compactPlan(for: current)

        #expect(plan.prompt == "Initial prompt")
        #expect(plan.latestAgentMessage == nil)
    }

    @Test("completed tool run before next reply collapses into one display segment")
    func completedToolRunBeforeReplyCollapses() {
        let t1 = tool(id: "A", name: "bash", status: .completed)
        let t2 = tool(id: "B", name: "read", status: .completed)
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
        let t2 = tool(id: "B", name: "read", status: .completed)
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
            tool(id: "C", name: "read", status: .completed),
            tool(id: "D", name: "read", status: .completed),
            tool(id: "E", name: "read", status: .completed),
            tool(id: "F", name: "write", status: .completed),
            tool(id: "G", name: "write", status: .completed)
        ]

        #expect(ToolCallRunSummary.text(for: records) == "used 2 bash, read 3 files, wrote 2 files")
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

    @Test("built-in presenter surfaces malformed args instead of generic running placeholder")
    func builtinPresenterSurfacesMalformedArgs() {
        let bash = ToolUIRegistry.presenter(for: "bash")
        #expect(bash.callingBody(.object(["timeout": .int(1)])) == "Malformed bash args: missing command")

        let read = ToolUIRegistry.presenter(for: "read")
        #expect(read.callingBody(.object(["limit": .int(10)])) == "Malformed read args: missing path")

        let update = ToolUIRegistry.presenter(for: "update")
        #expect(update.callingBody(.object(["path": .string("Package.swift")])) == "Malformed update args: missing old_text/new_text")

        let todo = ToolUIRegistry.presenter(for: "todo_write")
        #expect(todo.callingBody(.object(["items": .string("bad")])) == "Malformed todo_write args: missing items")

        let mouse = ToolUIRegistry.presenter(for: "use_mouse")
        #expect(mouse.callingBody(.object(["event": .string("bad")])) == "Malformed use_mouse args: missing event")
    }

    @Test("computer use presenters expose concrete action labels")
    func computerUsePresentersExposeConcreteActionLabels() {
        let windows = ToolUIRegistry.presenter(for: "list_windows")
        let appState = ToolUIRegistry.presenter(for: "get_app_state")
        let mouse = ToolUIRegistry.presenter(for: "use_mouse")
        let keyboard = ToolUIRegistry.presenter(for: "use_keyboard")
        let ax = ToolUIRegistry.presenter(for: "perform_AX_action")

        #expect(windows.label(.object(["pid": .int(123)]), true) == "listing windows")
        #expect(appState.label(.object([
            "windowId": .int(456),
            "captureMode": .string("vision"),
            "maxImageDimension": .int(0)
        ]), false) == "read app state")

        #expect(mouse.label(.object([
            "windowId": .int(456),
            "event": .object([
                "kind": .string("click"),
                "button": .string("left"),
                "point": .object(["x": .int(12), "y": .int(34)])
            ])
        ]), true) == "clicking at 12, 34")

        #expect(keyboard.label(.object([
            "event": .object([
                "kind": .string("hotkey"),
                "modifiers": .array([.string("command"), .string("shift")]),
                "key": .string("P")
            ])
        ]), false) == "pressed command+shift+P")

        #expect(ax.label(.object([
            "windowId": .int(456),
            "stateId": .string("state-123"),
            "elementIndex": .int(7),
            "event": .object([
                "kind": .string("action"),
                "action": .string("press")
            ])
        ]), false) == "pressed AX element 7")
    }

    @Test("computer use expanded details omit implementation identifiers")
    func computerUseExpandedDetailsOmitImplementationIdentifiers() {
        let startSession = ToolUIRegistry.presenter(for: "start_app_session")
        let keyboard = ToolUIRegistry.presenter(for: "use_keyboard")
        let ax = ToolUIRegistry.presenter(for: "perform_AX_action")

        #expect(startSession.callingBody(.object([
            "pid": .int(123),
            "windowId": .int(456)
        ])) == "target app")

        #expect(keyboard.callingBody(.object([
            "windowId": .int(456),
            "event": .object([
                "kind": .string("hotkey"),
                "modifiers": .array([.string("command")]),
                "key": .string("K")
            ])
        ])) == "event: hotkey\nkey: K\nmodifiers: command")

        #expect(ax.callingBody(.object([
            "windowId": .int(456),
            "stateId": .string("state-123"),
            "elementIndex": .int(7),
            "event": .object([
                "kind": .string("action"),
                "action": .string("press")
            ])
        ])) == "elementIndex: 7\nevent: action\naction: press")
    }

    @Test("computer use numeric rendering does not narrow oversized doubles")
    func computerUseNumericRenderingDoesNotNarrowOversizedDoubles() {
        let mouse = ToolUIRegistry.presenter(for: "use_mouse")

        #expect(mouse.label(.object([
            "event": .object([
                "kind": .string("click"),
                "button": .string("left"),
                "point": .object(["x": .double(1e300), "y": .int(34)])
            ])
        ]), true) == "clicking at 1e+300, 34")
    }

    @Test("computer use tool run summary uses one action family")
    func computerUseToolRunSummaryUsesOneActionFamily() {
        let records = [
            tool(id: "A", name: "list_apps", status: .completed),
            tool(id: "B", name: "start_app_session", status: .completed),
            tool(id: "C", name: "use_mouse", status: .completed),
            tool(id: "D", name: "use_keyboard", status: .completed),
            tool(id: "E", name: "perform_AX_action", status: .completed)
        ]

        #expect(ToolCallRunSummary.text(for: records) == "used computer 5 times")
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

    private func turn(
        id: String,
        prompt: String? = nil,
        segments: [TurnSegment] = []
    ) -> ConversationTurn {
        ConversationTurn(
            id: id,
            prompt: prompt ?? "prompt \(id)",
            context: ContextSnapshot(
                appName: nil,
                appIcon: nil,
                behaviorSummaries: []
            ),
            reply: "",
            status: .done,
            errorMessage: nil,
            segments: segments
        )
    }
}
