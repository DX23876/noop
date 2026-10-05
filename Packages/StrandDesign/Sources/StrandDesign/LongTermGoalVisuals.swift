import SwiftUI

// MARK: - Long-term goal visuals
//
// The pieces of a long-term goal's page: a hero card over a scene with the goal's big number and three
// figures, the band under it (a milestone line or a row of week dots), calm insight tiles and the filter
// chips of the goals overview. Like the rest of the goal visuals they take strings, numbers and tones
// only; the app decides what a goal says, these decide how it looks.

// MARK: - GoalHeroCard

/// One of the three figures along the bottom of a `GoalHeroCard`.
public struct GoalHeroStat: Identifiable {
    public let id: Int
    public let label: String
    public let value: String
    /// A small bar under the value, 0…1. nil draws none.
    public let fraction: Double?
    public init(id: Int, label: String, value: String, fraction: Double? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.fraction = fraction
    }
}

/// A goal's headline over an image: icon, title, state, the big number top right and a bar of three
/// figures along the bottom. The image is the caller's (a day-cycle scene, an area scene, a photo); the
/// card lays a dark scrim over it so the light text stays readable whatever the picture is.
public struct GoalHeroCard<Background: View>: View {

    public typealias Stat = GoalHeroStat

    let title: String
    let stateWord: String
    let stateSymbol: String
    let stateTone: StrandTone
    let icon: String
    let iconTint: Color
    let heroValue: String
    let heroCaption: String?
    let stats: [Stat]
    let compact: Bool
    let showsChevron: Bool
    let background: Background

    public init(title: String, stateWord: String, stateSymbol: String, stateTone: StrandTone,
                icon: String, iconTint: Color, heroValue: String, heroCaption: String? = nil,
                stats: [Stat], compact: Bool = false, showsChevron: Bool = false,
                @ViewBuilder background: () -> Background) {
        self.title = title
        self.stateWord = stateWord
        self.stateSymbol = stateSymbol
        self.stateTone = stateTone
        self.icon = icon
        self.iconTint = iconTint
        self.heroValue = heroValue
        self.heroCaption = heroCaption
        self.stats = stats
        self.compact = compact
        self.showsChevron = showsChevron
        self.background = background()
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    private var corner: CGFloat { compact ? NoopMetrics.cardRadius : NoopMetrics.heroRadius }
    private var iconSize: CGFloat { compact ? 36 : 52 }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            header
            Spacer(minLength: compact ? 28 : 96)
            // Without figures (the setup preview) an empty bar would draw as a stray sliver.
            if !stats.isEmpty { statsBar }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                StrandPalette.organicHeroChamber
                background
                // Top and bottom scrims: the title and the figures sit on darkened bands, the picture
                // stays visible between them.
                LinearGradient(colors: [StrandPalette.organicHeroChamber.opacity(0.7), .clear],
                               startPoint: .top, endPoint: .center)
                LinearGradient(colors: [.clear, StrandPalette.organicHeroChamber.opacity(0.75)],
                               startPoint: .center, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(StrandPalette.organicHeroBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var header: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            Image(systemName: icon)
                .font(.system(size: iconSize * 0.42, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: iconSize, height: iconSize)
                .background(Circle().fill(StrandPalette.organicHeroChamber.opacity(0.65)))
                .overlay(Circle().strokeBorder(iconTint.opacity(0.55), lineWidth: 1.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .font(compact ? StrandFont.headline : StrandFont.title2)
                    .foregroundStyle(StrandPalette.onDarkPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                statePill
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            // Stacked at accessibility sizes, the figure lines up with the title above it; trailing
            // alignment there pushed the value and its caption apart.
            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: heroValue)
                        .font(compact ? StrandFont.number(20) : StrandFont.number(28))
                        .foregroundStyle(StrandPalette.onDarkPrimary)
                        .lineLimit(1)
                        // A long figure ("105 sets / week") shrinks rather than losing its unit to "…".
                        .minimumScaleFactor(0.45)
                        .allowsTightening(true)
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(StrandPalette.onDarkSecondary)
                            .accessibilityHidden(true)
                    }
                }
                if let heroCaption {
                    Text(verbatim: heroCaption)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.onDarkSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var statePill: some View {
        HStack(spacing: 5) {
            Image(systemName: stateSymbol)
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
            Text(verbatim: stateWord)
                .font(StrandFont.caption.weight(.semibold))
        }
        .foregroundStyle(stateTone == .neutral ? StrandPalette.onDarkSecondary : stateTone.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(StrandPalette.organicHeroChamber.opacity(0.7)))
        .overlay(Capsule().strokeBorder((stateTone == .neutral ? StrandPalette.onDarkTertiary : stateTone.color)
            .opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private var statsBar: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        layout {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0, !typeSize.isAccessibilitySize {
                    Rectangle().fill(StrandPalette.onDarkTertiary.opacity(0.4))
                        .frame(width: 1)
                        .padding(.vertical, 4)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: stat.label)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.onDarkSecondary)
                        .lineLimit(1)
                    Text(verbatim: stat.value)
                        .font(compact ? StrandFont.bodyNumber : StrandFont.number(19))
                        .foregroundStyle(StrandPalette.onDarkPrimary)
                        .lineLimit(1)
                        // A rate with its unit ("+2 min/month") needs more room than a plain figure.
                        .minimumScaleFactor(0.5)
                    if let fraction = stat.fraction {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(StrandPalette.onDarkTertiary.opacity(0.35))
                                Capsule().fill(StrandPalette.accent)
                                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
                            }
                        }
                        .frame(height: 5)
                        .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, typeSize.isAccessibilitySize ? 0 : 10)
            }
        }
        .padding(.vertical, compact ? 8 : 12)
        .padding(.horizontal, typeSize.isAccessibilitySize ? 12 : 2)
        .background(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
            .fill(StrandPalette.organicHeroChamber.opacity(0.62)))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
            .strokeBorder(StrandPalette.organicHeroBorder, lineWidth: 1))
    }
}

/// A scene image filling a hero card, top-aligned so the sky shows.
public struct GoalHeroImage: View {
    let name: String
    public init(name: String) { self.name = name }
    public var body: some View {
        GeometryReader { geo in
            Image(name)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
        }
        .accessibilityHidden(true)
    }
}

// MARK: - MilestoneTrack

/// Waypoints on a line: passed ones filled with a check, the next one as a ring, the rest open. Shows
/// the window of five the page picks; a faded stub at either end says the route goes on.
public struct MilestoneTrack: View {

    public enum PointState: Sendable { case reached, next, open }

    public struct Point: Identifiable {
        public let id: Int
        public let label: String
        public let state: PointState
        public init(id: Int, label: String, state: PointState) {
            self.id = id
            self.label = label
            self.state = state
        }
    }

    let points: [Point]
    let tint: Color
    let moreBefore: Bool
    let moreAfter: Bool

    public init(points: [Point], tint: Color, moreBefore: Bool = false, moreAfter: Bool = false) {
        self.points = points
        self.tint = tint
        self.moreBefore = moreBefore
        self.moreAfter = moreAfter
    }

    private let dot: CGFloat = 26

    public var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let count = max(points.count, 1)
                let step = geo.size.width / CGFloat(count)
                ZStack(alignment: .leading) {
                    // Segments between neighbours: tinted up to the next waypoint, muted grey after it.
                    // Not a hairline token: those are glass highlights and vanish on a light card.
                    ForEach(points.indices.dropLast(), id: \.self) { index in
                        Rectangle()
                            .fill(points[index + 1].state == .open ? StrandPalette.textTertiary.opacity(0.35) : tint)
                            .frame(width: step, height: 3)
                            .offset(x: step * (CGFloat(index) + 0.5))
                    }
                    if moreBefore {
                        Rectangle().fill(tint.opacity(0.35)).frame(width: step / 2, height: 3)
                    }
                    if moreAfter {
                        Rectangle().fill(StrandPalette.textTertiary.opacity(0.35)).frame(width: step / 2, height: 3)
                            .offset(x: step * (CGFloat(count) - 0.5))
                    }
                    ForEach(points.indices, id: \.self) { index in
                        marker(points[index].state)
                            .offset(x: step * (CGFloat(index) + 0.5) - dot / 2)
                    }
                }
                .frame(height: dot)
            }
            .frame(height: dot)
            HStack(alignment: .top, spacing: 0) {
                ForEach(points) { point in
                    Text(verbatim: point.label)
                        .font(point.state == .next ? StrandFont.caption.weight(.semibold) : StrandFont.caption)
                        .foregroundStyle(point.state == .open ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: points.map { point -> String in
            switch point.state {
            case .reached: return "✓ \(point.label)"
            case .next: return "→ \(point.label)"
            case .open: return point.label
            }
        }.joined(separator: ", ")))
    }

    @ViewBuilder
    private func marker(_ state: PointState) -> some View {
        switch state {
        case .reached:
            Circle().fill(tint)
                .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StrandPalette.surfaceRaised))
                .frame(width: dot, height: dot)
        case .next:
            Circle().fill(StrandPalette.surfaceRaised)
                .overlay(Circle().strokeBorder(tint, lineWidth: 3))
                .frame(width: dot, height: dot)
        case .open:
            Circle().fill(StrandPalette.surfaceRaised)
                .overlay(Circle().strokeBorder(StrandPalette.textTertiary, lineWidth: 2))
                .frame(width: dot, height: dot)
        }
    }
}

// MARK: - WeekDotRow

/// Finished weeks as dots: kept with a check, almost kept half-filled, missed in grey (never red: a week
/// gone is information, not a reproach), protected with a shield, without data dashed, the running week
/// as a ring.
public struct WeekDotRow: View {

    public enum WeekState: Sendable { case kept, almost, missed, protected, noData, running }

    public struct Week: Identifiable {
        public let id: Int
        public let label: String
        public let state: WeekState
        public init(id: Int, label: String, state: WeekState) {
            self.id = id
            self.label = label
            self.state = state
        }
    }

    let weeks: [Week]
    let tint: Color

    public init(weeks: [Week], tint: Color) {
        self.weeks = weeks
        self.tint = tint
    }

    private let dot: CGFloat = 26

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(weeks) { week in
                VStack(spacing: 6) {
                    marker(week.state)
                    Text(verbatim: week.label)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func marker(_ state: WeekState) -> some View {
        switch state {
        case .kept:
            Circle().fill(tint)
                .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StrandPalette.surfaceRaised))
                .frame(width: dot, height: dot)
        case .almost:
            Circle().fill(tint.opacity(0.4))
                .overlay(Circle().strokeBorder(tint, lineWidth: 2))
                .frame(width: dot, height: dot)
        case .missed:
            // A hairline token is a glass highlight: on a light card it vanished, leaving a bare minus.
            Circle().fill(StrandPalette.textTertiary.opacity(0.28))
                .overlay(Image(systemName: "minus").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StrandPalette.textSecondary))
                .frame(width: dot, height: dot)
        case .protected:
            Circle().fill(StrandPalette.surfaceInset)
                .overlay(Image(systemName: "shield.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary))
                .frame(width: dot, height: dot)
        case .noData:
            Circle().strokeBorder(StrandPalette.textTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: dot, height: dot)
        case .running:
            Circle().strokeBorder(StrandPalette.textPrimary, lineWidth: 2)
                .frame(width: dot, height: dot)
        }
    }
}

// MARK: - InsightTile

/// One figure with a title and a line under it, on a calm surface. Only the value may carry a tone,
/// and only when it is the figure the goal's state rests on.
public struct InsightTile: View {
    let icon: String
    let title: String
    let value: String
    let caption: String?
    let valueTone: StrandTone?

    public init(icon: String, title: String, value: String, caption: String? = nil, valueTone: StrandTone? = nil) {
        self.icon = icon
        self.title = title
        self.value = value
        self.caption = caption
        self.valueTone = valueTone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            Text(verbatim: value)
                .font(StrandFont.number(18))
                .foregroundStyle(valueTone.map { $0 == .neutral ? StrandPalette.textPrimary : $0.foregroundColor }
                    ?? StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(verbatim: caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
            .fill(StrandPalette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - GoalFilterChips

/// The overview's period filter: one chip per choice, the selected one filled. Scrolls sideways when
/// the text is large.
public struct GoalFilterChips: View {

    public struct Chip: Identifiable, Equatable {
        public let id: String
        public let label: String
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    let chips: [Chip]
    @Binding var selection: String

    public init(chips: [Chip], selection: Binding<String>) {
        self.chips = chips
        self._selection = selection
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    let selected = chip.id == selection
                    Button {
                        selection = chip.id
                        StrandHaptic.selection.play()
                    } label: {
                        Text(verbatim: chip.label)
                            .font(StrandFont.subhead.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(selected ? StrandPalette.accentMuted : StrandPalette.surfaceRaised))
                            .overlay(Capsule().strokeBorder(selected ? StrandPalette.accent.opacity(0.5)
                                                                     : StrandPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }
}

#Preview("Long-term goal visuals") {
    ScrollView {
        VStack(spacing: 16) {
            GoalHeroCard(title: "Run 1,000 km", stateWord: "On track", stateSymbol: "circle.fill",
                         stateTone: .positive, icon: "figure.run", iconTint: StrandPalette.accent,
                         heroValue: "642 km", heroCaption: "of 1,000 km",
                         stats: [.init(id: 0, label: "Target", value: "1,000 km"),
                                 .init(id: 1, label: "Progress", value: "64 %", fraction: 0.64),
                                 .init(id: 2, label: "Estimated", value: "18 Dec")],
                         showsChevron: true) {
                StrandPalette.surfaceInset
            }
            MilestoneTrack(points: [.init(id: 0, label: "250 km", state: .reached),
                                    .init(id: 1, label: "500 km", state: .reached),
                                    .init(id: 2, label: "750 km", state: .next),
                                    .init(id: 3, label: "1,000 km", state: .open)],
                           tint: StrandPalette.statusPositive)
            WeekDotRow(weeks: [.init(id: 0, label: "W1", state: .kept), .init(id: 1, label: "W2", state: .almost),
                               .init(id: 2, label: "W3", state: .missed), .init(id: 3, label: "W4", state: .protected),
                               .init(id: 4, label: "W5", state: .noData), .init(id: 5, label: "W6", state: .running)],
                       tint: StrandPalette.statusPositive)
            HStack {
                InsightTile(icon: "speedometer", title: "Current pace", value: "32 km/week",
                            caption: "On track", valueTone: .positive)
                InsightTile(icon: "flag", title: "Next milestone", value: "750 km", caption: "in about 3 weeks")
            }
        }
        .padding()
    }
}
