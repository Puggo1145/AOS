import Testing
import Foundation
import ApplicationServices
import CoreGraphics
@testable import AOSComputerUseKit

// MARK: - StateCache lifecycle
//
// Per `docs/designs/computer-use.md` §"AX 快照生命周期":
//   - per (pid, windowId) keep only the latest (single key, no LRU)
//   - TTL = 30s (overridable for tests)
//   - element invalid → ErrStateStale
//   - (pid, windowId) mismatch → throws

@Suite("StateCache")
struct StateCacheTests {

    /// Use the host process's own AX root as a stable, always-alive
    /// element. Tests that need a "dead" element wouldn't be portable
    /// against AX without spawning child processes.
    private static func aliveElement() -> AXUIElement {
        AXUIElementCreateApplication(getpid())
    }

    /// `StateCache.lookup` runs `isElementAlive` as the final gate. In the
    /// test process AX reads can fail (no TCC grant). Skip the lookup-path
    /// tests when that's the case rather than reporting a false failure.
    private static func axProbeWorks() -> Bool {
        let element = aliveElement()
        return StateCache.isElementAlive(element)
    }

    @Test("Stores + retrieves an element by stateId")
    func storeAndLookup() async throws {
        guard Self.axProbeWorks() else { return }
        let cache = StateCache(ttlSeconds: 30)
        let pid: pid_t = 1234
        let wid: CGWindowID = 5678
        let element = Self.aliveElement()
        let stateId = await cache.store(pid: pid, windowId: wid, elements: [0: element])
        let found = try await cache.lookup(
            pid: pid, windowId: wid, stateId: stateId, elementIndex: 0
        )
        // CFEqual identifies the same AXUIElement instance even after the
        // CF roundtrip the cache does internally.
        #expect(CFEqual(found, element))
    }

    @Test("Valid stateId from a different window surfaces windowMismatch with the expected (pid, windowId)")
    func windowMismatchSurfaces() async throws {
        // Regression: the cache used to key its lookup by (pid, windowId)
        // and surface a stale(windowChanged) for any mismatch. The wire
        // protocol distinguishes ErrStateStale from ErrWindowMismatch
        // because the recovery branches differ — stale = "refresh and
        // retry", mismatch = "fix the target window". Collapsing both
        // into stale sent the agent down the wrong recovery path.
        let cache = StateCache(ttlSeconds: 30)
        let element = Self.aliveElement()
        let stateId = await cache.store(pid: 1234, windowId: 5678, elements: [0: element])
        do {
            _ = try await cache.lookup(
                pid: 1234, windowId: 9999, stateId: stateId, elementIndex: 0
            )
            Issue.record("expected lookup to fail for mismatched windowId")
        } catch let err as StateCacheLookupError {
            switch err {
            case .windowMismatch(let returnedStateId, let expectedPid, let expectedWindowId):
                #expect(returnedStateId == stateId.raw)
                #expect(expectedPid == 1234)
                #expect(expectedWindowId == 5678)
            default:
                Issue.record("unexpected error: \(err)")
            }
        }
    }

    @Test("Unknown stateId for a window with no snapshot surfaces stale, not windowMismatch")
    func unknownStateIdReturnsStale() async throws {
        // The other half of the protocol distinction: stateId truly
        // doesn't exist anywhere (neither the requested window nor any
        // other) → stale, telling the agent to refresh.
        let cache = StateCache(ttlSeconds: 30)
        do {
            _ = try await cache.lookup(
                pid: 1, windowId: 2,
                stateId: StateID("never-minted"),
                elementIndex: 0
            )
            Issue.record("expected lookup to fail for unknown stateId")
        } catch let err as StateCacheLookupError {
            if case .stale(let reason, _) = err {
                #expect(reason == .expired)
            } else {
                Issue.record("unexpected error: \(err)")
            }
        }
    }

    @Test("Storing again overwrites the prior bucket — old stateId becomes stale")
    func singleKeyOverwrites() async throws {
        guard Self.axProbeWorks() else { return }
        let cache = StateCache(ttlSeconds: 30)
        let element = Self.aliveElement()
        let firstId = await cache.store(pid: 1, windowId: 2, elements: [0: element])
        // Same (pid, windowId), new snapshot — different stateId.
        let secondId = await cache.store(pid: 1, windowId: 2, elements: [0: element])
        #expect(firstId != secondId)
        // First stateId is now stale.
        do {
            _ = try await cache.lookup(pid: 1, windowId: 2, stateId: firstId, elementIndex: 0)
            Issue.record("expected first stateId to be stale after overwrite")
        } catch let err as StateCacheLookupError {
            if case .stale = err { /* expected */ } else {
                Issue.record("unexpected error: \(err)")
            }
        }
        // Second stateId still works.
        _ = try await cache.lookup(pid: 1, windowId: 2, stateId: secondId, elementIndex: 0)
    }

    @Test("TTL expiry surfaces as stale (expired)")
    func ttlExpiry() async throws {
        // Same reason as windowMismatch: TTL check fires before the alive
        // probe.
        let cache = StateCache(ttlSeconds: 0.1)  // 100ms
        let element = Self.aliveElement()
        let stateId = await cache.store(pid: 1, windowId: 2, elements: [0: element])
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            _ = try await cache.lookup(pid: 1, windowId: 2, stateId: stateId, elementIndex: 0)
            Issue.record("expected lookup to fail after TTL expiry")
        } catch let err as StateCacheLookupError {
            if case .stale(let reason, _) = err {
                #expect(reason == .expired)
            } else {
                Issue.record("unexpected error: \(err)")
            }
        }
    }

    @Test("recordScreenshot is per (pid, windowId) and survives until TTL")
    func screenshotRecordRoundTrips() async {
        let cache = StateCache(ttlSeconds: 30)
        await cache.recordScreenshot(pid: 1, windowId: 2, pixelSize: CGSize(width: 1280, height: 800))
        await cache.recordScreenshot(pid: 1, windowId: 3, pixelSize: CGSize(width: 640, height: 400))

        let a = await cache.screenshotPixelSize(pid: 1, windowId: 2)
        let b = await cache.screenshotPixelSize(pid: 1, windowId: 3)
        let missing = await cache.screenshotPixelSize(pid: 1, windowId: 99)

        #expect(a == CGSize(width: 1280, height: 800))
        #expect(b == CGSize(width: 640, height: 400))
        #expect(missing == nil)
    }

    @Test("recordScreenshot rejects zero/negative dimensions")
    func screenshotRecordRejectsInvalid() async {
        let cache = StateCache(ttlSeconds: 30)
        await cache.recordScreenshot(pid: 1, windowId: 2, pixelSize: CGSize(width: 0, height: 800))
        await cache.recordScreenshot(pid: 1, windowId: 3, pixelSize: CGSize(width: 100, height: -1))
        let a = await cache.screenshotPixelSize(pid: 1, windowId: 2)
        let b = await cache.screenshotPixelSize(pid: 1, windowId: 3)
        #expect(a == nil)
        #expect(b == nil)
    }

    @Test("Screenshot record is dropped after TTL")
    func screenshotRecordExpires() async throws {
        let cache = StateCache(ttlSeconds: 0.1)
        await cache.recordScreenshot(pid: 1, windowId: 2, pixelSize: CGSize(width: 100, height: 80))
        let before = await cache.screenshotPixelSize(pid: 1, windowId: 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        let after = await cache.screenshotPixelSize(pid: 1, windowId: 2)
        #expect(before == CGSize(width: 100, height: 80))
        #expect(after == nil)
    }

    @Test("isElementAlive does not crash on a live AXApplication element")
    func isElementAliveDoesNotCrash() {
        // We can't always assert `true` here — the test process may not
        // have AX permission, in which case `AXUIElementCopyAttributeValue`
        // returns failure and the probe reports "dead." That's the
        // correct behavior in production (no AX = can't trust the
        // element). The stronger assertion that the probe distinguishes
        // live from dead requires a real AX-granted host.
        let element = Self.aliveElement()
        _ = StateCache.isElementAlive(element)
    }
}
