import SwiftUI

// MARK: - BevelGauge (NEW) — the layered ring gauge primitive
//
// The shared instrument behind RecoveryRing and StrainGauge: a 240° open gauge with
//   • a soft frosted inner disc (subtle radial fill, hairline rim)
//   • a faint full-span track ring carved from `surfaceInset` (the Titanium "well")
//   • a gradient-stroked progress arc (AngularGradient over the domain ramp:
//     Charge=gold, Effort=amber, Rest=blue, Stress=blue→gold→orange — caller-supplied)
//   • a faint, static outer bloom whose intensity scales with the fill (calm, not glowing)
//   • a clean end-cap dot at the arc tip (small white core, very faint shadow)
//   • a centred SF Pro **Rounded** bold number with an "of N" caption + state word
//
// It owns no domain logic — callers pass the fraction, the stroke gradient, the tip
// colour, and the centre read-out strings. RecoveryRing / StrainGauge keep their own
// public init signatures and delegate their visuals here, so every screen re-skins
// without any call-site change.

public struct BevelGauge: View {

    /// Fill fraction 0...1 of the 240° span.
    public var fraction: Double
    /// Angular gradient stops for the progress arc (the domain ramp).
    public var stops: [Gradient.Stop]
    /// Colour of the glowing end-cap + state word (usually the ramp sampled at `fraction`).
    public var tipColor: Color
    /// Big centred number, already formatted (e.g. "87" or "12.4").
    public var numberText: String
    /// Small caption under the number (e.g. "of 100" / "of 21"). nil hides it.
    public var captionText: String?
    /// State word above/below the number (e.g. "PRIMED"). nil hides it.
    public var stateText: String?
    /// Optional supporting line under the read-out.
    public var supporting: String?
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    public var showsLabel: Bool
    /// Animated draw-in fraction supplied by the caller (so it owns the @State + animation).
    public var animatedFraction: Double
    /// Whether the bloom is at full (vs resting) intensity — caller drives the breathe pulse.
    public var bloomActive: Bool

    public init(
        fraction: Double,
        stops: [Gradient.Stop],
        tipColor: Color,
        numberText: String,
        captionText: String? = nil,
        stateText: String? = nil,
        supporting: String? = nil,
        diameter: CGFloat = 200,
        lineWidth: CGFloat = 16,
        showsLabel: Bool = true,
        animatedFraction: Double,
        bloomActive: Bool = true
    ) {
        self.fraction = fraction
        self.stops = stops
        self.tipColor = tipColor
        self.numberText = numberText
        self.captionText = captionText
        self.stateText = stateText
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.animatedFraction = animatedFraction
        self.bloomActive = bloomActive
    }

    private let arcSpanDegrees: Double = 240
    private var startAngle: Angle { .degrees(150) }
    private var endAngle: Angle { .degrees(150 + arcSpanDegrees) }

    // Material-style restraint: a faint, static bloom (≈⅓ the old opacity, ≈½ the old
    // blur) so the arc reads as a clean flat ring rather than a skeuomorphic glow.
    private var bloomOpacity: Double { 0.05 + 0.13 * fraction }
    private var bloomRadius: CGFloat { lineWidth * (0.45 + 0.7 * fraction) }

    private var gradient: Gradient { Gradient(stops: stops) }

    public var body: some View {
        ZStack {
            innerDisc
            ring
            if showsLabel { centerLabel }
        }
        .frame(width: diameter, height: diameter)
    }

    // Frosted inner disc behind the arc — gives the gauge a glassy "well".
    private var innerDisc: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [StrandPalette.surfaceInset.opacity(0.0), StrandPalette.surfaceInset.opacity(0.55)],
                    center: .center, startRadius: diameter * 0.10, endRadius: diameter * 0.5
                )
            )
            .overlay(Circle().strokeBorder(StrandPalette.hairline.opacity(0.5), lineWidth: 1))
            .padding(lineWidth * 1.4)
    }

    private var ring: some View {
        ZStack {
            // Outer bloom — a faint, STATIC blurred copy of the filled arc. No breathing
            // pulse: it sits calm so the ring reads flat/Material, not glowing. `bloomActive`
            // is kept in the signature but no longer drives an animation here.
            arcShape(to: animatedFraction)
                .stroke(
                    AngularGradient(gradient: gradient, center: .center,
                                    startAngle: startAngle, endAngle: endAngle),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .blur(radius: bloomRadius)
                .opacity(bloomOpacity)
                .additiveBloom()

            // Faint full-span track — the inset "well" the gold/amber/blue arc sits in.
            arcShape(to: 1.0)
                .stroke(StrandPalette.surfaceInset,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Filled gradient arc.
            arcShape(to: animatedFraction)
                .stroke(
                    AngularGradient(gradient: gradient, center: .center,
                                    startAngle: startAngle, endAngle: endAngle),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            // Clean end-cap dot at the arc tip.
            if animatedFraction > 0.001 { endCap }
        }
    }

    private var endCap: some View {
        GeometryReader { geo in
            let radius = (min(geo.size.width, geo.size.height) - lineWidth) / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let tipAngle = startAngle.radians + (arcSpanDegrees * .pi / 180) * animatedFraction
            let pt = CGPoint(x: center.x + radius * cos(tipAngle),
                             y: center.y + radius * sin(tipAngle))
            // Clean Material tip: a single small solid dot at the arc end. The large
            // blurred halo is gone; only a very faint shadow keeps it from looking pasted on.
            Circle().fill(StrandPalette.tipCore)
                .frame(width: lineWidth * 0.7, height: lineWidth * 0.7)
                .overlay(Circle().fill(tipColor).opacity(0.35))
                .shadow(color: tipColor.opacity(0.35), radius: lineWidth * 0.18)
                .position(pt)
        }
    }

    private var centerLabel: some View {
        VStack(spacing: 2) {
            Text(numberText)
                .font(StrandFont.rounded(diameter * 0.30, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .contentTransition(.numericText())
            if let captionText {
                Text(captionText)
                    .font(StrandFont.rounded(diameter * 0.085, weight: .medium))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if let stateText {
                // Scale the state word WITH the gauge, like the number (0.30·d) and caption (0.085·d).
                // `min(11, …)` pins it to the original 11pt overline on the large solo-hero rings (≥130pt)
                // — byte-identical there — and shrinks it on the small three-up rings, where a fixed 11pt
                // word overflowed the arc and collided with the number/caption. Uses a *scaled overline*
                // (not rounded()) so Dynamic-Type text-scaling is preserved. Thanks @claypilat (#403).
                let stateSize = min(11, diameter * 0.085)
                Text(stateText)
                    .font(StrandFont.overlineScaled(stateSize))
                    .tracking(StrandFont.overlineTracking * stateSize / 11)
                    .foregroundStyle(tipColor)
                    .padding(.top, 2)
            }
            if let supporting {
                Text(supporting)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: diameter * 0.78)
                    .padding(.top, 2)
            }
        }
    }

    private func arcShape(to fraction: Double) -> RecoveryArc {
        RecoveryArc(startAngle: startAngle, spanDegrees: arcSpanDegrees,
                    fraction: fraction, lineWidth: lineWidth)
    }
}

#if DEBUG
#Preview("BevelGauge") {
    HStack(spacing: 24) {
        BevelGauge(
            fraction: 0.78, stops: StrandPalette.recoveryStops,
            tipColor: StrandPalette.recoveryColor(78), numberText: "78",
            captionText: "of 100", stateText: "PRIMED",
            diameter: 200, animatedFraction: 0.78
        )
        BevelGauge(
            fraction: 0.55, stops: StrandPalette.strainStops,
            tipColor: StrandPalette.strainColor(55), numberText: "11.6",
            captionText: "of 21", stateText: "MODERATE",
            diameter: 200, animatedFraction: 0.55
        )
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
