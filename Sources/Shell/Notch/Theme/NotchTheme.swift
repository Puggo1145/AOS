import SwiftUI

// MARK: - NotchTheme
//
// Small, environment-driven helpers shared across the notch UI. Two concerns
// live here:
//   1. Contrast-aware white foregrounds. Notch chrome runs almost entirely
//      on `Color.white.opacity(...)` against the black silhouette. When the
//      user has "Increase Contrast" enabled (System Settings → Accessibility
//      → Display), low-opacity values (<0.65) collapse below WCAG-readable
//      thresholds. `whiteForeground(_:)` floors them.
//   2. Dynamic Type-friendly fixed font sizes. Most chrome uses a fixed
//      pixel size to keep the closed bar geometry stable, but readers with
//      enlarged text settings need *some* growth. `scaledFixedSize(_:)`
//      pairs `@ScaledMetric`-style scaling with a chrome-safe ceiling so the
//      glyph still fits in the notch silhouette.

/// Foreground emphasis level used by the notch chrome. Maps to a baseline
/// white-opacity in normal contrast and floors to a higher value when
/// `\.colorSchemeContrast == .increased`.
enum NotchTextEmphasis {
    /// Body / primary text (~0.9 normal, 0.95 increased).
    case primary
    /// Secondary captions / inline labels (~0.65 normal, 0.85 increased).
    case secondary
    /// Tertiary "muted" text — placeholders, disabled hints (~0.5 normal,
    /// 0.75 increased).
    case tertiary
    /// Quaternary — dot indicators, decorative ticks (~0.4 normal, 0.65
    /// increased).
    case quaternary
}

extension NotchTextEmphasis {
    func opacity(forContrast contrast: ColorSchemeContrast) -> CGFloat {
        switch (self, contrast) {
        case (.primary, .increased): return 0.95
        case (.primary, _): return 0.9
        case (.secondary, .increased): return 0.85
        case (.secondary, _): return 0.65
        case (.tertiary, .increased): return 0.75
        case (.tertiary, _): return 0.5
        case (.quaternary, .increased): return 0.65
        case (.quaternary, _): return 0.4
        }
    }
}

extension View {
    /// Apply a contrast-aware white foreground. Use on chrome text against
    /// the black notch silhouette.
    func notchForeground(_ emphasis: NotchTextEmphasis) -> some View {
        modifier(NotchForegroundModifier(emphasis: emphasis))
    }

    /// Scaled font for notch chrome. The base size follows Dynamic Type, then
    /// clamps to a chrome-safe ceiling so compact controls still fit inside the
    /// notch silhouette. This is intentionally local to notch UI; app-wide
    /// content should prefer semantic `.body` / `.caption` styles directly.
    func notchFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body,
        maxScale: CGFloat = 1.35
    ) -> some View {
        modifier(NotchFontModifier(
            size: size,
            weight: weight,
            design: design,
            textStyle: textStyle,
            maxScale: maxScale
        ))
    }
}

private struct NotchForegroundModifier: ViewModifier {
    let emphasis: NotchTextEmphasis
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(.white.opacity(emphasis.opacity(forContrast: contrast)))
    }
}

private struct NotchFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let maxScale: CGFloat
    @ScaledMetric private var scaledSize: CGFloat

    init(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design,
        textStyle: Font.TextStyle,
        maxScale: CGFloat
    ) {
        self.size = size
        self.weight = weight
        self.design = design
        self.maxScale = maxScale
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: min(scaledSize, size * maxScale), weight: weight, design: design))
    }
}

struct NotchScaledMetric {
    let value: CGFloat
    let base: CGFloat
    let maxScale: CGFloat

    var clamped: CGFloat {
        min(value, base * maxScale)
    }
}

/// Returns the requested baseline opacity in normal contrast, floored to
/// `floorWhenIncreased` (default 0.85) when the user has enabled "Increase
/// Contrast" in System Settings. Use sparingly inside view bodies that
/// already pass through a literal opacity value and would otherwise need a
/// full migration to `notchForeground(_:)`.
struct ContrastAwareOpacity: View {
    let baseline: CGFloat
    let floorWhenIncreased: CGFloat
    let render: (CGFloat) -> AnyView

    @Environment(\.colorSchemeContrast) private var contrast

    init(
        baseline: CGFloat,
        floorWhenIncreased: CGFloat = 0.85,
        @ViewBuilder render: @escaping (CGFloat) -> some View
    ) {
        self.baseline = baseline
        self.floorWhenIncreased = floorWhenIncreased
        self.render = { AnyView(render($0)) }
    }

    var body: some View {
        let resolved = (contrast == .increased && baseline < floorWhenIncreased)
            ? floorWhenIncreased
            : baseline
        render(resolved)
    }
}

/// Free-function counterpart of `ContrastAwareOpacity` for use in property
/// reads. SwiftUI views can read `\.colorSchemeContrast` via @Environment;
/// this is the pre-environment fallback for static helpers.
func resolvedNotchOpacity(
    baseline: CGFloat,
    contrast: ColorSchemeContrast,
    floorWhenIncreased: CGFloat = 0.85
) -> CGFloat {
    (contrast == .increased && baseline < floorWhenIncreased) ? floorWhenIncreased : baseline
}

// MARK: - NotchPressableStyle
//
// Shared button style for chrome buttons (header gear / plus / history /
// settings rows / etc.) so press feedback is consistent. Honours Reduce
// Motion: when the user has opted out of decorative motion, the scale +
// opacity transitions snap rather than animate.
//
// Usage: `.buttonStyle(.notchPressable())` or `.buttonStyle(NotchPressableStyle())`.
struct NotchPressableStyle: ButtonStyle {
    /// Optional press scale floor. Defaults to 0.94 — slight enough not to
    /// feel jumpy on small targets but visible on the closed bar's icons.
    var pressedScale: CGFloat = 0.94
    /// Optional press opacity floor.
    var pressedOpacity: CGFloat = 0.7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let scale: CGFloat = configuration.isPressed ? pressedScale : 1
        let opacity: CGFloat = isEnabled ? (configuration.isPressed ? pressedOpacity : 1) : 0.4
        return configuration.label
            .scaleEffect(scale)
            .opacity(opacity)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.12),
                value: configuration.isPressed
            )
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == NotchPressableStyle {
    /// Convenience accessor mirroring `.plain` / `.bordered` so callsites
    /// read as `.buttonStyle(.notchPressable)`.
    static var notchPressable: NotchPressableStyle { NotchPressableStyle() }
}

// MARK: - Animation tokens
//
// One curve, named once. Previously every notch surface chose its own
// `.smooth(duration: 0.28-0.32)` literal, which made it easy for a new
// modifier to drift out of step with the silhouette. Centralising the two
// surfaces (height vs chrome) makes "tweak the entire notch's feel"
// a one-line change.
extension Animation {
    /// Outer silhouette / height transitions (closed→popping→opened, tray
    /// drawer height, segmented status changes). 0.32s smooth.
    static let notchHeight: Animation = .smooth(duration: 0.32, extraBounce: 0)
    /// Inner chrome transitions (panel swaps, settings/history overlay,
    /// onboarding gates). 0.28s smooth.
    static let notchChrome: Animation = .smooth(duration: 0.28)
}
