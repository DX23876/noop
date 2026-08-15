import SwiftUI

// MARK: - Telling series apart without colour
//
// Ground rule 3 of the redesign hangs meaning on colour families, and the two charts that draw more
// than one series at once (the Compare overlay, the workout recovery curves) distinguish them by
// colour ALONE. For a red-green colour-blind reader — and for anyone who turned on Settings ▸
// Accessibility ▸ Differentiate Without Color — those charts carry no distinction at all: a legend
// naming four colours the reader cannot separate is not a legend.
//
// The fix is a second, redundant encoding: a distinct dash pattern per series. Only applied when the
// system switch is on, so the default look is untouched.

/// Stroke dash patterns that keep multi-series charts readable with colour removed.
///
/// Pure and deliberately tiny, so the one thing that can go wrong — two series drawing the same
/// pattern — is unit-testable with no view.
public enum ChartDifferentiation {

    /// The dash ladder, in series order. Chosen so neighbours differ in the feature the eye picks up
    /// fastest (dash LENGTH), rather than in subtle gap ratios that blur at chart scale:
    /// solid → long dash → dot → dash-dot.
    ///
    /// Four entries because Compare permits 2–4 metrics; a fifth series wraps, which is still better
    /// than two identical solid lines, and the `cycle` is what the test pins.
    public static let dashPatterns: [[CGFloat]] = [
        [],             // solid
        [7, 4],         // long dash
        [2, 3],         // dot
        [10, 3, 2, 3],  // dash-dot
    ]

    /// The pattern for a series at `index`, wrapping past the end of the ladder. An empty array means
    /// a solid line, which is exactly what `StrokeStyle(dash:)` expects.
    public static func dashPattern(seriesIndex index: Int) -> [CGFloat] {
        guard !dashPatterns.isEmpty else { return [] }
        // Modulo on a negative index would be negative; series indices are never negative, but
        // clamping is cheaper than trusting every future caller.
        let wrapped = abs(index) % dashPatterns.count
        return dashPatterns[wrapped]
    }
}

/// A legend swatch drawn as a short stroke in a series' dash pattern, for legends that must explain a
/// dashed chart. Sized to sit on a footnote line beside its label, where a filled dot would otherwise
/// go — and deliberately the same 8pt visual weight, so swapping one for the other does not reflow the
/// row.
public struct DashSwatch: View {
    public let color: Color
    public let dash: [CGFloat]

    public init(color: Color, dash: [CGFloat]) {
        self.color = color
        self.dash = dash
    }

    public var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 4))
            p.addLine(to: CGPoint(x: 18, y: 4))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: dash))
        .frame(width: 18, height: 8)
        .accessibilityHidden(true)
    }
}

public extension EnvironmentValues {
    /// Whether the reader has asked for meaning to be carried by something other than colour.
    ///
    /// A thin alias for `accessibilityDifferentiateWithoutColor`, so a chart reads as
    /// `if differentiateWithoutColor` at the point of use and every chart spells the check the same
    /// way. The setting was not read anywhere in the app before this.
    var noopDifferentiateWithoutColor: Bool { accessibilityDifferentiateWithoutColor }
}
