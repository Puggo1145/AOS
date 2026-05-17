import Testing
import Foundation
import CoreGraphics
@testable import OSSenseKit

@Suite("ScreenMirror — pure helpers")
struct ScreenMirrorTests {

    @Test("Source under the cap is returned unchanged")
    func underCapNoop() {
        let source = CGSize(width: 800, height: 600)
        let result = ScreenMirror.downsampledSize(source: source, maxLongEdge: 1280)
        #expect(result == source)
    }

    @Test("Long edge is clamped while aspect ratio is preserved")
    func clampsLongEdge() {
        let source = CGSize(width: 2560, height: 1600)
        let result = ScreenMirror.downsampledSize(source: source, maxLongEdge: 1280)
        #expect(result.width == 1280)
        // 1600 / 2560 == 0.625 → 1280 * 0.625 = 800
        #expect(result.height == 800)
    }

    @Test("Portrait sources clamp on height when height > width")
    func clampsPortrait() {
        let source = CGSize(width: 800, height: 3200)
        let result = ScreenMirror.downsampledSize(source: source, maxLongEdge: 1280)
        #expect(result.height == 1280)
        #expect(result.width == 320)   // 800 * (1280 / 3200)
    }

    @Test("Zero source yields a 1×1 floor (SCStreamConfiguration rejects zero)")
    func zeroSourceFloor() {
        let result = ScreenMirror.downsampledSize(source: .zero, maxLongEdge: 1280)
        #expect(result.width >= 1 && result.height >= 1)
    }
}
