import SwiftUI

// MARK: - FlatScoreRing — the coloured score ring
//
// What the "Colored" ring style draws in place of the organic rings: a neutral full-circle track and one
// flat arc in a single clear colour from 12 o'clock, with rounded ends. No gradient, no glow, no shadow
// under the tip, so the colour alone carries the ring. The score sits in the middle, a percent sign after
// it when the score is a percentage. The arc fills once when it appears and again when the value changes;
// Reduce Motion draws it at once. No frame clock. Theme-aware; macOS-13 / iOS-17 safe.

public struct FlatScoreRing: View {

    /// Target fill, 0...1.
    public var fraction: Double
    /// The number shown in the centre.
    public var value: Double
    /// Formats the value into the centre string.
    public var format: (Double) -> String
    /// The arc colour.
    public var color: Color
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    /// A short unit after the number ("%"), nil for a score that is not a percentage.
    public var unit: String?

    public init(fraction: Double, value: Double, format: @escaping (Double) -> String, color: Color,
                diameter: CGFloat, lineWidth: CGFloat, unit: String? = nil) {
        self.fraction = fraction
        self.value = value
        self.format = format
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.unit = unit
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var filled: CGFloat { appeared ? CGFloat(min(max(fraction, 0), 1)) : 0 }

    public var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.coloredRingTrack, lineWidth: lineWidth)
            if fraction > 0 {
                Circle().trim(from: 0, to: max(0.0001, filled)).rotation(.degrees(-90))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(format(value))
                    .font(GlowRing.centerFont(diameter: diameter))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(unit)
                        .font(StrandFont.rounded(diameter * 0.16, weight: .bold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, lineWidth + 4)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.86), value: filled)
        .onAppear { appeared = true }
    }
}
