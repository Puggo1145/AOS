@testable import ComputerUseKit
import CoreGraphics
import Testing

@Suite("Virtual mouse motion")
struct VirtualMouseMotionTests {
    @Test("motion path starts and ends at the requested points")
    func motionPathStartsAndEndsAtRequestedPoints() {
        let start = CGPoint(x: 20, y: 40)
        let end = CGPoint(x: 420, y: 180)
        let path = CursorMotionPath(start: start, end: end)

        #expect(path.point(at: 0) == start)
        #expect(path.point(at: 1) == end)
        #expect(path.point(at: 0.5) != CGPoint(x: 220, y: 110))
    }

    @Test("heading-driven model exposes codex cursor path families")
    func headingDrivenModelExposesCodexCursorPathFamilies() {
        let candidates = HeadingDrivenCursorMotionModel.makeCandidates(
            start: CGPoint(x: 100, y: 120),
            end: CGPoint(x: 720, y: 380),
            bounds: CGRect(x: 0, y: 0, width: 1_280, height: 800),
            startForward: CGVector(dx: -0.7, dy: 0.7),
            endForward: CGVector(dx: -0.7, dy: 0.7)
        )

        #expect(candidates.count == 10)
        #expect(candidates.contains { $0.identifier == "direct-tight" })
        #expect(candidates.contains { $0.identifier == "turn-primary-tight" })
        #expect(HeadingDrivenCursorMotionModel.chooseBestCandidate(from: candidates) != nil)
    }

    @Test("motion path exposes normalized tangents for visual dynamics")
    func motionPathExposesNormalizedTangents() {
        let path = CursorMotionPath(
            start: CGPoint(x: 20, y: 40),
            end: CGPoint(x: 420, y: 180)
        )

        let tangent = path.tangent(at: 0.5)
        let length = hypot(tangent.dx, tangent.dy)

        #expect(abs(length - 1) < 0.0001)
        #expect(tangent.dx > 0)
    }

    @Test("official spring timing matches recovered cursor timing")
    func officialSpringTimingMatchesRecoveredCursorTiming() {
        let closeEnoughTime = CursorMotionProgressAnimator.closeEnoughTime()

        #expect(abs(closeEnoughTime - 1.429166666666663) < 0.000001)
        #expect(OfficialCursorMotionModel.closeEnoughTime == closeEnoughTime)
    }

    @Test("Notch Agent virtual mouse compresses codex transition timing")
    func notchVirtualMouseCompressesCodexTransitionTiming() {
        let path = CursorMotionPath(
            start: CGPoint(x: 100, y: 120),
            end: CGPoint(x: 720, y: 380)
        )
        let measurement = path.measure(bounds: CGRect(x: 0, y: 0, width: 1_280, height: 800))
        let duration = VirtualMouseAnimationTiming.travelDuration(distance: 672.6, measurement: measurement)

        #expect(duration < OfficialCursorMotionModel.closeEnoughTime)
        #expect(abs(duration - (OfficialCursorMotionModel.closeEnoughTime * 0.45)) < 0.000001)
    }

    @Test("visual dynamics rotates cursor toward movement then settles")
    func visualDynamicsRotatesCursorTowardMovementThenSettles() {
        let baseHeading = VirtualMouseGlyphMetrics.targetNeutralHeading
        let start = CGPoint(x: 100, y: 120)
        let target = CGPoint(x: 240, y: 220)
        let state = CursorVisualDynamicsAnimator.state(at: start, time: 0)

        let moving = CursorVisualDynamicsAnimator.advance(
            state: state,
            targetTipPosition: target,
            targetTime: 0.12,
            baseHeading: baseHeading,
            renderYAxisMultiplier: -1
        )
        var settled = moving
        for step in 8...240 {
            settled = CursorVisualDynamicsAnimator.advance(
                state: settled.state,
                targetTipPosition: target,
                targetTime: CGFloat(step) / 60,
                baseHeading: baseHeading,
                renderYAxisMultiplier: -1
            )
        }

        #expect(abs(moving.renderState.rotation) > 0.01)
        #expect(abs(settled.renderState.rotation) < abs(moving.renderState.rotation))
    }
}
