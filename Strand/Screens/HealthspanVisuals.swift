import SwiftUI
import StrandDesign
import StrandAnalytics

// HealthspanVisuals.swift — fork feature (backlog plan HEALTHSPAN_AGE_PLAN, spec S6): the drawn pieces of the
// Healthspan screens. A glowing orb filled with particles carries the age; a tick slider carries Pace of
// Aging on the paper's −1.0× to 3.0× scale; a ticked bar per measure shows where a value sits on that
// measure's curve, coloured by the years each value would add (amber) or remove (green).

// MARK: - Orb

/// The healthspan age inside a slowly breathing organic disc densely filled with twinkling particles in the
/// app's metric colours, with a luminous rim. Still under Reduce Motion.
struct HealthspanOrb: View {
    let age: Double
    var diameter: CGFloat = 220
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                orb(time: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    orb(time: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3_600))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("AgeLess age \(HealthspanSection.years(age))"))
    }

    private func orb(time: Double) -> some View {
        ZStack {
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                HealthspanOrbRenderer.draw(context: &context, size: size, time: time)
            }
            .frame(width: diameter * HealthspanOrbRenderer.overscan, height: diameter * HealthspanOrbRenderer.overscan)
            .allowsHitTesting(false)
            VStack(spacing: NoopMetrics.space1) {
                Text(HealthspanSection.years(age))
                    .font(StrandFont.rounded(diameter * 0.2, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("AgeLess age")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
            }
            .foregroundStyle(StrandPalette.onDarkPrimary)
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: diameter * 0.62)
        }
    }
}

private enum HealthspanOrbRenderer {
    /// The glow reaches past the orb's square; the canvas overscans so it fades instead of being cut.
    static let overscan: CGFloat = 1.3

    struct Particle {
        let angle, radial, size, phase, speed, drift: Double
        let colour: Int
    }

    /// Fixed particle field (deterministic, so the orb looks the same on every launch). Radii lean toward
    /// the rim, where the glow is brightest, while still filling the centre.
    static let particles: [Particle] = {
        var seed: UInt64 = 0x4845_414C_5448
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<1_100).map { _ in
            let u = next()
            return Particle(angle: next() * 2 * .pi, radial: pow(u, 0.38), size: 0.7 + pow(next(), 2.6) * 2.9,
                            phase: next() * 2 * .pi, speed: 0.6 + next() * 2.2, drift: (next() - 0.5) * 0.08,
                            colour: Int(next() * 100))
        }
    }()

    /// Gold leads; the other metric colours sparkle through it.
    static func colour(_ index: Int) -> Color {
        switch index % 100 {
        case 0..<46: return StrandPalette.recovery055
        case 46..<64: return StrandPalette.metricAmber
        case 64..<74: return StrandPalette.metricRose
        case 74..<84: return StrandPalette.metricPurple
        case 84..<92: return StrandPalette.metricCyan
        default: return StrandPalette.chargeColor
        }
    }

    /// The breathing outline: a few slow harmonics around the base circle.
    static func contour(_ angle: Double, _ t: Double) -> Double {
        1 + 0.032 * sin(3 * angle + 0.5 * t) + 0.022 * sin(5 * angle - 0.35 * t + 1.3)
            + 0.012 * sin(8 * angle + 0.8 * t + 2.1)
    }

    static func draw(context: inout GraphicsContext, size: CGSize, time t: Double) {
        let side = min(size.width, size.height) / overscan
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side * 0.46
        var outline = Path()
        for i in 0...96 {
            let a = Double(i) / 96 * 2 * .pi
            let r = radius * contour(a, t)
            let p = CGPoint(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r)
            if i == 0 { outline.move(to: p) } else { outline.addLine(to: p) }
        }
        outline.closeSubpath()
        let breathe = 0.85 + 0.15 * sin(t * 0.9)
        let gold = StrandPalette.recovery055

        // Halo around the orb.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.16))
            layer.fill(outline, with: .color(gold.opacity(0.32 * breathe)))
        }
        // The dark chamber the particles glow in.
        context.fill(outline, with: .radialGradient(
            Gradient(stops: [.init(color: .black.opacity(0.92), location: 0),
                             .init(color: .black.opacity(0.8), location: 0.75),
                             .init(color: .black.opacity(0.55), location: 1)]),
            center: centre, startRadius: 0, endRadius: radius * 1.05))
        // Luminous rim in the mixed colours.
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.addFilter(.blur(radius: radius * 0.07))
            layer.stroke(outline, with: .conicGradient(
                Gradient(colors: [gold, StrandPalette.metricAmber, StrandPalette.metricRose, gold,
                                  StrandPalette.metricPurple, StrandPalette.metricCyan, gold]),
                center: centre, angle: .radians(t * 0.15)), lineWidth: radius * 0.16 * breathe)
        }
        // Particles, twinkling and drifting slowly around the centre.
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            for p in particles {
                let a = p.angle + p.drift * t
                let r = radius * contour(a, t) * p.radial * 0.97
                let point = CGPoint(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r)
                let twinkle = 0.4 + 0.6 * (0.5 + 0.5 * sin(t * p.speed + p.phase))
                let rimBoost = 0.7 + 0.5 * p.radial
                let alpha = min(1, twinkle * rimBoost)
                let s = p.size * side / 220
                let c = colour(p.colour)
                if s > 1.4 {
                    let halo = s * 3.4
                    layer.fill(Path(ellipseIn: CGRect(x: point.x - halo / 2, y: point.y - halo / 2, width: halo, height: halo)),
                               with: .color(c.opacity(alpha * 0.22)))
                }
                layer.fill(Path(ellipseIn: CGRect(x: point.x - s / 2, y: point.y - s / 2, width: s, height: s)),
                           with: .color(c.opacity(alpha)))
            }
        }
        context.stroke(outline, with: .color(.white.opacity(0.22)), lineWidth: 0.7)
    }
}

// MARK: - Pace slider

/// Pace of Aging on a tick scale from −1.0× to 3.0×, the calendar's 1.0× in the middle, a marker at the pace.
struct HealthspanPaceSlider: View {
    let pace: Double

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Label("Slow", systemImage: "tortoise").labelStyle(.titleAndIcon)
                Spacer()
                Label("Fast", systemImage: "hare").labelStyle(.titleAndIcon)
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            GeometryReader { g in
                let w = g.size.width
                let x = (min(3, max(-1, pace)) + 1) / 4 * w
                Canvas { context, size in
                    for i in 0...40 {
                        let tx = Double(i) / 40 * size.width
                        let major = i % 10 == 0
                        let h: CGFloat = major ? 22 : 14
                        context.fill(Path(roundedRect: CGRect(x: tx - 0.75, y: size.height - h - 4, width: 1.5, height: h),
                                          cornerRadius: 0.75),
                                     with: .color(StrandPalette.textTertiary.opacity(major ? 0.8 : 0.45)))
                    }
                    context.fill(Path(roundedRect: CGRect(x: x - 1.5, y: 14, width: 3, height: size.height - 16),
                                      cornerRadius: 1.5),
                                 with: .color(StrandPalette.textPrimary))
                }
                Text(Self.paceText(pace))
                    .font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize()
                    .position(x: min(max(x, 24), w - 24), y: 6)
            }
            .frame(height: 46)
            HStack {
                Text(verbatim: Self.paceText(-1))
                Spacer()
                Text(verbatim: Self.paceText(1))
                Spacer()
                Text(verbatim: Self.paceText(3))
            }
            .font(StrandFont.caption.monospacedDigit())
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pace of Aging \(Self.paceText(pace)), \(HealthspanSection.paceState(pace))"))
    }

    static func paceText(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) + "×" }
}

// MARK: - Measure bar

/// One measure as a ticked bar over its curve: amber ticks add years, grey are neutral, green remove them,
/// deeper the further they go. ▼ marks the six-month average (the age uses it), ▲ the last 30 days.
struct HealthspanMeasureRow: View {
    let component: HealthspanEngine.Component
    let value: Double?
    let recentValue: Double?
    let years: Double?
    let scale: HealthspanEngine.BarScale

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(HealthspanSection.componentName(component)).strandOverline()
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                bar
                VStack(alignment: .trailing, spacing: 0) {
                    Text(years.map { HealthspanSection.signedNumber($0) } ?? "—")
                        .font(StrandFont.number(20).monospacedDigit())
                        .foregroundStyle(Self.textColour(years))
                    Text("years").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(minWidth: 56, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        let name = HealthspanSection.componentName(component)
        guard let value, let years else { return "\(name), \(String(localized: "No data yet"))" }
        return "\(name), \(HealthspanSection.value(component, value)), \(HealthspanSection.signedYears(years))"
    }

    private var bar: some View {
        VStack(spacing: 2) {
            GeometryReader { g in
                let w = g.size.width
                Canvas { context, size in
                    let n = scale.ticks.count
                    let step = size.width / CGFloat(n)
                    let maxPos = max(0.3, scale.ticks.map(\.years).max() ?? 0)
                    let maxNeg = max(0.3, -(scale.ticks.map(\.years).min() ?? 0))
                    for (i, t) in scale.ticks.enumerated() {
                        let colour = Self.colour(t.years, max: t.years > 0 ? maxPos : maxNeg)
                        context.fill(Path(roundedRect: CGRect(x: CGFloat(i) * step + 1, y: 20, width: step - 2, height: 10),
                                          cornerRadius: 1.5), with: .color(colour))
                    }
                    if let value {
                        let x = scale.position(value) * size.width
                        var down = Path()
                        down.move(to: CGPoint(x: x - 5, y: 11)); down.addLine(to: CGPoint(x: x + 5, y: 11))
                        down.addLine(to: CGPoint(x: x, y: 18)); down.closeSubpath()
                        context.fill(down, with: .color(StrandPalette.textPrimary))
                    }
                    if let recentValue {
                        let x = scale.position(recentValue) * size.width
                        var up = Path()
                        up.move(to: CGPoint(x: x - 4, y: 39)); up.addLine(to: CGPoint(x: x + 4, y: 39))
                        up.addLine(to: CGPoint(x: x, y: 32)); up.closeSubpath()
                        context.fill(up, with: .color(StrandPalette.textSecondary))
                    }
                }
                if let value {
                    Text(HealthspanSection.value(component, value))
                        .font(StrandFont.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize()
                        .position(x: min(max(scale.position(value) * w, 36), w - 36), y: 4)
                }
            }
            .frame(height: 40)
            HStack {
                Text(HealthspanSection.value(component, scale.range.lowerBound))
                Spacer()
                Text(HealthspanSection.value(component, scale.range.upperBound))
            }
            .font(StrandFont.caption.monospacedDigit())
            .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// Solid ink for a years figure: the tick colours fade with magnitude, text must not.
    static func textColour(_ years: Double?) -> Color {
        guard let years else { return StrandPalette.textTertiary }
        if years > 0.05 { return StrandPalette.statusWarningForeground }
        if years < -0.05 { return StrandPalette.statusPositive.legibleText }
        return StrandPalette.textSecondary
    }

    /// Amber adds years, green removes them; within a few weeks of neutral the tick stays grey.
    static func colour(_ years: Double, max: Double) -> Color {
        if years > 0.05 { return StrandPalette.metricAmber.opacity(0.45 + 0.55 * min(1, years / max)) }
        if years < -0.05 { return StrandPalette.statusPositive.opacity(0.45 + 0.55 * min(1, -years / max)) }
        return StrandPalette.textTertiary.opacity(0.35)
    }
}
