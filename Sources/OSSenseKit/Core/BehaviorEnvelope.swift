import Foundation

// MARK: - BehaviorEnvelope (live model)
//
// Per `docs/designs/os-sense.md` §"Behavior 契约". This is the live
// in-process envelope. The wire-side equivalent (`RPCSchema.BehaviorEnvelope`)
// has the same shape but is a **distinct type** by deliberate design — OS Sense
// must not import `RPCSchema`. The Shell composition root projects between
// the two when serializing `CitedContext` for `agent.submit`.
//
// `payload` is opaque: SenseStore / RPC layer / default chip UI all
// transit it unchanged; only the LLM (in the Sidecar prompt builder)
// interprets the structure by `kind`.

public struct BehaviorEnvelope: Equatable, Sendable, Identifiable {
    public let kind: String
    public let citationKey: String
    public let displaySummary: String
    public let payload: JSONValue

    public var id: String { citationKey }

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

// MARK: - JSONValue
//
// Local recursive Codable enum mirroring `RPCSchema.JSONValue` in shape,
// but **deliberately not imported** from there: per design "依赖方向（核心
// 契约）", OS Sense (read-side live model) does not depend on the wire
// schema package. The Shell composition layer translates between the two
// representations at the projection seam.

public indirect enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let a):
            try container.encode(a)
        case .object(let o):
            try container.encode(o)
        }
    }
}
