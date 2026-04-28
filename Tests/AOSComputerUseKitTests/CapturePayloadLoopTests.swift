import Testing
import CoreGraphics
import Foundation
@testable import AOSComputerUseKit

// MARK: - ComputerUseService.capturePayloadLoop
//
// End-to-end coverage for the capture-retry orchestration the service
// uses inside `getAppState`. The closure-based `capturePayloadLoop`
// lets us inject a fake capture (no SCStream / no Screen Recording
// permission) and assert the policy → retry → throw chain.

@Suite("ComputerUseService.capturePayloadLoop")
struct CapturePayloadLoopTests {

    private static func screenshot(width: Int, bytes: Int) -> Screenshot {
        // Square fake; only `imageData.count` and `width` matter to the
        // policy (it derives currentDim from max(width, height)).
        Screenshot(
            imageData: Data(count: bytes),
            format: .png,
            width: width,
            height: width,
            scaleFactor: 2.0,
            originalWidth: nil,
            originalHeight: nil
        )
    }

    @Test("Single attempt returns immediately when bytes already fit budget")
    func singleAttemptHappyPath() async throws {
        var calls: [Int] = []
        let shot = try await ComputerUseService.capturePayloadLoop(
            initialMaxImageDimension: 0
        ) { dim in
            calls.append(dim)
            return Self.screenshot(width: 1280, bytes: 200_000)
        }
        #expect(calls == [0])
        #expect(shot.imageData.count == 200_000)
    }

    @Test("Oversize on first attempt triggers a single shrink retry that fits")
    func oneShrinkRetry() async throws {
        var calls: [Int] = []
        let shot = try await ComputerUseService.capturePayloadLoop(
            initialMaxImageDimension: 0
        ) { dim in
            calls.append(dim)
            // First call: huge. Subsequent calls: well under budget.
            if calls.count == 1 {
                return Self.screenshot(width: 2880, bytes: 2_500_000)
            }
            return Self.screenshot(width: dim, bytes: 100_000)
        }
        #expect(calls.count == 2)
        #expect(calls[0] == 0)
        // Second call must request a smaller dim than the first capture
        // came back at (currentDim was 2880).
        #expect(calls[1] > 0 && calls[1] < 2880)
        #expect(shot.imageData.count == 100_000)
    }

    @Test("After exhausting retries throws payloadTooLarge with the final byte count")
    func exhaustsAndThrows() async {
        var calls: [Int] = []
        do {
            _ = try await ComputerUseService.capturePayloadLoop(
                initialMaxImageDimension: 0
            ) { dim in
                calls.append(dim)
                // Always return giant — no shrink ever fits. Use a
                // shrinking width that follows the requested dim so
                // `currentDim` walks down toward minDim across attempts.
                let w = dim > 0 ? dim : 4096
                return Self.screenshot(width: w, bytes: 2_500_000)
            }
            Issue.record("expected payloadTooLarge throw")
        } catch let err as ComputerUseError {
            switch err {
            case .payloadTooLarge(let bytes, _):
                #expect(bytes == 2_500_000)
            default:
                Issue.record("expected .payloadTooLarge, got \(err)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Must end with a capture at the floor (minDim = 256) before
        // giving up — proves the floor is exercised, not skipped.
        #expect(calls.last == ScreenshotPayloadPolicy.minDimension)
        #expect(calls.count >= 2)
    }

    @Test("Loop respects an honored initial maxImageDimension")
    func honorsInitialDim() async throws {
        var calls: [Int] = []
        _ = try await ComputerUseService.capturePayloadLoop(
            initialMaxImageDimension: 1024
        ) { dim in
            calls.append(dim)
            return Self.screenshot(width: dim, bytes: 100_000)
        }
        #expect(calls == [1024])
    }

    @Test("Capture closure errors propagate without being swallowed by the retry loop")
    func captureErrorPropagates() async {
        struct Boom: Error {}
        do {
            _ = try await ComputerUseService.capturePayloadLoop(
                initialMaxImageDimension: 0
            ) { _ in
                throw Boom()
            }
            Issue.record("expected throw")
        } catch is Boom {
            // expected — retry loop must not eat closure errors.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
