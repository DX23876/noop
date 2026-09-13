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

// MARK: - The instrument

/// Both lanes on one 240° scale: strength on the outer arc, cardio on the inner one.
///
/// Sharing the scale is the point — "further round" means the same thing on both arcs, so the two lanes
/// can be compared at a glance instead of by reading two separate dials. What the ring deliberately does
/// NOT do is merge them: each arc keeps its own knob, its own lit length and its own word in the middle,
/// because a lifting week and a running week are measured in different units and this fork's decision log
/// rules out a single blended score.
///
/// Each knob carries its lane's own symbol, and the rows beneath the ring repeat that symbol — that is
/// what maps an arc to a lane without a legend. Gaps at 0.8 / 1.0 / 1.3 keep the zones countable, and a
/// ratio past either end parks the knob there while the number beside it stays exact.
struct LoadDualRing: View {
    let strength: LaneStatus?
    let cardio: LaneStatus?
    var diameter: CGFloat = 252

    @State private var shownStrength: Double = 0
    @State private var shownCardio: Double = 0
    @State private var bounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let outerWidth: CGFloat = 15
    private let innerWidth: CGFloat = 12
    /// Wide enough that the two knobs never fuse into one blob when both lanes sit at the same ratio.
    private let ringGap: CGFloat = 10
    /// Room outside the outer ring for the 0.8 / 1.0 / 1.3 labels.
    private let labelInset: CGFloat = 16
    private let startDegrees = 150.0
    private let spanDegrees = 240.0

    private var thresholds: [Double] {
        [TrainingStatusModel.detrainingBelow, TrainingStatusModel.productiveFrom,
         TrainingStatusModel.overreachingAbove]
    }

    private var outerRadius: CGFloat { (diameter - 2 * labelInset - outerWidth) / 2 }
    private var innerRadius: CGFloat { outerRadius - outerWidth / 2 - ringGap - innerWidth / 2 }
    /// The padding that puts `RecoveryArc` on the inner radius, given it insets by half its own width.
    private var innerPadding: CGFloat { (diameter - innerWidth) / 2 - innerRadius }

    var body: some View {
        ZStack {
            glow
            rings
            ticks
            knobs
            centre
        }
        .frame(width: diameter, height: diameter)
        // The 240° arc leaves the bottom sixth of its square empty; pull what follows up into it rather
        // than leaving a gap under the instrument.
        .padding(.bottom, -diameter * 0.13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Training Load"))
        .accessibilityValue(Text(accessibilityValue))
        .task(id: "\(strength?.ratio ?? -1)|\(cardio?.ratio ?? -1)") {
            let outer = strength.map { LoadScale.fraction(for: $0.ratio) } ?? 0
            let inner = cardio.map { LoadScale.fraction(for: $0.ratio) } ?? 0
            if reduceMotion {
                shownStrength = outer
                shownCardio = inner
            } else {
                withAnimation(StrandMotion.drawIn) {
                    shownStrength = outer
                    shownCardio = inner
                }
                // The glyphs land once both arcs have filled.
                try? await Task.sleep(nanoseconds: 650_000_000)
                bounce += 1
            }
        }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let strength {
            parts.append("\(String(localized: "Strength")): \(strength.status.label), "
                         + LoadScale.ratioText(strength.ratio, band: strength.band))
        }
        if let cardio {
            parts.append("\(String(localized: "Cardio")): \(cardio.status.label), "
                         + LoadScale.ratioText(cardio.ratio, band: cardio.band))
        }
        return parts.isEmpty ? String(localized: "Needs two weeks of measured history")
                             : parts.joined(separator: ", ")
    }

    // MARK: Layers

    private var ramp: AngularGradient {
        AngularGradient(stops: LoadScale.rampStops, center: .center,
                        startAngle: .degrees(startDegrees), endAngle: .degrees(startDegrees + spanDegrees))
    }

    /// Light pooling in the middle, in whichever verdicts exist. Two lanes means two washes, which is
    /// what gives the centre its colour without printing a third, invented status there.
    private var glow: some View {
        ZStack {
            if let strength {
                Circle().fill(RadialGradient(
                    colors: [strength.status.color.opacity(0.26), strength.status.color.opacity(0)],
                    center: .center, startRadius: 0, endRadius: diameter * 0.38))
            }
            if let cardio {
                Circle().fill(RadialGradient(
                    colors: [cardio.status.color.opacity(0.22), cardio.status.color.opacity(0)],
                    center: .center, startRadius: 0, endRadius: diameter * 0.28))
            }
        }
        .padding(labelInset + outerWidth)
    }

    /// Rail, glow and lit arc per lane, with real gaps cut at the thresholds so the card's own surface
    /// shows through them.
    private var rings: some View {
        ZStack {
            laneArcs(lane: strength, fraction: shownStrength, width: outerWidth, padding: labelInset)
            laneArcs(lane: cardio, fraction: shownCardio, width: innerWidth, padding: innerPadding)
            separators.blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    private func laneArcs(lane: LaneStatus?, fraction: Double,
                          width: CGFloat, padding: CGFloat) -> some View {
        ZStack {
            arc(from: 0, to: 1, width: width)
                .stroke(StrandPalette.surfaceInset,
                        style: StrokeStyle(lineWidth: width, lineCap: .round,
                                           dash: lane == nil ? [2, 5] : []))
            if lane != nil {
                arc(from: 0, to: 1, width: width)
                    .stroke(ramp, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .opacity(0.26)
                arc(from: 0, to: fraction, width: width)
                    .stroke(ramp, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .blur(radius: 8)
                    .opacity(0.7)
                arc(from: 0, to: fraction, width: width)
                    .stroke(ramp, style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .padding(padding)
    }

    private var separators: some View {
        let from = innerRadius - innerWidth / 2 - 2
        let to = outerRadius + outerWidth / 2 + 2
        return Path { path in
            for value in thresholds {
                let angle = radians(LoadScale.fraction(for: value))
                path.move(to: point(angle, radius: from))
                path.addLine(to: point(angle, radius: to))
            }
        }
        // A mask: `destinationOut` only reads the stroke's coverage, so any opaque colour cuts the gap.
        .stroke(StrandPalette.textPrimary, lineWidth: 2.5)
        .frame(width: diameter, height: diameter)
    }

    /// Labels at Polar's three thresholds, outside the outer ring. A label a knob is sitting on steps
    /// aside rather than being drawn under it.
    private var ticks: some View {
        ZStack {
            ForEach(thresholds, id: \.self) { value in
                let fraction = LoadScale.fraction(for: value)
                Text(value, format: .number.precision(.fractionLength(1)))
                    .font(StrandFont.rounded(9, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .position(point(radians(fraction), radius: outerRadius + outerWidth / 2 + 9))
                    .opacity(coveredByKnob(fraction) ? 0 : 1)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func coveredByKnob(_ fraction: Double) -> Bool {
        (strength != nil && abs(shownStrength - fraction) < 0.05)
            || (cardio != nil && abs(shownCardio - fraction) < 0.05)
    }

    /// Each lane's position, carrying that lane's own symbol — the thing that says which arc is which.
    private var knobs: some View {
        ZStack {
            if let strength {
                knob(color: strength.status.color, symbol: "figure.strengthtraining.traditional",
                     fraction: shownStrength, radius: outerRadius, size: outerWidth + 6)
            }
            if let cardio {
                knob(color: cardio.status.color, symbol: "heart.fill",
                     fraction: shownCardio, radius: innerRadius, size: innerWidth + 6)
            }
        }
    }

    private func knob(color: Color, symbol: String, fraction: Double,
                      radius: CGFloat, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(StrandPalette.onDarkPrimary)
            Circle().fill(color.gradient).padding(2.5)
            Image(systemName: symbol)
                .font(StrandFont.rounded(size * 0.4, weight: .bold))
                .foregroundStyle(StrandPalette.onDarkPrimary)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.75), radius: 7)
        .position(point(radians(fraction), radius: radius))
        .frame(width: diameter, height: diameter)
    }

    /// Both verdicts, one per line, each next to its lane's symbol. Two lines rather than one word:
    /// there is no combined status to print, and inventing one is exactly what this page must not do.
    ///
    /// The ratio deliberately does NOT repeat here. The opening between the arcs is barely wider than
    /// "Восстановление", and a second line under each word pushed the block into the rings; the rows
    /// beneath the instrument carry every ratio already.
    private var centre: some View {
        VStack(alignment: .leading, spacing: 6) {
            centreRow(symbol: "figure.strengthtraining.traditional", lane: strength)
            centreRow(symbol: "heart.fill", lane: cardio)
        }
        // The 240° arc is open at the bottom, so the instrument's optical centre sits above its
        // geometric one; without the nudge the block reads as having slipped downwards.
        .offset(y: -diameter * 0.04)
    }

    private func centreRow(symbol: String, lane: LaneStatus?) -> some View {
        // No trailing spacer: each row sizes to its own content so the pair is CENTRED in the opening
        // rather than pinned to its left edge.
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(StrandFont.rounded(13, weight: .bold))
                .foregroundStyle(lane?.status.color ?? StrandPalette.textTertiary)
                .frame(width: 16)
                .trainingSymbolBounce(trigger: bounce)
            Text(lane?.status.label ?? "—")
                .font(StrandFont.rounded(15, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: diameter * 0.46, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Geometry

    private func arc(from: Double, to: Double, width: CGFloat) -> RecoveryArc {
        RecoveryArc(startAngle: .degrees(startDegrees + spanDegrees * from),
                    spanDegrees: spanDegrees * max(to - from, 0), fraction: 1, lineWidth: width)
    }

    private func radians(_ fraction: Double) -> Double {
        (startDegrees + spanDegrees * fraction) * .pi / 180
    }

    private func point(_ angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: diameter / 2 + radius * cos(angle), y: diameter / 2 + radius * sin(angle))
    }
}

/// A number that rolls to its value, in the wearer's locale. (The Liquid `CountUpNumber` always prints
/// a full stop, which reads wrong in German.)
@MainActor
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
                RadialGradient(colors: [leading.opacity(0.5), leading.opacity(0)],
                               center: .topLeading, startRadius: 0, endRadius: 300)
                RadialGradient(colors: [trailing.opacity(0.5), trailing.opacity(0)],
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
            leading.opacity(0.58), clear, trailing.opacity(0.58),
            leading.opacity(0.24), clear, trailing.opacity(0.24),
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
    /// Paint the card IN the colour rather than washing it. Reserved for the page's one statement, and
    /// refused for yellow by the caller, where white text on the fill would not read.
    var filled = false
    /// A second colour for a card that speaks about TWO lanes at once: the fill then runs from the
    /// lane that is falling behind to the one that is ahead, so the split is visible as a surface
    /// before a word of it is read.
    var secondary: Color? = nil
    @ViewBuilder let content: () -> Content

    private var fillColours: [Color] {
        guard let secondary else {
            return filled ? [color, color.opacity(0.78)] : [color.opacity(0.28), color.opacity(0.06)]
        }
        return filled ? [secondary, color] : [secondary.opacity(0.26), color.opacity(0.26)]
    }

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
                    shape.fill(LinearGradient(
                        colors: fillColours, startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay(alignment: .topTrailing) {
                    if let watermark {
                        Image(systemName: watermark)
                            .font(StrandFont.rounded(92, weight: .bold))
                            .foregroundStyle(filled ? StrandPalette.onDarkPrimary.opacity(0.16)
                                                    : color.opacity(0.14))
                            .rotationEffect(.degrees(-12))
                            .offset(x: 20, y: -16)
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(filled ? StrandPalette.onDarkPrimary.opacity(0.2)
                                                   : color.opacity(0.35), lineWidth: 1))
                .shadow(color: color.opacity(filled ? 0.3 : 0.14), radius: filled ? 16 : 12, y: 6)
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
    private let statuses: [TrainingStatus] = [.detraining, .maintaining, .productive, .overreaching]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space3) {
                ForEach(statuses, id: \.self) { legendItem($0) }
            }
            .fixedSize(horizontal: true, vertical: false)

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: NoopMetrics.space2) {
                ForEach(statuses, id: \.self) { legendItem($0) }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func legendItem(_ status: TrainingStatus) -> some View {
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
                    Text(verbatim: LoadScale.ratioText(focus.value, band: band))
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
