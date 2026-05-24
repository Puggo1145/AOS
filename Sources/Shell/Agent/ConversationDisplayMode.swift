import Foundation

public enum ConversationDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case history
    case compact

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .history: return "History"
        case .compact: return "Compact"
        }
    }
}

public enum ConversationDisplayProjection {
    public enum Item: Identifiable {
        case turn(ConversationTurn)

        public var id: String {
            switch self {
            case .turn(let turn): return "turn:\(turn.id)"
            }
        }
    }

    public static func turns(
        _ turns: [ConversationTurn],
        mode: ConversationDisplayMode
    ) -> [ConversationTurn] {
        switch mode {
        case .history:
            return turns
        case .compact:
            return turns.last.map { [$0] } ?? []
        }
    }

    /// Project the conversation feed for the selected display mode. Compact
    /// lifecycle UI intentionally lives in the tray drawer, not inside the
    /// transcript feed.
    public static func items(
        turns sourceTurns: [ConversationTurn],
        mode: ConversationDisplayMode
    ) -> [Item] {
        turns(sourceTurns, mode: mode).map { .turn($0) }
    }
}
