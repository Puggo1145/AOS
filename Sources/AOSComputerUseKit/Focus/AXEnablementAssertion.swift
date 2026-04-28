import ApplicationServices
import Foundation

// MARK: - AXEnablementAssertion
//
// Layer 1 of `FocusGuard`. Writes the two boolean AX attributes Chromium /
// Electron use as a "real AX client is here, build the full tree" signal:
//
//   - `AXManualAccessibility`     (modern Chromium hint)
//   - `AXEnhancedUserInterface`   (legacy AppleScript-era equivalent)
//
// Native Cocoa apps reject both writes silently; we cache that as
// "non-assertable" so we don't pay the cost on every snapshot. Per
// `docs/designs/computer-use.md` §"焦点抑制(FocusGuard)" we always re-write
// for Chromium because backgrounding / tab switches reset the attributes,
// and the per-write cost is sub-millisecond.
//
// Negative-cache TTL: a Chromium/Electron app's AX subsystem may not be
// ready on the very first snapshot (still booting), so a single failed
// write doesn't prove the app is "native Cocoa, never write again". The
// previous never-expire negative cache silently demoted such apps to
// degraded AX trees for their entire lifetime — restart of the app was the
// only recovery. We now expire negative entries after `negativeCacheTTL`
// (default 30s) so a transient failure recovers automatically; the
// per-call cost of one extra retry every 30s is sub-millisecond.

/// Injection point for the AX attribute write. Default is the real
/// `AXUIElementSetAttributeValue` SPI; tests pass a stub so they can
/// deterministically force the success / failure branches without
/// depending on whether the host process happens to accept the writes.
public typealias AXAttributeWriter = @Sendable (AXUIElement, CFString, CFTypeRef) -> AXError

public actor AXEnablementAssertion {
    private var assertedPids: Set<pid_t> = []
    /// Pid → time the negative entry was recorded. Entries older than
    /// `negativeCacheTTL` are treated as absent and re-probed.
    private var nonAssertableSince: [pid_t: Date] = [:]
    private let negativeCacheTTL: TimeInterval
    private let writeAttribute: AXAttributeWriter

    /// `negativeCacheTTL` is overridable so tests can pin a small interval
    /// without sleeping. Production default is 30s — long enough that
    /// repeat-rejection cost stays negligible across normal snapshot
    /// cadence, short enough that a Chromium app misclassified at boot
    /// recovers within one user-perceptible interaction.
    ///
    /// `writeAttribute` defaults to the real `AXUIElementSetAttributeValue`
    /// — the seam exists so tests can force `.failure` deterministically
    /// (tests can't assume the host process rejects AX writes; CI vs local
    /// behavior diverges). Production callers should never pass it.
    public init(
        negativeCacheTTL: TimeInterval = 30,
        writeAttribute: AXAttributeWriter? = nil
    ) {
        self.negativeCacheTTL = negativeCacheTTL
        // `AXUIElementSetAttributeValue` is a C symbol without a Sendable
        // annotation, so wrapping it in a Swift closure is the only way
        // to satisfy `@Sendable AXAttributeWriter` without a warning. The
        // wrapper has no captured state — it's safe.
        self.writeAttribute = writeAttribute ?? { element, attr, value in
            AXUIElementSetAttributeValue(element, attr, value)
        }
    }

    /// Try to flip both attributes on the application root. Returns `true`
    /// when at least one write succeeded (or this pid has succeeded
    /// previously); `false` when both writes failed. Failed pids are
    /// remembered with a timestamp so the run-loop pump can skip them
    /// cheaply but still re-probe after the TTL.
    @discardableResult
    public func assert(pid: pid_t, root: AXUIElement) -> Bool {
        if isNegativeCached(pid: pid) {
            // Still inside the TTL window — skip the writes.
            return false
        }

        let manualResult = writeAttribute(
            root, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        let enhancedResult = writeAttribute(
            root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )

        if manualResult != .success && enhancedResult != .success {
            // Don't mark a previously-asserted pid as non-assertable on a
            // single later miss — Chromium can drop and reattach AX state
            // mid-session and we'd thrash. Same shape as before, plus TTL.
            if !assertedPids.contains(pid) {
                nonAssertableSince[pid] = Date()
            }
            return assertedPids.contains(pid)
        }
        assertedPids.insert(pid)
        // A write succeeding clears any prior negative entry — the app
        // proved it can take the hint, so future calls should re-write.
        nonAssertableSince.removeValue(forKey: pid)
        return true
    }

    public func isKnownNonAssertable(pid: pid_t) -> Bool {
        isNegativeCached(pid: pid)
    }

    public func isAlreadyAsserted(pid: pid_t) -> Bool {
        assertedPids.contains(pid)
    }

    /// Returns true iff there's a negative entry for `pid` and it hasn't
    /// expired. Lazily evicts stale entries on read so the map doesn't
    /// grow unbounded for short-lived processes.
    private func isNegativeCached(pid: pid_t) -> Bool {
        guard let recordedAt = nonAssertableSince[pid] else { return false }
        if Date().timeIntervalSince(recordedAt) >= negativeCacheTTL {
            nonAssertableSince.removeValue(forKey: pid)
            return false
        }
        return true
    }
}
