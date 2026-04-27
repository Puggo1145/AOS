import Foundation

// MARK: - ui.* notification params
//
// Per docs/designs/rpc-protocol.md §"ui.*（Bun → Shell）". All `ui.*` methods
// are notifications keyed by `turnId`, driving streaming state in the Notch UI.

public struct UITokenParams: Codable, Sendable, Equatable {
    public let turnId: String
    public let delta: String

    public init(turnId: String, delta: String) {
        self.turnId = turnId
        self.delta = delta
    }
}

// `ui.thinking` carries reasoning-trace lifecycle events streamed by
// reasoning-capable models. Tagged by `kind` so the lifecycle is explicit on
// the wire instead of being inferred from neighboring channels:
//   - `.delta` carries an incremental chunk of reasoning text (`delta` set).
//   - `.end`   marks the end of the current reasoning block. No `delta`.
// Kept on a separate channel from `ui.token` so the Notch panel can render
// the reasoning trace distinctly from the visible reply.
public struct UIThinkingParams: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case delta
        case end
    }

    public let turnId: String
    public let kind: Kind
    /// Set iff `kind == .delta`. Omitted from the wire on `.end`.
    public let delta: String?

    public init(turnId: String, kind: Kind, delta: String? = nil) {
        self.turnId = turnId
        self.kind = kind
        self.delta = delta
    }

    // Custom Codable to enforce the tagged-union invariant at the wire
    // boundary, per AGENTS.md "fail fast and loudly". Synthesized Codable
    // would happily decode `{kind:"delta"}` (no delta) or
    // `{kind:"end", delta:"…"}`, both of which violate the contract the TS
    // discriminated union already enforces. Failing here keeps the two sides
    // honest and surfaces wire corruption immediately instead of letting it
    // propagate into downstream display state.

    private enum CodingKeys: String, CodingKey {
        case turnId, kind, delta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let turnId = try c.decode(String.self, forKey: .turnId)
        let kind = try c.decode(Kind.self, forKey: .kind)
        // Strict: presence of the `delta` *key* (including `delta: null`) is
        // what the wire contract gates on, not a non-null value. We test
        // `contains` rather than `decodeIfPresent` because the latter folds
        // missing-and-null into the same Optional.none, which would let
        // `{"kind":"end","delta":null}` slip past the .end invariant.
        switch kind {
        case .delta:
            guard c.contains(.delta) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .delta, in: c,
                    debugDescription: "ui.thinking kind=delta requires a 'delta' string"
                )
            }
            // `decode(String.self, ...)` throws `valueNotFound` on explicit null
            // — exactly the failure we want for `{"kind":"delta","delta":null}`.
            let delta = try c.decode(String.self, forKey: .delta)
            self.init(turnId: turnId, kind: .delta, delta: delta)
        case .end:
            guard !c.contains(.delta) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .delta, in: c,
                    debugDescription: "ui.thinking kind=end must not carry a 'delta' field"
                )
            }
            self.init(turnId: turnId, kind: .end, delta: nil)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(turnId, forKey: .turnId)
        try c.encode(kind, forKey: .kind)
        switch kind {
        case .delta:
            // Producer error to construct `.delta` with `nil`; surface it on
            // encode rather than emitting a malformed wire frame.
            guard let delta else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: c.codingPath,
                        debugDescription: "UIThinkingParams.delta must be set when kind == .delta"
                    )
                )
            }
            try c.encode(delta, forKey: .delta)
        case .end:
            // Drop `delta` regardless of struct value; `.end` is wire-defined
            // to omit the field.
            break
        }
    }
}

/// Discrete agent status pushed by the sidecar agent loop.
public enum UIStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case thinking
    case toolCalling = "tool_calling"
    case waitingInput = "waiting_input"
    case done
}

public struct UIStatusParams: Codable, Sendable, Equatable {
    public let turnId: String
    public let status: UIStatus

    public init(turnId: String, status: UIStatus) {
        self.turnId = turnId
        self.status = status
    }
}

public struct UIErrorParams: Codable, Sendable, Equatable {
    public let turnId: String
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(turnId: String, code: Int, message: String, data: JSONValue? = nil) {
        self.turnId = turnId
        self.code = code
        self.message = message
        self.data = data
    }
}
