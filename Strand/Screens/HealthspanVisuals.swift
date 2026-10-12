import SwiftUI
import StrandDesign
import StrandAnalytics

// HealthspanVisuals.swift — fork feature (backlog plan HEALTHSPAN_AGE_PLAN, spec S6): the drawn pieces of the
// AgeLess screens. A half-circle gauge carries the age against the actual age; a tick slider carries Pace of
// Aging on the paper's −1.0× to 3.0× scale; a ticked bar per measure shows where a value sits on that
// measure's curve, coloured by the years each value would add (coral) or remove (cyan to indigo).

// MARK: - Card

extension View {
    /// The white card every AgeLess block sits in, so nothing on the screen floats grey on the canvas.
    func agelessCard() -> some View {
        padding(NoopMetrics.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { FrostedCardSurface(tint: StrandPalette.agelessYoungDeep, cornerRadius: NoopMetrics.cardRadius) }
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }
}

// MARK: - Age gauge

/// The AgeLess age on a half-circle gauge spanning ten years either side of the actual age, which sits at the
/// top with its own mark. Younger, the arc fills from the young end to the age in an indigo to cyan glow; older,
/// only the years past the actual age fill, in coral. The age and the years younger or older sit in the gauge's centre.
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
        .accessibilityLabel(Text("\(Text("AgeLess age \(HealthspanSection.years(age))")), \(deltaText)"))
    }

    /// "4.4 years younger" from the already translated "years younger" / "years older".
    private var deltaText: Text {
        let delta = age - actualAge
        let words = Text(delta <= 0 ? "years younger" : "years older")
        return Text("\(Text(verbatim: HealthspanSection.years(abs(delta)))) \(words)")
    }

    private var deltaLine: some View {
        let delta = age - actualAge
        return deltaText
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

        // The glow under the fill, then the fill itself. Younger: the young end up to the age glows. Older: only
        // the years past the actual age glow, so the young half cannot read as years gained.
        let isOlder = knob > 0.5
        let filled = isOlder ? arc(centre, r, from: 0.5, to: knob) : arc(centre, r, from: 0, to: knob)
        let fill = isOlder ? older : young
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: line * 1.1))
            glow.opacity = 0.9
            glow.stroke(filled, with: fill, style: StrokeStyle(lineWidth: line * 1.8, lineCap: .round))
        }
        if !isOlder {
            context.stroke(arc(centre, r, from: knob, to: 0.5), with: .color(StrandPalette.agelessYoung.opacity(0.18)), style: style)
        }
        context.stroke(filled, with: fill, style: style)

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

/// Aging speed (the paper's Pace of Aging) on a tick scale from −1.0× to 3.0×, the calendar's 1.0× in the middle, a marker at the pace;
/// the slow side carries the young colours, the fast side the old one.
struct HealthspanPaceSlider: View {
    let pace: Double

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                // A leaf for ageing slowly, a flame for ageing fast: slow is the good end here.
                Label("Slow", systemImage: "leaf.fill").labelStyle(.titleAndIcon)
                    .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                Spacer()
                Label("Fast", systemImage: "flame.fill").labelStyle(.titleAndIcon)
                    .foregroundStyle(StrandPalette.agelessOld.legibleText)
            }
            .font(StrandFont.caption.weight(.medium))
            GeometryReader { g in
                let w = g.size.width
                let x = (min(3, max(-1, pace)) + 1) / 4 * w
                Canvas { context, size in
                    for i in 0...40 {
                        let tx = Double(i) / 40 * size.width
                        let major = i % 10 == 0
                        let h: CGFloat = major ? 22 : 14
                        // Below the calendar's 1.0× the ticks run indigo to cyan, above it coral.
                        let tick = i < 20 ? (i < 10 ? StrandPalette.agelessYoungDeep : StrandPalette.agelessYoung)
                            : i == 20 ? StrandPalette.textTertiary : StrandPalette.agelessOld
                        context.fill(Path(roundedRect: CGRect(x: tx - 0.75, y: size.height - h - 4, width: 1.5, height: h),
                                          cornerRadius: 0.75),
                                     with: .color(tick.opacity(major ? 0.9 : 0.55)))
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
            // The value label rides above ticks drawn at fixed heights; past this size it would cover them.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
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
        .accessibilityLabel(Text("Aging speed \(Self.paceText(pace)), \(HealthspanSection.paceState(pace))"))
    }

    static func paceText(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) + "×" }
}

// MARK: - Levers

/// The steps that would lower the age most, as a card beside the measure cards: what all of them together
/// would take off at the top, then each lever ranked, with a segmented bar as long as its gain against the
/// biggest one and the step from today's value to the next.
struct HealthspanLeversCard: View {
    let week: HealthspanWeek

    /// The years all levers together would remove, computed on the combined inputs rather than summed,
    /// since the curves do not add up exactly.
    private var combinedYears: Double? {
        var after = week.inputs
        for l in week.levers { after.set(l.component, l.newValue) }
        return HealthspanEngine.compute(after).map { $0.deltaYears - week.result.deltaYears }
    }

    var body: some View {
        let biggest = week.levers.map { -$0.years }.max() ?? 1
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Biggest levers")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                if let combinedYears {
                    Text(HealthspanSection.signedYears(combinedYears))
                        .font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                        .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                }
            }
            ForEach(Array(week.levers.enumerated()), id: \.element.component) { rank, lever in
                HealthspanLeverRow(rank: rank + 1, lever: lever, share: -lever.years / max(biggest, 0.01))
            }
        }
        .agelessCard()
    }
}

/// One lever: its rank, name and step, a segmented bar filled to its share of the biggest lever's gain,
/// and the years it would remove.
struct HealthspanLeverRow: View {
    let rank: Int
    let lever: HealthspanEngine.Lever
    /// This lever's gain as a fraction of the biggest one's, 0…1.
    let share: Double

    static let segments = 24

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Text(verbatim: "\(rank)")
                .font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(StrandPalette.agelessYoungDeep.opacity(0.14)))
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(HealthspanSection.componentName(lever.component))
                    .font(StrandFont.subhead.weight(.medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                Canvas { context, size in
                    let n = Self.segments
                    let step = size.width / CGFloat(n)
                    let filled = max(1, Int((min(1, max(0, share)) * Double(n)).rounded()))
                    for i in 0..<n {
                        let t = Double(i) / Double(n - 1)
                        let colour = i < filled
                            ? (t < 0.5 ? StrandPalette.agelessYoung : StrandPalette.agelessYoungDeep).opacity(0.55 + 0.45 * t)
                            : StrandPalette.textTertiary.opacity(0.18)
                        context.fill(Path(roundedRect: CGRect(x: CGFloat(i) * step + 1, y: 0, width: step - 2, height: size.height),
                                          cornerRadius: 1.5), with: .color(colour))
                    }
                }
                .frame(height: 8)
                Text(verbatim: "\(HealthspanSection.value(lever.component, lever.currentValue)) → \(HealthspanSection.value(lever.component, lever.newValue))")
                    .font(StrandFont.caption.monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(HealthspanSection.signedNumber(lever.years))
                    .font(StrandFont.number(20).monospacedDigit())
                    .foregroundStyle(HealthspanMeasureRow.textColour(lever.years))
                Text("years").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(minWidth: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        let c = lever.component
        return "\(HealthspanSection.componentName(c)), \(HealthspanSection.value(c, lever.currentValue)) → "
            + "\(HealthspanSection.value(c, lever.newValue)), \(HealthspanSection.signedYears(lever.years))"
    }
}

// MARK: - Measure bar

/// One measure as a ticked bar over its curve: coral ticks add years, grey are neutral, cyan to indigo remove
/// them, deeper the further they go. ▼ marks the six-month average the age uses; an arrow beside the years
/// says where the last 30 days are taking the measure, and a note says where the value came from or how to
/// supply a missing one.
struct HealthspanMeasureRow: View {
    let component: HealthspanEngine.Component
    let value: Double?
    let years: Double?
    let scale: HealthspanEngine.BarScale
    var trend: HealthspanEngine.Trend? = nil
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(HealthspanSection.componentName(component))
                .font(StrandFont.subhead.weight(.medium))
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                bar
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(spacing: 2) {
                        if let trend {
                            Image(systemName: trend.rising ? "arrow.up" : "arrow.down")
                                .font(StrandFont.caption.weight(.bold))
                                .foregroundStyle(trend.better ? StrandPalette.agelessYoungDeep.legibleText
                                                 : StrandPalette.agelessOld.legibleText)
                        }
                        Text(years.map { HealthspanSection.signedNumber($0) } ?? "—")
                            .font(StrandFont.number(20).monospacedDigit())
                            .foregroundStyle(Self.textColour(years))
                    }
                    Text("years").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(minWidth: 64, alignment: .trailing)
            }
            if let note {
                Text(note)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        let name = HealthspanSection.componentName(component)
        guard let value, let years else { return [name, String(localized: "No data yet"), note].compactMap { $0 }.joined(separator: ", ") }
        return [name, HealthspanSection.value(component, value), HealthspanSection.signedYears(years), note]
            .compactMap { $0 }.joined(separator: ", ")
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
            // The value label rides above ticks drawn at fixed heights; past this size it would cover them.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
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
