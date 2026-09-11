import SwiftUI
import WhoopStore
import StrandDesign
import StrandAnalytics

// MARK: - Cardio — the screen a run, a ride and a swim were missing
//
// Until now a cardio session in NOOP was "duration, average heart rate, calories". That is the one
// description under which a 42-minute run and a 42-minute ride are the same thing. Everything the sports
// are actually measured in — pace, speed, distance over a week, whether any of it is improving — either
// lived one tap deep in a single session's detail or did not exist at all.
//
// This is the counterpart to the Strength screen, built to the same grammar so the two read as one app:
//
//   • the SAME Monday-anchored week stepper, the same history-window control,
//   • a week that adds up (sessions, moving time, distance, calories, Effort) with the wearer's OWN
//     usual week behind the headline figure rather than a target,
//   • the same acute-versus-chronic load question, in MINUTES — `ReadinessEngine`'s windows and bands,
//     read from it, so "spiking" means the same thing on both screens,
//   • per-sport progression in that sport's own unit, with measured bests beside the modelled line,
//   • and beats per kilometre, the one figure that says whether the same run is costing less.
//
// Sessions open the EXISTING `WorkoutDetailView`. A second detail screen for the same row would be two
// places to fix a wrong number.

struct CardioView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine

    @StateObject private var model = CardioModel()

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var units: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                  override: distanceSystemRaw)
    }

    @State private var infoTopic: InfoTopic?
    @State private var openDetail: DetailTarget?

    struct DetailTarget: Identifiable, Equatable {
        let startTs: Int
        let sport: String
        var id: String { "\(startTs)|\(sport)" }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if model.sessions.isEmpty {
                    emptyState
                } else {
                    thisWeek
                    sportMix
                    sportProgress
                    bestsCard
                    recentSessions
                }
            }
            .padding(NoopMetrics.screenPadding)
            DemoScrollBottomAnchor()
        }
        .navigationTitle(Text("Cardio"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let context = coachContext { CoachCardButton(context: context) }
            }
        }
        .sheet(item: $infoTopic) { topic in infoSheet(topic) }
        .sheet(item: $openDetail) { target in
            NavigationStack {
                if let row = model.sessions.first(where: {
                    $0.startTs == target.startTs && $0.sport == target.sport
                }) {
                    WorkoutDetailView(row: workoutRow(for: row))
                }
            }
        }
        .task(id: repo.refreshSeq) {
            await model.load(repo: repo)
            await scrollToDemoBottom(proxy)
        }
        // `onChange`, not a second `.task(id:)` — that also fires on first appearance, which would load
        // the whole workout history twice on every visit.
        .onChangeCompat(of: model.range) { _ in
            Task { await model.load(repo: repo) }
        }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Cardio", overline: "Training")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("No cardio sessions in the last \(model.range.days) days.")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text("Runs, rides, swims and rows appear here as soon as your strap offloads them or a workout is imported — with pace, speed and distance, not just a duration.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - This week

    private var thisWeek: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            weekNavBar
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                              spacing: 10) {
                        tile(icon: "figure.run", label: String(localized: "Sessions"),
                             value: "\(model.week.sessionCount)", tint: DomainTheme.effort.color)
                        tile(icon: "clock.fill", label: String(localized: "Moving time"),
                             value: durationText(model.week.minutes * 60),
                             tint: DomainTheme.effort.color,
                             caption: usualMinutesText)
                        tile(icon: "point.topleft.down.to.point.bottomright.curvepath",
                             label: String(localized: "Distance"),
                             value: model.week.distanceM > 0
                                ? UnitFormatter.distanceFromMeters(model.week.distanceM, system: units)
                                : "—",
                             tint: StrandPalette.metricCyan,
                             caption: distanceCoverageText)
                        loadTile
                        tile(icon: "flame.fill", label: String(localized: "Calories"),
                             value: model.week.energyKcal > 0
                                ? grouped(model.week.energyKcal) : "—",
                             tint: StrandPalette.metricAmber,
                             caption: model.week.energyKcal > 0 ? "kcal" : nil)
                        tile(icon: "heart.fill", label: String(localized: "Effort"),
                             value: model.week.effort.map { String(format: "%.0f", $0) } ?? "—",
                             tint: StrandPalette.effortColor,
                             caption: String(localized: "this week"))
                    }
                    if let typical = model.typicalMinutes, model.week.minutes > 0 {
                        weekAgainstUsual(typical)
                    }
                }
            }
        }
    }

    /// This week's minutes against the wearer's own usual week — the same `TypicalRangeBar` grammar the
    /// Strength screen uses for muscle volume, so "the shaded part is normal for you" is learned once.
    private func weekAgainstUsual(_ typical: ClosedRange<Double>) -> some View {
        let scale = max(model.week.minutes, typical.upperBound, 1)
        return VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: 10) {
                Text("vs your usual")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 92, alignment: .leading)
                TypicalRangeBar(value: model.week.minutes / scale,
                                typical: (typical.lowerBound / scale)...(typical.upperBound / scale),
                                color: DomainTheme.effort.color, height: 8)
                Text(String(localized: "\(Int(typical.lowerBound.rounded()))–\(Int(typical.upperBound.rounded())) min"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var usualMinutesText: String? {
        guard let typical = model.typicalMinutes else { return nil }
        return String(localized: "usual \(Int(typical.lowerBound.rounded()))–\(Int(typical.upperBound.rounded()))")
    }

    private var distanceCoverageText: String? {
        guard model.week.sessionCount > 0 else { return nil }
        guard model.week.sessionsWithDistance < model.week.sessionCount else { return nil }
        return String(localized: "\(model.week.sessionsWithDistance) of \(model.week.sessionCount) sessions")
    }

    @ViewBuilder
    private var loadTile: some View {
        let load = model.load
        tile(icon: "chart.bar.fill",
             label: String(localized: "Cardio load"),
             value: load.map { String(format: "%.2f", $0.ratio) } ?? "—",
             tint: load.map { bandColor($0.band) } ?? StrandPalette.textTertiary,
             caption: load.map { bandLabel($0.band) } ?? String(localized: "needs 4 weeks"),
             info: .cardioLoad)
    }

    private var weekNavBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Endurance").strandOverline()
                Text("This week").font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer(minLength: 8)
            rangePicker
            HStack(spacing: 10) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.weekOffset <= model.minWeekOffset)
                Text(weekRangeText)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.weekOffset >= 0)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.accent)
        }
    }

    private var rangePicker: some View {
        Menu {
            ForEach(CardioModel.HistoryRange.allCases) { option in
                Button {
                    model.range = option
                } label: {
                    if model.range == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                Text(model.range.label).font(StrandFont.caption)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(StrandPalette.surfaceInset, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "History window"))
    }

    private func step(_ delta: Int) {
        Task { await model.stepWeek(delta, repo: repo) }
    }

    /// One tile of the weekly grid — compact and fixed-height, the twin of the Strength screen's. See
    /// that one for why the shared `TodayMetricTile` is not used at this size.
    private func tile(icon: String, label: String, value: String, tint: Color,
                      caption: String? = nil, info: InfoTopic? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ZStack {
                    Circle().fill(tint.opacity(0.13))
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                if let info {
                    Button { infoTopic = info } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What this means")
                }
            }
            Spacer(minLength: 0)
            Text(value)
                .font(StrandFont.number(26))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            // `subhead`, not `caption`: on iOS the scale runs subhead (13) → caption (12) → footnote
            // (11), and a tile label set in caption reads as a footnote to a number that is the point
            // of the tile. The caption line below stays a step smaller, which is what keeps the two
            // apart now that the label has grown.
            Text(label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(caption ?? " ")
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .leading)
        .background(TodayCardSurface(tint: tint, cornerRadius: NoopMetrics.groupedRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(caption.map { ", " + $0 } ?? "")")
    }

    // MARK: - What the week was made of

    /// Minutes split by sport, as one stacked bar plus a legend.
    ///
    /// A bar rather than a pie: the question is "how was the week divided", and lengths on a common
    /// baseline are the comparison people actually read correctly.
    @ViewBuilder
    private var sportMix: some View {
        if model.week.bySport.count > 1, model.week.minutes > 0 {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("How the week was spent", overline: "Moving time")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                ForEach(Array(model.week.bySport.enumerated()), id: \.offset) { index, total in
                                    Rectangle()
                                        .fill(sportColor(index))
                                        .frame(width: max(2, geo.size.width * total.minutes / model.week.minutes))
                                }
                            }
                            .clipShape(Capsule())
                        }
                        .frame(height: 14)
                        .accessibilityHidden(true)

                        VStack(spacing: 8) {
                            ForEach(Array(model.week.bySport.enumerated()), id: \.offset) { index, total in
                                HStack(spacing: 8) {
                                    Circle().fill(sportColor(index)).frame(width: 8, height: 8)
                                    Text(WorkoutSource.displaySport(total.sport))
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(sportMixDetail(total))
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .lineLimit(1)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sportMixDetail(_ total: CardioSportTotal) -> String {
        var parts = [durationText(total.minutes * 60)]
        if total.distanceM > 0 {
            parts.append(UnitFormatter.distanceFromMeters(total.distanceM, system: units))
        }
        parts.append(total.sessionCount == 1 ? String(localized: "1 session")
                                             : String(localized: "\(total.sessionCount) sessions"))
        return parts.joined(separator: " · ")
    }

    /// A stable palette across the legend and the bar. Index-based rather than hashed off the sport
    /// name so the same week always draws the same colours.
    private func sportColor(_ index: Int) -> Color {
        let ramp: [Color] = [DomainTheme.effort.color, StrandPalette.metricCyan,
                             StrandPalette.accent, StrandPalette.metricAmber,
                             StrandPalette.metricRose, StrandPalette.zone2]
        return ramp[index % ramp.count]
    }

    // MARK: - One sport over time

    private var sportProgress: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Progress", overline: "Per sport")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    sportPicker
                    if paceChartPoints.count < 2 {
                        Text("Not enough sessions of this sport with a distance to draw a trend. Pace needs both a distance and a duration.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TrendChart(points: paceChartPoints,
                                   gradient: Gradient(colors: [DomainTheme.effort.color.opacity(0.35),
                                                               DomainTheme.effort.color]),
                                   valueRange: paceRange,
                                   height: 150,
                                   valueFormat: { paceAxisLabel($0) },
                                   dateFormat: { $0.formatted(date: .abbreviated, time: .omitted) },
                                   accessibilityLabel: paceChartLabel,
                                   // Pace is stored in SECONDS per kilometre. Unformatted, the axis
                                   // read "0, 2.000, 4.000, 6.000" — a chart of a unit nobody thinks in.
                                   yAxisLabel: { paceAxisLabel($0) })
                        HStack(spacing: 14) {
                            if let line = model.paceTrend { paceTrendFact(line) }
                            if let line = model.efficiencyTrend { efficiencyFact(line) }
                        }
                        Text(paceCaption)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var sportPicker: some View {
        Menu {
            ForEach(model.sportChoices.prefix(30)) { choice in
                Button {
                    Task { await model.select(choice.sport) }
                } label: {
                    // Built from an already-localized sport name and a count, so the SEPARATOR is the
                    // only translatable part and it goes through the catalog like everything else.
                    Text(String(localized: "\(WorkoutSource.displaySport(choice.sport))  ·  \(choice.sessions)×"))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.selectedSport.map { WorkoutSource.displaySport($0) }
                     ?? String(localized: "Pick a sport"))
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// The charted series: pace for a sport read in pace, speed for one read in speed.
    private var paceChartPoints: [TrendPoint] {
        model.sportHistory.compactMap { session in
            let value: Double? = model.selectedModality.readout == .speed
                ? session.speedKmh
                : session.paceSecPerKm
            return value.map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(session.startTs)), value: $0)
            }
        }
    }

    private var paceRange: ClosedRange<Double> {
        let values = paceChartPoints.map(\.value)
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 0...1 }
        let pad = max(1.0, (hi - lo) * 0.2)
        return (lo - pad)...(hi + pad)
    }

    private func paceAxisLabel(_ value: Double) -> String {
        if model.selectedModality.readout == .speed {
            return UnitFormatter.speedFromKilometersPerHour(value, system: units) ?? "—"
        }
        return paceText(secPerKm: value, modality: model.selectedModality)
    }

    /// A pace in the unit its sport is actually spoken in. Swimming is read per hundred metres — every
    /// pool clock and every written set says so — and "4:37 /km" for a swim is the same number rendered
    /// in a unit no swimmer uses.
    private func paceText(secPerKm: Double, modality: CardioModality) -> String {
        guard modality.usesPerHundredMetres else {
            return UnitFormatter.paceFromSecPerKm(secPerKm, system: units)
        }
        let secPer100 = secPerKm / 10
        let minutes = Int(secPer100) / 60
        let seconds = Int(secPer100.rounded()) % 60
        return String(format: "%d:%02d /100 m", minutes, seconds)
    }

    private var paceChartLabel: String {
        model.selectedModality.readout == .speed
            ? String(localized: "Average speed per session")
            : String(localized: "Average pace per session")
    }

    /// Pace improving means the NUMBER FALLS, which is exactly the sort of inversion a chart hides. So
    /// the fact says "faster"/"slower" in words and puts the rate beside it.
    private func paceTrendFact(_ line: StrengthTrendLine) -> some View {
        let speedReadout = model.selectedModality.readout == .speed
        let improving = speedReadout ? line.slopePerWeek > 0 : line.slopePerWeek < 0
        let text: String
        if line.directionIsUnclear {
            text = String(localized: "no clear direction")
        } else if speedReadout {
            text = String(format: "%@ %.2f km/h per week",
                          improving ? String(localized: "faster") : String(localized: "slower"),
                          abs(line.slopePerWeek))
        } else {
            text = String(format: "%@ %.0f s/km per week",
                          improving ? String(localized: "faster") : String(localized: "slower"),
                          abs(line.slopePerWeek))
        }
        return factColumn(model.selectedModality.readout == .speed
                          ? String(localized: "Speed trend") : String(localized: "Pace trend"),
                          value: text,
                          tint: line.directionIsUnclear ? StrandPalette.textTertiary
                              : (improving ? StrandPalette.statusPositive : StrandPalette.statusWarning))
    }

    /// Beats per kilometre — the same distance costing fewer beats. Falling is the good direction, and
    /// the caption below the chart is where the confounders are named.
    private func efficiencyFact(_ line: StrengthTrendLine) -> some View {
        let improving = line.slopePerWeek < 0
        let text = line.directionIsUnclear
            ? String(localized: "no clear direction")
            : String(format: "%@ %.0f beats/km per week",
                     improving ? String(localized: "down") : String(localized: "up"),
                     abs(line.slopePerWeek))
        return factColumn(String(localized: "Heart cost"), value: text,
                          tint: line.directionIsUnclear ? StrandPalette.textTertiary
                              : (improving ? StrandPalette.statusPositive : StrandPalette.textSecondary))
    }

    private func factColumn(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.subhead).foregroundStyle(tint)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var paceCaption: String {
        var text = model.selectedModality.readout == .speed
            ? String(localized: "Average speed per session — distance over moving time. Only sessions that recorded both appear.")
            : String(localized: "Average pace per session — moving time over distance. Only sessions that recorded both appear, and a session's average says nothing about how it was paced inside: NOOP stores one distance and one duration, not splits.")
        text += " "
        text += String(localized: "Heart cost is beats spent per kilometre — average heart rate × minutes, over kilometres. It falls when the same distance costs your heart less, and it also moves with heat, hills, wind and sleep, so read the direction over weeks, never two sessions against each other.")
        return text
    }

    // MARK: - Bests

    @ViewBuilder
    private var bestsCard: some View {
        if !model.bests.isEmpty, let sport = model.selectedSport {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    SectionHeader("Your bests",
                                  overline: LocalizedStringKey(WorkoutSource.displaySport(sport)))
                    Spacer(minLength: 8)
                    Button { infoTopic = .bests } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What this means")
                }
                NoopCard {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if let farthest = model.bests.farthest {
                                bestChip(String(localized: "Farthest"),
                                         value: UnitFormatter.distanceFromMeters(farthest.value, system: units),
                                         day: farthest.day, tint: StrandPalette.metricCyan)
                            }
                            if let longest = model.bests.longest {
                                bestChip(String(localized: "Longest"),
                                         value: durationText(longest.value),
                                         day: longest.day, tint: DomainTheme.effort.color)
                            }
                            ForEach(CardioDistanceBand.allCases, id: \.self) { band in
                                if let best = model.bests.fastestPaceByBand[band] {
                                    bestChip(bandTitle(band),
                                             value: UnitFormatter.paceFromSecPerKm(best.value, system: units),
                                             day: best.day, tint: StrandPalette.accent)
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    private func bandTitle(_ band: CardioDistanceBand) -> String {
        switch band {
        case .short:    return String(localized: "Fastest short")
        case .medium:   return String(localized: "Fastest medium")
        case .long:     return String(localized: "Fastest long")
        case .veryLong: return String(localized: "Fastest very long")
        }
    }

    private func bestChip(_ label: String, value: String, day: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
            Text(value).font(StrandFont.number(17)).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
            Text(StrengthView.shortDay(day)).font(StrandFont.caption).foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minWidth: 108, alignment: .leading)
        .background(StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value), \(StrengthView.shortDay(day))")
    }

    // MARK: - Sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recent sessions", overline: "Log")
            VStack(spacing: 8) {
                ForEach(model.sessions.prefix(8), id: \.startTs) { session in
                    Button {
                        openDetail = DetailTarget(startTs: session.startTs, sport: session.sport)
                    } label: {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                    .strandPressable()
                }
            }
        }
    }

    private func sessionRow(_ session: CardioSessionMetrics) -> some View {
        NoopCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: sportSymbol(session))
                        .font(.system(size: 13))
                        .foregroundStyle(DomainTheme.effort.color)
                        .accessibilityHidden(true)
                    Text(WorkoutSource.displaySport(session.sport))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Date(timeIntervalSince1970: TimeInterval(session.startTs))
                        .formatted(date: .abbreviated, time: .omitted))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text(sessionDetailLine(session))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the session"))
    }

    /// The line the Workouts list could never write: the sport's own units first, then the body's answer.
    private func sessionDetailLine(_ session: CardioSessionMetrics) -> String {
        var parts: [String] = [durationText(session.durationS ?? 0)]
        if let distance = session.distanceM, distance > 0 {
            parts.append(UnitFormatter.distanceFromMeters(distance, system: units))
        }
        switch session.modality.readout {
        case .pace:
            if let pace = session.paceSecPerKm {
                parts.append(paceText(secPerKm: pace, modality: session.modality))
            }
        case .speed:
            if let speed = session.speedKmh,
               let text = UnitFormatter.speedFromKilometersPerHour(speed, system: units) {
                parts.append(text)
            }
        case .none:
            break
        }
        if let hr = session.avgHr { parts.append(String(localized: "\(hr) bpm avg")) }
        if let beats = session.beatsPerKm {
            parts.append(String(localized: "\(Int(beats.rounded())) beats/km"))
        }
        return parts.filter { $0 != "–" }.joined(separator: " · ")
    }

    private func sportSymbol(_ session: CardioSessionMetrics) -> String {
        switch session.modality {
        case .foot:     return "figure.run"
        case .cycling:  return "bicycle"
        case .swimming: return "figure.pool.swim"
        case .rowing:   return "figure.rower"
        default:        return "figure.mixed.cardio"
        }
    }

    /// The stored row behind a derived session, for the existing detail screen.
    private func workoutRow(for session: CardioSessionMetrics) -> WorkoutRow {
        WorkoutRow(startTs: session.startTs, endTs: session.endTs, sport: session.sport,
                   source: session.source, durationS: session.durationS,
                   energyKcal: session.energyKcal, avgHr: session.avgHr, maxHr: session.maxHr,
                   strain: session.strain, distanceM: session.distanceM, zonesJSON: nil,
                   notes: nil, steps: session.steps)
    }

    // MARK: - Wording

    private func durationText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "–" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m") }
        return String(localized: "\(minutes)m")
    }

    private func grouped(_ value: Double) -> String {
        HevySource.groupedKg(value)
    }

    private var weekRangeText: String {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: model.weekAnchorDay),
              let start = WeightSeries.date(forDay: monday),
              let end = WeightSeries.date(forDay: WeeklyDigestEngine.addDays(monday, 6)) else {
            return model.weekAnchorDay
        }
        let format = Date.FormatStyle().day().month(.abbreviated)
        return "\(start.formatted(format)) – \(end.formatted(format))"
    }

    private func bandLabel(_ band: ReadinessEngine.LoadBand) -> String {
        switch band {
        case .rampingDown:  return String(localized: "ramping down")
        case .steady:       return String(localized: "steady")
        case .buildingFast: return String(localized: "building fast")
        case .spiking:      return String(localized: "spiking")
        }
    }

    private func bandColor(_ band: ReadinessEngine.LoadBand) -> Color {
        switch band {
        case .rampingDown:  return StrandPalette.textSecondary
        case .steady:       return StrandPalette.statusPositive
        case .buildingFast: return StrandPalette.statusWarning
        case .spiking:      return StrandPalette.statusCritical
        }
    }

    // MARK: - Info

    enum InfoTopic: String, Identifiable {
        case cardioLoad, bests
        var id: String { rawValue }
    }

    private func infoSheet(_ topic: InfoTopic) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text(infoTitle(topic))
                        .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text(infoBody(topic))
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { infoTopic = nil } }
            }
        }
    }

    private func infoTitle(_ topic: InfoTopic) -> String {
        switch topic {
        case .cardioLoad: return String(localized: "Cardio load")
        case .bests:      return String(localized: "Your bests")
        }
    }

    private func infoBody(_ topic: InfoTopic) -> String {
        switch topic {
        case .cardioLoad:
            return String(localized: "Your cardio minutes over the last 7 days, divided by your average over the last 28. Around 1.0 means this week looks like your usual weeks; well above means you are ramping up faster than your body has been prepared for.\n\nMinutes rather than Effort, because Effort is already on this screen as its own number and a ratio of it would be a second opinion about the same thing. Minutes answer the question a training week is actually planned in: how much more time than usual.\n\nRest days count as zeros, so training twice in a week cannot read the same as training six times. It stays blank until there are four weeks of history.")
        case .bests:
            return String(localized: "Measured bests for this sport: the farthest you went, the longest you were out, and your fastest AVERAGE pace within each band of session length.\n\nThe bands matter. A fast 3 km and a fast half marathon are different achievements, so they are kept apart rather than competing for one 'fastest' line.\n\nThese are averages over a whole session, never splits. NOOP stores one distance and one duration per session, so 'your fastest 5 km' inside a longer run is a claim the data cannot support and is deliberately not offered.")
        }
    }

    // MARK: - Coach

    private var coachContext: CoachCardContext? {
        guard model.loaded, !model.sessions.isEmpty else { return nil }
        var parts: [String] = []
        parts.append("This week: \(model.week.sessionCount) cardio sessions, \(Int(model.week.minutes.rounded())) minutes")
        if model.week.distanceM > 0 {
            parts.append(String(format: "%.1f km", model.week.distanceM / 1000))
        }
        if let load = model.load {
            parts.append(String(format: "minute load acute:chronic %.2f (%@)", load.ratio,
                                bandLabel(load.band)))
        }
        if let sport = model.selectedSport, let line = model.paceTrend {
            parts.append(String(format: "%@ pace trend %+.0f s/km per week%@", sport,
                                line.slopePerWeek,
                                line.directionIsUnclear ? " (direction unclear)" : ""))
        }
        return CoachCardContext(
            title: String(localized: "Cardio"),
            summary: parts.joined(separator: " · "),
            suggestions: [
                String(localized: "Is my endurance volume sensible right now?"),
                String(localized: "Am I getting faster, or just training more?"),
                String(localized: "How should I split easy and hard sessions?"),
            ])
    }
}
