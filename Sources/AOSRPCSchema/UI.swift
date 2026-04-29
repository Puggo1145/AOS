import Foundation

// MARK: - ui.* notification params
//
// Per docs/designs/rpc-protocol.md §"ui.*（Bun → Shell）". All `ui.*` methods
// are notifications keyed by `turnId`, driving streaming state in the Notch UI.

public struct UITokenParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let delta: String

    public init(sessionId: String, turnId: String, delta: String) {
        self.sessionId = sessionId
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

    public let sessionId: String
    public let turnId: String
    public let kind: Kind
    /// Set iff `kind == .delta`. Omitted from the wire on `.end`.
    public let delta: String?

    public init(sessionId: String, turnId: String, kind: Kind, delta: String? = nil) {
        self.sessionId = sessionId
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
        case sessionId, turnId, kind, delta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sessionId = try c.decode(String.self, forKey: .sessionId)
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
            self.init(sessionId: sessionId, turnId: turnId, kind: .delta, delta: delta)
        case .end:
            guard !c.contains(.delta) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .delta, in: c,
                    debugDescription: "ui.thinking kind=end must not carry a 'delta' field"
                )
            }
            self.init(sessionId: sessionId, turnId: turnId, kind: .end, delta: nil)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
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

// `ui.toolCall` carries the lifecycle of one tool invocation, tagged by `phase`
// so each frame is self-describing on the wire:
//   - `.called`   — the assistant emitted a tool call AND its arguments
//                   passed schema validation. Carries `toolCallId`,
//                   `toolName`, and the validated `args` payload (opaque
//                   JSON; the sidecar has already shape-checked it against
//                   the tool's schema). The handler is about to run.
//   - `.result`   — the tool finished executing (success OR runtime error).
//                   Carries `toolCallId`, `toolName`, `isError`, and a
//                   one-shot text rendering of the result content
//                   (`outputText`). Structured details stay sidecar-side.
//   - `.rejected` — argument validation failed; the handler never ran.
//                   Carries `toolCallId`, `toolName`, the model's raw
//                   `args` (so the UI can surface what was attempted), and
//                   `errorMessage` (the validation failure shown to both
//                   the user and the model on the next round). MUST NOT
//                   carry `isError` / `outputText`: phase IS the failure
//                   signal, and there is no tool output to render.
// Lives on its own channel (separate from `ui.token` / `ui.thinking`) so the
// Notch panel can render tool activity distinctly from the visible reply.
//
// Rationale for the dedicated `.rejected` phase (vs overloading `.result`):
// the Shell's `ConversationMirror.applyToolCall(.result)` deliberately drops
// frames whose `toolCallId` is unknown — that's how it tolerates the
// `agent.reset` / in-flight tool race. Validation failure happens BEFORE any
// `.called` is emitted (no record yet), so reusing `.result` would make the
// rejection invisible. A separate phase keeps the per-phase field invariants
// strict on both sides while still letting the mirror synthesize an errored
// record in one well-defined place.
public struct UIToolCallParams: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable, Equatable {
        case called
        case result
        case rejected
    }

    public let sessionId: String
    public let turnId: String
    public let phase: Phase
    public let toolCallId: String
    public let toolName: String
    /// Set iff `phase == .called` or `phase == .rejected`.
    public let args: JSONValue?
    /// Set iff `phase == .result`.
    public let isError: Bool?
    /// Set iff `phase == .result`.
    public let outputText: String?
    /// Set iff `phase == .rejected`. Human-readable validation failure.
    public let errorMessage: String?

    public init(
        sessionId: String,
        turnId: String,
        phase: Phase,
        toolCallId: String,
        toolName: String,
        args: JSONValue? = nil,
        isError: Bool? = nil,
        outputText: String? = nil,
        errorMessage: String? = nil
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.phase = phase
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.args = args
        self.isError = isError
        self.outputText = outputText
        self.errorMessage = errorMessage
    }

    // Custom Codable enforces the tagged-union invariant at the wire boundary,
    // mirroring `UIThinkingParams` above. Synthesized Codable would happily
    // round-trip a `.called` frame that also carries `outputText` (or a
    // `.result` frame that also carries `args`), both of which violate the
    // contract the TS discriminated union enforces by construction. Failing
    // here keeps the two sides honest and surfaces wire corruption immediately.
    //
    // Field-presence semantics (NOT field-value): we test `contains(_:)` rather
    // than `decodeIfPresent` so that an explicit `null` is rejected the same as
    // an unexpected non-null value. This matches the symmetric strictness of
    // `UIThinkingParams` and the byte-equal expectations of the fixtures.

    private enum CodingKeys: String, CodingKey {
        case sessionId, turnId, phase, toolCallId, toolName, args, isError, outputText, errorMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sessionId = try c.decode(String.self, forKey: .sessionId)
        let turnId = try c.decode(String.self, forKey: .turnId)
        let phase = try c.decode(Phase.self, forKey: .phase)
        let toolCallId = try c.decode(String.self, forKey: .toolCallId)
        let toolName = try c.decode(String.self, forKey: .toolName)
        switch phase {
        case .called:
            guard c.contains(.args) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .args, in: c,
                    debugDescription: "ui.toolCall phase=called requires an 'args' field"
                )
            }
            guard !c.contains(.isError) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .isError, in: c,
                    debugDescription: "ui.toolCall phase=called must not carry 'isError'"
                )
            }
            guard !c.contains(.outputText) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .outputText, in: c,
                    debugDescription: "ui.toolCall phase=called must not carry 'outputText'"
                )
            }
            guard !c.contains(.errorMessage) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .errorMessage, in: c,
                    debugDescription: "ui.toolCall phase=called must not carry 'errorMessage'"
                )
            }
            let args = try c.decode(JSONValue.self, forKey: .args)
            self.init(
                sessionId: sessionId, turnId: turnId, phase: .called,
                toolCallId: toolCallId, toolName: toolName, args: args
            )
        case .result:
            guard !c.contains(.args) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .args, in: c,
                    debugDescription: "ui.toolCall phase=result must not carry 'args'"
                )
            }
            guard c.contains(.isError) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .isError, in: c,
                    debugDescription: "ui.toolCall phase=result requires an 'isError' boolean"
                )
            }
            guard c.contains(.outputText) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .outputText, in: c,
                    debugDescription: "ui.toolCall phase=result requires an 'outputText' string"
                )
            }
            guard !c.contains(.errorMessage) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .errorMessage, in: c,
                    debugDescription: "ui.toolCall phase=result must not carry 'errorMessage'"
                )
            }
            let isError = try c.decode(Bool.self, forKey: .isError)
            let outputText = try c.decode(String.self, forKey: .outputText)
            self.init(
                sessionId: sessionId, turnId: turnId, phase: .result,
                toolCallId: toolCallId, toolName: toolName,
                isError: isError, outputText: outputText
            )
        case .rejected:
            guard c.contains(.args) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .args, in: c,
                    debugDescription: "ui.toolCall phase=rejected requires an 'args' field"
                )
            }
            guard c.contains(.errorMessage) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .errorMessage, in: c,
                    debugDescription: "ui.toolCall phase=rejected requires an 'errorMessage' string"
                )
            }
            guard !c.contains(.isError) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .isError, in: c,
                    debugDescription: "ui.toolCall phase=rejected must not carry 'isError'"
                )
            }
            guard !c.contains(.outputText) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .outputText, in: c,
                    debugDescription: "ui.toolCall phase=rejected must not carry 'outputText'"
                )
            }
            let args = try c.decode(JSONValue.self, forKey: .args)
            let errorMessage = try c.decode(String.self, forKey: .errorMessage)
            self.init(
                sessionId: sessionId, turnId: turnId, phase: .rejected,
                toolCallId: toolCallId, toolName: toolName,
                args: args, errorMessage: errorMessage
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(turnId, forKey: .turnId)
        try c.encode(phase, forKey: .phase)
        try c.encode(toolCallId, forKey: .toolCallId)
        try c.encode(toolName, forKey: .toolName)
        switch phase {
        case .called:
            guard let args else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: c.codingPath,
                        debugDescription: "UIToolCallParams.args must be set when phase == .called"
                    )
                )
            }
            try c.encode(args, forKey: .args)
        case .result:
            guard let isError, let outputText else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: c.codingPath,
                        debugDescription: "UIToolCallParams.isError and .outputText must be set when phase == .result"
                    )
                )
            }
            try c.encode(isError, forKey: .isError)
            try c.encode(outputText, forKey: .outputText)
        case .rejected:
            guard let args, let errorMessage else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: c.codingPath,
                        debugDescription: "UIToolCallParams.args and .errorMessage must be set when phase == .rejected"
                    )
                )
            }
            try c.encode(args, forKey: .args)
            try c.encode(errorMessage, forKey: .errorMessage)
        }
    }
}

/// Discrete agent status pushed by the sidecar agent loop.
public enum UIStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case working
    case waiting
    case done
}

public struct UIStatusParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let status: UIStatus

    public init(sessionId: String, turnId: String, status: UIStatus) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.status = status
    }
}

public struct UIErrorParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(sessionId: String, turnId: String, code: Int, message: String, data: JSONValue? = nil) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Token-usage snapshot emitted once per LLM round. Drives the live composer's
/// context-usage ring. See `UIUsageParams` in `sidecar/src/rpc/rpc-types.ts`
/// for the full contract. The headline "used context" is
/// `inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens` — the
/// byte-equivalent the next round's prompt+reply round-trips through.
public struct UIUsageParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let totalTokens: Int
    public let contextWindow: Int
    public let modelId: String

    public init(
        sessionId: String,
        turnId: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalTokens: Int,
        contextWindow: Int,
        modelId: String
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.contextWindow = contextWindow
        self.modelId = modelId
    }
}
