import Foundation

// MARK: - NotchPanelMeasurements
//
// Owns the measured-height bookkeeping for the opened panel's swappable
// content (onboarding cards, Settings, History, the live conversation
// history + composer stacks). Each field is written by the shared
// `onHeightChange` reporter (see HeightReporting.swift) on every layout
// pass; `NotchViewModel` derives `notchOpenedSize` from these so the
// silhouette hugs whichever content is currently mounted instead of using
// a hand-tuned constant.
// Extracted out of NotchViewModel so the measurement/clamping rules can be
// exercised without the full service graph; see NotchMouseActiveRectTests.

@MainActor
@Observable
public final class NotchPanelMeasurements {
    /// Measured natural height of whichever onboarding panel is currently
    /// rendered (PermissionOnboardPanelView or OnboardPanelView). Reported
    /// up via the shared height reporter so the silhouette hugs the panel's intrinsic
    /// size — without this the panel falls back to `compactMin` and the
    /// cards collide with the tray drawer below.
    public var onboardingContentHeight: CGFloat = 0 {
        didSet { onStateChange?() }
    }

    /// Measured natural height of SettingsPanelView. Same content-driven
    /// pattern as onboarding: the shared height reporter reports the intrinsic height,
    /// `notchOpenedSize` clamps it into [compactMin, max]. Adding/removing
    /// rows in Settings no longer needs a hand-tuned constant.
    public var settingsContentHeight: CGFloat = 0 {
        didSet { onStateChange?() }
    }
    public private(set) var settingsMeasurementPending: Bool = false
    private var settingsPendingPanelHeight: CGFloat?

    /// Measured natural height of SessionHistoryPanelView. Same content-driven
    /// pattern as Settings: the shared height reporter reports the intrinsic height,
    /// `notchOpenedSize` clamps it into [compactMin, max]; the inner
    /// ScrollView takes over once the list exceeds the ceiling.
    public var historyPanelContentHeight: CGFloat = 0 {
        didSet { onStateChange?() }
    }
    public private(set) var historyMeasurementPending: Bool = false
    private var historyPendingPanelHeight: CGFloat?

    /// Measured natural heights of the two stacks inside OpenedPanelView.
    /// The view writes these via PreferenceKey on every layout pass; we
    /// derive `notchOpenedSize.height` from them so the silhouette grows
    /// alongside the streamed reply, capped at `notchOpenedMaxHeight`.
    public var historyContentHeight: CGFloat = 0 {
        didSet { onStateChange?() }
    }
    public var composerContentHeight: CGFloat = 0 {
        didSet { onStateChange?() }
    }

    /// Mutation hook so detached-placement window resize still fires when a
    /// measurement changes the panel's natural height. NotchViewModel wires
    /// this to `openedSurfaceStateDidChange()`.
    public var onStateChange: (@MainActor () -> Void)?

    public init() {}

    /// Called from `showSettings`'s didSet when the Settings overlay opens.
    /// Until the first real measurement arrives, `notchOpenedSize` uses
    /// `fallback` (the panel's current height) instead of collapsing to
    /// `compactMin` — otherwise the panel would visibly shrink-then-grow
    /// on the opening frame.
    public func beginSettingsMeasurement(fallback: CGFloat) {
        settingsMeasurementPending = true
        settingsPendingPanelHeight = fallback
    }

    /// Mirror of `beginSettingsMeasurement` for the History overlay.
    public func beginHistoryMeasurement(fallback: CGFloat) {
        historyMeasurementPending = true
        historyPendingPanelHeight = fallback
    }

    public func markSettingsMeasured(height: CGFloat) {
        if height > 0 {
            settingsMeasurementPending = false
            settingsPendingPanelHeight = nil
        }
        settingsContentHeight = height
    }

    public func markHistoryMeasured(height: CGFloat) {
        if height > 0 {
            historyMeasurementPending = false
            historyPendingPanelHeight = nil
        }
        historyPanelContentHeight = height
    }

    /// Settings overlay height clamped into [compactMinHeight, maxHeight].
    /// Before the first measurement lands, falls back to the pending
    /// panel height captured when the overlay opened (see
    /// `beginSettingsMeasurement`) so the silhouette doesn't collapse to
    /// `compactMinHeight` for one frame.
    public func settingsHeight(compactMinHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        measuredOverlayPanelHeight(
            settingsContentHeight,
            measurementPending: settingsMeasurementPending,
            pendingPanelHeight: settingsPendingPanelHeight,
            compactMinHeight: compactMinHeight,
            maxHeight: maxHeight
        )
    }

    /// Mirror of `settingsHeight` for the History overlay.
    public func historyHeight(compactMinHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        measuredOverlayPanelHeight(
            historyPanelContentHeight,
            measurementPending: historyMeasurementPending,
            pendingPanelHeight: historyPendingPanelHeight,
            compactMinHeight: compactMinHeight,
            maxHeight: maxHeight
        )
    }

    private func measuredOverlayPanelHeight(
        _ measuredHeight: CGFloat,
        measurementPending: Bool,
        pendingPanelHeight: CGFloat?,
        compactMinHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        if measuredHeight > 0 {
            return min(max(measuredHeight, compactMinHeight), maxHeight)
        }
        if measurementPending, let pendingPanelHeight {
            return min(max(pendingPanelHeight, compactMinHeight), maxHeight)
        }
        return min(max(measuredHeight, compactMinHeight), maxHeight)
    }
}
