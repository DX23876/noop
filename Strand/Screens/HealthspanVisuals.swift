import SwiftUI
import StrandDesign
import StrandAnalytics

// HealthspanVisuals.swift — fork feature (backlog plan HEALTHSPAN_AGE_PLAN, spec S6): the drawn pieces of the
// AgeLess screens. A half-circle gauge carries the age against the actual age; a tick slider carries Pace of
// Aging on the paper's −1.0× to 3.0× scale; a ticked bar per measure shows where a value sits on that
// measure's curve, coloured by the years each value would add (coral) or remove (cyan to indigo).

// MARK: - Age gauge

/// The AgeLess age on a half-circle gauge spanning ten years either side of the actual age, which sits at the
/// top with its own mark. The arc fills from the young end to the age in an indigo to cyan glow; past the actual
/// age the extra years turn coral. The age and the years younger or older sit in the gauge's centre.
struct HealthspanAgeGauge: View, Animatable {
    let age: Double
    let actualAge: Double
    /// 0 draws the needle at the actual age, 1 at the AgeLess age; animated once on appear.
    var progress: Double = 1

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static let span = 10.0
    static let bleed: CGFloat = 40

    /// Where an age sits on the gauge, 0 at the young end and 1 at the old end.
    static func fraction(_ age: Double, actualAge: Double) -> Double {
        min(1, max(0, (age - actualAge + span) / (2 * span)))
    }

    static func whole(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0))) }

    private var shownAge: Double { actualAge + (age - actualAge) * progress }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let r = w * 0.36
            let line = r * 0.15
            let centre = CGPoint(x: w / 2, y: r + line / 2 + 46)
            ZStack {
                // The canvas overhangs the gauge so the glow fades out instead of ending at its frame.
                Canvas { context, _ in
                    context.translateBy(x: Self.bleed, y: Self.bleed)
                    draw(&context, centre: centre, r: r, line: line)
                }
                .frame(width: g.size.width + 2 * Self.bleed, height: g.size.height + 2 * Self.bleed)
                .position(x: g.size.width / 2, y: g.size.height / 2)
                .allowsHitTesting(false)
                Text(verbatim: Self.whole(actualAge))
                    .font(StrandFont.number(17).monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
                    .position(x: centre.x, y: 10)
                ForEach([-Self.span, Self.span], id: \.self) { offset in
                    Text(verbatim: Self.whole(actualAge + offset))
                        .font(StrandFont.number(15).monospacedDigit())
                        .foregroundStyle(StrandPalette.textTertiary)
                        .position(x: centre.x + (offset < 0 ? -r : r), y: centre.y + line / 2 + 16)
                }
                VStack(spacing: NoopMetrics.space1) {
                    Text(verbatim: HealthspanSection.years(shownAge))
                        .font(StrandFont.number(r * 0.55, weight: .bold).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    deltaLine
                }
                .frame(width: r * 1.5)
                .position(x: centre.x, y: centre.y - r * 0.28)
            }
        }
        .aspectRatio(1.55, contentMode: .fit)
        .frame(maxWidth: 380)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("AgeLess age \(HealthspanSection.years(age))"))
    }

    private var deltaLine: some View {
        let delta = age - actualAge
        return (Text(verbatim: HealthspanSection.years(abs(delta)) + " ")
                + Text(delta <= 0 ? "years younger" : "years older"))
            .font(StrandFont.subhead.weight(.medium))
            .foregroundStyle(delta <= 0 ? StrandPalette.agelessYoungDeep.legibleText : StrandPalette.agelessOld.legibleText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func angle(_ fraction: Double) -> Angle { .degrees(180 + 180 * fraction) }

    private func arc(_ centre: CGPoint, _ r: CGFloat, from: Double, to: Double) -> Path {
        var p = Path()
        p.addArc(center: centre, radius: r, startAngle: angle(from), endAngle: angle(to), clockwise: false)
        return p
    }

    private func point(_ centre: CGPoint, _ r: CGFloat, _ fraction: Double) -> CGPoint {
        let a = angle(fraction).radians
        return CGPoint(x: centre.x + r * cos(a), y: centre.y + r * sin(a))
    }

    private func draw(_ context: inout GraphicsContext, centre: CGPoint, r: CGFloat, line: CGFloat) {
        let knob = Self.fraction(shownAge, actualAge: actualAge)
        let style = StrokeStyle(lineWidth: line, lineCap: .round)
        let young = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [StrandPalette.agelessYoungDeep, StrandPalette.agelessYoung]),
            startPoint: point(centre, r, 0), endPoint: point(centre, r, max(0.12, min(knob, 0.5))))
        let older = GraphicsContext.Shading.color(StrandPalette.agelessOld)
        let knobColour = knob <= 0.5 ? StrandPalette.agelessYoung : StrandPalette.agelessOld

        // Ticks, one per year, outside the arc; the actual age gets the long dark mark across the arc.
        for i in 0...20 where i != 10 {
            let f = Double(i) / 20
            let inner = point(centre, r + line / 2 + 8, f), outer = point(centre, r + line / 2 + (i % 5 == 0 ? 18 : 14), f)
            var t = Path(); t.move(to: inner); t.addLine(to: outer)
            context.stroke(t, with: .color(StrandPalette.textTertiary.opacity(i % 5 == 0 ? 0.7 : 0.4)), lineWidth: 1.2)
        }
        context.stroke(arc(centre, r, from: 0, to: 1), with: .color(StrandPalette.textTertiary.opacity(0.14)), style: style)

        // The glow under the fill, then the fill itself.
        let filled = arc(centre, r, from: 0, to: min(knob, 0.5))
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: line * 1.1))
            glow.opacity = 0.9
            glow.stroke(filled, with: young, style: StrokeStyle(lineWidth: line * 1.8, lineCap: .round))
            if knob > 0.5 { glow.stroke(arc(centre, r, from: 0.5, to: knob), with: older, style: StrokeStyle(lineWidth: line * 1.8, lineCap: .round)) }
        }
        if knob < 0.5 {
            context.stroke(arc(centre, r, from: knob, to: 0.5), with: .color(StrandPalette.agelessYoung.opacity(0.18)), style: style)
        }
        context.stroke(filled, with: young, style: style)
        if knob > 0.5 { context.stroke(arc(centre, r, from: 0.5, to: knob), with: older, style: style) }

        var mark = Path()
        mark.move(to: point(centre, r - line / 2, 0.5)); mark.addLine(to: point(centre, r + line / 2 + 20, 0.5))
        context.stroke(mark, with: .color(StrandPalette.textPrimary), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        // The needle: a ringed dot riding the arc at the age.
        let k = point(centre, r, knob), d = line * 1.45
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: line * 0.8))
            glow.fill(Path(ellipseIn: CGRect(x: k.x - d * 0.75, y: k.y - d * 0.75, width: d * 1.5, height: d * 1.5)), with: .color(knobColour.opacity(0.8)))
        }
        context.fill(Path(ellipseIn: CGRect(x: k.x - d / 2, y: k.y - d / 2, width: d, height: d)), with: .color(.white))
        let inner = d * 0.66
        context.fill(Path(ellipseIn: CGRect(x: k.x - inner / 2, y: k.y - inner / 2, width: inner, height: inner)), with: .color(knobColour))
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

/// One measure as a ticked bar over its curve: coral ticks add years, grey are neutral, cyan to indigo remove
/// them, deeper the further they go. ▼ marks the six-month average (the age uses it), ▲ the last 30 days.
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
        if years > 0.05 { return StrandPalette.agelessOld.legibleText }
        if years < -0.05 { return StrandPalette.agelessYoungDeep.legibleText }
        return StrandPalette.textSecondary
    }

    /// Coral adds years, cyan to indigo removes them; within a few weeks of neutral the tick stays grey.
    static func colour(_ years: Double, max: Double) -> Color {
        if years > 0.05 { return StrandPalette.agelessOld.opacity(0.4 + 0.6 * min(1, years / max)) }
        if years < -0.05 {
            let t = min(1, -years / max)
            return t < 0.5 ? StrandPalette.agelessYoung.opacity(0.55 + 0.9 * t) : StrandPalette.agelessYoungDeep.opacity(0.5 + t / 2)
        }
        return StrandPalette.textTertiary.opacity(0.35)
    }
}
