import SwiftUI

// MARK: - GlowRing — the classic score ring
//
// A crisp arc with rounded caps over a faint full-circle track in the arc's own colour (so the ring reads
// as "X% of a circle"), deepening from its start to its tip, with a soft shadow under the tip as on Apple's
// activity rings, and a bold centred number that counts up. No blur, no bloom. The arc springs in from
// 12 o'clock and re-animates when the value changes (day nav). Theme-aware; motion gated on Reduce Motion;
// macOS-13 / iOS-17 safe. Also what the "Classic" ring style draws in place of the organic rings.

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
    @Environment(\.colorScheme) private var colorScheme
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
            rings

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

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: .round) }

    /// The arc's colour from a deeper shade at its start to the full colour at its tip.
    private var sweep: AngularGradient {
        AngularGradient(colors: [color.opacity(0.62), color], center: .center,
                        startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * Double(max(filled, 0.01))))
    }

    /// A disc riding at the tip of the arc, turned with it from 12 o'clock.
    private func tip<S: View>(_ disc: S) -> some View {
        disc.offset(y: -diameter / 2).rotationEffect(.degrees(360 * Double(filled)))
    }

    /// A faint track in the arc's own colour, the arc deepening towards its tip, and a soft shadow under the
    /// tip, so a ring past a full turn still shows where it ends.
    @ViewBuilder private var rings: some View {
        Circle().stroke(color.opacity(colorScheme == .light ? 0.16 : 0.2), style: stroke)
        if clamped > 0 {
            arc.stroke(sweep, style: stroke)
            tip(Circle().fill(color).frame(width: lineWidth, height: lineWidth)
                .shadow(color: .black.opacity(colorScheme == .light ? 0.22 : 0.45), radius: lineWidth * 0.22))
        }
    }
}
