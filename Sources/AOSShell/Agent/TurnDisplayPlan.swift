import Foundation
import AOSComputerUseKit

/// Render-time projection for a turn's ordered segments.
///
/// `ConversationTurn.segments` remains the full audit trail. This planner
/// only decides which adjacent slots the Notch transcript should initially
/// compress, so expansion can always recover the original segment order.
public enum TurnDisplaySegment: Identifiable, Equatable {
    case segment(TurnSegment)
    case toolRun(ToolCallRunSegment)

    public var id: String {
        switch self {
        case .segment(let segment):
            return segment.id
        case .toolRun(let run):
            return run.id
        }
    }
}

public struct ToolCallRunSegment: Identifiable, Equatable {
    public let segments: [TurnSegment]
    public let toolCallIds: [String]

    public var id: String {
        "toolrun:" + toolCallIds.joined(separator: "+")
    }

    public init(segments: [TurnSegment], toolCallIds: [String]) {
        self.segments = segments
        self.toolCallIds = toolCallIds
    }
}

public struct CompactTurnDisplayPlan: Equatable {
    public let turnId: String
    public let prompt: String
    public let clipboardLabels: [String]
    public let latestAgentMessage: TurnDisplaySegment?
    public let shouldShowAgentStatus: Bool

    public init(
        turnId: String,
        prompt: String,
        clipboardLabels: [String],
        latestAgentMessage: TurnDisplaySegment?,
        shouldShowAgentStatus: Bool
    ) {
        self.turnId = turnId
        self.prompt = prompt
        self.clipboardLabels = clipboardLabels
        self.latestAgentMessage = latestAgentMessage
        self.shouldShowAgentStatus = shouldShowAgentStatus
    }
}

public enum TurnDisplayPlanner {
    public static func plan(
        segments: [TurnSegment],
        toolCallsById: [String: ToolCallRecord]
    ) -> [TurnDisplaySegment] {
        var out: [TurnDisplaySegment] = []
        var i = 0

        while i < segments.count {
            guard case .toolCall = segments[i] else {
                out.append(.segment(segments[i]))
                i += 1
                continue
            }

            var runSegments: [TurnSegment] = []
            var toolCallIds: [String] = []
            var j = i

            while j < segments.count {
                switch segments[j] {
                case .toolCall(let id):
                    runSegments.append(segments[j])
                    toolCallIds.append(id)
                    j += 1
                case .thinking:
                    runSegments.append(segments[j])
                    j += 1
                case .reply:
                    break
                }

                if j < segments.count, case .reply = segments[j] {
                    break
                }
            }

            let isSettledByReply = j < segments.count && {
                if case .reply = segments[j] { return true }
                return false
            }()

            if isSettledByReply,
               shouldCollapse(toolCallIds: toolCallIds, toolCallsById: toolCallsById) {
                out.append(.toolRun(ToolCallRunSegment(
                    segments: runSegments,
                    toolCallIds: toolCallIds
                )))
            } else {
                out.append(contentsOf: runSegments.map(TurnDisplaySegment.segment))
            }
            i = j
        }

        return out
    }

    public static func latestMessage(
        segments: [TurnSegment],
        toolCallsById: [String: ToolCallRecord]
    ) -> TurnDisplaySegment? {
        plan(segments: segments, toolCallsById: toolCallsById).last
    }

    @MainActor
    public static func compactPlan(for turn: ConversationTurn) -> CompactTurnDisplayPlan {
        let toolCallsById = Dictionary(uniqueKeysWithValues: turn.toolCalls.map { ($0.id, $0) })
        let latest = latestMessage(
            segments: turn.segments,
            toolCallsById: toolCallsById
        )
        return CompactTurnDisplayPlan(
            turnId: turn.id,
            prompt: turn.prompt,
            clipboardLabels: turn.context.clipboardLabels,
            latestAgentMessage: latest,
            shouldShowAgentStatus: latest != nil || shouldShowEmptyAgentStatus(for: turn.status)
        )
    }

    private static func shouldShowEmptyAgentStatus(for status: AgentStatus) -> Bool {
        switch status {
        case .working, .waiting, .error:
            return true
        case .idle, .listening, .done:
            return false
        }
    }

    private static func shouldCollapse(
        toolCallIds: [String],
        toolCallsById: [String: ToolCallRecord]
    ) -> Bool {
        guard toolCallIds.count >= 2 else { return false }
        return toolCallIds.allSatisfy { id in
            toolCallsById[id]?.status == .completed
        }
    }
}

@MainActor
public enum ToolCallRunSummary {
    public static func text(for records: [ToolCallRecord]) -> String {
        var buckets: [(key: String, count: Int, label: (Int) -> String)] = []

        for record in records {
            let unit = ToolUIRegistry.presenter(for: record.name).summaryUnit
            if let idx = buckets.firstIndex(where: { $0.key == unit.key }) {
                buckets[idx].count += 1
            } else {
                buckets.append((key: unit.key, count: 1, label: unit.label))
            }
        }

        return buckets.map { $0.label($0.count) }.joined(separator: ", ")
    }
}

@MainActor
public enum VirtualMouseActivityPlanner {
    public static func activity(for turn: ConversationTurn) -> ComputerUseVirtualMouseAgentActivity? {
        guard turn.status == .working || turn.status == .waiting else {
            return nil
        }
        let toolCallsById = Dictionary(uniqueKeysWithValues: turn.toolCalls.map { ($0.id, $0) })
        guard let latest = TurnDisplayPlanner.latestMessage(
            segments: turn.segments,
            toolCallsById: toolCallsById
        ) else {
            return nil
        }

        switch latest {
        case .segment(.thinking(let segment)):
            return segment.isOpenForAppend ? .thinking : nil
        case .segment(.toolCall(let id)):
            return toolCallsById[id].map(activity(for:))
        case .toolRun(let run):
            guard let id = run.toolCallIds.last, let record = toolCallsById[id] else {
                return nil
            }
            return activity(for: record)
        case .segment(.reply):
            return nil
        }
    }

    private static func activity(for record: ToolCallRecord) -> ComputerUseVirtualMouseAgentActivity {
        let presenter = ToolUIRegistry.presenter(for: record.name)
        return .toolCall(label: presenter.label(record.args, record.status == .calling))
    }
}
