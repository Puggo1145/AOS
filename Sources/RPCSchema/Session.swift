import Foundation

// MARK: - session.* — Shell↔Bun bidirectional namespace
//
// Per docs/designs/session-management.md.
//
// Direction split (enforced by sidecar dispatcher, mirrored on Shell side):
//   - Shell→Bun requests: session.create / session.list / session.activate
//   - Bun→Shell notifications: session.created / session.activated /
//     session.listChanged
//
// `SessionListItem` is the wire-shape projection of a Session. `turnCount`
// and `lastActivityAt` are derived on demand by the sidecar — there is no
// caching, so the Shell mirror should also treat them as authoritative on
// every received `session.created` / `session.list` response.

public struct SessionListItem: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// Milliseconds since epoch.
    public let createdAt: Int
    /// Number of `status == .done` turns.
    public let turnCount: Int
    /// Last turn's `startedAt`; equals `createdAt` for empty sessions.
    public let lastActivityAt: Int

    public init(
        id: String,
        title: String,
        createdAt: Int,
        turnCount: Int,
        lastActivityAt: Int
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.turnCount = turnCount
        self.lastActivityAt = lastActivityAt
    }
}

// MARK: - session.create

public struct SessionCreateParams: Codable, Sendable, Equatable {
    /// Optional initial title; defaults to "新对话". Auto-derivation from the
    /// first user prompt happens on submit, only if title is still default.
    public let title: String?

    public init(title: String? = nil) {
        self.title = title
    }
}

public struct SessionCreateResult: Codable, Sendable, Equatable {
    public let session: SessionListItem

    public init(session: SessionListItem) {
        self.session = session
    }
}

// MARK: - session.list

public struct SessionListParams: Codable, Sendable, Equatable {
    public init() {}
}

public struct SessionListResult: Codable, Sendable, Equatable {
    /// `nil` only before the Shell has issued its bootstrap `session.create`.
    public let activeId: String?
    public let sessions: [SessionListItem]

    public init(activeId: String?, sessions: [SessionListItem]) {
        self.activeId = activeId
        self.sessions = sessions
    }
}

// MARK: - session.activate

public struct SessionActivateParams: Codable, Sendable, Equatable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

public struct SessionActivateResult: Codable, Sendable, Equatable {
    /// Full snapshot of the activated session's conversation, ordered by
    /// `startedAt` ascending. All statuses included (in-flight + terminal).
    /// Display-only mirror fields (thinking) are NOT carried — see
    /// "Snapshot merge 契约" in docs/designs/session-management.md.
    public let snapshot: [ConversationTurnWire]

    public init(snapshot: [ConversationTurnWire]) {
        self.snapshot = snapshot
    }
}

// MARK: - session.created / activated / listChanged

public struct SessionCreatedNotificationParams: Codable, Sendable, Equatable {
    public let session: SessionListItem

    public init(session: SessionListItem) {
        self.session = session
    }
}

public struct SessionActivatedNotificationParams: Codable, Sendable, Equatable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

public struct SessionListChangedNotificationParams: Codable, Sendable, Equatable {
    public init() {}
}
