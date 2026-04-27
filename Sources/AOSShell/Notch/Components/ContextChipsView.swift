import SwiftUI
import AppKit
import AOSOSSenseKit

// MARK: - ContextChipsView
//
// Live chip row for the composer. Per the post-redesign contract:
//
//   chips = [appChip + viewfinderToggle] ++ behaviors
//
// The app chip is the basic identity and is always projected. Immediately
// to its right sits the **per-app screenshot toggle** — a viewfinder
// button that flips a `VisualCapturePolicyStore` entry for the current
// bundleId. While that toggle is on, every submit while the app is
// frontmost attaches a fresh window snapshot at submit time. State is
// process-only memory (per product decision).
//
// The clipboard chip does NOT live here. Pasted content is rendered
// inline inside the composer's input row (see `ComposerCard.inputRow`)
// because (a) the paste is a per-turn input, not ambient context, and
// (b) co-locating chip + delete affordance with the input avoids the
// dual-state confusion of "remove the chip from the top row, but the
// pasted text remains in the field below".
//
// Behavior chips remain individually selectable; deselected keys flow up
// to `ComposerCard` and are filtered out at projection time.

/// Per-bundle "attach screenshot" affordance state. Encodes the three
/// gates (model vision capability, OS screen-recording permission, and
/// the user's per-app pick) as a closed set so the view body renders one
/// state instead of composing three booleans inline. Callers derive this
/// at the parent boundary; ContextChipsView itself does not see the LLM
/// model — it only sees "is the toggle usable, and if not, why not".
enum ScreenshotToggleState: Equatable {
    /// The active model has no vision input — capture is pointless. Chip
    /// renders `eye.slash` and refuses taps. This is the user-facing
    /// signal mirroring the catalog projection; the actual downgrade is
    /// the sidecar's authority.
    case unsupportedByModel
    /// Vision-capable model, but ScreenCaptureKit is unauthorized — chip
    /// stays visible but dim, taps are no-ops until permission lands.
    case needsScreenRecordingPermission
    /// Toggle is operable; `on` is the per-bundle "always capture" pick.
    case operable(on: Bool)
}

struct ContextChipsView: View {
    let senseStore: SenseStore
    let policyStore: VisualCapturePolicyStore
    /// Derived screenshot-toggle state for the current (model, permission,
    /// per-app pick) tuple. Computed at the parent (`ComposerCard`) so
    /// this view stays free of LLM concepts.
    let screenshotToggle: ScreenshotToggleState
    @Binding var deselectedBehaviorKeys: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let app = senseStore.context.app {
                    appChipWithToggle(app: app)
                }
                ForEach(senseStore.context.behaviors, id: \.id) { envelope in
                    behaviorChip(envelope: envelope)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 32)
        .onChange(of: senseStore.context.app?.bundleId) { _, _ in
            // App switch invalidates per-app behavior chip identities;
            // reset behavior selections so the user starts each app fresh.
            // The capture-toggle state is keyed by bundleId in the policy
            // store, so it naturally reflects the new app on its own.
            deselectedBehaviorKeys.removeAll()
        }
    }

    // MARK: - App chip + capture toggle

    /// App identity chip with the per-app screenshot toggle attached as
    /// one visual unit on its trailing edge. Replaces the old standalone
    /// "Window snapshot" chip.
    @ViewBuilder
    private func appChipWithToggle(app: AppIdentity) -> some View {
        HStack(spacing: 6) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            captureToggleButton(bundleId: app.bundleId)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    @ViewBuilder
    private func captureToggleButton(bundleId: String) -> some View {
        Button {
            // Only the operable state mutates store; other states are
            // visible but inert so the user can discover the affordance
            // and the tooltip explains why it's currently disabled.
            if case .operable = screenshotToggle {
                _ = policyStore.toggle(bundleId: bundleId)
            }
        } label: {
            Image(systemName: screenshotToggleIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(screenshotToggleOpacity))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(screenshotToggleHelp(bundleId: bundleId))
        .accessibilityLabel(Text("Always capture screenshot for this app"))
        .accessibilityValue(Text(screenshotToggleAccessibilityValue))
    }

    private var screenshotToggleIcon: String {
        switch screenshotToggle {
        case .unsupportedByModel: return "eye.slash"
        case .needsScreenRecordingPermission: return "eye"
        case .operable(let on): return on ? "eye.fill" : "eye"
        }
    }

    private var screenshotToggleOpacity: Double {
        switch screenshotToggle {
        case .unsupportedByModel: return 0.35
        case .needsScreenRecordingPermission: return 0.25
        case .operable(let on): return on ? 0.95 : 0.55
        }
    }

    private func screenshotToggleHelp(bundleId: String) -> String {
        switch screenshotToggle {
        case .unsupportedByModel:
            return "The selected model can't read images — switch to a vision-capable model to attach screenshots"
        case .needsScreenRecordingPermission:
            return "Screen recording permission required"
        case .operable(let on):
            return on
                ? "Always attach a window snapshot when sending from \(bundleId)"
                : "Attach a window snapshot to every send from this app"
        }
    }

    private var screenshotToggleAccessibilityValue: String {
        switch screenshotToggle {
        case .unsupportedByModel: return "unavailable for current model"
        case .needsScreenRecordingPermission: return "screen recording permission required"
        case .operable(let on): return on ? "on" : "off"
        }
    }

    // MARK: - Behavior chip

    @ViewBuilder
    private func behaviorChip(envelope: BehaviorEnvelope) -> some View {
        let key = envelope.citationKey
        let selected = !deselectedBehaviorKeys.contains(key)
        Button {
            if selected {
                deselectedBehaviorKeys.insert(key)
            } else {
                deselectedBehaviorKeys.remove(key)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: behaviorIcon(for: envelope.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(selected ? 0.9 : 0.45))
                Text(envelope.displaySummary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 0.9 : 0.45))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.12 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(selected ? 0 : 0.18),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(envelope.displaySummary))
        .accessibilityValue(Text(selected ? "selected" : "deselected"))
    }

    /// Pick an SF Symbol per behavior kind. The chip surfaces the *kind* of
    /// signal (selection, input field, list selection, …); the actual content
    /// rides in the envelope payload and is the LLM's to read.
    private func behaviorIcon(for kind: String) -> String {
        switch kind {
        case "general.selectedText": return "text.quote"
        case "general.currentInput": return "keyboard"
        case "general.selectedItems": return "checklist"
        default: return "sparkles"
        }
    }

}
