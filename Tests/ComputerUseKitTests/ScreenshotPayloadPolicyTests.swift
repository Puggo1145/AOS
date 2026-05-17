import Testing
@testable import ComputerUseKit

@Suite("ScreenshotPayloadPolicy")
struct ScreenshotPayloadPolicyTests {
    @Test("Screenshots up to 1MB are considered uncompressed")
    func maxUncompressedBytes() {
        #expect(ScreenshotPayloadPolicy.maxUncompressedBytes == 1 * 1024 * 1024)
    }

    @Test("Resize target shrinks proportionally from the current encoded overshoot")
    func resizeTargetShrinksFromOvershoot() {
        let next = ScreenshotPayloadPolicy.nextResizeMaxDimension(
            currentMaxDimension: 2000,
            currentBytes: 8 * 1024 * 1024
        )

        #expect(next < 2000)
        #expect(next > ScreenshotPayloadPolicy.minDimension)
    }

    @Test("Resize target never drops below the minimum usable dimension")
    func resizeTargetHasFloor() {
        let next = ScreenshotPayloadPolicy.nextResizeMaxDimension(
            currentMaxDimension: 300,
            currentBytes: 80 * 1024 * 1024
        )

        #expect(next == ScreenshotPayloadPolicy.minDimension)
    }
}
