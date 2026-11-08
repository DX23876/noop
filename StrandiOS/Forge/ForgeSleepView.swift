#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

/// The redesign's Sleep tab (2026-11): the night with arrows to the nights before, Rest and time asleep,
/// tonight's bedtime from the wind-down planner, the night's stages, highlights against the wearer's
/// usual, the night's figures, history and the alarm. The full Sleep screen (edits, naps, marks,
/// customisation) stays one tap away so nothing is lost.
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
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    @State private var presentation: SleepPresentation?
    @State private var model: SleepModel?
    /// 0 = the latest night; 1 the one before, and so on (the arrows above the tiles).
    @State private var nightOffset = 0
    @State private var shownNight: Night?
    @State private var restByDay: [String: Double] = [:]
    @State private var historyRange: HistoryRange = .week
    @State private var loaded = false

    enum HistoryRange: String, CaseIterable, Identifiable {
        case week, month, year
        var id: String { rawValue }
        var days: Int { switch self { case .week: 7; case .month: 30; case .year: 365 } }
        var label: LocalizedStringKey { switch self { case .week: "Week"; case .month: "Month"; case .year: "Year" } }
    }

    private var revision: SleepPresentationRevision { SleepPresentationRevision(repo: repo) }
    private var night: Night? { shownNight ?? model?.night }
    private var wakeKey: String? { night.map { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.session.endTs))) } }
    private var nightRow: DailyMetric? { wakeKey.flatMap { key in repo.days.last(where: { $0.day == key }) } }
    /// The need every sleep card names: the one the Rest score and the debt ledger use.
    private var need: Double { SleepModel.debtNeedMin(days: repo.days) }
    /// The night editor, its undo and the nap delete confirmation, shared with the full Sleep screen.
    @StateObject private var editor = SleepNightEditor()
    /// The bedtime planner still counts back from the wearer's own setting in Alarms.
    private var plannedNeed: Double { Double(WindDownNudge.sleepNeedMinutes) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForgeLargeHeader(title: "Sleep", onProfile: onProfile) { ForgeSearchButton() }.id("forge-sleep-top")
                    VStack(alignment: .leading, spacing: 14) {
                        if let model, let night {
                            nightNavigator(night)
                            summaryTiles(model, night: night)
                            if coachFeatureEnabled {
                                Button {
                                    onAsk(String(localized: "Look at my last night's sleep and tell me what stood out and what I could change tonight."))
                                } label: {
                                    Label("Discuss last night with the coach", systemImage: "bubble.left")
                                        .font(.system(.subheadline, weight: .semibold))
                                        .foregroundStyle(ForgeColor.accent)
                                        .frame(maxWidth: .infinity, minHeight: 46)
                                        .background(Capsule().fill(ForgeColor.card.opacity(0.6)))
                                }
                                .buttonStyle(.plain)
                            }
                        } else if loaded {
                            ForgeTabHero(overline: String(localized: "Last night"),
                                         headline: String(localized: "No night recorded yet"))
                        }
                        tonightCard
                        SleepUndoStrip(editor: editor)
                        if let model, let night {
                            nightCard(night)
                            naps(night)
                            if night.stages.total > 0 { ForgeNightBreakdown(model: model, night: night) }
                            GoalsContextCard(context: .sleep)
                            highlights(model, night: night)
                            nightFacts(model)
                        }
                        history
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
        .overlay { ForgeStatusBarScrim(tab: .sleep) }
        .refreshable { await repo.refresh() }
        .sleepNightEditing(editor)
        .task(id: revision) {
            let key = revision
            if let p = try? await sleepStore.presentation(repo: repo, revision: key), key == revision {
                presentation = p
                model = p.model
            }
            loaded = true
            let series = await repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource, days: 400)
            restByDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        .task(id: nightOffset) {
            guard nightOffset > 0, let presentation else { shownNight = nil; return }
            shownNight = try? await sleepStore.night(offset: nightOffset, presentation: presentation, repo: repo,
                                                     revision: revision)
        }
    }

    // MARK: Night navigation

    private func nightNavigator(_ night: Night) -> some View {
        HStack {
            Button { nightOffset += 1 } label: {
                Image(systemName: "chevron.left").font(.system(.body, weight: .semibold))
                    .frame(width: 44, height: 36)
            }
            .accessibilityLabel(Text("Previous night"))
            Spacer()
            Text("\(nightDays(night)) · \(night.onsetText) to \(night.wakeText)")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(ForgeColor.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer()
            Button { if nightOffset > 0 { nightOffset -= 1 } } label: {
                Image(systemName: "chevron.right").font(.system(.body, weight: .semibold))
                    .frame(width: 44, height: 36)
            }
            .disabled(nightOffset == 0)
            .accessibilityLabel(Text("Next night"))
        }
        .foregroundStyle(ForgeColor.text)
    }

    // MARK: Summary

    /// The last seven days' weekday initials, Monday-first order kept from the dates themselves.
    private func weekdayLabels(_ count: Int) -> [String] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
            .map { $0.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.activeLocale)) }
    }

    private func summaryTiles(_ m: SleepModel, night: Night) -> some View {
        let rest = wakeKey.flatMap { restByDay[$0] } ?? (nightOffset == 0 ? m.performance.latest : nil)
        let asleepWeek = repo.days.suffix(7).map { ($0.totalSleepMin ?? 0) / 60 }
        return HStack(spacing: 10) {
            NavigationLink(value: ForgeRoute.rest(rest)) {
                ForgeMetricTile(label: DomainTheme.rest.productName,
                                value: rest.map { "\(Int($0.rounded()))" }, unit: "%",
                                trend: Array(m.performance.series.suffix(7)), tint: ForgeColor.rest,
                                badge: rest.map { r in
                                    (ForgeToday.restWord(r), r >= 80 ? ForgeBadge.Tone.good : r >= 60 ? .neutral : .attention)
                                },
                                axisLabels: weekdayLabels(7))
            }
            NavigationLink(value: TabRoute.metric("sleep_total_min")) {
                ForgeMetricTile(label: String(localized: "Sleep duration"),
                                value: ForgeTodayView.hoursMinutes(night.stages.asleep), unit: "h",
                                trend: asleepWeek.count > 1 ? asleepWeek : nil, tint: ForgeColor.rest,
                                badge: (String(localized: "Need \(ForgeTodayView.hoursMinutes(need)) h"), .attention),
                                axisLabels: weekdayLabels(7))
            }
        }
        .buttonStyle(LiquidPressStyle())
    }

    // MARK: Tonight

    private var tonightCard: some View {
        let bed = ForgeToday.plannedBedtime(now: Date())
        return NavigationLink(value: MoreDestination.alarms) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "moon.fill")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(ForgeColor.rest)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(ForgeColor.rest.opacity(ForgeOpacity.wash)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Tonight").font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                        Text("for full recovery").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    Spacer()
                    if let bed {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(bed, format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                                .font(.system(size: 32, weight: .regular, design: .rounded))
                                .foregroundStyle(ForgeColor.restInk)
                            Text("bedtime").font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
                        }
                    }
                }
                Rectangle().fill(ForgeColor.separator).frame(height: 0.5)
                Text("Need **\(ForgeTodayView.hoursMinutes(need)) h** · alarm \(wakeText)")
                    .font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                // The bedtime above counts back from the setting, so say so when the two needs part.
                if abs(need - plannedNeed) >= 15 {
                    Text("Bedtime counts \(ForgeTodayView.hoursMinutes(plannedNeed)) h, as set in Alarms.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            .forgeCard(radius: ForgeRadius.card, padding: 16)
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
    private func nightDays(_ night: Night) -> String {
        let start = night.onsetDate
        let end = Date(timeIntervalSince1970: TimeInterval(night.session.endTs))
        let style = Date.FormatStyle.dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale)
        return String(localized: "\(start.formatted(style)) to \(end.formatted(style))")
    }

    // MARK: Night

    private func nightCard(_ night: Night) -> some View {
        // The prototype draws the stages as lanes; "Classic" (per-stage rows) maps to that here, any other
        // style the person chose keeps its own look.
        let chosen = SleepChartStyle.resolve(chartStyleRaw)
        let filled = chosen == .classic ? false : chosen.isFilled
        let palette = chosen == .classic ? SleepStagePalette.noop : chosen.stagePalette
        let edited = night.editGroup.contains(where: \.userEdited)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(nightOffset == 0 ? "Last night" : "This night").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                Spacer()
                Text("\(night.onsetText) to \(night.wakeText)")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                // The same editor the full Sleep screen opens, here in place.
                Button { editor.edit(night) } label: {
                    Image(systemName: edited ? "pencil.circle.fill" : "pencil.circle")
                        .font(.title3)
                        .foregroundStyle(ForgeColor.restInk)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Edit sleep times"))
            }
            if night.stages.total > 0 {
                // The breakdown below reads the night in full, so the chart opens nothing else.
                VStack(alignment: .leading, spacing: 10) {
                        Hypnogram(intervals: night.intervals, height: 170, showsStageAxis: true, showsHover: false,
                                  nightStart: night.onsetDate, showsTimeAxis: true, filled: filled, stagePalette: palette)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.card))
                        let parts: [(String, Double, Color)] = [
                            (String(localized: "Deep"), night.stages.deep, StrandPalette.sleepStageColor(.deep, palette: palette)),
                            (String(localized: "REM"), night.stages.rem, StrandPalette.sleepStageColor(.rem, palette: palette)),
                            (String(localized: "Light"), night.stages.light, StrandPalette.sleepStageColor(.light, palette: palette)),
                            (String(localized: "Awake"), night.stages.awake, StrandPalette.sleepStageColor(.awake, palette: palette)),
                        ]
                        // The night's make-up as one bar, in the chart's own stage colours.
                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                ForEach(parts, id: \.0) { part in
                                    Rectangle().fill(part.2)
                                        .frame(width: max(0, (geo.size.width - 6) * part.1 / max(night.stages.total, 1)))
                                }
                            }
                            .clipShape(Capsule())
                        }
                        .frame(height: 10)
                        .accessibilityHidden(true)
                        HStack(spacing: 14) {
                            ForEach(parts, id: \.0) { stageFact($0.0, $0.1, color: $0.2) }
                        }
                }
            } else {
                Text("No sleep stages for this night.")
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            }
        }
        .forgeCard(radius: ForgeRadius.card, padding: 14)
    }

    // MARK: Naps

    /// The day's blocks outside the main night, each removable when it was detected wrongly. The delete, its
    /// confirmation and its undo are the shared night editor's, as on the full Sleep screen.
    @ViewBuilder private func naps(_ night: Night) -> some View {
        let main = Set(SleepView.mainNightGroup(night.sourceBlocks, habitualMidsleepSec: presentation?.habitualMidsleepSec).map(\.startTs))
        let blocks = night.sourceBlocks.filter { !main.contains($0.startTs) }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForgeSectionTitle(title: "Naps")
                VStack(spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.element.startTs) { index, nap in
                        if index > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                        napRow(nap)
                    }
                }
                .forgeCard(radius: ForgeRadius.card, padding: 14)
            }
        }
    }

    private func napRow(_ nap: CachedSleepSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "powersleep")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(ForgeColor.rest)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(Night.clockString(nap.effectiveStartTs)) – \(Night.clockString(nap.endTs))")
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                Text(ForgeTodayView.hoursMinutes(Double(nap.endTs - nap.effectiveStartTs) / 60))
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
            Spacer(minLength: 8)
            Button { editor.napPendingDelete = nap } label: {
                Image(systemName: "trash")
                    .font(.system(.body))
                    .foregroundStyle(ForgeColor.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Delete nap"))
        }
    }

    private func stageFact(_ label: String, _ minutes: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ForgeTodayView.hoursMinutes(minutes)).font(ForgeFont.rounded(17, .bold)).foregroundStyle(ForgeColor.text)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Highlights

    private struct Highlight: Identifiable {
        let id: String
        let title: String
        let detail: String
        let word: String
        let tone: ForgeBadge.Tone
    }

    /// What this night did differently from the wearer's usual, from the typical values the sleep model
    /// already keeps. Only differences of at least ten minutes count.
    private func highlightItems(_ m: SleepModel, night: Night) -> [Highlight] {
        let rows: [(String, String, Double, Double?)] = [
            ("asleep", String(localized: "Time asleep"), night.stages.asleep, m.typicalTotalMin),
            ("deep", String(localized: "Deep sleep"), night.stages.deep, m.typicalDeepMin),
            ("rem", String(localized: "REM sleep"), night.stages.rem, m.typicalRemMin),
            ("light", String(localized: "Light sleep"), night.stages.light, m.typicalLightMin),
        ]
        return rows.compactMap { id, title, value, typical in
            guard let typical, abs(value - typical) >= 10 else { return nil }
            let more = value > typical
            return Highlight(id: id, title: title,
                             detail: String(localized: "\(ForgeTodayView.hoursMinutes(value)), usually \(ForgeTodayView.hoursMinutes(typical))"),
                             word: more ? String(localized: "more") : String(localized: "less"),
                             tone: more ? .good : .attention)
        }
    }

    @ViewBuilder private func highlights(_ m: SleepModel, night: Night) -> some View {
        let items = highlightItems(m, night: night)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForgeSectionTitle(title: "Highlights")
                TabView {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.fill")
                                    .font(.system(.callout, weight: .semibold))
                                    .foregroundStyle(ForgeColor.restInk)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(ForgeColor.rest.opacity(ForgeOpacity.wash)))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                                    Text(item.detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                                }
                                Spacer()
                                ForgeBadge(text: item.word, tone: item.tone)
                            }
                            Text("\(index + 1) of \(items.count)").font(.system(.caption)).foregroundStyle(ForgeColor.tertiary)
                        }
                        .padding(.bottom, 16)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(height: 110)
                .forgeCard(radius: ForgeRadius.card, padding: 14)
            }
        }
    }

    // MARK: This night

    /// The body through the night, each figure with its last fourteen nights as bars, this night drawn
    /// full. Efficiency and breathing rate lead "What shaped the night" above, so they are not repeated
    /// here; breathing stays when that card is absent (a night without stages).
    private func nightFacts(_ m: SleepModel) -> some View {
        let row = nightRow
        let key = wakeKey ?? ""
        let recent = Array(repo.days.filter { $0.day <= key }.suffix(14))
        func series(_ f: (DailyMetric) -> Double?) -> [Double?] { recent.map(f) }
        var facts: [NightSignal] = [
            NightSignal(label: String(localized: "Wake-ups"), value: row?.disturbances.map(String.init), unit: "",
                        symbol: "eye.fill", series: series { $0.disturbances.map(Double.init) }),
            NightSignal(label: String(localized: "Resting HR at night"), value: row?.restingHr.map(String.init), unit: "bpm",
                        symbol: "heart.fill", series: series { $0.restingHr.map(Double.init) }),
            NightSignal(label: String(localized: "HRV"), value: row?.avgHrv.map { "\(Int($0.rounded()))" }, unit: "ms",
                        symbol: "waveform.path.ecg", series: series { $0.avgHrv }),
            NightSignal(label: String(localized: "Skin temperature"), value: row?.skinTempDevC.map { String(format: "%+.1f", $0) },
                        unit: "°C", symbol: "thermometer.medium", series: series { $0.skinTempDevC }),
        ]
        if (night?.stages.total ?? 0) <= 0 {
            facts.insert(NightSignal(label: String(localized: "Breaths/min"), value: row?.respRateBpm.map { String(format: "%.1f", $0) },
                                     unit: "", symbol: "lungs.fill", series: series { $0.respRateBpm }), at: 3)
        }
        return VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "This night")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(facts) { ForgeNightSignalTile(signal: $0, highlightLast: recent.last?.day == key) }
            }
        }
    }

    // MARK: History

    /// Hours asleep night by night with the sleep need as a dotted line, as in the prototype.
    private var history: some View {
        let points: [(Date, Double)] = repo.days.suffix(historyRange.days).compactMap { d in
            guard let m = d.totalSleepMin, let date = Self.dayParser.date(from: d.day) else { return nil }
            return (date, m / 60)
        }
        return VStack(alignment: .leading, spacing: 10) {
            ForgeSectionTitle(title: "History")
            Picker("Range", selection: $historyRange) {
                ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if points.count > 1 {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, p in
                        BarMark(x: .value("Night", p.0, unit: .day), y: .value("Hours", p.1))
                            .foregroundStyle(ForgeColor.rest.opacity(index == points.count - 1 ? 1 : 0.55))
                            .cornerRadius(historyRange == .year ? 1 : 5)
                    }
                    RuleMark(y: .value("Need", need / 60))
                        .foregroundStyle(ForgeColor.restInk)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 4]))
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    if historyRange == .week {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        }
                    } else {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        }
                    }
                }
                .frame(height: 150)
                .forgeCard(radius: ForgeRadius.card, padding: 14)
                .accessibilityLabel(Text("Hours asleep night by night"))
            }
        }
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Alarm and naps

    private var reminderText: String {
        guard WindDownNudge.isEnabled, let bed = ForgeToday.plannedBedtime(now: Date()) else {
            return String(localized: "Off")
        }
        let at = bed.addingTimeInterval(TimeInterval(-WindDownNudge.leadMinutes * 60))
        return String(localized: "Reminder at \(at.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale)))")
    }

    private var more: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "Alarms")
            ForgeGroup {
                NavigationLink(value: MoreDestination.alarms) {
                    ForgeRow(systemImage: "alarm.fill", tint: ForgeColor.rest, title: String(localized: "Smart alarm"),
                             subtitle: String(localized: "Wakes you in a light phase, alarm \(wakeText)"))
                }
                ForgeRowDivider()
                NavigationLink(value: MoreDestination.alarms) {
                    ForgeRow(systemImage: "moon.fill", tint: ForgeColor.rest, title: String(localized: "Bedtime"),
                             subtitle: reminderText)
                }
            }
            .buttonStyle(.plain)
            // What the full Sleep screen kept beyond the night itself: marks for the night and the nights
            // deleted by mistake, so the tab no longer sends anyone to the older page for them.
            SleepMarkCard()
            DeletedSleepNightsSection()
        }
    }
}

/// One body signal of the night for the "This night" grid.
struct NightSignal: Identifiable {
    let label: String
    let value: String?
    let unit: String
    let symbol: String
    /// Oldest first; the last entry is the night on screen.
    let series: [Double?]
    var id: String { label }
}

/// A night's figure large, with the nights before it as small bars: the one on screen drawn full, the
/// others faint, a missing night a dot on the baseline. The bars rise once when the tile appears.
struct ForgeNightSignalTile: View {
    let signal: NightSignal
    let highlightLast: Bool
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let present = signal.series.compactMap { $0 }
        let lo = present.min() ?? 0, hi = present.max() ?? 1
        let span = max(hi - lo, 0.0001)
        VStack(alignment: .leading, spacing: 8) {
            Label(signal.label, systemImage: signal.symbol)
                .font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                .labelStyle(.titleAndIcon).lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(signal.value ?? "–").font(ForgeFont.rounded(26, .bold)).foregroundStyle(ForgeColor.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if signal.value != nil, !signal.unit.isEmpty {
                    Text(signal.unit).font(.system(.footnote, weight: .medium)).foregroundStyle(ForgeColor.secondary)
                }
            }
            if present.count > 1 {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(signal.series.enumerated()), id: \.offset) { i, v in
                        let isLast = highlightLast && i == signal.series.count - 1
                        if let v {
                            // Scaled within the fortnight, with a floor so the lowest night still shows.
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(ForgeColor.rest.opacity(isLast ? 1 : 0.35))
                                .frame(height: (6 + 22 * (v - lo) / span) * (grown ? 1 : 0.15))
                                .frame(maxWidth: .infinity)
                        } else {
                            Circle().fill(ForgeColor.separator).frame(width: 3, height: 3).frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 28, alignment: .bottom)
                .accessibilityHidden(true)
            } else {
                Color.clear.frame(height: 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .forgeCard(radius: ForgeRadius.card, padding: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(signal.label))
        .accessibilityValue(Text(verbatim: [signal.value ?? "–", signal.unit].filter { !$0.isEmpty }.joined(separator: " ")))
        .revealWhenVisible {
            if reduceMotion { grown = true; return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.88).delay(0.05)) { grown = true }
        }
    }
}
#endif
