import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - How a Training Load status looks
//
// The status itself is decided in `TrainingStatusModel`; this file only draws it. Every colour comes
// from the palette's own status and metric tokens, so the dial follows whichever chart style the
// wearer picked instead of carrying a second colour world of its own:
//
//   below usual (detraining / recovering) → metricCyan      the cool end, "less than usual"
//   maintaining                           → textTertiary    neutral, nothing to act on
//   productive                            → statusPositive
//   unproductive (strength only)          → statusWarning   work without return
//   overreaching                          → statusCritical

extension TrainingStatus {
    /// The word on the dial.
    var label: String {
        switch self {
        case .detraining:   return String(localized: "Detraining")
        case .recovering:   return String(localized: "Recovering")
        case .maintaining:  return String(localized: "Maintaining")
        case .productive:   return String(localized: "Productive")
        case .unproductive: return String(localized: "Unproductive")
        case .overreaching: return String(localized: "Overreaching")
        }
    }

    /// One line on what the state means — the legend's text.
    var meaning: String {
        switch self {
        case .detraining:
            return String(localized: "Well below your usual load for a while. Fitness starts to slip.")
        case .recovering:
            return String(localized: "A lighter stretch right after a hard phase. A deload, not a decline.")
        case .maintaining:
            return String(localized: "About your usual load. You are holding your level.")
        case .productive:
            return String(localized: "At or a little above your usual load, and it is working.")
        case .unproductive:
            return String(localized: "Strength only: plenty of load, but your lifts are not improving.")
        case .overreaching:
            return String(localized: "Well above your usual load. Fine for a short block, risky if it lasts.")
        }
    }

    var symbol: String {
        switch self {
        case .detraining:   return "arrow.down.right"
        case .recovering:   return "battery.100percent.bolt"
        case .maintaining:  return "equal"
        case .productive:   return "arrow.up.right"
        case .unproductive: return "arrow.triangle.2.circlepath"
        case .overreaching: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .detraining, .recovering: return StrandPalette.metricCyan
        case .maintaining:             return StrandPalette.textTertiary
        case .productive:              return StrandPalette.statusPositive
        case .unproductive:            return StrandPalette.statusWarning
        case .overreaching:            return StrandPalette.statusCritical
        }
    }
}

// MARK: - The dial

/// A 240° dial on Polar's scale: four zones, the ratio as a bead, the status in the middle.
///
/// Built from the same parts as the Today rings (`RecoveryArc`, the frosted inner disc, the inset
/// "well"), so the two instruments read as one family. The zone the lane is in is drawn at full
/// strength and the others recede, so the answer is visible before any text is read. The scale runs
/// from 0.5 to 1.6: wide enough for every zone to have room, and a ratio beyond it simply parks the
/// bead at the end — the number in the centre is always the exact one.
struct LoadStatusRing: View {
    let title: LocalizedStringKey
    let symbol: String
    let lane: LaneStatus?
    /// The lane's own figure, e.g. "66.4 weighted sets · +12 %".
    let figure: String?
    /// What the verdict rests on, e.g. "4 of 6 lifts rising".
    let evidence: String?
    var diameter: CGFloat = 156

    @State private var shownFraction: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lineWidth: CGFloat = 11
    /// Room outside the ring for the 0.8 / 1.0 / 1.3 labels.
    private let labelInset: CGFloat = 15
    private let startDegrees = 150.0
    private let spanDegrees = 240.0

    static let scaleLow = 0.5
    static let scaleHigh = 1.6

    static func fraction(for ratio: Double) -> Double {
        min(max((ratio - scaleLow) / (scaleHigh - scaleLow), 0), 1)
    }

    static func ratioText(_ ratio: Double, band: TrainingLoadBand) -> String {
        let shown = displayRatio(ratio, band: band)
        return String(localized: "\(shown.formatted(.number.precision(.fractionLength(2)))) × usual")
    }

    /// The ratio rounded TOWARD its own zone, so the number never contradicts the word beside it. Plain
    /// rounding showed 0.7996 as "0.80" under "Recovering", although 0.80 is where maintaining begins;
    /// here it reads 0.79. Above 1.3 rounds up (1.3004 → 1.31), and inside a zone the value is kept
    /// within that zone's bounds (0.996 → 0.99, not 1.00).
    static func displayRatio(_ ratio: Double, band: TrainingLoadBand) -> Double {
        let hundredths = ratio * 100
        switch band {
        case .below:       return floor(hundredths) / 100
        case .above:       return ceil(hundredths) / 100
        case .maintaining: return min(max(hundredths.rounded() / 100, 0.8), 0.99)
        case .productive:  return min(max(hundredths.rounded() / 100, 1.0), 1.3)
        }
    }

    private struct Zone: Identifiable {
        let band: TrainingLoadBand
        let from: Double
        let to: Double
        let color: Color
        var id: TrainingLoadBand { band }
    }

    private var zones: [Zone] {
        [Zone(band: .below, from: Self.scaleLow, to: TrainingStatusModel.detrainingBelow,
              color: TrainingStatus.detraining.color),
         Zone(band: .maintaining, from: TrainingStatusModel.detrainingBelow,
              to: TrainingStatusModel.productiveFrom, color: TrainingStatus.maintaining.color),
         Zone(band: .productive, from: TrainingStatusModel.productiveFrom,
              to: TrainingStatusModel.overreachingAbove, color: TrainingStatus.productive.color),
         Zone(band: .above, from: TrainingStatusModel.overreachingAbove, to: Self.scaleHigh,
              color: TrainingStatus.overreaching.color)]
    }

    private var ringRadius: CGFloat { (diameter - 2 * labelInset - lineWidth) / 2 }

    var body: some View {
        VStack(spacing: NoopMetrics.space2) {
            Label { Text(title) } icon: { Image(systemName: symbol) }
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            ZStack {
                dial
                centre
            }
            .frame(width: diameter, height: diameter)
            // The 240° arc leaves the bottom sixth of its square empty; pull the figures up into it
            // rather than leaving a gap under every dial.
            .padding(.bottom, -diameter * 0.14)
            if let figure {
                Text(figure)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if let evidence {
                Text(evidence)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(accessibilityValue))
        .task(id: lane?.ratio) {
            let target = lane.map { Self.fraction(for: $0.ratio) } ?? 0
            if reduceMotion {
                shownFraction = target
            } else {
                withAnimation(StrandMotion.drawIn) { shownFraction = target }
            }
        }
    }

    private var accessibilityValue: String {
        guard let lane else { return String(localized: "Needs two weeks of measured history") }
        return "\(lane.status.label), \(Self.ratioText(lane.ratio, band: lane.band))"
    }

    // MARK: Layers

    private var dial: some View {
        ZStack {
            // Frosted inner disc, as on the Today rings.
            Circle()
                .fill(RadialGradient(colors: [StrandPalette.surfaceInset.opacity(0),
                                              StrandPalette.surfaceInset.opacity(0.6)],
                                     center: .center, startRadius: diameter * 0.08,
                                     endRadius: diameter * 0.42))
                .overlay(Circle().strokeBorder(StrandPalette.hairline.opacity(0.5), lineWidth: 1))
                .padding(labelInset + lineWidth * 1.3)

            // The inset well the zones sit in; dashed while there is no comparison yet.
            arc(from: 0, to: 1)
                .stroke(StrandPalette.surfaceInset,
                        style: StrokeStyle(lineWidth: lineWidth + 5, lineCap: .round,
                                           dash: lane == nil ? [2, 5] : []))
                .padding(labelInset)

            ForEach(zones) { zone in
                let active = lane?.band == zone.band
                let low = Self.fraction(for: zone.from) + 0.006
                let high = Self.fraction(for: zone.to) - 0.006
                // Every zone in full colour, the way Apple Health draws its ranges. The zone the lane
                // is in stands out by width and glow — fading the others to pastel read as disabled.
                arc(from: low, to: high)
                    .stroke(AngularGradient(colors: [zone.color.opacity(0.82), zone.color],
                                            center: .center,
                                            startAngle: .degrees(startDegrees + spanDegrees * low),
                                            endAngle: .degrees(startDegrees + spanDegrees * high)),
                            style: StrokeStyle(lineWidth: active ? lineWidth + 6 : lineWidth, lineCap: .butt))
                    .shadow(color: active ? zone.color.opacity(0.55) : Color.clear, radius: active ? 6 : 0)
                    .padding(labelInset)
            }

            ticks
            if lane != nil { bead }
        }
    }

    /// Short marks and labels at Polar's three thresholds, outside the ring.
    private var ticks: some View {
        ZStack {
            ForEach([TrainingStatusModel.detrainingBelow, TrainingStatusModel.productiveFrom,
                     TrainingStatusModel.overreachingAbove], id: \.self) { value in
                let angle = radians(Self.fraction(for: value))
                Path { path in
                    path.move(to: point(angle, radius: ringRadius + lineWidth / 2 + 1))
                    path.addLine(to: point(angle, radius: ringRadius + lineWidth / 2 + 5))
                }
                .stroke(StrandPalette.textTertiary, lineWidth: 1)
                Text(value, format: .number.precision(.fractionLength(1)))
                    .font(StrandFont.rounded(8.5, weight: .medium))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .position(point(angle, radius: ringRadius + lineWidth / 2 + 11))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    /// The ratio's position, drawn in its status colour with a rim in the card colour so it reads on
    /// top of any zone.
    private var bead: some View {
        let color = lane?.status.color ?? StrandPalette.textTertiary
        return Circle()
            .fill(color)
            .frame(width: lineWidth + 7, height: lineWidth + 7)
            .overlay(Circle().strokeBorder(StrandPalette.surfaceRaised, lineWidth: 3))
            .shadow(color: color.opacity(0.75), radius: 8)
            .position(point(radians(shownFraction), radius: ringRadius))
            .frame(width: diameter, height: diameter)
    }

    private var centre: some View {
        VStack(spacing: 3) {
            if let lane {
                ZStack {
                    Circle().fill(lane.status.color)
                        .shadow(color: lane.status.color.opacity(0.45), radius: 5)
                    Image(systemName: lane.status.symbol)
                        .font(StrandFont.rounded(diameter * 0.12, weight: .bold))
                        .foregroundStyle(StrandPalette.onDarkPrimary)
                }
                .frame(width: diameter * 0.25, height: diameter * 0.25)
                Text(lane.status.label)
                    .font(StrandFont.rounded(diameter * 0.105, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Self.ratioText(lane.ratio, band: lane.band))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Image(systemName: "hourglass")
                    .font(StrandFont.rounded(diameter * 0.12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Needs two weeks of measured history")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: diameter * 0.6)
    }

    // MARK: Geometry

    private func arc(from: Double, to: Double) -> RecoveryArc {
        RecoveryArc(startAngle: .degrees(startDegrees + spanDegrees * from),
                    spanDegrees: spanDegrees * max(to - from, 0), fraction: 1, lineWidth: lineWidth)
    }

    private func radians(_ fraction: Double) -> Double {
        (startDegrees + spanDegrees * fraction) * .pi / 180
    }

    private func point(_ angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: diameter / 2 + radius * cos(angle), y: diameter / 2 + radius * sin(angle))
    }
}

// MARK: - Zone legend

/// The four zones of the dial, one dot each.
struct LoadZoneLegend: View {
    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            ForEach([TrainingStatus.detraining, .maintaining, .productive, .overreaching], id: \.self) { status in
                HStack(spacing: 4) {
                    Circle().fill(status.color).frame(width: 9, height: 9)
                    Text(status.label)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Ratio chart

/// Eight weeks of the ratio per lane over the four zones — the dials' number, drawn as a history.
///
/// The zone bands are the same four colours as the dials, and 1.0 (your usual) is a dashed line, so a
/// build, a deload and a spike read at a glance. Values are clamped to the drawn range (0.4–1.8): a day
/// at 2.4 sits on the top edge rather than squashing every other day into a thin stripe.
struct LoadRatioChart: View {
    let points: [TrainingLoadModel.RatioPoint]

    private static let floor = 0.4
    private static let ceiling = 1.8

    private struct Sample: Identifiable {
        let date: Date
        let value: Double
        let lane: String
        var id: String { "\(lane)-\(date.timeIntervalSince1970)" }
    }

    private var strengthLabel: String { String(localized: "Strength") }
    private var cardioLabel: String { String(localized: "Cardio") }

    private var samples: [Sample] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return points.flatMap { point -> [Sample] in
            guard let date = parser.date(from: point.day) else { return [] }
            var out: [Sample] = []
            if let value = point.strength {
                out.append(Sample(date: date, value: min(max(value, Self.floor), Self.ceiling), lane: strengthLabel))
            }
            if let value = point.cardio {
                out.append(Sample(date: date, value: min(max(value, Self.floor), Self.ceiling), lane: cardioLabel))
            }
            return out
        }
    }

    var body: some View {
        Chart {
            band(Self.floor, TrainingStatusModel.detrainingBelow, TrainingStatus.detraining.color)
            band(TrainingStatusModel.detrainingBelow, TrainingStatusModel.productiveFrom, TrainingStatus.maintaining.color)
            band(TrainingStatusModel.productiveFrom, TrainingStatusModel.overreachingAbove, TrainingStatus.productive.color)
            band(TrainingStatusModel.overreachingAbove, Self.ceiling, TrainingStatus.overreaching.color)
            RuleMark(y: .value("Usual", 1.0))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(samples) { sample in
                LineMark(x: .value("Day", sample.date), y: .value("Ratio", sample.value),
                         series: .value("Lane", sample.lane))
                    .foregroundStyle(by: .value("Lane", sample.lane))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            }
        }
        // Two clearly different hues: amber and the Effort colour are both orange in the Health style.
        .chartForegroundStyleScale([strengthLabel: StrandPalette.metricPurple,
                                    cardioLabel: StrandPalette.effortColor])
        .chartYScale(domain: Self.floor...Self.ceiling)
        // Room at the trailing edge so the last date label is not cut off.
        .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 18))
        .chartYAxis {
            AxisMarks(position: .leading, values: [TrainingStatusModel.detrainingBelow,
                                                   TrainingStatusModel.productiveFrom,
                                                   TrainingStatusModel.overreachingAbove]) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number, format: .number.precision(.fractionLength(1)))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 190)
        .accessibilityLabel(Text("Load against your usual"))
    }

    private func band(_ from: Double, _ to: Double, _ color: Color) -> some ChartContent {
        RectangleMark(yStart: .value("From", from), yEnd: .value("To", to))
            .foregroundStyle(color.opacity(0.16))
    }
}

// MARK: - Direction bar

/// Rising / unclear / falling lifts as one capsule, each part as wide as its share.
struct DirectionBar: View {
    let rising: Int
    let unclear: Int
    let falling: Int

    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(rising + unclear + falling, 1))
            let parts = [(rising, StrandPalette.statusPositive), (unclear, StrandPalette.textTertiary),
                         (falling, StrandPalette.statusCritical)].filter { $0.0 > 0 }
            let gaps = CGFloat(max(parts.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle()
                        .fill(part.1)
                        .frame(width: max(0, (geo.size.width - gaps) * CGFloat(part.0) / total))
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

// MARK: - VO₂max sparkline

/// Eight weeks of VO₂max: a soft area, the line, a dot per reading. No axes — the number and the chip
/// above it carry the values; this carries the shape.
struct VO2maxSparkline: View {
    let readings: [VO2maxReading]
    let color: Color

    private struct Point: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    private var points: [Point] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return readings.compactMap { reading in
            parser.date(from: reading.day).map { Point(date: $0, value: reading.value) }
        }
    }

    var body: some View {
        let values = readings.map(\.value)
        let low = (values.min() ?? 0) - 1
        let high = (values.max() ?? 1) + 1
        return Chart(points) { point in
            AreaMark(x: .value("Day", point.date), yStart: .value("Low", low), yEnd: .value("VO2max", point.value))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Day", point.date), y: .value("VO2max", point.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.catmullRom)
            PointMark(x: .value("Day", point.date), y: .value("VO2max", point.value))
                .foregroundStyle(color)
                .symbolSize(30)
        }
        .chartYScale(domain: low...high)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 80)
        .accessibilityHidden(true)
    }
}

// MARK: - History strip

/// Eight weeks, one cell per week and lane, each in the status it had AT THE TIME.
struct StatusHistoryStrip: View {
    let history: [TrainingStatusModel.WeeklyStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(symbol: "figure.strengthtraining.traditional", title: "Strength") { $0.strength }
            row(symbol: "heart.fill", title: "Cardio") { $0.cardio }
            HStack {
                if let first = history.first { Text(Self.shortDate(first.day)) }
                Spacer()
                Text("This week")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.leading, 24)
        }
    }

    private func row(symbol: String, title: LocalizedStringKey,
                     status: @escaping (TrainingStatusModel.WeeklyStatus) -> TrainingStatus?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 20)
            ForEach(Array(history.enumerated()), id: \.offset) { index, week in
                cell(status(week), isCurrent: index == history.count - 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(history.map { status($0)?.label ?? "—" }.joined(separator: ", ")))
    }

    private func cell(_ status: TrainingStatus?, isCurrent: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(status?.color ?? StrandPalette.surfaceInset)
            .overlay {
                if let status {
                    Image(systemName: status.symbol)
                        .font(StrandFont.rounded(9, weight: .bold))
                        .foregroundStyle(StrandPalette.onDarkPrimary)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isCurrent ? StrandPalette.textPrimary.opacity(0.55) : Color.clear,
                              lineWidth: 1.5))
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
    }

    /// "2026-07-20" → "20 Jul", in the wearer's locale.
    static func shortDate(_ day: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
