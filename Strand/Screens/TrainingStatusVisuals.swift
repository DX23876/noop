import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - How a Training Load status looks
//
// The status itself is decided in `TrainingStatusModel`; this file only draws it. Every colour comes
// from the palette's own tokens, so the dial follows whichever chart style the wearer picked instead of
// carrying a second colour world of its own. The four zones form one cool-to-hot ramp:
//
//   below usual (detraining / recovering) → restColor       the calm, cool end: less than usual
//   maintaining                           → metricCyan      steady, on the way to productive
//   productive                            → statusPositive
//   unproductive (strength only)          → statusWarning   work without return
//   overreaching                          → statusCritical
//
// The drawing leans on what the platform offers — a drifting mesh-gradient backdrop (iOS 18 /
// macOS 15), symbol effects, chart selection, donut sectors and scroll transitions (iOS 17 / macOS 14)
// — each behind an availability gate with a plain fallback, because the app still ships macOS 13.

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
        case .detraining, .recovering: return StrandPalette.restColor
        case .maintaining:             return StrandPalette.metricCyan
        case .productive:              return StrandPalette.statusPositive
        case .unproductive:            return StrandPalette.statusWarning
        case .overreaching:            return StrandPalette.statusCritical
        }
    }
}

extension TrainingLoadBand {
    /// The zone's colour — the colour of the status that zone stands for on Polar's scale.
    var color: Color {
        switch self {
        case .below:       return TrainingStatus.detraining.color
        case .maintaining: return TrainingStatus.maintaining.color
        case .productive:  return TrainingStatus.productive.color
        case .above:       return TrainingStatus.overreaching.color
        }
    }
}

// MARK: - The scale

/// The dial's 0.5–1.6 scale and the one colour ramp drawn along it.
enum LoadScale {
    static let low = 0.5
    static let high = 1.6

    static func fraction(for ratio: Double) -> Double {
        min(max((ratio - low) / (high - low), 0), 1)
    }

    /// The four zone colours as one ramp, with a short blend at each threshold: the ring reads as one
    /// instrument rather than four pieces stuck together, and every zone still keeps its own colour.
    /// An orange lift just past 1.3 is the ramp heating up into the red.
    static var rampStops: [Gradient.Stop] {
        let blend = 0.022
        let toMaintaining = fraction(for: TrainingStatusModel.detrainingBelow)
        let toProductive = fraction(for: TrainingStatusModel.productiveFrom)
        let toOverreaching = fraction(for: TrainingStatusModel.overreachingAbove)
        return [
            .init(color: TrainingLoadBand.below.color, location: 0),
            .init(color: TrainingLoadBand.below.color, location: toMaintaining - blend),
            .init(color: TrainingLoadBand.maintaining.color, location: toMaintaining + blend),
            .init(color: TrainingLoadBand.maintaining.color, location: toProductive - blend),
            .init(color: TrainingLoadBand.productive.color, location: toProductive + blend),
            .init(color: TrainingLoadBand.productive.color, location: toOverreaching - blend),
            .init(color: StrandPalette.metricAmber, location: toOverreaching + 0.012),
            .init(color: TrainingLoadBand.above.color, location: toOverreaching + 0.07),
            .init(color: TrainingLoadBand.above.color, location: 1),
        ]
    }
}

// MARK: - The dial

/// A 240° dial on Polar's scale: the ramp as a faint rail, lit up to the lane's ratio, with a knob at
/// the ratio and the status in the middle.
///
/// The lit part is "how much you did compared with your usual": at 0.79 only the cool end glows, at
/// 1.2 the ring glows through to green. Gaps at 0.8 / 1.0 / 1.3 keep the zones countable. The scale
/// runs from 0.5 to 1.6: wide enough for every zone to have room, and a ratio beyond it parks the knob
/// at the end — the number in the centre is always the exact one.
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
    @State private var shownRatio: Double = 0
    @State private var bounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lineWidth: CGFloat = 14
    /// Room outside the ring for the 0.8 / 1.0 / 1.3 labels.
    private let labelInset: CGFloat = 15
    private let startDegrees = 150.0
    private let spanDegrees = 240.0

    static func fraction(for ratio: Double) -> Double { LoadScale.fraction(for: ratio) }

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

    private var ringRadius: CGFloat { (diameter - 2 * labelInset - lineWidth) / 2 }
    private var statusColor: Color { lane?.status.color ?? StrandPalette.textTertiary }

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
            let ratio = lane?.ratio ?? 0
            if reduceMotion {
                shownFraction = target
                shownRatio = ratio
            } else {
                withAnimation(StrandMotion.drawIn) {
                    shownFraction = target
                    shownRatio = ratio
                }
                // The glyph lands with a small bounce once the ring has filled.
                try? await Task.sleep(nanoseconds: 650_000_000)
                bounce += 1
            }
        }
    }

    private var accessibilityValue: String {
        guard let lane else { return String(localized: "Needs two weeks of measured history") }
        return "\(lane.status.label), \(Self.ratioText(lane.ratio, band: lane.band))"
    }

    // MARK: Layers

    private var ramp: AngularGradient {
        AngularGradient(stops: LoadScale.rampStops, center: .center,
                        startAngle: .degrees(startDegrees), endAngle: .degrees(startDegrees + spanDegrees))
    }

    private var dial: some View {
        ZStack {
            // Light from the ring pooling in the middle, in the status colour.
            Circle()
                .fill(RadialGradient(colors: [statusColor.opacity(0.20), statusColor.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: diameter * 0.34))
                .padding(labelInset + lineWidth)
            rings
            ticks
            if lane != nil { knob }
        }
    }

    /// Rail, glow and lit arc, with real gaps cut at the thresholds so whatever sits behind the card
    /// shows through them.
    private var rings: some View {
        ZStack {
            arc(from: 0, to: 1)
                .stroke(StrandPalette.surfaceInset,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                           dash: lane == nil ? [2, 5] : []))
            if lane != nil {
                arc(from: 0, to: 1)
                    .stroke(ramp, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .opacity(0.24)
                arc(from: 0, to: shownFraction)
                    .stroke(ramp, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .blur(radius: 7)
                    .opacity(0.6)
                arc(from: 0, to: shownFraction)
                    .stroke(ramp, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            separators.blendMode(.destinationOut)
        }
        .padding(labelInset)
        .compositingGroup()
    }

    private var separators: some View {
        let inner = ringRadius - lineWidth / 2 - 2
        let outer = ringRadius + lineWidth / 2 + 2
        return Path { path in
            for value in [TrainingStatusModel.detrainingBelow, TrainingStatusModel.productiveFrom,
                          TrainingStatusModel.overreachingAbove] {
                let angle = radians(Self.fraction(for: value))
                path.move(to: point(angle, radius: inner, inset: labelInset))
                path.addLine(to: point(angle, radius: outer, inset: labelInset))
            }
        }
        // A mask: `destinationOut` only reads the stroke's coverage, so any opaque colour cuts the gap.
        .stroke(StrandPalette.textPrimary, lineWidth: 2.5)
    }

    /// Labels at Polar's three thresholds, outside the ring. A label the knob is sitting on steps
    /// aside rather than being drawn under it.
    private var ticks: some View {
        ZStack {
            ForEach([TrainingStatusModel.detrainingBelow, TrainingStatusModel.productiveFrom,
                     TrainingStatusModel.overreachingAbove], id: \.self) { value in
                let fraction = Self.fraction(for: value)
                Text(value, format: .number.precision(.fractionLength(1)))
                    .font(StrandFont.rounded(8.5, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .position(point(radians(fraction), radius: ringRadius + lineWidth / 2 + 8))
                    .opacity(lane != nil && abs(shownFraction - fraction) < 0.05 ? 0 : 1)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    /// The ratio's position: a light knob with the status colour at its core, the way the Activity
    /// rings mark their end.
    private var knob: some View {
        Circle()
            .fill(StrandPalette.onDarkPrimary)
            .frame(width: lineWidth + 8, height: lineWidth + 8)
            .overlay(Circle().fill(statusColor.gradient).padding(4.5))
            .shadow(color: statusColor.opacity(0.8), radius: 7)
            .position(point(radians(shownFraction), radius: ringRadius))
            .frame(width: diameter, height: diameter)
    }

    private var centre: some View {
        VStack(spacing: 3) {
            if let lane {
                StatusBadge(symbol: lane.status.symbol, color: lane.status.color, size: diameter * 0.26,
                            bounceTrigger: bounce)
                Text(lane.status.label)
                    .font(StrandFont.rounded(diameter * 0.1, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // Narrower than the ring's opening, so a long word shrinks instead of touching it.
                    .frame(maxWidth: diameter * 0.52)
                RatioReadout(value: shownRatio, band: lane.band)
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

    private func point(_ angle: Double, radius: CGFloat, inset: CGFloat = 0) -> CGPoint {
        let centre = diameter / 2 - inset
        return CGPoint(x: centre + radius * cos(angle), y: centre + radius * sin(angle))
    }
}

/// The ratio as a number that rolls to its value, rounded toward its zone at every frame so even the
/// numbers passed on the way never contradict the word above them.
private struct RatioReadout: View, Animatable {
    var value: Double
    let band: TrainingLoadBand

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: LoadStatusRing.ratioText(value, band: band))
            .monospacedDigit()
    }
}

/// A number that rolls to its value, in the wearer's locale. (The Liquid `CountUpNumber` always prints
/// a full stop, which reads wrong in German.)
struct TrainingCountUp: View, Animatable {
    var value: Double
    var decimals: Int = 0

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: value.formatted(.number.precision(.fractionLength(decimals))))
            .monospacedDigit()
    }
}

// MARK: - Surfaces

/// The hero's surface: a card lit from above by the two lanes' status colours — strength from the
/// left, cardio from the right — so the page's answer is the first thing the eye picks up.
struct TrainingHeroSurface: View {
    let leading: Color
    let trailing: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        ZStack {
            shape.fill(StrandPalette.surfaceRaised)
            StatusGlow(leading: leading, trailing: trailing).clipShape(shape)
        }
        .overlay(shape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .shadow(color: leading.opacity(0.16), radius: 18, x: -8, y: 10)
        .shadow(color: trailing.opacity(0.16), radius: 18, x: 8, y: 10)
    }
}

/// Two soft pools of colour. A slowly drifting mesh gradient where the OS has one; two radial
/// gradients before that. Posed still under Reduce Motion, Low Power, quiet motion and off-screen.
private struct StatusGlow: View {
    let leading: Color
    let trailing: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dashboardIsActive) private var dashboardIsActive
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var isVisible = true

    var body: some View {
        content.dashboardAnimationVisibility($isVisible)
    }

    @ViewBuilder private var content: some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            if isVisible && dashboardIsActive && scenePhase == .active && !motion.poseStill(reduceMotion) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    MeshGlow(leading: leading, trailing: trailing,
                             phase: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                MeshGlow(leading: leading, trailing: trailing, phase: 0)
            }
        } else {
            ZStack {
                RadialGradient(colors: [leading.opacity(0.38), leading.opacity(0)],
                               center: .topLeading, startRadius: 0, endRadius: 300)
                RadialGradient(colors: [trailing.opacity(0.38), trailing.opacity(0)],
                               center: .topTrailing, startRadius: 0, endRadius: 300)
            }
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct MeshGlow: View {
    let leading: Color
    let trailing: Color
    let phase: Double

    var body: some View {
        let drift = Float(sin(phase * 0.42) * 0.08)
        let lift = Float(cos(phase * 0.31) * 0.06)
        let clear = StrandPalette.surfaceRaised.opacity(0)
        let points: [SIMD2<Float>] = [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.42 + lift], [0.5 + drift, 0.38 - lift], [1, 0.42 - lift],
            [0, 1], [0.5, 1], [1, 1],
        ]
        let colors: [Color] = [
            leading.opacity(0.46), clear, trailing.opacity(0.46),
            leading.opacity(0.16), clear, trailing.opacity(0.16),
            clear, clear, clear,
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: colors)
    }
}

/// A card washed in one colour, for the page's statements — the advice, the warning. An optional
/// large symbol sits in the corner as a watermark.
struct TrainingWashCard<Content: View>: View {
    let color: Color
    var watermark: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        content()
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The watermark sits in an overlay so its size never feeds back into the card's: in a
                // ZStack the large symbol grew the background past the content and over its neighbours.
                ZStack {
                    shape.fill(StrandPalette.surfaceRaised)
                    shape.fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.06)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay(alignment: .topTrailing) {
                    if let watermark {
                        Image(systemName: watermark)
                            .font(StrandFont.rounded(92, weight: .bold))
                            .foregroundStyle(color.opacity(0.14))
                            .rotationEffect(.degrees(-12))
                            .offset(x: 20, y: -16)
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(color.opacity(0.35), lineWidth: 1))
                .shadow(color: color.opacity(0.14), radius: 12, y: 6)
            }
    }
}

/// A filled symbol badge: the colour as a soft vertical gradient with a gloss from above, the glyph in
/// white. A circle by default, a squircle when given a corner radius.
struct StatusBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32
    var cornerRadius: CGFloat? = nil
    /// Each change bounces the glyph once (iOS 17 / macOS 14).
    var bounceTrigger: Int = 0
    /// Pulses the glyph for as long as it is true — for a signal that asks for attention.
    var pulses: Bool = false

    private var shape: AnyShape {
        if let cornerRadius { return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
        return AnyShape(Circle())
    }

    var body: some View {
        ZStack {
            shape.fill(color.gradient)
            shape.fill(LinearGradient(colors: [StrandPalette.onDarkPrimary.opacity(0.34),
                                               StrandPalette.onDarkPrimary.opacity(0)],
                                      startPoint: .top, endPoint: .center))
            Image(systemName: symbol)
                .font(StrandFont.rounded(size * 0.44, weight: .bold))
                .foregroundStyle(StrandPalette.onDarkPrimary)
                .trainingSymbolBounce(trigger: bounceTrigger)
                .trainingSymbolPulse(pulses)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.42), radius: size * 0.14, y: size * 0.06)
        .accessibilityHidden(true)
    }
}

// MARK: - Zone legend

/// The four zones of the dial, one dot each.
struct LoadZoneLegend: View {
    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            ForEach([TrainingStatus.detraining, .maintaining, .productive, .overreaching], id: \.self) { status in
                HStack(spacing: 4) {
                    Circle().fill(status.color.gradient).frame(width: 9, height: 9)
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

/// Eight weeks of one lane's ratio, the line coloured by the zone it is in, over faint zone bands.
///
/// Touching the chart reads out any day (iOS 17 / macOS 14); without a touch the readout is the latest
/// day. One lane at a time: with the line coloured by zone, two lines would be two lines in the same
/// colours. Values are clamped to the drawn range (0.4–1.8): a day at 2.4 sits on the top edge rather
/// than squashing every other day into a thin stripe.
struct LoadRatioChart: View {
    let points: [TrainingLoadModel.RatioPoint]

    enum Lane: Hashable { case strength, cardio }

    struct Sample: Equatable {
        let date: Date
        let value: Double
    }

    /// A run of the line inside one zone, from threshold to threshold.
    struct Segment: Identifiable, Equatable {
        let id: Int
        let band: TrainingLoadBand
        let samples: [Sample]
    }

    @State private var lane: Lane = .strength
    @State private var selection: Date?

    static let floor = 0.4
    static let ceiling = 1.8

    /// The lane's days, oldest first; nil where the day had no comparison yet.
    private var days: [Sample?] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return points.map { point -> Sample? in
            guard let date = parser.date(from: point.day),
                  let value = lane == .strength ? point.strength : point.cardio else { return nil }
            return Sample(date: date, value: value)
        }
    }

    /// Splits the line where it crosses 0.8, 1.0 or 1.3, so each piece can take its zone's colour.
    ///
    /// A crossing gets its own point exactly on the threshold, interpolated in time, and that point
    /// ends one piece and starts the next — so the coloured line is continuous and changes colour on
    /// the threshold, not halfway between two days. A day without a comparison breaks the line.
    static func zoneSegments(_ days: [Sample?]) -> [Segment] {
        let thresholds = [TrainingStatusModel.detrainingBelow, TrainingStatusModel.productiveFrom,
                          TrainingStatusModel.overreachingAbove]
        let bands: [TrainingLoadBand] = [.below, .maintaining, .productive, .above]
        var segments: [Segment] = []
        var current: [Sample] = []
        var currentBand: TrainingLoadBand?
        var previous: Sample?

        func close() {
            if let band = currentBand, !current.isEmpty {
                segments.append(Segment(id: segments.count, band: band, samples: current))
            }
            current = []
            currentBand = nil
        }

        for day in days {
            guard let sample = day else {
                close()
                previous = nil
                continue
            }
            let band = TrainingStatusModel.band(ratio: sample.value)
            if let last = previous, let lastBand = currentBand, band != lastBand,
               let from = bands.firstIndex(of: lastBand), let to = bands.firstIndex(of: band) {
                let rising = from < to
                let crossed = rising ? Array(from..<to) : Array((to..<from).reversed())
                for index in crossed {
                    let threshold = thresholds[index]
                    let span = sample.value - last.value
                    let share = span == 0 ? 0 : min(max((threshold - last.value) / span, 0), 1)
                    let edge = Sample(date: last.date.addingTimeInterval(sample.date.timeIntervalSince(last.date) * share),
                                      value: threshold)
                    if current.last != edge { current.append(edge) }
                    let next = rising ? bands[index + 1] : bands[index]
                    close()
                    current = [edge]
                    currentBand = next
                }
            }
            if current.last != sample { current.append(sample) }
            currentBand = band
            previous = sample
        }
        close()
        return segments
    }

    var body: some View {
        let days = days
        let samples = days.compactMap { $0 }
        let focus = focusSample(in: samples)
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            header(focus)
            Picker("Load against your usual", selection: $lane) {
                Text("Strength").tag(Lane.strength)
                Text("Cardio").tag(Lane.cardio)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            chart(samples: samples, segments: Self.zoneSegments(days), focus: focus)
        }
    }

    /// The touched day, or the latest one.
    private func focusSample(in samples: [Sample]) -> Sample? {
        guard let selection else { return samples.last }
        return samples.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    private func header(_ focus: Sample?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Load against your usual")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            if let focus {
                let band = TrainingStatusModel.band(ratio: focus.value)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: LoadStatusRing.ratioText(focus.value, band: band))
                        .font(StrandFont.number(17, weight: .bold))
                        .foregroundStyle(band.color)
                        .contentTransition(.numericText())
                    Text(focus.date, format: .dateTime.day().month(.abbreviated))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .animation(NoopMotion.value, value: focus.date)
            }
        }
    }

    private func clamped(_ value: Double) -> Double { min(max(value, Self.floor), Self.ceiling) }

    private func chart(samples: [Sample], segments: [Segment], focus: Sample?) -> some View {
        let tint = samples.last.map { TrainingStatusModel.band(ratio: $0.value).color } ?? StrandPalette.textTertiary
        return Chart {
            band(Self.floor, TrainingStatusModel.detrainingBelow, TrainingLoadBand.below.color)
            band(TrainingStatusModel.detrainingBelow, TrainingStatusModel.productiveFrom, TrainingLoadBand.maintaining.color)
            band(TrainingStatusModel.productiveFrom, TrainingStatusModel.overreachingAbove, TrainingLoadBand.productive.color)
            band(TrainingStatusModel.overreachingAbove, Self.ceiling, TrainingLoadBand.above.color)
            RuleMark(y: .value("Usual", 1.0))
                .foregroundStyle(StrandPalette.textSecondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                AreaMark(x: .value("Day", sample.date), yStart: .value("Floor", Self.floor),
                         yEnd: .value("Ratio", clamped(sample.value)))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.26), tint.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            // A soft wide stroke under the line first, then the line, both in the zone's colour.
            ForEach(segments) { segment in
                ForEach(Array(segment.samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(x: .value("Day", sample.date), y: .value("Ratio", clamped(sample.value)),
                             series: .value("Zone", "glow-\(segment.id)"))
                        .foregroundStyle(segment.band.color.opacity(0.22))
                        .lineStyle(StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(segments) { segment in
                ForEach(Array(segment.samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(x: .value("Day", sample.date), y: .value("Ratio", clamped(sample.value)),
                             series: .value("Zone", "line-\(segment.id)"))
                        .foregroundStyle(segment.band.color)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let focus {
                if selection != nil {
                    RuleMark(x: .value("Day", focus.date))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                PointMark(x: .value("Day", focus.date), y: .value("Ratio", clamped(focus.value)))
                    .symbol {
                        FocusDot(color: TrainingStatusModel.band(ratio: focus.value).color)
                    }
            }
        }
        .chartYScale(domain: Self.floor...Self.ceiling)
        // Room at the trailing edge so the last date label and the focus dot are not cut off.
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
        .chartLegend(.hidden)
        .trainingChartSelection($selection)
        .liquidSelectionHaptic(trigger: focus?.date)
        .animation(NoopMotion.card, value: lane)
        .frame(height: 190)
        .accessibilityLabel(Text("Load against your usual"))
    }

    private func band(_ from: Double, _ to: Double, _ color: Color) -> some ChartContent {
        RectangleMark(yStart: .value("From", from), yEnd: .value("To", to))
            .foregroundStyle(color.opacity(0.08))
    }
}

/// The focused point on a line: the colour with a rim in the card colour and a soft halo.
private struct FocusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(StrandPalette.surfaceRaised, lineWidth: 2.5))
            .background(Circle().fill(color.opacity(0.25)).frame(width: 28, height: 28))
    }
}

// MARK: - Lift directions

/// Rising / unclear / falling lifts as one capsule, each part as wide as its share. The fallback for
/// the donut below macOS 14.
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
                        .fill(part.1.gradient)
                        .frame(width: max(0, (geo.size.width - gaps) * CGFloat(part.0) / total))
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// The same three counts as a donut, the number of lifts in the middle.
@available(iOS 17.0, macOS 14.0, *)
struct LiftDirectionDonut: View {
    let rising: Int
    let unclear: Int
    let falling: Int

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Part: Identifiable {
        let id: String
        let count: Int
        let color: Color
    }

    private var parts: [Part] {
        [Part(id: "rising", count: rising, color: StrandPalette.statusPositive),
         Part(id: "unclear", count: unclear, color: StrandPalette.textTertiary),
         Part(id: "falling", count: falling, color: StrandPalette.statusCritical)].filter { $0.count > 0 }
    }

    var body: some View {
        let parts = parts
        ZStack {
            Chart(parts) { part in
                SectorMark(angle: .value("Lifts", part.count), innerRadius: .ratio(0.66),
                           angularInset: parts.count > 1 ? 2 : 0)
                    .cornerRadius(5)
                    .foregroundStyle(part.color.gradient)
            }
            .chartLegend(.hidden)
            .rotationEffect(.degrees(appeared ? 0 : -120))
            .scaleEffect(appeared ? 1 : 0.82)
            .opacity(appeared ? 1 : 0)
            VStack(spacing: 0) {
                Text(verbatim: "\(rising + unclear + falling)")
                    .font(StrandFont.number(28, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Lifts")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(StrandMotion.hero) { appeared = true }
            }
        }
    }
}

// MARK: - VO₂max chart

/// Eight weeks of VO₂max: a soft area, a line that brightens toward today, the first reading as a
/// dashed baseline and the latest as a lit point. No axes — the number and the chip above it carry the
/// values; this carries the shape and how far it moved from where the window began.
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
        let points = points
        let values = points.map(\.value)
        let low = (values.min() ?? 0) - 1.5
        let high = (values.max() ?? 1) + 1.5
        return Chart {
            if let first = points.first {
                RuleMark(y: .value("Start", first.value))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            ForEach(points) { point in
                AreaMark(x: .value("Day", point.date), yStart: .value("Low", low),
                         yEnd: .value("VO2max", point.value))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.34), color.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", point.date), y: .value("VO2max", point.value))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.5), color],
                                                    startPoint: .leading, endPoint: .trailing))
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = points.last {
                PointMark(x: .value("Day", last.date), y: .value("VO2max", last.value))
                    .symbol { FocusDot(color: color) }
            }
        }
        .chartYScale(domain: low...high)
        .chartXScale(range: .plotDimension(startPadding: 6, endPadding: 14))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 110)
        .accessibilityHidden(true)
    }
}

// MARK: - Small instruments

/// How many of the recent nights flagged: one pill per night, strained ones first. A count, not a
/// timeline — the reading does not keep which night flagged.
struct NightsMeter: View {
    let strained: Int
    let read: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Capsule()
                    .fill(color(index).gradient)
                    .frame(height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ index: Int) -> Color {
        if index < strained { return StrandPalette.statusWarning }
        if index < read { return StrandPalette.statusPositive }
        return StrandPalette.surfaceInset
    }
}

/// A small ring filled to a share, the lane's symbol in the middle — how much of a figure is measured.
struct CoverageRing: View {
    let fraction: Double
    let color: Color
    let symbol: String

    var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.surfaceInset, lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(StrandFont.rounded(12, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }
}

// MARK: - History strip

/// Eight weeks, one cell per week and lane, each in the status it had AT THE TIME.
struct StatusHistoryStrip: View {
    let history: [TrainingStatusModel.WeeklyStatus]

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // The cells pop in one after another; each cell's animation is gated on Reduce Motion.
        .onAppear { appeared = true }
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
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
                    .animation(reduceMotion ? nil : NoopMotion.card.delay(Double(index) * NoopMotion.stagger * 1.5),
                               value: appeared)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(history.map { status($0)?.label ?? "—" }.joined(separator: ", ")))
    }

    private func cell(_ status: TrainingStatus?, isCurrent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ZStack {
            if let status {
                shape.fill(status.color.gradient)
                shape.fill(LinearGradient(colors: [StrandPalette.onDarkPrimary.opacity(0.3),
                                                   StrandPalette.onDarkPrimary.opacity(0)],
                                          startPoint: .top, endPoint: .center))
                Image(systemName: status.symbol)
                    .font(StrandFont.rounded(9.5, weight: .bold))
                    .foregroundStyle(StrandPalette.onDarkPrimary)
            } else {
                shape.fill(StrandPalette.surfaceInset)
            }
        }
        .overlay(shape.strokeBorder(isCurrent ? StrandPalette.textPrimary.opacity(0.7) : Color.clear,
                                    lineWidth: 1.5)
            .padding(-2.5))
        .shadow(color: isCurrent ? (status?.color ?? Color.clear).opacity(0.55) : Color.clear, radius: 5)
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
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

// MARK: - Availability shims
//
// Each is a no-op where the effect does not exist: the view renders, it just does not move.

extension View {
    /// Bounces an SF Symbol once per change of `trigger` (iOS 17 / macOS 14).
    @ViewBuilder func trainingSymbolBounce(trigger: Int) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.symbolEffect(.bounce, value: trigger)
        } else {
            self
        }
    }

    /// Pulses an SF Symbol while `active` (iOS 17 / macOS 14).
    @ViewBuilder func trainingSymbolPulse(_ active: Bool) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.symbolEffect(.pulse, options: .repeating, isActive: active)
        } else {
            self
        }
    }

    /// Lets a chart be touched to read out a day (iOS 17 / macOS 14).
    @ViewBuilder func trainingChartSelection(_ selection: Binding<Date?>) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.chartXSelection(value: selection)
        } else {
            self
        }
    }

    /// Cards rise and settle as they scroll in from below; leaving at the top, they stay put so a card
    /// being read is never faded (iOS 17 / macOS 14).
    @ViewBuilder func trainingCardEntrance() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.scrollTransition(topLeading: .identity, bottomTrailing: .interactive) { content, phase in
                content
                    .opacity(phase.isIdentity ? 1 : 0.65)
                    .scaleEffect(phase.isIdentity ? 1 : 0.96)
                    .offset(y: phase.isIdentity ? 0 : 12)
            }
        } else {
            self
        }
    }
}
