import SwiftUI

// MARK: - GlowRing — crisp WHOOP-style score ring
//
// Quality here is CRISPNESS, not blur. A clean solid arc with rounded caps over a clearly-visible
// full-circle track (so the ring reads as "X% of a circle"), a bold centred number that counts up, and
// only a TIGHT, low-opacity glow hugging the arc (additive on dark, hidden on light) — never a wide
// fuzzy bloom. The arc springs in from 12 o'clock and re-animates when the value changes (day nav).
// Theme-aware (number + track follow light/dark). Motion gated on Reduce Motion; macOS-13 / iOS-17 safe.

public struct GlowRing: View {

    /// Target fill, 0...1.
    public var fraction: Double
    /// The number shown in the centre — rolls up to this.
    public var value: Double
    /// Formats the (animated) value into the centre string.
    public var format: (Double) -> String
    /// The arc colour (solid, saturated — the domain accent).
    public var color: Color
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    /// An optional short word under the number, INSIDE the ring — the score's band read in words
    /// (DEPLETED / LOW / MODERATE / PRIMED / PEAK).
    ///
    /// It exists because the Charge ring is now coloured by its VALUE: colour alone carries no
    /// information for a colour-blind reader, and several of the selectable chart styles compress the
    /// red-to-green distance further. The word is what makes a value-coloured ring readable, so it is a
    /// condition of that change rather than an ornament. nil (the default) renders exactly as before,
    /// which is what the fixed-colour Effort and Rest rings pass.
    public var caption: String? = nil

    public init(fraction: Double, value: Double, format: @escaping (Double) -> String,
                color: Color, diameter: CGFloat, lineWidth: CGFloat, caption: String? = nil) {
        self.fraction = fraction
        self.value = value
        self.format = format
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.caption = caption
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// The centre-number font for a ring of the given diameter — the house numeral at `diameter * 0.36`,
    /// bold. Exposed so an EMPTY / carried / "No data" ring (which doesn't draw a `GlowRing`) can render
    /// its centre text in the EXACT same size + weight as a filled ring, keeping the hero trio's three
    /// centre read-outs visually consistent regardless of state.
    public static func centerFont(diameter: CGFloat) -> Font {
        StrandFont.rounded(diameter * 0.36, weight: .bold)
    }

    /// The band-word font for a ring of the given diameter. Scaled off the diameter exactly as
    /// `centerFont` is, so the number and the word keep their proportion across the hero's now-unequal
    /// centre and flank rings.
    public static func captionFont(diameter: CGFloat) -> Font {
        StrandFont.rounded(max(8, diameter * 0.11), weight: .semibold)
    }

    private var clamped: CGFloat { CGFloat(min(max(fraction, 0), 1)) }
    private var filled: CGFloat { appeared ? clamped : 0 }
    private var shown: Double { appeared ? value : 0 }
    private var drawSpring: Animation { .spring(response: 0.9, dampingFraction: 0.86) }

    public var body: some View {
        ZStack {
            // Clearly-visible full-circle track, so the arc reads as a fraction of a circle (like WHOOP).
            Circle()
                .stroke(StrandPalette.textPrimary.opacity(0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Design Reset: NO glow. A flat, crisp solid arc only — the clean Material-style look.
            arc.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Centred rolling number, with the optional band word tucked under it.
            VStack(spacing: 0) {
                Text(format(shown))
                    .font(Self.centerFont(diameter: diameter))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.85), value: shown)
                if let caption {
                    Text(caption)
                        .font(Self.captionFont(diameter: diameter))
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .padding(.horizontal, lineWidth + 4)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : drawSpring, value: filled)
        .onAppear { appeared = true }
    }

    /// The trimmed arc, drawn from 12 o'clock clockwise.
    private var arc: some Shape {
        Circle().trim(from: 0, to: max(0.0001, filled)).rotation(.degrees(-90))
    }
}
