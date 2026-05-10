import Foundation

// MARK: - agent.* params / results
//
// Per docs/designs/rpc-protocol.md §"agent.*（Shell → Bun）".
// `agent.submit` carries the prompt plus the **wire-only** `CitedContext`
// projection of `SenseContext`. `agent.cancel` is keyed by `turnId`.

public struct AgentSubmitParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let prompt: String
    public let citedContext: CitedContext

    public init(sessionId: String, turnId: String, prompt: String, citedContext: CitedContext) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.prompt = prompt
        self.citedContext = citedContext
    }
}

public struct AgentSubmitResult: Codable, Sendable, Equatable {
    public let accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }
}

public struct AgentCancelParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turnId: String

    public init(sessionId: String, turnId: String) {
        self.sessionId = sessionId
        self.turnId = turnId
    }
}

public struct AgentCancelResult: Codable, Sendable, Equatable {
    public let cancelled: Bool

    public init(cancelled: Bool) {
        self.cancelled = cancelled
    }
}

// MARK: - agent.reset
//
// `agent.reset` clears the conversation of ONE session (cancels its in-flight
// turn first). The sidecar follows up with `conversation.reset { sessionId }`
// so observers drop the mirror for that session, plus `session.listChanged`
// so the history list reflects the zeroed turnCount.

public struct AgentResetParams: Codable, Sendable, Equatable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

public struct AgentResetResult: Codable, Sendable, Equatable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

// MARK: - agent.compact
//
// Manual context-compact entry. Layer 3 of the compact stack — the user
// explicitly asks the sidecar to summarize prior history right now (vs.
// the auto path that fires from `runTurn` entry once the running token
// estimate gets close to the model's context window).
//
// The handler bypasses the auto-compact circuit breaker (manual intent
// overrides past auto failures) and rejects when a turn is in flight on
// the session. Both paths emit the same `ui.compact { started → done |
// failed }` lifecycle; on the manual path the wire `turnId` on those
// frames is the empty string — there is no "next turn" the marker
// should visually precede, so Shell renders the marker at the tail of
// history.

public struct AgentCompactParams: Codable, Sendable, Equatable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

public struct AgentCompactResult: Codable, Sendable, Equatable {
    public let ok: Bool
    /// Turns folded into the summary on success. Omitted when there was
    /// no prior history to compact.
    public let compactedTurnCount: Int?

    public init(ok: Bool, compactedTurnCount: Int? = nil) {
        self.ok = ok
        self.compactedTurnCount = compactedTurnCount
    }
}

// MARK: - conversation.* (Sidecar → Shell notifications)
//
// The sidecar owns the canonical conversation state (turns array + the LLM
// history derived from it). Shell mirrors it from these notifications:
//   - `conversation.turnStarted { turn }` once per `agent.submit` after the
//     sidecar has registered the turn. Carries the snapshot the sidecar
//     persisted (initial empty reply, status: working).
//   - `conversation.reset` after `agent.reset` wipes the store.
//   - reply token deltas keep flowing over the existing `ui.token` so tight
//     streaming doesn't pay a serialization cost per character.
//   - per-turn status changes flow over `ui.status` / `ui.error`.

public enum TurnStatus: String, Codable, Sendable, Equatable {
    case working
    case waiting
    case done
    case error
    case cancelled
}

public struct ConversationTurnWire: Codable, Sendable, Equatable {
    public let id: String
    public let prompt: String
    public let citedContext: CitedContext
    public let reply: String
    public let status: TurnStatus
    public let errorMessage: String?
    public let errorCode: Int?
    /// Milliseconds since epoch.
    public let startedAt: Int

    public init(
        id: String,
        prompt: String,
        citedContext: CitedContext,
        reply: String,
        status: TurnStatus,
        errorMessage: String? = nil,
        errorCode: Int? = nil,
        startedAt: Int
    ) {
        self.id = id
        self.prompt = prompt
        self.citedContext = citedContext
        self.reply = reply
        self.status = status
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.startedAt = startedAt
    }
}

public struct ConversationTurnStartedParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turn: ConversationTurnWire

    public init(sessionId: String, turn: ConversationTurnWire) {
        self.sessionId = sessionId
        self.turn = turn
    }
}

public struct ConversationResetParams: Codable, Sendable, Equatable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// MARK: - CitedContext
//
// Wire-only projection of `SenseContext`. Live model fields that hold
// non-serializable types (NSImage, CGImage, …) are flattened or dropped.
// All inner fields are optional — degraded mode (no AX, no adapters)
// serializes as `{}`. Per design doc, this is graceful degradation,
// not a stub: missing fields are omitted, never serialized as `null`.

public struct CitedContext: Codable, Sendable, Equatable {
    public let app: CitedApp?
    public let window: CitedWindow?
    public let behaviors: [BehaviorEnvelope]?
    public let visual: CitedVisual?
    /// Zero or more clipboard payloads — one per paste the user performed
    /// into the composer this turn. Order is paste order. Omitted (nil)
    /// when no pastes occurred; an empty array is invalid.
    public let clipboards: [CitedClipboard]?

    public init(
        app: CitedApp? = nil,
        window: CitedWindow? = nil,
        behaviors: [BehaviorEnvelope]? = nil,
        visual: CitedVisual? = nil,
        clipboards: [CitedClipboard]? = nil
    ) {
        self.app = app
        self.window = window
        self.behaviors = behaviors
        self.visual = visual
        self.clipboards = clipboards
    }
}

public struct CitedApp: Codable, Sendable, Equatable {
    public let bundleId: String
    public let name: String
    public let pid: Int
    /// Base64-encoded PNG of the app icon. Optional; omitted when
    /// `NSRunningApplication.icon` is unavailable.
    public let iconPNG: String?

    public init(bundleId: String, name: String, pid: Int, iconPNG: String? = nil) {
        self.bundleId = bundleId
        self.name = name
        self.pid = pid
        self.iconPNG = iconPNG
    }
}

public struct CitedWindow: Codable, Sendable, Equatable {
    public let title: String
    /// `CGWindowID`. Hint, not a long-lived handle; windows can be recreated
    /// or moved between Spaces after OS Sense captures this value.
    public let windowId: Int?

    public init(title: String, windowId: Int? = nil) {
        self.title = title
        self.windowId = windowId
    }
}

public struct BehaviorEnvelope: Codable, Sendable, Equatable {
    public let kind: String
    public let citationKey: String
    public let displaySummary: String
    /// Opaque per-producer JSON. Sidecar passes through unchanged.
    public let payload: JSONValue

    public init(
        kind: String,
        citationKey: String,
        displaySummary: String,
        payload: JSONValue
    ) {
        self.kind = kind
        self.citationKey = citationKey
        self.displaySummary = displaySummary
        self.payload = payload
    }
}

public struct CitedVisualSize: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct CitedVisual: Codable, Sendable, Equatable {
    /// Base64-encoded PNG, ≤ 400KB after encoding.
    public let frame: String
    public let frameSize: CitedVisualSize
    /// ISO-8601 UTC timestamp.
    public let capturedAt: String

    public init(frame: String, frameSize: CitedVisualSize, capturedAt: String) {
        self.frame = frame
        self.frameSize = frameSize
        self.capturedAt = capturedAt
    }
}

// MARK: - CitedClipboard
//
// Discriminated union, encoded as `{ kind: "...", ... }`:
//   - `.text(String)`         → `{ kind: "text", content }`
//   - `.filePaths([String])`  → `{ kind: "filePaths", paths }`
//   - `.image(metadata: …)`   → `{ kind: "image", metadata: { width, height, type } }`

public struct CitedClipboardImageMetadata: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let type: String

    public init(width: Int, height: Int, type: String) {
        self.width = width
        self.height = height
        self.type = type
    }
}

public enum CitedClipboard: Sendable, Equatable, Codable {
    case text(String)
    case filePaths([String])
    case image(metadata: CitedClipboardImageMetadata)

    private enum CodingKeys: String, CodingKey {
        case kind
        case content
        case paths
        case metadata
    }

    private enum Kind: String {
        case text
        case filePaths
        case image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: kindRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown CitedClipboard kind: \(kindRaw)"
            )
        }
        switch kind {
        case .text:
            let s = try container.decode(String.self, forKey: .content)
            self = .text(s)
        case .filePaths:
            let p = try container.decode([String].self, forKey: .paths)
            self = .filePaths(p)
        case .image:
            let m = try container.decode(CitedClipboardImageMetadata.self, forKey: .metadata)
            self = .image(metadata: m)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try container.encode(Kind.text.rawValue, forKey: .kind)
            try container.encode(s, forKey: .content)
        case .filePaths(let p):
            try container.encode(Kind.filePaths.rawValue, forKey: .kind)
            try container.encode(p, forKey: .paths)
        case .image(let m):
            try container.encode(Kind.image.rawValue, forKey: .kind)
            try container.encode(m, forKey: .metadata)
        }
    }
}
