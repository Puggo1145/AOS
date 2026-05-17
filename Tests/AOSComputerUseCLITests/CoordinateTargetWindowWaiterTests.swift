import AOSComputerUseKit
@testable import AOSComputerUseCLI
import CoreGraphics
import Darwin
import Foundation
import Testing

@Suite("Coordinate target window waiter")
struct CoordinateTargetWindowWaiterTests {
    @Test("waits through empty raw window enumerations until the target publishes an on-screen window")
    func waitsThroughEmptyRawWindowEnumerationsUntilTargetPublishesOnScreenWindow() async throws {
        let targetPID = pid_t.random(in: 1_000..<50_000)
        let targetWindow = WindowInfo(
            id: CGWindowID.random(in: 1..<UInt32.max),
            pid: targetPID,
            owner: "AOSCoordinateTarget",
            title: "Target",
            bounds: WindowBounds(x: 10, y: 20, width: 640, height: 480),
            zIndex: 4,
            isOnScreen: true,
            layer: 0
        )
        let recorder = CoordinateWindowLookupRecorder(
            windowsByAttempt: [
                [],
                [],
                [targetWindow],
            ]
        )

        let window = try await CoordinateTargetWindowWaiter.waitForWindow(
            pid: targetPID,
            attempts: 80,
            pollDelayNanoseconds: 0,
            windowsForPIDLookup: { pid in
                #expect(pid == targetPID)
                return recorder.nextWindows()
            },
            sleep: { _ in }
        )

        #expect(window == targetWindow)
        #expect(recorder.lookupCount == 3)
    }
}

private final class CoordinateWindowLookupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var windowsByAttempt: [[WindowInfo]]
    private var count = 0

    init(windowsByAttempt: [[WindowInfo]]) {
        self.windowsByAttempt = windowsByAttempt
    }

    var lookupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func nextWindows() -> [WindowInfo] {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        guard !windowsByAttempt.isEmpty else {
            return []
        }
        return windowsByAttempt.removeFirst()
    }
}
