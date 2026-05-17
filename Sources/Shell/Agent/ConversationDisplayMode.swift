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
}
