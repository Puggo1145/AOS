import Foundation

public enum ConversationDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case history
    case compact

    public var id: String { rawValue }

    /// UserDefaults key shared by every surface that reads or writes the
    /// display mode (Settings pages, conversation view). Single source of
    /// truth so the surfaces can never drift onto different keys.
    public static let storageKey = "notch-agent.conversationDisplayMode"

    /// Non-crashing projection from a persisted raw string. Persisted prefs
    /// are external input — a stale/legacy value written by an older build
    /// (or a hand-edited plist) must not crash the app, so unknown strings
    /// fall back to `.history`, the default mode.
    public static func from(raw: String) -> ConversationDisplayMode {
        ConversationDisplayMode(rawValue: raw) ?? .history
    }

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
