import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import StrandCore

// MARK: - Weight — overview, history and reports (owner decisions 2026-11-26)
//
// The Today tile answers "what do I weigh?" in one number. This screen answers what that number cannot: which way
// it is going, where it leads, how it went month by month. Every figure comes from ONE derivation,
// `WeightTracker` (StrandAnalytics), fed by `WeightTrackerPreparation` (shared with the Android core). No maths
// happens in this file: a second smoothing in a view is how a screen starts disagreeing with the goal card, the
// widgets and the coach about the same body.
//
// What the scale said and the trend stay two different things, deliberately: the scale is not wrong when it reads
// 1.4 kg above yesterday, it is measuring water. A forecast is arithmetic on one rate, and says so; when the rate
// points away from the goal or would need years, the page says that instead of printing a date.

@MainActor
final class WeightTrackerModel: ObservableObject {
    @Published private(set) var snapshot: WeightTracker.Snapshot?
    @Published private(set) var stored = WeightTracker.Stored()
    /// "goal" or "dietPlan": where the goal on the page came from; nil without one.
    @Published private(set) var goalFromPlan = false
    @Published private(set) var loaded = false

    func reload(repo: Repository) async {
        let prefs = GoalPreferences.standard
        stored = WeightTrackerPreparation.stored(prefs)
        let plan = DietPlan.decode(UserDefaults.standard.string(forKey: DietPlan.storageKey))
        let goals = CoachGoalStore.shared
        goalFromPlan = !goals.activeGoals.contains { $0.kind == .weight && $0.target != nil }
            && WeightTrackerPreparation.goal(goals: goals, plan: plan) != nil
        if let store = await repo.storeHandle() {
            snapshot = await WeightTrackerPreparation.snapshot(store: store, reader: repo.storeReader(store), goals: goals,
                                                               prefs: prefs, plan: plan)
        }
        loaded = true
        #if os(iOS)
        WeightWidgetPublisher.publish(snapshot)
        #endif
    }

    func save(_ next: WeightTracker.Stored, repo: Repository) async {
        WeightTrackerPreparation.save(next, to: GoalPreferences.standard)
        await reload(repo: repo)
    }
}

struct WeightDetailView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var units: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @StateObject private var model = WeightTrackerModel()
    @ObservedObject private var goalStore = CoachGoalStore.shared
    @State private var section: WeightSection = .overview
    @State private var editing: WeightLogDraft?
    @State private var editingEvent: WeightEventDraft?
    @State private var showingSettings = false
    @State private var historyRange: HistoryRange = .quarter
    @State private var reportPeriod: WeightTracker.Period = .month
    @State private var showArchive = false

    enum WeightSection: Hashable { case overview, history, reports }
    enum HistoryRange: Int, CaseIterable, Identifiable {
        case month = 30, quarter = 90, year = 365, all = 0
        var id: Int { rawValue }
        var label: LocalizedStringKey {
            switch self { case .month: "30 days"; case .quarter: "90 days"; case .year: "1 year"; case .all: "All" }
        }
    }

    var body: some View {
        Group {
            if NoopVisualStyle.skin == .forge {
                ScreenScaffold(title: "Weight") { settingsButton } content: { content }
                    .pagePicture("scalemass.fill", accent: "leaf.fill", tint: Self.weightTint)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) { content }
                        .padding(NoopMetrics.screenPadding)
                }
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationTitle(Text("Weight"))
                .toolbar { ToolbarItem(placement: .primaryAction) { settingsButton } }
            }
        }
        .task { await model.reload(repo: repo) }
        .onReceive(goalStore.$goals.dropFirst()) { _ in Task { await model.reload(repo: repo) } }
        .sheet(item: $editing) { draft in
            WeightLogSheet(draft: draft, unitSystem: units,
                           onSave: { kg, at, note in await save(draft: draft, kg: kg, at: at, note: note) },
                           onDelete: draft.isExisting ? { await delete(id: draft.id) } : nil)
        }
        .sheet(item: $editingEvent) { draft in
            WeightEventSheet(draft: draft,
                             onSave: { saved in await saveEvent(saved) },
                             onDelete: draft.isExisting ? { await deleteEvent(id: draft.id) } : nil)
        }
        .sheet(isPresented: $showingSettings) {
            WeightSettingsSheet(stored: model.stored, rates: model.snapshot?.rates, units: units) { next in
                await model.save(next, repo: repo)
            }
        }
    }

    /// The weight page's one colour: the pink of its picture in the new design, the accent in the shipped one.
    static var weightTint: Color { NoopVisualStyle.skin == .forge ? Color.pink : StrandPalette.accent }

    private var settingsButton: some View {
        Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
            .accessibilityLabel(Text("Weight settings"))
            .tint(Self.weightTint)
    }

    @ViewBuilder private var content: some View {
        if let s = model.snapshot {
            hero(s)
            Picker("Section", selection: $section) {
                Text("Overview").tag(WeightSection.overview)
                Text("History").tag(WeightSection.history)
                Text("Reports").tag(WeightSection.reports)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch section {
            case .overview: overview(s)
            case .history: history(s)
            case .reports: reports(s)
            }
        } else if model.loaded {
            NoopCard { emptyState }
            logButton
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func shows(_ card: WeightTracker.Card) -> Bool { !model.stored.settings.hiddenCards.contains(card.rawValue) }

    // MARK: Hero

    /// The newest weigh-in as the one big number, the trend beside it, and the goal in words.
    private func hero(_ s: WeightTracker.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mass(s.latest.kg))
                        .font(StrandFont.rounded(44, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("Last weigh-in \(relative(s.latest.date))")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(mass(s.trendKg))
                        .font(StrandFont.rounded(20, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(s.trendSettled ? String(localized: "trend") : String(localized: "trend, still settling"))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            if let goal = s.goal {
                Text(goal.isMaintain
                     ? String(localized: "Goal: stay near \(mass(goal.target))")
                     : String(localized: "Goal \(mass(goal.target))"))
                    .font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                if model.goalFromPlan {
                    Text("From your diet plan").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: Overview

    @ViewBuilder private func overview(_ s: WeightTracker.Snapshot) -> some View {
        if shows(.milestones), let m = s.milestones, let goal = s.goal { milestonesCard(m, goal: goal, trend: s.trendKg) }
        if shows(.forecast) { forecastCard(s) }
        if shows(.events) { eventsCard(s) }
        if shows(.changes) { changesCard(s) }
        if shows(.week), let w = s.week { weekCard(w) }
        logButton
    }

    private func milestonesCard(_ m: WeightTracker.Milestones, goal: WeightTracker.Goal, trend: Double) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    BevelGauge(fraction: m.progress, stops: StrandPalette.strainStops, tipColor: StrandPalette.metricAmber,
                               numberText: "\(Int((m.progress * 100).rounded())) %",
                               captionText: String(localized: "of the way"),
                               stateText: String(localized: "TREND"), diameter: 104, lineWidth: 9,
                               animatedFraction: m.progress)
                    VStack(alignment: .leading, spacing: 4) {
                        if let next = m.next {
                            Text("Next stop").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            Text(mass(next)).font(StrandFont.rounded(28, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                            if let toGo = m.toNextKg {
                                Text("\(mass(toGo)) to go").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            }
                        } else {
                            Text("Every stop reached").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                milestoneTrack(m)
                Text("\(m.reachedCount) of \(m.route.count) stops reached")
                    .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Every stop as a dot on one line: reached ones filled, the rest open.
    private func milestoneTrack(_ m: WeightTracker.Milestones) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(m.route.enumerated()), id: \.offset) { i, stop in
                if i > 0 {
                    Rectangle().fill(stop.reachedDay != nil ? Self.weightTint : StrandPalette.hairline).frame(height: 3)
                }
                Circle()
                    .fill(stop.reachedDay != nil ? Self.weightTint : StrandPalette.surfaceBase)
                    .overlay(Circle().stroke(stop.reachedDay != nil ? Self.weightTint : StrandPalette.textTertiary, lineWidth: 2))
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityHidden(true)
    }

    private func forecastCard(_ s: WeightTracker.Snapshot) -> some View {
        let f = s.forecast
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            sectionTitle("Forecast")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Rate", selection: Binding(get: { f.rateMode }, set: { mode in
                        var next = model.stored
                        next.settings.rateMode = mode
                        Task { await model.save(next, repo: repo) }
                    })) {
                        Text("Current").tag(WeightTracker.RateMode.current)
                        Text("Overall").tag(WeightTracker.RateMode.overall)
                        Text("Plan").tag(WeightTracker.RateMode.wish)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(forecastSentence(s)).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(basisLine(f)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    if f.rateMode == .wish {
                        Text(wishSourceLine(s.rates)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        if s.rates.wishIsSteep {
                            Label("More than about 1 % of your weight a week is a lot to sustain.", systemImage: "exclamationmark.triangle")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarning)
                        }
                    }
                }
            }
        }
    }

    private func forecastSentence(_ s: WeightTracker.Snapshot) -> String {
        let f = s.forecast
        let rate = f.rateKgPerWeek.map { perWeek($0) }
        switch f.state {
        case .arriving:
            let date = f.targetDate.map { $0.formatted(.dateTime.day().month(.wide).year().locale(AppLanguage.activeLocale)) } ?? ""
            if f.rateMode == .wish {
                return String(localized: "Following the plan of \(rate ?? "—"), you would reach \(mass(s.goal?.target ?? 0)) around \(date).")
            }
            return String(localized: "At \(rate ?? "—"), you reach \(mass(s.goal?.target ?? 0)) around \(date).")
        case .reached: return String(localized: "The trend has reached your goal.")
        case .movingAway: return String(localized: "At \(rate ?? "—") the trend moves away from your goal, so there is no date to give.")
        case .tooSlow: return String(localized: "At \(rate ?? "—") your goal is more than three years away.")
        case .notEnoughData:
            return f.rateMode == .wish
                ? String(localized: "There is no plan rate yet. Set a goal date, a diet plan or your own rate in the settings.")
                : String(localized: "Too few weigh-ins for a rate yet: it needs two weeks and eight weigh-ins.")
        case .withinBand: return String(localized: "The trend is inside your band.")
        case .outsideBand: return String(localized: "The trend is outside your band.")
        case .noGoal:
            guard let rate else { return String(localized: "Too few weigh-ins for a rate yet: it needs two weeks and eight weigh-ins.") }
            return String(localized: "The trend changes by \(rate). Set a weight goal to see when you reach it.")
        }
    }

    private func basisLine(_ f: WeightTracker.Forecast) -> String {
        switch f.basis {
        case .trend: String(localized: "Starts from the trend, \(mass(f.startKg)).")
        case .tenDayLow: String(localized: "Starts from the lowest weigh-in of the last ten days, \(mass(f.startKg)) on \(f.startDate.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))).")
        }
    }

    private func wishSourceLine(_ r: WeightTracker.Rates) -> String {
        switch r.wishSource {
        case .dietPlan: String(localized: "The plan rate comes from your diet plan. It is a plan, not a prediction.")
        case .goal: String(localized: "The plan rate comes from your goal's date. It is a plan, not a prediction.")
        case .manual: String(localized: "The plan rate is the one you set. It is a plan, not a prediction.")
        case nil: String(localized: "It is a plan, not a prediction.")
        }
    }

    private func eventsCard(_ s: WeightTracker.Snapshot) -> some View {
        let current = s.events.filter { $0.phase != .archived }
        let archived = s.events.filter { $0.phase == .archived }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                sectionTitle("Your dates")
                Spacer()
                Button { editingEvent = WeightEventDraft() } label: { Label("Add", systemImage: "plus") }
                    .font(StrandFont.subhead.weight(.semibold)).tint(Self.weightTint)
            }
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    if current.isEmpty {
                        Text("Add a date, like a holiday or a wedding, to see what you are likely to weigh then.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    ForEach(Array(current.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider().overlay(StrandPalette.hairline).padding(.leading, 16) }
                        eventRow(e)
                    }
                    if !archived.isEmpty {
                        Divider().overlay(StrandPalette.hairline)
                        DisclosureGroup(isExpanded: $showArchive) {
                            ForEach(archived) { eventRow($0) }
                        } label: {
                            Text("Past dates (\(archived.count))").font(StrandFont.footnote.weight(.semibold))
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func eventRow(_ e: WeightTracker.EventForecast) -> some View {
        let date = WeightSeries.date(forDay: e.event.day)?.formatted(.dateTime.day().month(.abbreviated).year().locale(AppLanguage.activeLocale)) ?? e.event.day
        return Button { editingEvent = WeightEventDraft(event: e.event) } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.event.name).font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(e.phase == .upcoming
                         ? (e.daysAway == 0 ? String(localized: "\(date), today") : String(localized: "\(date), in \(e.daysAway) days"))
                         : date)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    switch e.phase {
                    case .upcoming:
                        Text(e.predictedKg.map(mass) ?? "—").font(StrandFont.rounded(17, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("expected").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    case .passed, .archived:
                        Text(e.measuredKg.map(mass) ?? "—").font(StrandFont.rounded(17, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(e.predictedBeforeKg.map { String(localized: "measured, forecast \(mass($0))") }
                             ?? String(localized: "measured"))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func changesCard(_ s: WeightTracker.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            sectionTitle("Change")
            NoopCard {
                HStack(alignment: .top, spacing: 10) {
                    ForEach([7, 30, 90, nil] as [Int?], id: \.self) { days in
                        let value = s.changes.first { $0.days == days }?.kg
                        VStack(alignment: .leading, spacing: 2) {
                            Text(value.map(signedMass) ?? "—")
                                .font(StrandFont.rounded(18, weight: .bold)).foregroundStyle(color(for: value, goal: s.goal))
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text(days.map { String(localized: "\($0) days") } ?? String(localized: "since start"))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func weekCard(_ w: WeightTracker.Week) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            sectionTitle("This week")
            NoopCard {
                HStack(alignment: .center, spacing: 14) {
                    Chart {
                        ForEach(Array(w.readings.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Day", p.date), y: .value("Weight", p.kg), series: .value("Line", "scale"))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        ForEach(Array(w.trend.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Day", p.date), y: .value("Weight", p.kg), series: .value("Line", "trend"))
                                .foregroundStyle(Self.weightTint).lineStyle(StrokeStyle(lineWidth: 2.5))
                        }
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .chartYScale(domain: (w.low.kg - 0.5)...(w.high.kg + 0.5))
                    .frame(height: 110)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        weekFigure("High", w.high.kg, StrandPalette.statusWarning)
                        weekFigure("Latest", w.latest.kg, StrandPalette.textPrimary)
                        weekFigure("Trend", w.trendKg, Self.weightTint)
                        weekFigure("Low", w.low.kg, StrandPalette.statusPositive)
                    }
                    .frame(width: 110, alignment: .leading)
                }
            }
        }
    }

    private func weekFigure(_ label: LocalizedStringKey, _ kg: Double, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(StrandFont.caption.weight(.semibold)).foregroundStyle(tint)
            Spacer(minLength: 4)
            Text(mass(kg)).font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: History

    @ViewBuilder private func history(_ s: WeightTracker.Snapshot) -> some View {
        if shows(.chart) { historyChart(s) }
        logButton
        logbook(s)
    }

    private func historyChart(_ s: WeightTracker.Snapshot) -> some View {
        let cutoff = historyRange == .all ? Date.distantPast : Date().addingTimeInterval(-Double(historyRange.rawValue) * 86_400)
        let raw = s.readings.filter { $0.date >= cutoff }
        let trend = s.trend.filter { $0.date >= cutoff }
        let values = raw.map(\.kg) + (s.goal.map { [$0.target] } ?? [])
        let lo = (values.min() ?? 50) - 1, hi = (values.max() ?? 100) + 1
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Range", selection: $historyRange) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Chart {
                    ForEach(Array(raw.enumerated()), id: \.offset) { _, p in
                        PointMark(x: .value("Day", p.date), y: .value("Weight", p.kg))
                            .foregroundStyle(StrandPalette.textTertiary).symbolSize(14)
                    }
                    ForEach(Array(trend.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Day", p.date), y: .value("Weight", p.kg))
                            .foregroundStyle(Self.weightTint).lineStyle(StrokeStyle(lineWidth: 2.5)).interpolationMethod(.monotone)
                    }
                    if let goal = s.goal {
                        if let band = goal.band {
                            RectangleMark(yStart: .value("Low", goal.target - band), yEnd: .value("High", goal.target + band))
                                .foregroundStyle(StrandPalette.statusPositive.opacity(0.12))
                        }
                        RuleMark(y: .value("Goal", goal.target))
                            .foregroundStyle(StrandPalette.statusPositive).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Goal").font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.statusPositive)
                            }
                    }
                }
                .chartYScale(domain: lo...hi)
                .chartYAxis { AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel { if let kg = v.as(Double.self) { Text(mass(kg, decimals: 0)) } }
                } }
                .frame(height: 220)
                .accessibilityLabel(Text("Weight history"))
                Text("Dots: what the scale said. Line: the trend.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func logbook(_ s: WeightTracker.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            sectionTitle("Logbook")
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Day").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Scale").frame(width: 72, alignment: .trailing)
                        Text("Trend").frame(width: 64, alignment: .trailing)
                        Text("Week").frame(width: 60, alignment: .trailing)
                    }
                    .font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    ForEach(s.log.prefix(400)) { row in
                        Divider().overlay(StrandPalette.hairline).padding(.leading, 16)
                        logRow(row, goal: s.goal)
                    }
                }
            }
            Text("Tap a weigh-in you logged here to edit or delete it.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func logRow(_ row: WeightTracker.LogRow, goal: WeightTracker.Goal?) -> some View {
        let editable = row.reading.id != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.reading.date.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)))
                        .font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(row.reading.source == "noop" ? String(localized: "Logged in NOOP") : String(localized: "Apple Health"))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(mass(row.reading.kg)).font(StrandFont.subhead.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary).frame(width: 72, alignment: .trailing)
                Text(mass(row.trendKg)).font(StrandFont.subhead).monospacedDigit()
                    .foregroundStyle(StrandPalette.textSecondary).frame(width: 64, alignment: .trailing)
                Text(row.weeklyRateKg.map { signedNumber($0) } ?? "—").font(StrandFont.subhead.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(color(for: row.weeklyRateKg, goal: goal)).frame(width: 60, alignment: .trailing)
            }
            if let note = row.reading.note, !note.isEmpty {
                Text(note).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            if let m = row.milestoneKg {
                Label(String(localized: "Reached \(mass(m))"), systemImage: "flag.fill")
                    .font(StrandFont.caption.weight(.semibold)).foregroundStyle(Self.weightTint)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard editable, let id = row.reading.id else { return }
            editing = WeightLogDraft(id: id, kg: row.reading.kg, at: row.reading.date, note: row.reading.note)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(editable ? .isButton : [])
    }

    // MARK: Reports

    @ViewBuilder private func reports(_ s: WeightTracker.Snapshot) -> some View {
        Picker("Period", selection: $reportPeriod) {
            Text("Months").tag(WeightTracker.Period.month)
            Text("Years").tag(WeightTracker.Period.year)
        }
        .pickerStyle(.segmented).labelsHidden()
        let list = reportPeriod == .month ? s.months : s.years
        if list.isEmpty {
            NoopCard { Text("No weigh-ins yet.").font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary) }
        }
        ForEach(list.prefix(36)) { reportCard($0, goal: s.goal) }
    }

    private func reportCard(_ r: WeightTracker.Report, goal: WeightTracker.Goal?) -> some View {
        let title = r.period == .month
            ? r.start.formatted(.dateTime.month(.wide).year().locale(AppLanguage.activeLocale))
            : r.start.formatted(.dateTime.year().locale(AppLanguage.activeLocale))
        return NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("\(r.count) weigh-ins").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                if !r.enough {
                    Text("Too few weigh-ins for a report: it needs four.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            reportFigure(String(localized: "Lowest"), r.low.map { mass($0.kg) } ?? "—",
                                         r.low.map { $0.date.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)) })
                            reportFigure(String(localized: "Average"), r.averageKg.map { mass($0) } ?? "—",
                                         r.vsPreviousKg.map { String(localized: "\(signedMass($0)) vs before") })
                        }
                        GridRow {
                            reportFigure(String(localized: "Trend change"), r.trendChangeKg.map(signedMass) ?? "—", nil)
                            reportFigure(String(localized: "Per week"), r.ratePerWeekKg.map(signedMass) ?? "—", nil)
                        }
                    }
                    Chart {
                        ForEach(Array(r.trend.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Day", p.date), y: .value("Weight", p.kg))
                                .foregroundStyle(Self.weightTint).lineStyle(StrokeStyle(lineWidth: 2.5))
                        }
                        if let goal { RuleMark(y: .value("Goal", goal.target))
                            .foregroundStyle(StrandPalette.statusPositive).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])) }
                    }
                    .chartYScale(domain: reportDomain(r, goal: goal))
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel() } }
                    .chartYAxis(.hidden)
                    .frame(height: 90)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private func reportDomain(_ r: WeightTracker.Report, goal: WeightTracker.Goal?) -> ClosedRange<Double> {
        let v = r.trend.map(\.kg) + (goal.map { [$0.target] } ?? [])
        return ((v.min() ?? 50) - 0.5)...((v.max() ?? 100) + 0.5)
    }

    private func reportFigure(_ label: String, _ value: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(StrandFont.rounded(18, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
            if let sub { Text(sub).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Shared pieces

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key).font(Font.title3.weight(.bold)).foregroundStyle(StrandPalette.textPrimary).accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No weigh-ins yet").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Log one and NOOP will track the trend behind the daily ups and downs. Weigh-ins from Apple Health show up here too.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var logButton: some View {
        Button {
            editing = WeightLogDraft(seedKg: model.snapshot?.latest.kg ?? profile.weightKg)
        } label: {
            Label("Log weight", systemImage: "plus.circle.fill").font(StrandFont.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.noopProminent)
        .tint(Self.weightTint)
    }

    /// Tinted only against a goal: without one, losing is not "good" and gaining is not "bad". A maintain goal
    /// tints nothing either.
    private func color(for delta: Double?, goal: WeightTracker.Goal?) -> Color {
        guard let delta, abs(delta) > 0.05, let goal, !goal.isMaintain else { return StrandPalette.textPrimary }
        let toward = (goal.target - goal.baseline) > 0 ? delta > 0 : delta < 0
        return toward ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }

    private func mass(_ kg: Double) -> String { UnitFormatter.massFromKilograms(kg, system: units) }
    private func mass(_ kg: Double, decimals: Int) -> String {
        let value = units == .imperial ? kg * UnitFormatter.poundsPerKilogram : kg
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }

    /// A change, always signed, so "−0.3 kg" and "+0.3 kg" are never mistaken for one another.
    private func signedMass(_ kg: Double) -> String {
        let formatted = UnitFormatter.massFromKilograms(abs(kg), system: units)
        if kg > 0.05 { return "+" + formatted }
        if kg < -0.05 { return "−" + formatted }
        return formatted
    }

    private func signedNumber(_ kg: Double) -> String {
        let value = abs(units == .imperial ? kg * UnitFormatter.poundsPerKilogram : kg)
        let text = value.formatted(.number.precision(.fractionLength(1)))
        return kg > 0.05 ? "+" + text : kg < -0.05 ? "−" + text : text
    }

    private func perWeek(_ kg: Double) -> String { String(localized: "\(signedMass(kg)) a week") }

    private func relative(_ date: Date) -> String { min(date, Date()).formatted(.relative(presentation: .named)) }

    // MARK: Mutations

    private func save(draft: WeightLogDraft, kg: Double, at: Date, note: String?) async {
        if draft.isExisting {
            _ = await repo.updateWeight(id: draft.id, kg: kg, at: at, note: note)
        } else {
            _ = await repo.logWeight(kg: kg, at: at, note: note)
        }
        // The Apple Health mirror and the reminder follow `.noopWeightLogged` in `StrandiOSApp`.
        await repo.reconcileProfileWeight(profile)
        await model.reload(repo: repo)
    }

    private func delete(id: String) async {
        _ = await repo.deleteWeight(id: id)
        await repo.reconcileProfileWeight(profile)
        await model.reload(repo: repo)
    }

    private func saveEvent(_ draft: WeightEventDraft) async {
        var next = model.stored
        if let i = next.events.firstIndex(where: { $0.id == draft.id }) {
            next.events[i].name = draft.name
            next.events[i].day = WeightTrackerPreparation.dayKey(draft.date)
        } else {
            next.events.append(.init(id: draft.id, name: draft.name, day: WeightTrackerPreparation.dayKey(draft.date)))
        }
        await model.save(next, repo: repo)
    }

    private func deleteEvent(id: String) async {
        var next = model.stored
        next.events.removeAll { $0.id == id }
        await model.save(next, repo: repo)
    }
}

// MARK: - Draft

/// What the sheet edits: a new weigh-in or an existing one. `Identifiable` so `.sheet(item:)` can
/// present it, which also guarantees the sheet is rebuilt when the user taps a different row.
struct WeightLogDraft: Identifiable {
    let id: String
    let kg: Double
    let at: Date
    let note: String?
    /// False for a brand-new weigh-in — the sheet hides Delete and the save path inserts.
    let isExisting: Bool

    /// A fresh weigh-in, seeded with the last known weight so the field starts somewhere sensible
    /// rather than empty.
    init(seedKg: Double) {
        self.id = UUID().uuidString
        self.kg = seedKg
        self.at = Date()
        self.note = nil
        self.isExisting = false
    }

    /// An existing weigh-in from the page's log.
    init(id: String, kg: Double, at: Date, note: String?) {
        self.id = id
        self.kg = kg
        self.at = at
        self.note = note
        self.isExisting = true
    }

    init(entry: WeightEntry) {
        self.id = entry.id
        self.kg = entry.value
        self.at = entry.takenAt ?? WeightSeries.date(forDay: entry.day) ?? Date()
        self.note = entry.note
        self.isExisting = true
    }
}

// MARK: - Log sheet

/// One screen, no wizard: a number, when it was taken, an optional note. Entering a weight should
/// cost one tap more than opening the app.
struct WeightLogSheet: View {
    let draft: WeightLogDraft
    let unitSystem: UnitSystem
    let onSave: (Double, Date, String?) async -> Void
    /// Nil for a new weigh-in — there is nothing to delete yet.
    let onDelete: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var at: Date = Date()
    @State private var note: String = ""
    @State private var saving = false

    /// The typed value converted back to kilograms, or nil when it isn't a usable number. Accepts a
    /// comma decimal separator: a German keyboard's number pad offers "," and rejecting it would make
    /// the field feel broken for half the shipped locales.
    private var parsedKg: Double? {
        let normalised = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let entered = Double(normalised), entered > 0 else { return nil }
        let kg = unitSystem == .imperial ? entered / UnitFormatter.poundsPerKilogram : entered
        // Same plausibility bounds the trend fold applies, so a value the maths would silently drop
        // can't be saved in the first place.
        return GoalMeasure.isPlausible(kg, cfg: GoalMeasure.weightTrend) ? kg : nil
    }

    var body: some View {
        NavigationStack {
            Group { if NoopVisualStyle.skin == .forge { forgeForm } else {
            Form {
                Section {
                    HStack {
                        TextField("Weight", text: $text)
                            .font(StrandFont.title2)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        Text(UnitFormatter.massUnit(unitSystem))
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    DatePicker("When", selection: $at, in: ...Date())
                } footer: {
                    if !text.isEmpty && parsedKg == nil {
                        Text("Enter a weight between \(Int(GoalMeasure.weightTrend.minVal)) and \(Int(GoalMeasure.weightTrend.maxVal)) kg.")
                            .foregroundStyle(StrandPalette.metricAmber)
                    }
                }
                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                }
                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            Task { saving = true; await onDelete(); dismiss() }
                        } label: {
                            Text("Delete weigh-in").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .forgeListBackground()
            } }
            .navigationTitle(Text(draft.isExisting ? "Edit weigh-in" : "Log weight"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let kg = parsedKg else { return }
                        Task {
                            saving = true
                            await onSave(kg, at, note.isEmpty ? nil : note)
                            dismiss()
                        }
                    }
                    .disabled(parsedKg == nil || saving)
                }
            }
        }
        .onAppear {
            let shown = unitSystem == .imperial ? UnitFormatter.kgToPounds(draft.kg) : draft.kg
            text = NoopVisualStyle.skin == .forge
                ? UnitFormatter.localizedMark(String(format: "%.1f", shown))
                : String(format: "%.1f", shown)
            at = draft.at
            note = draft.note ?? ""
        }
    }

    /// The new design: the number is the page, the rest sits under it.
    private var forgeForm: some View {
        ScrollView {
            VStack(spacing: NoopMetrics.gap) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                    TextField("Weight", text: $text)
                        .font(StrandFont.number(64).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize()
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text(UnitFormatter.massUnit(unitSystem))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, NoopMetrics.space4)
                if !text.isEmpty && parsedKg == nil {
                    Text("Enter a weight between \(Int(GoalMeasure.weightTrend.minVal)) and \(Int(GoalMeasure.weightTrend.maxVal)) kg.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarningForeground)
                }
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        DatePicker("When", selection: $at, in: ...Date())
                            .font(StrandFont.subhead)
                        Divider().overlay(StrandPalette.hairline)
                        TextField("Note", text: $note, axis: .vertical)
                            .font(StrandFont.subhead)
                            .frame(minHeight: 44)
                    }
                }
                if let onDelete {
                    Button(role: .destructive) {
                        Task { saving = true; await onDelete(); dismiss() }
                    } label: {
                        Text("Delete weigh-in")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.statusCritical)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(StrandPalette.surfaceInset, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .forgeScreenBackground()
    }
}
