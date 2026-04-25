import Foundation

// MARK: - Canonical JSON encoder
//
// Single canonical-form encoder used by:
//   - `AOSShell/RPCClient` for every outbound NDJSON frame
//   - `Tests/AOSRPCSchemaTests` for fixture byte-equal roundtrip tests
//   - any future tooling that needs to produce byte-equal JSON
//
// Two output flags are pinned:
//   - `.sortedKeys`             — every object keys-sorted at every nesting
//                                 level. Matches TS test's `sortKeys` plus
//                                 `JSON.stringify`.
//   - `.withoutEscapingSlashes` — Foundation's default escapes "/" as "\/" in
//                                 strings (e.g. URLs, base64 padding); TS's
//                                 `JSON.stringify` does NOT escape "/". Without
//                                 this flag the Swell side would emit a wire
//                                 stream with `\/` while the sidecar emits `/`,
//                                 breaking byte-equal fixtures and any future
//                                 consumer that diffs the two.
//
// Keep this single source of truth — runtime encoding and test encoding MUST
// match or the conformance harness silently lies.

public enum CanonicalJSON {
    /// Shared canonical encoder. Returned fresh each call because
    /// `JSONEncoder` is not thread-safe (its `outputFormatting` is mutable).
    public static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }

    /// Encode `value` to canonical JSON bytes.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }
}
