#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

/// The redesign's Sleep tab (2026-11), told as one story (owner, 2026-11-28): last night with arrows to the nights
/// before (Rest and time asleep), the night in detail (its curve, stages and what shaped it), tonight (bedtime,
/// sleep balance, alarm, marks) and the weeks (history, body clock, the week's sleep goal). Each figure appears
/// once. The full Sleep screen (edits, naps, marks, customisation) stays one tap away so nothing is lost.
///
/// Reads the SAME `SleepPresentationStore` model the shipped Sleep screen draws, so both agree.
struct ForgeSleepView: View {
    let onProfile: () -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.sleepPresentationStore) private var sceneSleepStore
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    private var sleepStore: SleepPresentationStore { sceneSleepStore ?? repo.sleepPresentation }
    @AppStorage(SleepChartStyle.storageKey) private var chartStyleRaw = SleepChartStyle.classic.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    @State private var presentation: SleepPresentation?
    @State private var model: SleepModel?
    /// 0 = the latest night; 1 the one before, and so on (the arrows above the tiles).
    @State private var nightOffset = 0
    /// The night offset whose editor should open once that night is on screen (an add refused for lying on
    /// top of it).
    @State private var pendingEdit: Int?
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
    private var need: Double { SleepModel.currentNeedMin(days: repo.days, restTraits: repo.restTraits) }
    /// The night editor, its undo and the nap delete confirmation, shared with the full Sleep screen.
    @StateObject private var editor = SleepNightEditor()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForgeLargeHeader(title: "Sleep", onProfile: onProfile) {
                        ForgeCoachButton(page: .sleep, day: wakeKey)
                        ForgeSearchButton()
                    }.id("forge-sleep-top")
                    VStack(alignment: .leading, spacing: 14) {
                        // While last night is not in yet: syncing, being worked out, a failed sync, no sync yet,
                        // or no night found, decided by the shared `SleepFreshness` as on Android and the
                        // classic page. Held until the page has read its nights, so it never flashes.
                        if loaded {
                            SleepFreshnessNote(latestWakeTs: model?.night.session.endTs) { words in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: words.symbol).font(.headline).foregroundStyle(ForgeColor.accent)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(words.title).font(.headline).foregroundStyle(ForgeColor.text)
                                        if let message = words.message {
                                            Text(message).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .forgeCard()
                                .accessibilityElement(children: .combine)
                            }
                        }
                        // The page as one story (owner, 2026-11-28): last night, the night in detail, tonight, the
                        // weeks. The coach is the header's button; a second one under the tiles said the same.
                        if let model, let night {
                            nightNavigator(night)
                            summaryTiles(model, night: night)
                        } else if loaded {
                            ForgeTabHero(overline: String(localized: "Last night"),
                                         headline: String(localized: "No night recorded yet"))
                            // A night the strap missed entirely is exactly when someone needs this, and
                            // there is no night card below to hang it on.
                            addSleepRow(endTs: Int(Date().timeIntervalSince1970))
                        }
                        SleepUndoStrip(editor: editor)
                        if let model, let night {
                            nightCard(night)
                            naps(night)
                            addSleepRow(endTs: night.session.endTs)
                            if night.stages.total > 0 { ForgeNightBreakdown(model: model, night: night) }
                            nightFacts(model)
                        }
                        tonight
                        history
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .forgeDemoScrollAnchor()
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("forge-sleep-top", anchor: .top) }
            }
        }
        .background(ForgeBackground(tab: .sleep))
        .overlay { ForgeStatusBarScrim(tab: .sleep) }
        .refreshable { await ForgeConnectedRefresh.shared.pull(); await repo.refresh() }
        .overlay(alignment: .top) { ForgeRefreshStrips() }
        .sleepNightEditing(editor)
        // An add refused for lying on top of a stored sleep offers that sleep. This page browses one night
        // at a time, so it moves to the night that holds the onset and opens the editor there.
        .onChange(of: editor.jumpToSleepStart) { target in
            guard let target else { return }
            // Cleared FIRST, whatever happens next: a jump dropped because the page had not loaded used to
            // leave the value set, and `onChange` then never fired again for the same sleep.
            editor.jumpToSleepStart = nil
            guard let groups = presentation?.groups,
                  let index = groups.firstIndex(where: { $0.contains { $0.effectiveStartTs == target } })
            else { return }
            // The night in the way is often the one already on screen. Setting the offset it already holds
            // restarts nothing, so the editor has to be opened here rather than waited for.
            if index == nightOffset {
                if let night = shownNight ?? model?.night { editor.edit(night) }
            } else {
                pendingEdit = index
                nightOffset = index
            }
        }
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
            defer {
                // The night asked for is on screen now, so the editor can open on it.
                if pendingEdit == nightOffset, let night = shownNight ?? model?.night {
                    pendingEdit = nil
                    editor.edit(night)
                }
            }
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
                                value: ForgeTodayView.hoursMinutes(night.stages.asleep), unit: String(localized: "h"),
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
                        Text("Bedtime").font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                        Text("for full recovery").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    Spacer()
                    if let bed {
                        Text(bed, format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                            .font(ForgeFont.figure(26))
                            .foregroundStyle(ForgeColor.restInk)
                    }
                }
                Rectangle().fill(ForgeColor.separator).frame(height: 0.5)
                Text("Need **\(ForgeTodayView.hoursMinutes(need)) h** · alarm \(wakeText)")
                    .font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
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
        // In the reader's clock, as the bedtime above it: "7:00 AM" beside "11:00 PM", not "07:00".
        let wake = cal.date(byAdding: .minute, value: minutes, to: cal.startOfDay(for: tomorrow)) ?? tomorrow
        return wake.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.activeLocale))
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
                Text(Repository.isLastNight(endTs: night.session.endTs, now: Date()) ? "Last night" : "This night")
                    .font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                Spacer()
                Text("\(night.onsetText) to \(night.wakeText)")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                // The same editor the full Sleep screen opens, here in place.
                Button { editor.edit(night) } label: {
                    // The plain pencil, as Android draws it: the outlined circle at this size read as a no-entry
                    // sign (design critique 2026-11-28). An edited night keeps the filled badge.
                    Image(systemName: edited ? "pencil.circle.fill" : "pencil")
                        .font(edited ? .title3 : .system(.body, weight: .semibold))
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
                        nightFigures(night)
                        Hypnogram(intervals: night.intervals, height: 170, showsStageAxis: true, showsHover: false,
                                  nightStart: night.onsetDate, showsTimeAxis: true, filled: filled, stagePalette: palette)
                            .padding(10)
                            .background(ForgeCardSurface(radius: ForgeRadius.inner))
                }
            } else {
                Text("No sleep stages for this night.")
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            }
        }
        .forgeCard(radius: ForgeRadius.card, padding: 16)
    }

    /// Time in bed, efficiency, and the night in hours: how long asleep and how much of it restorative,
    /// each against the wearer's usual.
    ///
    /// The page had the last two only as percentage rings, and the hours only in the Highlights carousel
    /// and only when a stage was ten minutes off the usual. A tester asked for them back (2026-11-19):
    /// the figures were reachable only through Health, Sleep, Sleep details, which is three taps away
    /// from the page that is about last night. The numbers are `NightSummaryFacts`', the same resolver
    /// the old screen's "Stage breakdown" header reads, so the two cards cannot state different hours
    /// for one night.
    @ViewBuilder private func nightFigures(_ night: Night) -> some View {
        let facts = NightSummaryFacts.read(
            night: NightSummaryFacts.Night(inBedMin: night.timeInBed, asleepMin: night.stages.asleep,
                                           deepMin: night.stages.deep, remMin: night.stages.rem,
                                           storedEfficiency: night.session.efficiency),
            days: repo.days)
        // An Oura night's stages are the ring's own classification, not NOOP's approximation, and the
        // old screen says so in its own words; a night without the stager's segments gets neither line.
        let caption = (night.realSegments?.count ?? 0) >= 2
            ? (repo.activeDeviceIsOura ? String(localized: "raw on-device stages")
                                       : String(localized: "stages approximate (on-device)"))
            : nil
        VStack(alignment: .leading, spacing: 10) {
            Text(caption.map {
                String(localized: "\(Self.durationText(facts.inBedMin)) in bed · \(Self.percentText(facts.efficiencyPct)) efficiency · \($0)")
            } ?? String(localized: "\(Self.durationText(facts.inBedMin)) in bed · \(Self.percentText(facts.efficiencyPct)) efficiency"))
                .font(ForgeFont.caption)
                .foregroundStyle(ForgeColor.secondary)
            HStack(alignment: .top, spacing: 16) {
                figure(String(localized: "Time asleep"), minutes: facts.asleepMin,
                       typical: facts.typicalAsleepMin, tint: ForgeColor.text)
                figure(String(localized: "Restorative sleep"), minutes: facts.restorativeMin,
                       typical: facts.typicalRestorativeMin,
                       tint: StrandPalette.sleepStageColor(.rem))
                Spacer(minLength: 0)
            }
        }
    }

    private func figure(_ label: String, minutes: Double, typical: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.durationText(minutes)).font(ForgeFont.figure(26)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(.caption, weight: .semibold)).foregroundStyle(ForgeColor.text)
            if let typical {
                Text("usually \(Self.durationText(typical))")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "8:13 h": every length on the page in one form, as the summary tiles and the stage rows write it
    /// (owner, 2026-11-28; "8h 13m" beside "8:00 h" read as two different measures).
    static func durationText(_ minutes: Double) -> String {
        // Through the catalogue's "%@ h", so Russian reads "ч" and Chinese "小时", as the old "7ч 47м" did.
        String(localized: "\(ForgeTodayView.hoursMinutes(minutes)) h")
    }

    static func percentText(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Adding a sleep NOOP never recorded: a night it missed, or a nap. It sits under the night it would
    /// join, because that is where someone is standing when they notice the gap.
    private func addSleepRow(endTs: Int) -> some View {
        Button {
            let anchor = Date(timeIntervalSince1970: TimeInterval(endTs))
            let day = Repository.localDayKey(anchor)
            let hasMain = repo.sleeps.contains {
                Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == day
            }
            editor.startAdding(dayStart: anchor, hasMainSleep: hasMain)
        } label: {
            Label("Add a sleep", systemImage: "plus")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(ForgeColor.restInk)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(Capsule().fill(ForgeColor.fill))
        }
        .buttonStyle(.plain)
    }

    // MARK: Naps

    /// The day's blocks outside the main night, each removable when it was detected wrongly. The delete, its
    /// confirmation and its undo are the shared night editor's, as on the full Sleep screen.
    @ViewBuilder private func naps(_ night: Night) -> some View {
        // One nap rule with the Today timeline, the Coach's context and Android (owner, 2026-11-11):
        // `SleepNight.naps` — a block off the main night that the wearer entered, or that has ten minutes
        // of sleep in it (an unstaged block: ten minutes of span).
        let main = SleepView.mainNightGroup(night.sourceBlocks, habitualMidsleepSec: presentation?.habitualMidsleepSec)
        let blocks = SleepNight.naps(night.sourceBlocks, mainGroup: main)
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForgeSectionTitle(title: "Naps")
                VStack(spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.element.startTs) { index, nap in
                        if index > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                        napRow(nap)
                    }
                }
                .forgeCard(radius: ForgeRadius.card, padding: 16)
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
            facts.insert(NightSignal(label: String(localized: "Breaths/min"), value: row?.respRateBpm.map { UnitFormatter.localizedMark(String(format: "%.1f", $0)) },
                                     unit: "", symbol: "lungs.fill", series: series { $0.respRateBpm }), at: 3)
        }
        // It continues "What shaped the night" right above it, so it carries no title of its own; "This night"
        // beside "Last night" and "Tonight" named three nights for one (owner, 2026-11-28).
        return VStack(alignment: .leading, spacing: 8) {
            if (night?.stages.total ?? 0) <= 0 { ForgeSectionTitle(title: "What shaped the night") }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
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
                VStack(alignment: .leading, spacing: 10) {
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
                .accessibilityLabel(Text("Hours asleep night by night"))
                // The chart has no scale of its own; the dotted line's key gives it one.
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(ForgeColor.restInk).frame(width: 2.5, height: 2.5) }
                    }
                    Text("Need \(ForgeTodayView.hoursMinutes(need)) h")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                .accessibilityElement(children: .combine)
                }
                .forgeCard(radius: ForgeRadius.card, padding: 16)
            }
            if let night, let phase = appModel.circadianPhase, phase.confidence != .unreadable {
                let clock = BodyClockDialCard(estimate: phase,
                                              actualBedHour: SleepView.localClockHour(night.session.effectiveStartTs),
                                              actualWakeHour: SleepView.localClockHour(night.session.endTs), bare: true)
                if clock.drawsDial { clock.forgeCard(radius: ForgeRadius.card, padding: 16) }
            }
            GoalsContextCard(context: .sleep)
            DeletedSleepNightsSection()
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

    /// Tonight as one block: when to go to bed, the balance behind it, the alarm and the night's marks.
    private var tonight: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForgeSectionTitle(title: "Tonight")
            tonightCard
            if let model {
                SleepDebtLedgerCard(model: model, bare: true)
                    .forgeCard(radius: ForgeRadius.card, padding: 16)
            }
            ForgeGroup {
                NavigationLink(value: MoreDestination.alarms) {
                    ForgeRow(systemImage: "alarm.fill", tint: ForgeColor.rest, title: String(localized: "Smart alarm"),
                             subtitle: String(localized: "Wakes you in a light phase, alarm \(wakeText)"), plainMark: true)
                }
                ForgeRowDivider(inset: 56)
                NavigationLink(value: MoreDestination.alarms) {
                    ForgeRow(systemImage: "moon.fill", tint: ForgeColor.rest, title: String(localized: "Wind down"),
                             subtitle: reminderText, plainMark: true)
                }
            }
            .buttonStyle(.plain)
            SleepMarkCard()
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
                Text(signal.value ?? "–").font(ForgeFont.figure(26)).foregroundStyle(ForgeColor.text)
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
        .forgeCard(radius: ForgeRadius.card, padding: 16)
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
