import AppKit
import CoreGraphics
import Foundation

public struct FrontmostApplicationSnapshot: Sendable, Hashable, Codable {
    public let pid: pid_t
    public let bundleIdentifier: String?

    public init(pid: pid_t, bundleIdentifier: String?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct WindowOrderObservationSample: Sendable, Hashable, Codable {
    public let elapsedNanoseconds: UInt64
    public let frontmostPID: pid_t?
    public let frontmostBundleIdentifier: String?
    public let frontmostWindowId: CGWindowID?
    public let targetIsActive: Bool
    public let targetRank: Int?
    public let protectedCoveredCount: Int?
    public let originalFrontmostIsActive: Bool?

    public init(
        elapsedNanoseconds: UInt64,
        frontmostPID: pid_t?,
        frontmostBundleIdentifier: String?,
        frontmostWindowId: CGWindowID?,
        targetIsActive: Bool,
        targetRank: Int?,
        protectedCoveredCount: Int?,
        originalFrontmostIsActive: Bool? = nil
    ) {
        self.elapsedNanoseconds = elapsedNanoseconds
        self.frontmostPID = frontmostPID
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.frontmostWindowId = frontmostWindowId
        self.targetIsActive = targetIsActive
        self.targetRank = targetRank
        self.protectedCoveredCount = protectedCoveredCount
        self.originalFrontmostIsActive = originalFrontmostIsActive
    }
}

/// Passive WindowServer order probe used to compare AOS and Codex behavior.
///
/// This probe intentionally does not post input, raise windows, or repair
/// anything. It captures the same visual-order invariant as
/// ``WindowOrderGuardian`` so diagnostics can distinguish "no order change"
/// from "order changed and was repaired fast enough to hide".
public struct WindowOrderProbe: Sendable {
    private let targetPID: pid_t
    private let targetWindowId: CGWindowID
    private let orderGuardian: WindowOrderGuardian
    private let originalFrontmostPID: pid_t?
    private let visibleWindowsLookup: @Sendable () -> [WindowInfo]
    private let frontmostApplicationLookup: @Sendable () -> FrontmostApplicationSnapshot?
    private let targetActiveLookup: @Sendable () -> Bool
    private let applicationActiveLookup: @Sendable (pid_t) -> Bool

    public init(
        targetPID: pid_t,
        targetWindowId: CGWindowID,
        beforeWindows: [WindowInfo],
        visibleWindowsLookup: @escaping @Sendable () -> [WindowInfo],
        frontmostApplicationLookup: @escaping @Sendable () -> FrontmostApplicationSnapshot?,
        targetActiveLookup: @escaping @Sendable () -> Bool,
        applicationActiveLookup: @escaping @Sendable (pid_t) -> Bool = { _ in false }
    ) throws {
        guard let targetWindow = beforeWindows.first(where: { $0.id == targetWindowId }) else {
            throw ComputerUseError.windowNotFound(windowId: targetWindowId)
        }
        guard targetWindow.pid == targetPID else {
            throw ComputerUseError.windowMismatch(
                pid: targetPID,
                windowId: targetWindowId,
                ownerPid: targetWindow.pid
            )
        }

        self.targetPID = targetPID
        self.targetWindowId = targetWindowId
        self.orderGuardian = try WindowOrderGuardian(
            targetWindowId: targetWindowId,
            beforeWindows: beforeWindows
        )
        self.originalFrontmostPID = frontmostApplicationLookup()?.pid
        self.visibleWindowsLookup = visibleWindowsLookup
        self.frontmostApplicationLookup = frontmostApplicationLookup
        self.targetActiveLookup = targetActiveLookup
        self.applicationActiveLookup = applicationActiveLookup
    }

    public static func live(targetPID: pid_t, targetWindowId: CGWindowID) throws -> WindowOrderProbe {
        try WindowOrderProbe(
            targetPID: targetPID,
            targetWindowId: targetWindowId,
            beforeWindows: WindowEnumerator.visibleWindows(),
            visibleWindowsLookup: {
                WindowEnumerator.visibleWindows()
            },
            frontmostApplicationLookup: {
                guard let app = NSWorkspace.shared.frontmostApplication else {
                    return nil
                }
                return FrontmostApplicationSnapshot(
                    pid: app.processIdentifier,
                    bundleIdentifier: app.bundleIdentifier
                )
            },
            targetActiveLookup: {
                NSRunningApplication(processIdentifier: targetPID)?.isActive ?? false
            },
            applicationActiveLookup: { pid in
                NSRunningApplication(processIdentifier: pid)?.isActive ?? false
            }
        )
    }

    public func sample(elapsedNanoseconds: UInt64) -> WindowOrderObservationSample {
        let currentWindows = visibleWindowsLookup()
        let frontmostApplication = frontmostApplicationLookup()
        let frontmostWindowId = frontmostApplication.flatMap { app in
            Self.frontmostLayerZeroWindowId(pid: app.pid, currentWindows: currentWindows)
        }
        let targetRank = Self.targetRank(targetWindowId: targetWindowId, currentWindows: currentWindows)

        return WindowOrderObservationSample(
            elapsedNanoseconds: elapsedNanoseconds,
            frontmostPID: frontmostApplication?.pid,
            frontmostBundleIdentifier: frontmostApplication?.bundleIdentifier,
            frontmostWindowId: frontmostWindowId,
            targetIsActive: targetActiveLookup(),
            targetRank: targetRank,
            protectedCoveredCount: orderGuardian.protectedCoveredCount(currentWindows: currentWindows),
            originalFrontmostIsActive: originalFrontmostPID.map(applicationActiveLookup)
        )
    }

    private static func targetRank(
        targetWindowId: CGWindowID,
        currentWindows: [WindowInfo]
    ) -> Int? {
        WindowOrderGuardian
            .guardableWindows(currentWindows)
            .firstIndex { $0.id == targetWindowId }
            .map { $0 + 1 }
    }

    private static func frontmostLayerZeroWindowId(
        pid: pid_t,
        currentWindows: [WindowInfo]
    ) -> CGWindowID? {
        WindowOrderGuardian
            .guardableWindows(currentWindows)
            .filter { $0.pid == pid }
            .max(by: { $0.zIndex < $1.zIndex })?
            .id
    }
}
