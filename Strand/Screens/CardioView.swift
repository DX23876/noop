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
//   • a week that adds up (sessions, moving time, distance, calories, TRIMP) with the wearer's OWN
//     usual week behind the headline figure rather than a target,
//   • cardiovascular load from additive session TRIMP, shown as the last seven days against the
//     wearer's own 28-day level rather than as a borrowed acute:chronic category,
//   • per-sport progression in that sport's own unit, with measured bests beside the modelled line,
//   • and beats per kilometre, the one figure that says whether the same run is costing less.
//
// Sessions open the EXISTING `WorkoutDetailView`. A second detail screen for the same row would be two
// places to fix a wrong number.

struct CardioView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    /// The wearer's own zone definitions — the same resolver every other zone display reads.
    @EnvironmentObject private var profile: ProfileStore

    @StateObject private var model = CardioModel()

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var units: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                  override: distanceSystemRaw)
    }

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
                    weekControl
                    loadHero
                    weekFigures
                    loadChart
                    TrainingHistoryLink(focus: .cardio) {
                        TrainingHistoryRow(subtitle: String(localized: "Your cardio load and VO₂max over months and years"))
                    }
                    intensityCard.id("intensity")
                    activityTiles(proxy)
                    sportMix
                    sportProgress.id("progress")
                    bestsCard
                    recentSessions
                    explainers
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
            model.zoneSet = profile.hrZoneSet
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

    private var weekControl: some View {
        TrainingWeekControl(overline: String(localized: "Endurance"), rangeText: weekRangeText,
                            canGoBack: model.weekOffset > model.minWeekOffset,
                            canGoForward: model.weekOffset < 0,
                            step: { delta in step(delta) },
                            ranges: CardioModel.HistoryRange.allCases,
                            selectedRange: $model.range,
                            rangeLabel: { $0.label })
    }

    /// The week's cardio load against the wearer's usual, read exactly as Training Load reads it.
    private var loadHero: some View {
        let lane = model.lane
        return LoadHeroCard(lane: .cardio, title: String(localized: "Cardio load"),
                            percent: lane?.trend?.percentChange, state: LoadPillState.of(lane),
                            figure: lane.map(trimpText), trend: model.laneRatios.compactMap(\.cardio),
                            coverage: lane.flatMap { $0.possibleCount > 0
                                ? String(localized: "\($0.measuredCount) of \($0.possibleCount) sessions complete")
                                : nil },
                            caveat: loadCaveat)
    }

    private func trimpText(_ lane: TrainingLoadModel.Lane) -> String {
        let total = String(localized: "\(Int(lane.sevenDayTotal.rounded())) TRIMP")
        return lane.isLowerBound ? String(localized: "at least \(total)") : total
    }

    private var loadCaveat: String? {
        guard let lane = model.lane, lane.possibleCount > 0 else { return nil }
        if model.laneSeries?.measured == false {
            return String(localized: "No usable heart-rate trace in this window, so cardiovascular load is not estimated")
        }
        guard Double(lane.measuredCount) / Double(lane.possibleCount) < TrainingLoad.trustedRatedShare else { return nil }
        return String(localized: "Only \(lane.measuredCount) of \(lane.possibleCount) sessions are complete; the measured total is a lower bound")
    }

    private var weekFigures: some View {
        VStack(spacing: NoopMetrics.space2) {
            KPIStrip(lane: .cardio, items: [
                KPIItem(id: "sessions", icon: "figure.run", value: "\(model.week.sessionCount)",
                        label: String(localized: "Sessions")),
                KPIItem(id: "time", icon: "clock.fill", value: durationText(model.week.minutes * 60),
                        label: String(localized: "Moving time"), caption: usualMinutesText),
                KPIItem(id: "distance", icon: "point.topleft.down.to.point.bottomright.curvepath",
                        value: model.week.distanceM > 0
                            ? UnitFormatter.distanceFromMeters(model.week.distanceM, system: units) : "—",
                        label: String(localized: "Distance"), caption: distanceCoverageText),
                KPIItem(id: "energy", icon: "flame.fill",
                        value: model.week.energyKcal > 0 ? grouped(model.week.energyKcal) : "—",
                        label: String(localized: "Calories"), caption: model.week.energyKcal > 0 ? "kcal" : nil),
            ])
            if let typical = model.typicalMinutes, model.week.minutes > 0 {
                NoopCard(padding: NoopMetrics.space3) { weekAgainstUsual(typical) }
            }
        }
    }

    /// This week's minutes against the wearer's own usual week — the same `TypicalRangeBar` grammar the
    /// Strength screen uses for muscle volume, so "the shaded part is normal for you" is learned once.
    private func weekAgainstUsual(_ typical: ClosedRange<Double>) -> some View {
        let scale = max(model.week.minutes, typical.upperBound, 1)
        return HStack(spacing: 10) {
            Text("vs your usual")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 92, alignment: .leading)
            TypicalRangeBar(value: model.week.minutes / scale,
                            typical: (typical.lowerBound / scale)...(typical.upperBound / scale),
                            color: TrainingLane.cardio.color, height: 8)
            Text(String(localized: "\(Int(typical.lowerBound.rounded()))–\(Int(typical.upperBound.rounded())) min"))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
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

    private var loadChart: some View {
        LoadHistoryChart(lane: .cardio, title: String(localized: "Cardio load"), unit: "TRIMP",
                         byDay: model.laneSeries?.byDay ?? [:], unknownDays: model.laneSeries?.unknownDays ?? [],
                         readingDay: model.laneReadingDay,
                         usualWeek: model.lane?.relative.personalRange.map { $0.usualLowerBound...$0.usualUpperBound })
    }

    private func step(_ delta: Int) {
        Task { await model.stepWeek(delta, repo: repo) }
    }

    // MARK: - Activity and heart rate

    @ViewBuilder private func activityTiles(_ proxy: ScrollViewProxy) -> some View {
        let top = model.loadShares.first
        if top != nil || model.weekAverageHr != nil {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.gap),
                                GridItem(.flexible(), spacing: NoopMetrics.gap)],
                      spacing: NoopMetrics.gap) {
                if let top {
                    SummaryTile(symbol: CardioView.symbol(for: top.modality), tint: TrainingLane.cardio.color,
                                title: String(localized: "Most used activity"), headline: sportName(top.sport),
                                detail: activityDetail(top),
                                action: {
                                    Task { await model.select(top.sport) }
                                    withAnimation { proxy.scrollTo("progress", anchor: .top) }
                                }) { EmptyView() }
                }
                if let hr = model.weekAverageHr {
                    SummaryTile(symbol: "heart.fill", tint: StrandPalette.statusCritical,
                                title: String(localized: "Average heart rate"),
                                headline: String(localized: "\(Int(hr.rounded())) bpm"),
                                detail: model.typicalAverageHr.map {
                                    String(localized: "usual \(Int($0.rounded())) bpm")
                                },
                                action: { withAnimation { proxy.scrollTo("intensity", anchor: .top) } }) {
                        EmptyView()
                    }
                }
            }
        }
    }

    /// The sport's share of the week's measured load, and its pace in the unit that sport is read in.
    private func activityDetail(_ share: CardioSportLoadShare) -> String {
        var parts = [String(localized: "\(Int((share.share * 100).rounded())) % of cardio load")]
        if let pace = model.topSportPace {
            switch share.modality.readout {
            case .pace: parts.append(paceText(secPerKm: pace, modality: share.modality))
            case .speed:
                if let speed = UnitFormatter.speedFromKilometersPerHour(3600 / pace, system: units) {
                    parts.append(speed)
                }
            case .none: break
            }
        }
        return parts.joined(separator: " · ")
    }

    static func symbol(for modality: CardioModality) -> String {
        switch modality {
        case .foot:     return "figure.run"
        case .cycling:  return "bicycle"
        case .swimming: return "figure.pool.swim"
        case .rowing:   return "figure.rower"
        default:        return "figure.mixed.cardio"
        }
    }

    // MARK: - Intensity distribution

    /// Where this week's training time actually sat, by heart-rate zone.
    ///
    /// The question a weekly total cannot answer: five hours of cardio is a different week depending on
    /// whether it was all easy or half of it hard. It is reported as MEASURED TIME and nothing else —
    /// no ideal shape is implied, because the polarised and threshold models disagree about what that
    /// shape should be, and which applies depends on the sport, the phase and the athlete.
    @ViewBuilder private var intensityCard: some View {
        if let split = model.zoneSplit, split.total > 0 {
            let minutes = split.minutes
            let total = split.total
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Intensity", overline: "Time in zone",
                              trailing: durationText(total * 60))
                NoopCard(tint: TrainingLane.cardio.color) {
                    VStack(alignment: .leading, spacing: 12) {
                        GeometryReader { geo in
                            // Five segments leave four 2-point gaps. Subtract them before distributing
                            // the measured time so the bar ends exactly at the card edge.
                            let barWidth = max(0, geo.size.width - 8)
                            HStack(spacing: 2) {
                                ForEach(0..<5, id: \.self) { index in
                                    Rectangle()
                                        .fill(StrandPalette.hrZoneColor(index + 1))
                                        .frame(width: max(0, CGFloat(minutes[index] / total) * barWidth))
                                }
                            }
                        }
                        .frame(height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(zoneSplitAccessibilityLabel(minutes, total: total))
                        Divider().overlay(StrandPalette.hairline)
                        HStack(spacing: 0) {
                            ForEach(0..<5, id: \.self) { index in
                                zoneStat(index + 1, minutes: minutes[index], total: total)
                            }
                        }
                    }
                }
            }
        }
    }

    private func zoneStat(_ zone: Int, minutes: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StrandPalette.hrZoneColor(zone))
                    .frame(width: 9, height: 9)
                Text("Z\(zone)" as String).strandOverline()
            }
            Text("\(Int((minutes / max(total, 0.001) * 100).rounded()))%")
                .font(StrandFont.number(15))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(durationText(minutes * 60))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func zoneSplitAccessibilityLabel(_ minutes: [Double], total: Double) -> String {
        let parts = (1...5).map { zone in
            String(localized: "zone \(zone) \(Int((minutes[zone - 1] / total * 100).rounded())) percent")
        }
        return String(localized: "Heart-rate zone split: \(parts.joined(separator: ", "))")
    }

    /// What the split rests on — said plainly, because a five-bar chart looks equally precise whether it
    /// came from a dense trace or from one averaged value per minute.
    private func zoneProvenanceText(_ split: CardioZoneSplit) -> String {
        let base = split.sessionsRead == split.sessionsPossible
            ? String(localized: "Measured across all \(split.sessionsRead) sessions this week.")
            : String(localized: "Measured across \(split.sessionsRead) of \(split.sessionsPossible) sessions this week; the rest had no heart-rate trace complete enough to bin.")
        guard split.usedMinuteBuckets else { return base }
        return base + " " + String(localized: "Part of it comes from Apple Health, which stores one averaged heart rate per minute — enough for time in zone, not enough to resolve intervals shorter than a minute.")
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
                                    Text(sportName(total.sport))
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
                    Text(String(localized: "\(sportName(choice.sport))  ·  \(choice.sessions)×"))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.selectedSport.map { sportName($0) }
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
                SectionHeader("Your bests", overline: LocalizedStringKey(sportName(sport)))
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
            if !model.enduranceSessions.isEmpty {
                SectionHeader("Endurance", overline: "Recent sessions")
                sessionButtons(Array(model.enduranceSessions.prefix(8)))
            }
            if !model.conditioningSessions.isEmpty {
                SectionHeader("Conditioning", overline: "Team, interval and mixed sports")
                sessionButtons(Array(model.conditioningSessions.prefix(8)))
            }
            if !model.otherSessions.isEmpty {
                SectionHeader("Other", overline: "Recent sessions")
                sessionButtons(Array(model.otherSessions.prefix(8)))
            }
        }
    }

    private func sessionButtons(_ sessions: [CardioSessionMetrics]) -> some View {
        VStack(spacing: 8) {
            ForEach(sessions, id: \.startTs) { session in
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

    private func sessionRow(_ session: CardioSessionMetrics) -> some View {
        NoopCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: sportSymbol(session))
                        .font(.system(size: 13))
                        .foregroundStyle(DomainTheme.effort.color)
                        .accessibilityHidden(true)
                    Text(sportName(session.sport))
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

    /// Localized display for the common cardio labels while the stored sport stays locale-stable for
    /// imports, deduplication and export. Unknown/free-text labels pass through exactly as entered.
    private func sportName(_ sport: String) -> String {
        WorkoutSource.localizedDisplaySport(sport)
    }

    private func sportSymbol(_ session: CardioSessionMetrics) -> String {
        CardioView.symbol(for: session.modality)
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

    // MARK: - How it works

    private var explainers: some View {
        var items = [
            ExplainerItem(id: "load", symbol: "function", title: String(localized: "Cardio load"),
                          subtitle: String(localized: "How your cardio load is calculated"),
                          text: String(localized: "How much cardiovascular work the last 7 days asked of you, against your own level over the last 28 days. It is a percentage, not a score: +18 % means the recent week ran about a fifth above your usual.\n\nThe underlying signal is additive TRIMP, derived from heart rate and time in intensity zones. Moving time stays separate because sixty easy minutes and sixty threshold minutes are equal duration but very different cardiovascular loads.\n\nRest days count as zeros. Neither direction is good or bad on its own: a higher week can be a planned build or too much, and the load alone cannot tell those apart. Charge and your own session rating add that context. It stays blank until there are two weeks of history.")),
            ExplainerItem(id: "bests", symbol: "trophy", title: String(localized: "Your bests"),
                          subtitle: String(localized: "What counts as a best"),
                          text: String(localized: "Measured bests for this sport: the farthest you went, the longest you were out, and your fastest AVERAGE pace within each band of session length.\n\nThe bands matter. A fast 3 km and a fast half marathon are different achievements, so they are kept apart rather than competing for one 'fastest' line.\n\nThese are averages over a whole session, never splits. NOOP stores one distance and one duration per session, so 'your fastest 5 km' inside a longer run is a claim the data cannot support and is deliberately not offered.")),
        ]
        if let split = model.zoneSplit, split.total > 0 {
            items.append(ExplainerItem(id: "zones", symbol: "waveform.path.ecg",
                                       title: String(localized: "Intensity"),
                                       subtitle: String(localized: "Where the zone split comes from"),
                                       text: zoneProvenanceText(split)))
        }
        return ExplainerRows(items: items)
    }

    // MARK: - Coach

    private var coachContext: CoachCardContext? {
        guard model.loaded, !model.sessions.isEmpty else { return nil }
        var parts: [String] = []
        parts.append("This week: \(model.week.sessionCount) cardio sessions, \(Int(model.week.minutes.rounded())) minutes")
        if model.week.distanceM > 0 {
            parts.append(String(format: "%.1f km", model.week.distanceM / 1000))
        }
        if let load = model.lane?.trend {
            parts.append(String(format: "cardio load %+.0f%% vs own 28-day level", load.percentChange))
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
