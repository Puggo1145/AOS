import Foundation

// MARK: - dev.* — observability surface for the Shell's Dev Mode window
//
// Per `docs/designs/rpc-protocol.md` "Namespace 规则" extension:
//   - `dev.context.get`     Shell→Bun request. Pulls the latest LLM context
//                           snapshot. `snapshot` is `null` until the agent
//                           loop has produced at least one turn.
//   - `dev.context.changed` Bun→Shell notification fired once per turn,
//                           immediately before `streamSimple()` is called.
//
// `messagesJson` is a pre-formatted JSON string of the `Message[]` array
// the Sidecar passed to the LLM provider. The Shell renders it verbatim
// in monospace — there is no further parsing on the Shell side. This keeps
// the wire format the single source of truth for "原文" display.

public struct DevContextSnapshot: Codable, Sendable, Equatable {
    /// Milliseconds since epoch.
    public let capturedAt: Int
    /// Session that issued this turn. Per docs/designs/session-management.md
    /// the sidecar keeps a *global latest* (not per-session) snapshot — Dev
    /// Mode renders the sessionId + an "active?" badge so background turns
    /// are distinguishable.
    public let sessionId: String
    public let turnId: String
    public let modelId: String
    public let providerId: String
    /// Reasoning effort applied for this turn; `nil` for non-reasoning models.
    public let effort: String?
    public let systemPrompt: String
    /// Pretty-printed JSON of the messages array passed to `streamSimple`.
    public let messagesJson: String

    public init(
        capturedAt: Int,
        sessionId: String,
        turnId: String,
        modelId: String,
        providerId: String,
        effort: String?,
        systemPrompt: String,
        messagesJson: String
    ) {
        self.capturedAt = capturedAt
        self.sessionId = sessionId
        self.turnId = turnId
        self.modelId = modelId
        self.providerId = providerId
        self.effort = effort
        self.systemPrompt = systemPrompt
        self.messagesJson = messagesJson
    }
}

public struct DevContextGetParams: Codable, Sendable, Equatable {
    public init() {}
}

public struct DevContextGetResult: Codable, Sendable, Equatable {
    /// `nil` when the agent loop has not yet produced a turn.
    public let snapshot: DevContextSnapshot?

    public init(snapshot: DevContextSnapshot?) {
        self.snapshot = snapshot
    }
}

public struct DevContextChangedParams: Codable, Sendable, Equatable {
    public let snapshot: DevContextSnapshot

    public init(snapshot: DevContextSnapshot) {
        self.snapshot = snapshot
    }
}
