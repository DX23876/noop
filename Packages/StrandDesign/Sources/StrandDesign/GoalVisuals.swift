import SwiftUI

// MARK: - Goal visuals
//
// The drawing primitives behind weekly, monthly and long-term goals. They take numbers and tones only —
// no goal types, no analytics — so the same pieces draw a goal on Today, on the goals overview, in a
// goal's detail, in a widget and on the watch, and read the same way everywhere.
//
// The central piece is `PaceTrack`: a bar whose fill is what has been done and whose thin vertical mark
// is where the plan says the wearer should be today. Ahead of the mark is ahead; behind it is behind.
// That single comparison is what every goal surface asks the eye to make, so it is drawn identically
// at every size.

/// Remembers which goal tracks have already drawn their fill-in this launch, so a track scrolled away
/// and back keeps its value instead of sweeping up from zero again (the same courtesy the score rings
/// give). Process-wide and in memory only.
@MainActor
enum GoalVisualsAnimationMemory {
    static var drawn: Set<String> = []
}

// MARK: - PaceTrack

public struct PaceTrack: View {

    /// Done so far as a share of the target. May exceed 1; the fill is clamped, the overflow is the
    /// caller's to put into words.
    public var fraction: Double
    /// Where the pace says the wearer should be now, 0…1. nil hides the mark (a period that has not
    /// started, an average goal, a goal without a plan).
    public var paceFraction: Double?
    /// The fill colour. The goals surfaces pass the goal's own colour; the verdict is a word beside it.
    public var tint: Color
    /// Track height. 6 on Today, 8 on cards, 12 in a goal's detail.
    public var height: CGFloat
    /// Whole-unit segments for small count goals ("2 of 4" as two filled pieces of four). nil or > 10
    /// draws a continuous track.
    public var segments: Int?
    /// Where the current rate lands at period end, 0…1, drawn as a dashed extension (detail only).
    public var projectedFraction: Double?
    /// Draws the track without fill or mark: there is no measurement to show.
    public var isEmpty: Bool
    /// Stable identity for the one-time fill-in animation. nil animates on every appearance.
    public var animationKey: String?

    public init(fraction: Double, paceFraction: Double? = nil, tint: Color, height: CGFloat = 8,
                segments: Int? = nil, projectedFraction: Double? = nil, isEmpty: Bool = false,
                animationKey: String? = nil) {
        self.fraction = fraction
        self.paceFraction = paceFraction
        self.tint = tint
        self.height = height
        self.segments = segments
        self.projectedFraction = projectedFraction
        self.isEmpty = isEmpty
        self.animationKey = animationKey
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(QuietMotionPrefs.enabledKey) private var quietMotion = false
    @State private var shown: Double?

    private var clamped: Double { isEmpty ? 0 : min(max(fraction, 0), 1) }
    private var markWidth: CGFloat { contrast == .increased ? 3.5 : 2.5 }
    private var markHeight: CGFloat { max(height + 6, height * 1.7) }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fill = shown ?? clamped
            ZStack(alignment: .leading) {
                track(width: width, fill: fill)
                if let projected = projectedFraction, !isEmpty, projected > fill {
                    projection(width: width, from: fill, to: min(1, projected))
                }
                if let pace = paceFraction, !isEmpty, clamped < 1 {
                    // A solid mark with a halo outside it: the halo separates it from the fill, and the
                    // core stays its full width (an inside border used to eat a 2 pt mark down to a
                    // white sliver that read as a gap, not a target).
                    Capsule(style: .continuous)
                        .fill(StrandPalette.textPrimary.opacity(0.85))
                        .frame(width: markWidth, height: markHeight)
                        .background(Capsule(style: .continuous)
                            .fill(StrandPalette.surfaceRaised)
                            .frame(width: markWidth + 2, height: markHeight + 2))
                        .offset(x: max(0, min(width - markWidth, width * CGFloat(min(max(pace, 0), 1))
                                                - markWidth / 2)))
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: markHeight)
        .onAppear(perform: appear)
        .onChange(of: clamped) { value in
            if reduceMotion || quietMotion { shown = value } else {
                withAnimation(.easeOut(duration: 0.6)) { shown = value }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func track(width: CGFloat, fill: Double) -> some View {
        let count = segments.flatMap { (2...10).contains($0) ? $0 : nil }
        if let count {
            let gap: CGFloat = 3
            let piece = max(1, (width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    let share = min(1, max(0, fill * Double(count) - Double(index)))
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous).fill(trackColor)
                        Capsule(style: .continuous).fill(tint)
                            .frame(width: piece * CGFloat(share))
                    }
                    .frame(width: piece, height: height)
                }
            }
        } else {
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(trackColor)
                Capsule(style: .continuous).fill(tint)
                    .frame(width: width * CGFloat(fill))
            }
            .frame(height: height)
        }
    }

    private func projection(width: CGFloat, from: Double, to: Double) -> some View {
        Path { path in
            path.move(to: CGPoint(x: width * CGFloat(from), y: height / 2))
            path.addLine(to: CGPoint(x: width * CGFloat(to), y: height / 2))
        }
        .stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: max(2, height * 0.35), lineCap: .round,
                                                      dash: [3, 4]))
        .frame(height: height)
    }

    private var trackColor: Color {
        // `hairlineStrong` is white in light appearance; increased contrast needs a darker track, not that.
        contrast == .increased ? StrandPalette.textTertiary : StrandPalette.hairline
    }

    private func appear() {
        let target = clamped
        if reduceMotion || quietMotion {
            shown = target
            return
        }
        if let key = animationKey, GoalVisualsAnimationMemory.drawn.contains(key) {
            shown = target
            return
        }
        shown = 0
        withAnimation(.easeOut(duration: 0.6)) { shown = target }
        if let key = animationKey { GoalVisualsAnimationMemory.drawn.insert(key) }
    }
}

// MARK: - DayDotStrip

/// One state per day of a week: met, missed, today, future, rest day, no data. Missed days are hollow,
/// never red — a week is judged as a whole, not one evening at a time.
public struct DayDotStrip: View {

    public enum DayState: Equatable, Sendable {
        case met, missed, today, todayMet, future, rest, noData
    }

    public struct Day: Identifiable, Equatable {
        public let id: String
        public let state: DayState
        /// Weekday initial shown below the dot ("M"). Empty hides the label row.
        public let label: String
        /// Optional SF Symbol inside a met dot (a sport icon in a goal's detail).
        public let symbol: String?

        public init(id: String, state: DayState, label: String, symbol: String? = nil) {
            self.id = id
            self.state = state
            self.label = label
            self.symbol = symbol
        }
    }

    public var days: [Day]
    public var tint: Color
    public var diameter: CGFloat
    /// Days the pace suggests for what is still missing; drawn with a tinted ring.
    public var suggested: Set<String>

    public init(days: [Day], tint: Color, diameter: CGFloat = 14, suggested: Set<String> = []) {
        self.days = days
        self.tint = tint
        self.diameter = diameter
        self.suggested = suggested
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                VStack(spacing: 3) {
                    dot(day)
                    if !day.label.isEmpty {
                        Text(day.label)
                            .font(StrandFont.caption)
                            .foregroundStyle(day.state == .today || day.state == .todayMet
                                             ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dot(_ day: Day) -> some View {
        let circle = Circle()
        ZStack {
            switch day.state {
            case .met, .todayMet:
                circle.fill(tint)
                if let symbol = day.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: diameter * 0.45, weight: .semibold))
                        .foregroundStyle(StrandPalette.surfaceRaised)
                }
            // Not the hairline tokens: they are glass highlights, white in light appearance, and left
            // missed and coming days invisible on a light card.
            case .missed:
                circle.strokeBorder(StrandPalette.textTertiary, lineWidth: 1)
            case .today:
                circle.strokeBorder(StrandPalette.textPrimary, lineWidth: 1.5)
            case .future:
                if suggested.contains(day.id) {
                    circle.strokeBorder(tint, lineWidth: 1.5)
                } else {
                    circle.strokeBorder(StrandPalette.textTertiary,
                                        style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            case .rest:
                Capsule().fill(StrandPalette.textTertiary)
                    .frame(width: diameter * 0.6, height: 2)
            case .noData:
                circle.strokeBorder(StrandPalette.textTertiary, lineWidth: 1)
                DiagonalHatch(spacing: 3)
                    .stroke(StrandPalette.textTertiary.opacity(0.6), lineWidth: 0.75)
                    .clipShape(circle)
            }
            if day.state == .todayMet {
                circle.strokeBorder(StrandPalette.textPrimary, lineWidth: 1.5)
                    .padding(-2.5)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - TargetColumns

/// One column per day against a dashed target line — for average goals (nightly sleep). Columns that
/// reach the line are drawn in the status tone, the others in the same tone at reduced strength; a
/// missing night is a short stub so it never reads as zero hours.
public struct TargetColumns: View {
    public var values: [Double?]
    public var target: Double
    /// The scale's top. Defaults to a little above the larger of the target and the values.
    public var maximum: Double?
    public var tint: Color
    public var height: CGFloat
    /// False for a target to stay under, like a running pace: a column at or below the line has met it.
    public var higherIsBetter: Bool

    public init(values: [Double?], target: Double, maximum: Double? = nil, tint: Color, height: CGFloat = 40,
                higherIsBetter: Bool = true) {
        self.values = values
        self.target = target
        self.maximum = maximum
        self.tint = tint
        self.height = height
        self.higherIsBetter = higherIsBetter
    }

    public var body: some View {
        let top = maximum ?? max(target * 1.25, (values.compactMap { $0 }.max() ?? 0) * 1.05, 0.0001)
        GeometryReader { geo in
            let count = max(1, values.count)
            let gap: CGFloat = 4
            // A handful of columns is capped so one run reads as a column, not as a block across the card;
            // a full week keeps filling the width as before.
            let fill = max(2, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let width = count < 5 ? min(24, fill) : fill
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(values.indices, id: \.self) { index in
                        if let value = values[index] {
                            RoundedRectangle(cornerRadius: min(3, width / 3), style: .continuous)
                                .fill((higherIsBetter ? value >= target : value <= target) ? tint : tint.opacity(0.4))
                                .frame(width: width, height: max(2, geo.size.height * CGFloat(min(1, value / top))))
                        } else {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(StrandPalette.hairline)
                                .frame(width: width, height: 4)
                        }
                    }
                }
                Path { path in
                    let y = geo.size.height * CGFloat(1 - min(1, target / top))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(StrandPalette.textSecondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - PeriodHistoryBars

/// The last periods as columns: height = share of the target reached (capped, with a dot when it went
/// over), colour = how the period ended, the running period hollow.
public struct PeriodHistoryBars: View {

    public struct Bar: Identifiable, Equatable {
        public let id: String
        public let fraction: Double
        public let tint: Color
        public let isCurrent: Bool

        public init(id: String, fraction: Double, tint: Color, isCurrent: Bool = false) {
            self.id = id
            self.fraction = fraction
            self.tint = tint
            self.isCurrent = isCurrent
        }
    }

    public var bars: [Bar]
    public var height: CGFloat
    /// Draws the target as a dashed line across the top of a full column.
    public var showsTarget: Bool
    public var selection: Binding<String?>?

    public init(bars: [Bar], height: CGFloat = 44, showsTarget: Bool = false, selection: Binding<String?>? = nil) {
        self.bars = bars
        self.height = height
        self.showsTarget = showsTarget
        self.selection = selection
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(bars) { bar in
                let h = max(3, height * CGFloat(min(1, max(0, bar.fraction))))
                ZStack(alignment: .top) {
                    if bar.isCurrent {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(bar.tint, lineWidth: 1.5)
                    } else {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(bar.tint)
                    }
                    if bar.fraction > 1.0001 {
                        Circle().fill(StrandPalette.textPrimary).frame(width: 4, height: 4).offset(y: -7)
                    }
                }
                .frame(height: h)
                .frame(maxWidth: .infinity)
                .opacity(selection?.wrappedValue == nil || selection?.wrappedValue == bar.id ? 1 : 0.45)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let selection else { return }
                    selection.wrappedValue = selection.wrappedValue == bar.id ? nil : bar.id
                }
            }
        }
        .frame(height: height + 8, alignment: .bottom)
        .overlay(alignment: .top) {
            if showsTarget {
                GeometryReader { geo in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 8))
                        path.addLine(to: CGPoint(x: geo.size.width, y: 8))
                    }
                    .stroke(StrandPalette.textSecondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - StatusRing (lock screen, ladder tiles)

/// A ring split into segments by how many goals are in each state — counts goals, not progress.
public struct GoalStatusRing: View {
    public struct Share: Identifiable {
        public let id: String
        public let count: Int
        public let tint: Color
        public init(id: String, count: Int, tint: Color) {
            self.id = id
            self.count = count
            self.tint = tint
        }
    }

    public var shares: [Share]
    public var lineWidth: CGFloat
    public var diameter: CGFloat

    public init(shares: [Share], lineWidth: CGFloat = 4, diameter: CGFloat = 34) {
        self.shares = shares
        self.lineWidth = lineWidth
        self.diameter = diameter
    }

    public var body: some View {
        let total = max(1, shares.reduce(0) { $0 + $1.count })
        let gap = shares.filter { $0.count > 0 }.count > 1 ? 0.02 : 0
        ZStack {
            Circle().stroke(StrandPalette.hairline, lineWidth: lineWidth)
            ForEach(Array(segments(total: total).enumerated()), id: \.offset) { _, segment in
                Circle()
                    .trim(from: segment.from, to: max(segment.from, segment.to - gap))
                    .stroke(segment.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func segments(total: Int) -> [(from: Double, to: Double, tint: Color)] {
        var start = 0.0
        var result: [(Double, Double, Color)] = []
        for share in shares where share.count > 0 {
            let end = start + Double(share.count) / Double(total)
            result.append((start, end, share.tint))
            start = end
        }
        return result
    }
}

#if DEBUG
#Preview("Goal visuals") {
    VStack(alignment: .leading, spacing: 18) {
        PaceTrack(fraction: 0.5, paceFraction: 0.57, tint: StrandPalette.statusPositive, height: 6, segments: 4)
        PaceTrack(fraction: 0.4, paceFraction: 0.6, tint: StrandPalette.statusWarning, height: 8)
        PaceTrack(fraction: 0.12, paceFraction: 0.13, tint: StrandPalette.statusCritical, height: 12,
                  projectedFraction: 0.86)
        PaceTrack(fraction: 1.07, tint: StrandPalette.statusPositive)
        PaceTrack(fraction: 0, tint: StrandPalette.textSecondary, isEmpty: true)
        DayDotStrip(days: [
            .init(id: "1", state: .met, label: "M"), .init(id: "2", state: .missed, label: "T"),
            .init(id: "3", state: .met, label: "W"), .init(id: "4", state: .today, label: "T"),
            .init(id: "5", state: .future, label: "F"), .init(id: "6", state: .rest, label: "S"),
            .init(id: "7", state: .noData, label: "S"),
        ], tint: StrandPalette.statusPositive, suggested: ["5"])
        TargetColumns(values: [7.6, 6.8, nil, 7.9, 7.1, nil, nil], target: 7.5, tint: StrandPalette.statusWarning)
        PeriodHistoryBars(bars: (0..<12).map {
            .init(id: "\($0)", fraction: [0.75, 1, 0.5, 1.2][$0 % 4],
                  tint: $0 % 4 == 2 ? StrandPalette.statusWarning : StrandPalette.statusPositive,
                  isCurrent: $0 == 11)
        })
        GoalStatusRing(shares: [.init(id: "a", count: 2, tint: StrandPalette.statusPositive),
                                .init(id: "b", count: 1, tint: StrandPalette.statusWarning)])
    }
    .padding(24)
    .background(StrandPalette.surfaceBase)
}
#endif
