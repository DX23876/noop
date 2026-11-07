#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

/// The redesign's Effort page: the ring, today's target from the Coupled bands, what added to it today,
/// the last 14 days and how Effort is made. The value is the one the Today ring shows (passed in, so the
/// two can never disagree); the full metric history stays one tap away.
struct ForgeEffortDetailView: View {
    let effortStored: Double?
    let charge: Double?
    var onAsk: (String) -> Void = { _ in }

    @EnvironmentObject private var repo: Repository
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    @State private var todayWorkouts: [WorkoutRow] = []

    private var target: ClosedRange<Double>? { ForgeToday.effortTargetStored(charge: charge) }
    private var shown: Double? { effortStored.map { UnitFormatter.effortValue($0, scale: effortScale) } }

    @State private var scrolledPast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: String(localized: "Today"), title: DomainTheme.effort.productName,
                                  scrolledPast: $scrolledPast)
                VStack(spacing: 10) {
                    OrganicScoreHeroClock(dataReady: true) { frame in
                        ScoreRing(
                            model: OrganicScoreVisualModel.resolve(metric: .effort, value: shown,
                                                                   scaleMaximum: effortScale == .whoop ? 21 : 100),
                            tint: StrandPalette.organicEffort, score: shown,
                            decimals: effortScale == .whoop ? 1 : 0, frame: frame, diameter: 170, hitDiameter: 170)
                            .frame(width: 170, height: 170)
                    }
                    ForgeScoreCaption(name: DomainTheme.effort.productName, tint: ForgeColor.effortInk,
                                      detail: target.map {
                                          let t = ForgeToday.targetText($0, scale: effortScale)
                                          return String(localized: "target \(t.low) to \(t.high)")
                                      })
                    if let line = ForgeToday.summary(effortStored: effortStored, charge: charge, scale: effortScale) {
                        Text(line).font(.system(.body)).foregroundStyle(ForgeColor.text)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text(effortStored.map { value -> LocalizedStringKey in
                        let figure = ForgeToday.effortText(value, scale: effortScale)
                        return "Why \(figure)?"
                    } ?? "What added to it today")
                        .font(ForgeFont.section).foregroundStyle(ForgeColor.text)
                        .padding(.horizontal, 4)
                    if todayWorkouts.isEmpty {
                        Text("No workout yet today. Effort also counts everyday movement and heart rate through the day.")
                            .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(todayWorkouts.enumerated()), id: \.offset) { index, row in
                                if index > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                                NavigationLink(value: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) {
                                    workoutRow(row)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .forgeCard(radius: ForgeRadius.card, padding: 14)
                    }
                }

                ForgeDailyChart(title: String(localized: "Last 14 days"),
                                points: lastDays.map { ($0.day, UnitFormatter.effortValue($0.strain ?? 0, scale: effortScale)) },
                                maxValue: effortScale == .whoop ? 21 : 100, tint: ForgeColor.effort, bars: true,
                                history: TabRoute.effort(DashboardEffortReadout(day: Repository.logicalDayKey(Date()),
                                                                                value: effortStored)),
                                bands: lastDays.map { d in
                                    ForgeToday.effortTargetStored(charge: d.recovery).map {
                                        UnitFormatter.effortValue($0.lowerBound, scale: effortScale)
                                            ... UnitFormatter.effortValue($0.upperBound, scale: effortScale)
                                    }
                                },
                                caption: String(localized: "The shaded band is the target your Charge allowed on each day."))

                ForgeExplainer(title: "How Effort is made",
                               text: "Effort adds up how hard your heart worked through the day against your own resting and maximum heart rate, workouts included. The target comes from this morning's Charge: more Charge, more room. Everything is calculated on this iPhone.") { ExplainerScoreInputs.effort }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .training))
        .forgeDetailBar(title: DomainTheme.effort.productName, showsTitle: scrolledPast)
        .task {
            let cal = Calendar.current
            todayWorkouts = (await repo.workoutRows(days: 2, reconcileHrCap: 0))
                .filter { cal.isDateInToday(Date(timeIntervalSince1970: TimeInterval($0.startTs))) }
                .sorted { $0.startTs > $1.startTs }
        }
    }

    private var lastDays: [DailyMetric] { Array(repo.days.suffix(14).filter { $0.strain != nil }) }

    /// One session of today: sport, start time and length, and the session's own Effort. Effort is not a
    /// sum of its sessions, so the rows list what happened without splitting the day's figure into shares.
    private func workoutRow(_ row: WorkoutRow) -> some View {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let minutes = Int((row.durationS ?? Double(row.endTs - row.startTs)) / 60)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkoutSource.localizedDisplaySport(row.sport))
                    .font(.system(.callout)).foregroundStyle(ForgeColor.text)
                Text("\(start.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))) · \(minutes) min")
                    .font(.system(.footnote)).foregroundStyle(ForgeColor.secondary)
            }
            Spacer(minLength: 8)
            if let strain = row.strain {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(ForgeToday.effortText(strain, scale: effortScale))
                        .font(ForgeFont.rounded(19, .bold)).foregroundStyle(ForgeColor.text)
                    Text(DomainTheme.effort.productName).font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The redesign's Rest page: the ring, how last night measured against the wearer's usual, the nights
/// before, and how Rest is made. Reads the SAME sleep presentation model the Sleep screens use.
struct ForgeRestDetailView: View {
    let rest: Double?
    var onAsk: (String) -> Void = { _ in }

    @EnvironmentObject private var repo: Repository
    @Environment(\.sleepPresentationStore) private var sceneSleepStore
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    private var sleepStore: SleepPresentationStore { sceneSleepStore ?? repo.sleepPresentation }
    @State private var model: SleepModel?

    @State private var scrolledPast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: String(localized: "Last night"), title: DomainTheme.rest.productName,
                                  scrolledPast: $scrolledPast)
                VStack(spacing: 10) {
                    OrganicScoreHeroClock(dataReady: true) { frame in
                        ScoreRing(
                            model: OrganicScoreVisualModel.resolve(metric: .rest, value: rest, scaleMaximum: 100),
                            tint: StrandPalette.organicRest, score: rest, decimals: 0, frame: frame,
                            diameter: 170, hitDiameter: 170)
                            .frame(width: 170, height: 170)
                    }
                    ForgeScoreCaption(name: DomainTheme.rest.productName, tint: ForgeColor.restInk,
                                      detail: rest.map { ForgeToday.restWord($0).lowercased(with: AppLanguage.activeLocale) })
                    if let m = model {
                        Text("\(ForgeTodayView.hoursMinutes(m.night.stages.asleep)) h asleep, \(m.night.onsetText) to \(m.night.wakeText)")
                            .font(.system(.body)).foregroundStyle(ForgeColor.text)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)

                if let m = model {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(rest.map { value -> LocalizedStringKey in
                            let figure = "\(Int(value.rounded())) %"
                            return "Why \(figure)?"
                        } ?? "What shaped it")
                            .font(ForgeFont.section).foregroundStyle(ForgeColor.text)
                            .padding(.horizontal, 4)
                        // A factor that has never left zero (last night 0, usually 0) has no nights behind it
                        // yet; it is left out rather than shown as a result.
                        let factors = [(String(localized: "Hours against your need"), m.hoursVsNeeded),
                                       (String(localized: "Efficiency"), m.efficiency),
                                       (String(localized: "Consistency"), m.consistency),
                                       (String(localized: "Restorative sleep"), m.restorative)]
                            .filter { !(($0.1.latest ?? 0) == 0 && ($0.1.typical ?? 0) == 0) }
                        VStack(spacing: 0) {
                            ForEach(Array(factors.enumerated()), id: \.offset) { i, f in
                                if i > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                                factor(f.0, f.1)
                            }
                        }
                        .forgeCard(radius: ForgeRadius.card, padding: 14)
                    }
                }

                ForgeDailyChart(title: String(localized: "Last 14 days"),
                                points: Array((model?.performance.series ?? []).suffix(14).enumerated()).map {
                                    (String($0.offset), $0.element)
                                },
                                maxValue: 100, tint: ForgeColor.rest, bars: false, indexed: true,
                                history: TabRoute.metric(HeroRingMetric.rest),
                                lastLabel: model?.performance.latestDay.flatMap(ForgeDailyChart.weekdayLetter))

                ForgeExplainer(title: "How Rest is made",
                               text: "Rest weighs how long you slept against what you needed, how well you slept, how regular your times were and how much deep and REM sleep you got. Everything is calculated on this iPhone.") { ExplainerScoreInputs.rest }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .sleep))
        .forgeDetailBar(title: DomainTheme.rest.productName, showsTitle: scrolledPast)
        .task {
            let revision = SleepPresentationRevision(repo: repo)
            model = (try? await sleepStore.presentation(repo: repo, revision: revision))?.model
        }
    }

    /// One factor: last night's value, which way it moved Rest against the wearer's usual, and both on the
    /// 0 to 100 track. Two points either way count as usual.
    private func factor(_ label: String, _ metric: SleepModel.Metric) -> some View {
        let delta: Int = {
            guard let latest = metric.latest, let typical = metric.typical else { return 0 }
            return latest - typical >= 2 ? 1 : (latest - typical <= -2 ? -1 : 0)
        }()
        return ForgeWhyRow(label: label,
                           value: metric.latest.map { "\(Int($0.rounded())) %" } ?? "–",
                           delta: delta,
                           usual: metric.typical.map { String(localized: "usually \(Int($0.rounded())) %") },
                           track: metric.latest.map { ($0, metric.typical) })
    }
}

// MARK: - Shared pieces of the score pages

/// Today's Effort on a 0 to 100 track with the target band marked (the same track the evening note shows).
struct ForgeEffortTargetBar: View {
    let effort: Double
    let target: ClosedRange<Double>
    let scale: EffortScale

    var body: some View {
        let t = ForgeToday.targetText(target, scale: scale)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(ForgeColor.fill)
                    Capsule().fill(ForgeColor.effort.opacity(ForgeOpacity.band))
                        .frame(width: w * (target.upperBound - target.lowerBound) / 100)
                        .offset(x: w * target.lowerBound / 100)
                    Circle().fill(ForgeColor.effort).frame(width: 12, height: 12)
                        .offset(x: max(0, min(w - 12, w * effort / 100 - 6)))
                }
            }
            .frame(height: 12)
            Text("Effort \(ForgeToday.effortText(effort, scale: scale)), target \(t.low) to \(t.high)")
                .font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.fill))
        .accessibilityElement(children: .combine)
    }
}

/// "Last 14 days" as the prototype draws it: the title with a History link beside it, then one value per
/// day in a card, as bars or a line, optionally over a shaded band per day (Effort's daily target).
struct ForgeDailyChart: View {
    let title: String
    let points: [(String, Double)]
    let maxValue: Double
    let tint: Color
    var bars = true
    /// When the keys are positions rather than day keys (a series without dates).
    var indexed = false
    var history: TabRoute? = nil
    /// A band per point (same order as `points`), drawn behind the marks.
    var bands: [ClosedRange<Double>?] = []
    var caption: String? = nil
    /// The label under the newest mark when the keys are positions (`indexed`): the series has no dates,
    /// so only its newest point can be named.
    var lastLabel: String? = nil

    /// Grid values on the score's own scale: thirds on 0 to 100, sevens on Effort's 0 to 21.
    static func ticks(_ maxValue: Double) -> [Double] {
        maxValue <= 21 ? [0, 7, 14, 21] : [0, 33, 66, 100].filter { $0 <= maxValue }
    }

    /// The weekday letter under a mark, read from its day key; nil for a key that is not a date.
    private func axisLabel(_ index: Int) -> String? {
        guard points.indices.contains(index) else { return nil }
        if indexed { return index == points.count - 1 ? lastLabel : nil }
        return ForgeDailyChart.weekdayLetter(points[index].0)
    }

    static func weekdayLetter(_ dayKey: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: dayKey) else { return nil }
        return date.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(ForgeFont.section).foregroundStyle(ForgeColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let history {
                    NavigationLink(value: history) {
                        Text("History").font(.system(.body)).foregroundStyle(ForgeColor.accent)
                    }
                }
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) {
                if points.count > 1 {
                    // Days as categories: relative bar and band widths need a categorical axis.
                    Chart {
                        ForEach(Array(points.enumerated()), id: \.offset) { index, p in
                            if index < bands.count, let band = bands[index] {
                                RectangleMark(x: .value("Day", "\(index)"),
                                              yStart: .value("Low", band.lowerBound), yEnd: .value("High", band.upperBound),
                                              width: .ratio(1))
                                    .foregroundStyle(tint.opacity(ForgeOpacity.band))
                            }
                            if bars {
                                BarMark(x: .value("Day", "\(index)"), y: .value("Value", p.1), width: .ratio(0.62))
                                    .foregroundStyle(tint.opacity(index == points.count - 1 ? 1 : 0.6))
                                    .cornerRadius(4)
                            } else {
                                AreaMark(x: .value("Day", "\(index)"), y: .value("Value", p.1))
                                    .interpolationMethod(.linear)
                                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.02)],
                                                                    startPoint: .top, endPoint: .bottom))
                                LineMark(x: .value("Day", "\(index)"), y: .value("Value", p.1))
                                    .interpolationMethod(.linear)
                                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                                    .foregroundStyle(tint)
                                if index == points.count - 1 {
                                    PointMark(x: .value("Day", "\(index)"), y: .value("Value", p.1))
                                        .symbolSize(40).foregroundStyle(tint)
                                }
                            }
                        }
                    }
                    .chartYScale(domain: 0...maxValue)
                    // Real values on labelled axes: the score on the right, the day under each mark.
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: Self.ticks(maxValue)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ForgeColor.separator)
                            AxisValueLabel().font(.system(.caption2)).foregroundStyle(ForgeColor.tertiary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: points.indices.map { "\($0)" }) { value in
                            if let raw = value.as(String.self), let index = Int(raw),
                               let label = axisLabel(index) {
                                AxisValueLabel {
                                    Text(label).font(.system(.caption2))
                                        .foregroundStyle(index == points.count - 1 ? ForgeColor.text : ForgeColor.tertiary)
                                }
                            }
                        }
                    }
                    .frame(height: 150)
                    if let caption {
                        Text(caption).font(.system(.footnote)).foregroundStyle(ForgeColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Not enough days yet.").font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                }
            }
            .forgeCard(radius: ForgeRadius.card, padding: 14)
        }
    }
}

/// "How X is made": one short paragraph under the page's chart.
struct ForgeExplainer<Picture: View>: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @ViewBuilder var picture: () -> Picture

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            picture()
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(ForgeFont.section).foregroundStyle(ForgeColor.text)
                Text(text).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// A pushed score page's header as the prototype draws it: an optional overline above the large title.
/// The bar shows the title once the header has scrolled away (`forgeDetailBar`).
struct ForgeDetailHeader: View {
    let overline: String?
    let title: String
    @Binding var scrolledPast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let overline {
                Text(overline.uppercased(with: AppLanguage.activeLocale))
                    .font(ForgeFont.overDate).foregroundStyle(ForgeColor.secondary)
            }
            Text(title).font(ForgeFont.largeTitle).foregroundStyle(ForgeColor.text)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).maxY < 0 } action: { scrolledPast = $0 }
    }
}

/// The score's name in its colour with a short word under it, between the ring and the page's sentence.
struct ForgeScoreCaption: View {
    let name: String
    let tint: Color
    let detail: String?

    /// The page title already names the score, so under the ring only its verdict is printed ("Low"), in
    /// the score's colour; the name stands in only while there is no verdict yet.
    var body: some View {
        let verdict = detail.map { $0.prefix(1).uppercased(with: AppLanguage.activeLocale) + $0.dropFirst() }
        Text(verdict ?? name)
            .font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(tint)
            .accessibilityLabel(Text(verbatim: verdict.map { "\(name), \($0)" } ?? name))
    }
}

/// One "Why N?" row: the factor, its value, which way it moved the score, and a 0 to 100 track with the
/// wearer's usual marked and last night's value as a dot (only for values that live on that scale).
struct ForgeWhyRow: View {
    let label: String
    let value: String
    let delta: Int
    var usual: String? = nil
    /// Last night and the usual value on a 0 to 100 scale, when the factor has one.
    var track: (value: Double, usual: Double?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Driver labels come from the analytics package in English; the catalog carries their translations.
                Text(LocalizedStringKey(label)).font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    .lineLimit(2).layoutPriority(1)
                Spacer(minLength: 8)
                Text(value).font(ForgeFont.rounded(19, .regular)).foregroundStyle(ForgeColor.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                ForgeDirection(delta: delta).frame(minWidth: 64, alignment: .trailing)
            }
            if let track {
                GeometryReader { geo in
                    let w = geo.size.width
                    let dot = delta > 0 ? ForgeColor.chargeInk : delta < 0 ? ForgeColor.effortInk : ForgeColor.secondary
                    ZStack(alignment: .leading) {
                        Capsule().fill(ForgeColor.fill).frame(height: 6)
                        if let usual = track.usual {
                            Capsule().fill(ForgeColor.chargeInk.opacity(0.55)).frame(width: 3, height: 14)
                                .offset(x: max(0, min(w - 3, w * usual / 100 - 1.5)))
                        }
                        Circle().fill(dot).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(ForgeColor.card, lineWidth: 2))
                            .offset(x: max(0, min(w - 14, w * track.value / 100 - 7)))
                    }
                    .frame(height: 14)
                }
                .frame(height: 14)
            }
            if let usual {
                Text(usual).font(.system(.footnote)).foregroundStyle(ForgeColor.secondary)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The inline bar of a pushed score page: empty while its own header shows, the title once scrolled.
    func forgeDetailBar(title: String, showsTitle: Bool) -> some View {
        navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(.headline).foregroundStyle(ForgeColor.text)
                        .opacity(showsTitle ? 1 : 0)
                        .accessibilityHidden(!showsTitle)
                }
            }
    }
}
#endif
