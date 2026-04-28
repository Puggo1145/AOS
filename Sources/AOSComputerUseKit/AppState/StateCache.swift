import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - StateCache
//
// Per `docs/designs/computer-use.md` §"AX 快照生命周期":
//
//   stateId TTL = 30s
//   per (pid, windowId) keep only the latest snapshot (no LRU)
//   element invalid → ErrStateStale
//   (pid, windowId) ↔ stateId mismatch → ErrWindowMismatch
//
// `stateId` is a UUID handed back to the agent so subsequent click /
// type calls can refer to a specific tree walk. The cache validates
// (pid, windowId) consistency and element liveness before returning.

public struct StateID: Sendable, Hashable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public enum StateCacheLookupError: Error, Sendable, Equatable {
    /// `stateId` not found, expired, or its element is no longer valid.
    case stale(reason: StaleReason, stateId: String)
    /// (pid, windowId) of the request doesn't match the snapshot's
    /// (pid, windowId).
    case windowMismatch(stateId: String, expectedPid: pid_t, expectedWindowId: CGWindowID)
    case invalidElementIndex(stateId: String, elementIndex: Int)

    public enum StaleReason: String, Sendable, Equatable {
        case expired
        case elementInvalid
        case windowChanged
    }
}

public actor StateCache {
    private struct Entry {
        let stateId: StateID
        let pid: pid_t
        let windowId: CGWindowID
        let createdAt: Date
        let elements: [Int: AXUIElement]
    }

    /// The most recent screenshot's actual pixel size for `(pid, windowId)`.
    /// Stored independently of any AX snapshot so vision-only flows
    /// (`captureMode: .vision`) and pure coordinate clicks can still find the
    /// reference dimensions used to convert the model's pixel coords to
    /// window-local points. `WindowCoordinateSpace` prefers this ratio
    /// (`bounds.size / pixelSize`) over the assumed `backingScale` because
    /// it survives `maxImageDimension` downscaling, fractional bounds
    /// rounding, and any other real/declared scale mismatch.
    private struct ScreenshotRecord {
        let pixelSize: CGSize
        let recordedAt: Date
    }

    /// Single-key bucket. Per the design: same (pid, windowId) snapshot
    /// just overwrites — no LRU, no fan-out. Keeps the cache trivially
    /// bounded by the count of (pid, windowId) combos the agent visits.
    private var bucket: [Key: Entry] = [:]
    private var screenshotBucket: [Key: ScreenshotRecord] = [:]
    private let ttl: TimeInterval

    public init(ttlSeconds: TimeInterval = 30) {
        self.ttl = ttlSeconds
    }

    private struct Key: Hashable {
        let pid: pid_t
        let windowId: CGWindowID
    }

    /// Replace any prior snapshot for `(pid, windowId)`. Returns the new
    /// `stateId`.
    @discardableResult
    public func store(
        pid: pid_t,
        windowId: CGWindowID,
        elements: [Int: AXUIElement]
    ) -> StateID {
        let stateId = StateID(UUID().uuidString)
        let entry = Entry(
            stateId: stateId,
            pid: pid,
            windowId: windowId,
            createdAt: Date(),
            elements: elements
        )
        bucket[Key(pid: pid, windowId: windowId)] = entry
        return stateId
    }

    /// Look up `elementIndex` for `(pid, windowId, stateId)`. Validates:
    ///
    ///   - stateId exists and TTL not exceeded
    ///   - request's (pid, windowId) matches the stored snapshot
    ///   - element is still alive (probe via `AXUIElementCopyAttributeValue`
    ///     on `AXRole`; any non-success means the underlying AX node was
    ///     reaped)
    public func lookup(
        pid: pid_t,
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int
    ) throws -> AXUIElement {
        // Resolve the entry by `stateId` first, not by `(pid, windowId)`.
        // The wire protocol's recovery semantics differ:
        //   - stateId belongs to a different window → ErrWindowMismatch
        //     (the model targeted the wrong window — fix the args).
        //   - stateId not found → ErrStateStale (refresh and retry).
        // Keying by (pid, windowId) collapsed those two cases into stale,
        // sending the agent down the wrong recovery branch.
        let entry: Entry
        if let found = entryByStateId(stateId) {
            entry = found
        } else {
            // Drop the (pid, windowId) bucket if it expired so a fresh
            // store doesn't collide with a dead entry.
            if let stored = bucket[Key(pid: pid, windowId: windowId)],
               Date().timeIntervalSince(stored.createdAt) > ttl {
                bucket.removeValue(forKey: Key(pid: pid, windowId: windowId))
            }
            throw StateCacheLookupError.stale(
                reason: .expired, stateId: stateId.raw
            )
        }
        if entry.pid != pid || entry.windowId != windowId {
            throw StateCacheLookupError.windowMismatch(
                stateId: stateId.raw,
                expectedPid: entry.pid,
                expectedWindowId: entry.windowId
            )
        }
        if Date().timeIntervalSince(entry.createdAt) > ttl {
            bucket.removeValue(forKey: Key(pid: pid, windowId: windowId))
            throw StateCacheLookupError.stale(
                reason: .expired, stateId: stateId.raw
            )
        }
        guard let element = entry.elements[elementIndex] else {
            throw StateCacheLookupError.invalidElementIndex(
                stateId: stateId.raw, elementIndex: elementIndex
            )
        }
        if !Self.isElementAlive(element) {
            throw StateCacheLookupError.stale(
                reason: .elementInvalid, stateId: stateId.raw
            )
        }
        return element
    }

    /// Linear scan over `bucket.values` looking for `stateId`. The cache
    /// is single-key per (pid, windowId), so the bucket size is bounded
    /// by the count of distinct windows the agent has touched in the
    /// last 30s — typically a handful. A dictionary index on stateId
    /// would be premature optimization at this size.
    private func entryByStateId(_ stateId: StateID) -> Entry? {
        for entry in bucket.values where entry.stateId == stateId {
            return entry
        }
        return nil
    }

    /// Pure function used by tests + `lookup`. Probes `AXRole` —
    /// reading fails when the element has been deallocated by the
    /// target. Cheap (single CF roundtrip).
    public static func isElementAlive(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &ref)
        return result == .success
    }

    /// Record the actual pixel size of the latest screenshot for
    /// `(pid, windowId)`. Same overwrite semantics as `store`.
    public func recordScreenshot(
        pid: pid_t,
        windowId: CGWindowID,
        pixelSize: CGSize
    ) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        screenshotBucket[Key(pid: pid, windowId: windowId)] = ScreenshotRecord(
            pixelSize: pixelSize,
            recordedAt: Date()
        )
    }

    /// Most recent screenshot's actual pixel dimensions for
    /// `(pid, windowId)`, if any. TTL matches the AX snapshot TTL so a
    /// stale entry doesn't outlive a moved/resized window.
    public func screenshotPixelSize(
        pid: pid_t,
        windowId: CGWindowID
    ) -> CGSize? {
        let key = Key(pid: pid, windowId: windowId)
        guard let record = screenshotBucket[key] else { return nil }
        if Date().timeIntervalSince(record.recordedAt) > ttl {
            screenshotBucket.removeValue(forKey: key)
            return nil
        }
        return record.pixelSize
    }

    /// Drop everything — used by `agent.reset` semantics if/when the
    /// Shell wants to invalidate live snapshots.
    public func clear() {
        bucket.removeAll()
        screenshotBucket.removeAll()
    }
}
