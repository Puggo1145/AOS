import Foundation

// MARK: - PayloadSizeGuard
//
// Per-payload sanity cap on a single text string that flows into a
// `BehaviorEnvelope` or `ClipboardItem`. Defense-in-depth only — the
// authoritative outbound size check lives at the wire boundary in
// `RPCClient.request`, which measures the encoded NDJSON line and rejects
// requests that exceed the sidecar's 2 MiB transport limit before any byte
// hits the pipe.
//
// This cap exists to keep a single runaway capture (a giant paste, a
// pathological AX selection) from dominating the encoded frame on its own,
// and to bound the worst-case JSON escape expansion any one string can
// contribute. It does NOT guarantee the eventual encoded request fits
// under the line cap: multiple chips, JSON-encoding overhead (control
// characters expand 6×), and other envelope fields all add up. Aggregate
// safety is the wire layer's job.
//
// Sized at 1 MiB so the original "no truncation for normal pastes" intent
// holds for any realistic human-authored content. When it does fire, an
// explicit `…[truncated, original N bytes]` marker is appended so neither
// the user nor the LLM mistake the result for the full content.

public enum PayloadSizeGuard {
    /// Per-string sanity cap, in UTF-8 bytes. Not a transport-safety
    /// guarantee — see file header. The wire layer (`RPCClient.request`)
    /// owns final size enforcement against the 2 MiB NDJSON line limit.
    public static let maxTextBytes: Int = 1_048_576  // 1 MiB

    /// Return `text` unchanged when within the cap; otherwise truncate on a
    /// UTF-8 boundary and append a marker that names the original byte size
    /// so downstream consumers know the content was clipped.
    public static func clamp(_ text: String) -> String {
        let utf8 = text.utf8
        let originalBytes = utf8.count
        guard originalBytes > maxTextBytes else { return text }

        // Walk back from `maxTextBytes` to the nearest UTF-8 scalar boundary
        // so we never split a multi-byte character.
        let head = String(decoding: utf8.prefix(maxTextBytes), as: UTF8.self)
        return head + "\n\n…[truncated, original \(originalBytes) bytes]"
    }
}
