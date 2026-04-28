import Testing
@testable import AOSComputerUseKit

// MARK: - ScreenshotPayloadPolicy
//
// Pure-function tests for the screenshot retry policy used by
// `ComputerUseService.getAppState`. The policy decides the next
// `maxImageDimension` to retry capture at when the previous encode
// blew past the wire payload budget. Regression context: shipping
// without a cap let 4K-window PNGs (>1MB base64) silently stall
// codex `/responses` and overflow the sidecar 2MB NDJSON line cap.

@Suite("ScreenshotPayloadPolicy.nextMaxDim")
struct ScreenshotPayloadPolicyTests {

    @Test("Within budget returns nil — caller stops")
    func underBudgetReturnsNil() {
        let next = ScreenshotPayloadPolicy.nextMaxDim(
            currentBytes: 500_000,
            currentMaxDim: 2048,
            rawByteBudget: 700_000
        )
        #expect(next == nil)
    }

    @Test("Over budget returns a smaller dim sized for the overshoot")
    func overBudgetShrinks() {
        // currentBytes 4× budget → ratio = sqrt(0.25) = 0.5 → fudge ×0.85
        // expected ≈ 2048 × 0.5 × 0.85 ≈ 870
        let next = ScreenshotPayloadPolicy.nextMaxDim(
            currentBytes: 2_800_000,
            currentMaxDim: 2048,
            rawByteBudget: 700_000
        )
        #expect(next != nil)
        #expect(next! < 2048)
        #expect(next! >= 256)
        // Sanity-check the math is in the right neighborhood.
        #expect(next! > 500 && next! < 1100)
    }

    @Test("Computed next under floor still returns minDim — prove a floor-size capture doesn't fit before giving up")
    func underFloorReturnsMinDim() {
        // Heavy shrink would compute next < 256: ratio = sqrt(700k/50M)
        // ≈ 0.118, next = 400 × 0.118 × 0.85 ≈ 40 → below floor. Policy
        // must return minDim instead of giving up — a 256×256 PNG is
        // typically tens of KB and almost always fits the budget, so we
        // prove it before throwing payloadTooLarge.
        let next = ScreenshotPayloadPolicy.nextMaxDim(
            currentBytes: 50_000_000,
            currentMaxDim: 400,
            rawByteBudget: 700_000,
            minDim: 256
        )
        #expect(next == 256)
    }

    @Test("Already at minDim and still over budget returns 0 — caller throws payloadTooLarge")
    func atFloorAndOverGivesUp() {
        // Caller already captured at minDim and the bytes still don't
        // fit. Nowhere left to shrink to.
        let next = ScreenshotPayloadPolicy.nextMaxDim(
            currentBytes: 5_000_000,
            currentMaxDim: 256,
            rawByteBudget: 700_000,
            minDim: 256
        )
        #expect(next == 0)
    }

    @Test("currentMaxDim of 0 (no prior cap) still triggers a retry hint when oversize")
    func zeroCurrentDimMeansGiveUp() {
        // Defensive: when the first capture used maxDim=0 (no cap) and
        // came back over budget, the policy can't compute a ratio off
        // "0", so it returns 0 and makes the caller throw. The service
        // is expected to pass max(width,height) instead of 0 — this
        // test locks the defensive branch in case that contract drifts.
        let next = ScreenshotPayloadPolicy.nextMaxDim(
            currentBytes: 2_000_000,
            currentMaxDim: 0,
            rawByteBudget: 700_000
        )
        #expect(next == 0)
    }

    @Test("Pathological case where ratio rounds back to currentMaxDim still shrinks by 1")
    func neverNoOpRetry() {
        // Budget barely under currentBytes → ratio ≈ 1 → could round
        // back to currentMaxDim and loop forever. Policy must force
        // strict shrinkage.
        let next = ScreenshotPayloadPolicy.nextMaxDim(
            currentBytes: 700_001,
            currentMaxDim: 1024,
            rawByteBudget: 700_000
        )
        #expect(next != nil)
        #expect(next! < 1024)
    }
}
