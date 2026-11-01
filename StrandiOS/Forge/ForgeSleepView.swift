#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import StrandCore

/// The redesign's Sleep tab (2026-11): last night's Rest and time asleep, tonight's bedtime from the
/// wind-down planner, the night's stages, and the way into the full Sleep screen (night by night, edits,
/// naps, marks, customisation), which stays the shipped one so nothing is lost.
///
/// Reads the SAME `SleepPresentationStore` model the shipped Sleep screen draws, so both agree.
struct ForgeSleepView: View {
    let onProfile: () -> Void
    var onAsk: (String) -> Void = { _ in }
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    @Environment(\.sleepPresentationStore) private var sceneSleepStore
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    private var sleepStore: SleepPresentationStore { sceneSleepStore ?? repo.sleepPresentation }
    @AppStorage(SleepChartStyle.storageKey) private var chartStyleRaw = SleepChartStyle.classic.rawValue

    @State private var model: SleepModel?
    @State private var restHistory: [(day: String, value: Double)] = []
    @State private var historyRange: HistoryRange = .week

    enum HistoryRange: String, CaseIterable, Identifiable {
        case week, month, year
        var id: String { rawValue }
        var days: Int { switch self { case .week: 7; case .month: 30; case .year: 365 } }
        var label: LocalizedStringKey { switch self { case .week: "Week"; case .month: "Month"; case .year: "Year" } }
    }
    @State private var loaded = false

    private var revision: SleepPresentationRevision { SleepPresentationRevision(repo: repo) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForgeLargeHeader(title: "Sleep", onProfile: onProfile).id("forge-sleep-top")
                    VStack(alignment: .leading, spacing: 14) {
                        if let model {
                            Text("\(nightDays(model)) · \(model.night.onsetText) to \(model.night.wakeText)")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(ForgeColor.secondary)
                                .padding(.horizontal, 4)
                            summaryTiles(model)
                            if coachFeatureEnabled {
                                Button {
                                    onAsk(String(localized: "Look at my last night's sleep and tell me what stood out and what I could change tonight."))
                                } label: {
                                    Label("Discuss last night with the coach", systemImage: "sparkles")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(ForgeColor.accent)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(Capsule().fill(ForgeColor.fill))
                                }
                                .buttonStyle(.plain)
                            }
                        } else if loaded {
                            ForgeTabHero(overline: String(localized: "Last night"),
                                         headline: String(localized: "No night recorded yet"))
                        }
                        tonightCard
                        if let model { nightCard(model) }
                        GoalsContextCard(context: .sleep)
                        if let model { nightFacts(model) }
                        if restHistory.count > 1 { history }
                        more
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("forge-sleep-top", anchor: .top) }
            }
        }
        .background(ForgeBackground(tab: .sleep))
        .refreshable { await repo.refresh() }
        .task(id: revision) {
            let key = revision
            if let presentation = try? await sleepStore.presentation(repo: repo, revision: key), key == revision {
                model = presentation.model
            }
            loaded = true
            let series = await repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource, days: 365)
            restHistory = series.map { ($0.day, $0.value) }
        }
    }

    // MARK: Summary

    private func summaryTiles(_ m: SleepModel) -> some View {
        HStack(spacing: 10) {
            NavigationLink(value: TabRoute.metric(HeroRingMetric.rest)) {
                ForgeMetricTile(label: DomainTheme.rest.productName,
                                value: m.performance.latest.map { "\(Int($0.rounded()))" }, unit: "%",
                                trend: Array(m.performance.series.suffix(7)), tint: ForgeColor.rest,
                                badge: m.performance.typical.map {
                                    (String(localized: "usually \(Int($0.rounded())) %"), ForgeBadge.Tone.neutral)
                                })
            }
            NavigationLink(value: TabRoute.sleep) {
                ForgeMetricTile(label: String(localized: "Asleep"),
                                value: ForgeTodayView.hoursMinutes(m.night.stages.asleep), unit: "h",
                                trend: nil, tint: ForgeColor.rest,
                                badge: m.typicalTotalMin.map {
                                    (String(localized: "usually \(ForgeTodayView.hoursMinutes($0)) h"), ForgeBadge.Tone.neutral)
                                })
            }
        }
        .buttonStyle(LiquidPressStyle())
    }

    // MARK: Tonight

    private var tonightCard: some View {
        let bed = ForgeToday.plannedBedtime(now: Date())
        let need = WindDownNudge.sleepNeedMinutes
        return NavigationLink(value: MoreDestination.alarms) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ForgeColor.rest)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(ForgeColor.rest.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tonight").font(.system(size: 17, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Text("Need \(ForgeTodayView.hoursMinutes(Double(need))) h · alarm \(wakeText)")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                Spacer()
                if let bed {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(bed, format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                            .font(ForgeFont.rounded(26, .bold)).foregroundStyle(ForgeColor.text)
                        Text("bedtime").font(.system(size: 11)).foregroundStyle(ForgeColor.secondary)
                    }
                }
            }
            .forgeCard(radius: 22, padding: 14)
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// Tomorrow's wake time from the same planner the bedtime comes from.
    private var wakeText: String {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let minutes = WindDownNudge.wakeMinutes(forWeekday: cal.component(.weekday, from: tomorrow))
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// "Sat to Sun": the two weekdays the night spans.
    private func nightDays(_ m: SleepModel) -> String {
        let start = m.night.onsetDate
        let end = Date(timeIntervalSince1970: TimeInterval(m.night.session.endTs))
        let style = Date.FormatStyle.dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale)
        return String(localized: "\(start.formatted(style)) to \(end.formatted(style))")
    }

    // MARK: Night

    private func nightCard(_ m: SleepModel) -> some View {
        // The per-stage rows ("Classic") need a full-width card; the tab draws the stepped chart instead,
        // in the palette the person chose.
        let chosen = SleepChartStyle.resolve(chartStyleRaw)
        let style: SleepChartStyle = chosen == .classic ? .filled : chosen
        return NavigationLink(value: TabRoute.sleep) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last night").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Text("\(m.night.onsetText) to \(m.night.wakeText)")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                Hypnogram(intervals: m.intervals, height: 150, showsStageAxis: true, showsHover: false,
                          nightStart: m.night.onsetDate, showsTimeAxis: true,
                          filled: style.isFilled, stagePalette: style.stagePalette)
                HStack(spacing: 14) {
                    stageFact(String(localized: "Deep"), m.night.stages.deep)
                    stageFact(String(localized: "REM"), m.night.stages.rem)
                    stageFact(String(localized: "Light"), m.night.stages.light)
                    stageFact(String(localized: "Awake"), m.night.stages.awake)
                }
            }
            .forgeCard(radius: 24, padding: 14)
        }
        .buttonStyle(LiquidPressStyle())
    }

    private func stageFact(_ label: String, _ minutes: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ForgeTodayView.hoursMinutes(minutes)).font(ForgeFont.rounded(17, .bold)).foregroundStyle(ForgeColor.text)
            Text(label).font(.system(size: 12)).foregroundStyle(ForgeColor.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func nightFacts(_ m: SleepModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "This night")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                NavigationLink(value: TabRoute.metric("sleep_efficiency")) {
                    ForgeMetricTile(label: String(localized: "Efficiency"),
                                    value: m.efficiency.latest.map { "\(Int($0.rounded()))" }, unit: "%",
                                    trend: Array(m.efficiency.series.suffix(7)), tint: ForgeColor.rest)
                }
                NavigationLink(value: TabRoute.metric("sleep_debt_min")) {
                    ForgeMetricTile(label: String(localized: "Sleep debt"),
                                    value: m.sleepDebt.latest.map { ForgeTodayView.hoursMinutes($0) }, unit: "h",
                                    trend: Array(m.sleepDebt.series.suffix(7)), tint: ForgeColor.rest)
                }
                NavigationLink(value: TabRoute.metric("sleep_consistency")) {
                    ForgeMetricTile(label: String(localized: "Consistency"),
                                    value: m.consistency.latest.map { "\(Int($0.rounded()))" }, unit: "%",
                                    trend: Array(m.consistency.series.suffix(7)), tint: ForgeColor.rest)
                }
                NavigationLink(value: TabRoute.metric("resp_rate")) {
                    ForgeMetricTile(label: String(localized: "Breathing"),
                                    value: m.respiratory.latest.map { String(format: "%.1f", $0) }, unit: "/min",
                                    trend: Array(m.respiratory.series.suffix(7)), tint: ForgeColor.rest)
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    // MARK: History

    /// Rest night by night over a week, a month or a year: the same stored series the Rest detail reads.
    private var history: some View {
        let points = restHistory.suffix(historyRange.days).compactMap { p -> (Date, Double)? in
            Self.dayParser.date(from: p.day).map { ($0, p.value) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            ForgeSectionTitle(title: "History")
            VStack(alignment: .leading, spacing: 10) {
                Picker("Range", selection: $historyRange) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Chart {
                    ForEach(points, id: \.0) { p in
                        if historyRange == .week {
                            BarMark(x: .value("Night", p.0, unit: .day), y: .value("Rest", p.1))
                                .foregroundStyle(ForgeColor.rest.opacity(0.85))
                                .cornerRadius(5)
                        } else {
                            LineMark(x: .value("Night", p.0), y: .value("Rest", p.1))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(ForgeColor.rest)
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .frame(height: 150)
                .accessibilityLabel(Text("Rest night by night"))
            }
            .forgeCard(radius: 22, padding: 14)
        }
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: More

    private var more: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "Nights, alarm and naps")
            ForgeGroup {
                NavigationLink(value: TabRoute.sleep) {
                    ForgeRow(systemImage: "bed.double.fill", tint: ForgeColor.rest, title: String(localized: "Night by night"),
                             subtitle: String(localized: "Every night, edit times, naps and marks"))
                }
                ForgeRowDivider()
                NavigationLink(value: MoreDestination.alarms) {
                    ForgeRow(systemImage: "alarm.fill", tint: .orange, title: String(localized: "Smart alarm and bedtime"),
                             subtitle: String(localized: "Wake window and wind-down reminder"))
                }
            }
            .buttonStyle(.plain)
        }
    }
}
#endif
