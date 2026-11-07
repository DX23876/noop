#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import StrandCore

/// The redesign's weekly report: the coach's weekly review on top when there is one, then the week in
/// figures against last week (works fully with the coach off), highlights, Charge, sleep and Effort per
/// day, and the week's goals.
struct ForgeWeeklyReportView: View {
    var onAsk: (String) -> Void = { _ in }

    @ObservedObject var coach: AICoachEngine

    @EnvironmentObject private var repo: Repository
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @AppStorage("training.weekStartsOn") private var weekStartRaw = "monday"
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    @State private var restByDay: [String: Double] = [:]
    @State private var workouts: [WorkoutRow] = []

    private var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = weekStartRaw == "sunday" ? 1 : 2
        return cal
    }

    private var weeks: (this: ForgeWeekly.Week, last: ForgeWeekly.Week) {
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        // On the first day of a new week the report is about the week that just ended, not a week of one day.
        let now = Date()
        let anchor = calendar.component(.weekday, from: now) == calendar.firstWeekday
            ? calendar.date(byAdding: .day, value: -1, to: now) ?? now : now
        return ForgeWeekly.weeks(containing: anchor, calendar: calendar, dayKey: { Repository.localDayKey($0) }) { key in
            let d = byDay[key]
            return .init(charge: d?.recovery, effort: d?.strain, rest: restByDay[key],
                         asleepMin: d?.totalSleepMin, steps: d?.steps.map(Double.init))
        }
    }

    private var weeklyNote: ChatMessage? {
        guard coachFeatureEnabled else { return nil }
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        return coach.conversations.flatMap(\.messages)
            .filter { $0.role == .assistant && $0.origin == .weeklyReview && $0.date >= cutoff }
            .max(by: { $0.date < $1.date })
    }

    var body: some View {
        let w = weeks
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(w.this)
                summaryCard(w, note: weeklyNote)
                highlights(w)
                chargeChart(w)
                sleepBars(w.this)
                effortBars(w.this)
                GoalsContextCard(context: .training)
                GoalsContextCard(context: .sleep)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .today))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let series = await repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource, days: 21)
            restByDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            workouts = await repo.workoutRows(days: 9, reconcileHrCap: 0)
        }
    }

    private func header(_ week: ForgeWeekly.Week) -> some View {
        let first = Self.parse(week.days.first)
        let last = Self.parse(week.days.last)
        return VStack(alignment: .leading, spacing: 2) {
            if let first, let last {
                Text(String(localized: "\(first.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))) to \(last.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)))").uppercased(with: AppLanguage.activeLocale))
                    .font(ForgeFont.overDate).foregroundStyle(ForgeColor.secondary)
                Text("Week \(calendar.component(.weekOfYear, from: first))")
                    .font(ForgeFont.largeTitle).foregroundStyle(ForgeColor.text)
            }
        }
        .padding(.horizontal, 4)
    }

    /// The prototype's top card: the coach's weekly review when there is one, the week's three averages as
    /// rings with the change against last week, every day as small rings, and the coach's questions.
    private func summaryCard(_ w: (this: ForgeWeekly.Week, last: ForgeWeekly.Week), note: ChatMessage?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note {
                let split = ForgeTimeline.splitNote(note.text)
                Label("Coach · weekly report", systemImage: "waveform.path.ecg")
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                Text(split.headline).font(.system(.title3, weight: .bold)).foregroundStyle(ForgeColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !split.body.isEmpty {
                    Text(ForgeTodayView.markdown(split.body)).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Your week").font(.system(.title3, weight: .bold)).foregroundStyle(ForgeColor.text)
            }
            OrganicScoreHeroClock(dataReady: true) { frame in
                HStack(alignment: .top, spacing: 4) {
                    weekRing(.charge, w.this.mean(\.charge), w.last.mean(\.charge), name: DomainTheme.charge.productName,
                             tint: StrandPalette.chargeColor, ink: ForgeColor.chargeInk,
                             scaleMaximum: 100, decimals: 0, frame: frame, format: { "\(Int($0.rounded()))" })
                    weekRing(.effort, w.this.mean(\.effort).map { UnitFormatter.effortValue($0, scale: effortScale) },
                             w.last.mean(\.effort).map { UnitFormatter.effortValue($0, scale: effortScale) },
                             name: DomainTheme.effort.productName, tint: StrandPalette.organicEffort, ink: ForgeColor.effortInk,
                             scaleMaximum: effortScale == .whoop ? 21 : 100, decimals: effortScale == .whoop ? 1 : 0,
                             frame: frame, format: { $0.formatted(.number.precision(.fractionLength(effortScale == .whoop ? 1 : 0))) })
                    weekRing(.rest, w.this.mean(\.rest), w.last.mean(\.rest), name: DomainTheme.rest.productName,
                             tint: StrandPalette.organicRest, ink: ForgeColor.restInk,
                             scaleMaximum: 100, decimals: 0, frame: frame, format: { "\(Int($0.rounded()))" })
                }
            }
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    VStack(spacing: 4) {
                        ForgeMiniRings(charge: w.this.values[i].charge, effort: w.this.values[i].effort, rest: w.this.values[i].rest)
                            .frame(width: 32, height: 32)
                        if let day = Self.parse(w.this.days[i]) {
                            Text(day, format: .dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
                                .font(.system(.caption2)).foregroundStyle(ForgeColor.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if coachFeatureEnabled {
                FlowRows(spacing: 8) {
                    ForgeChip(title: String(localized: "How do I keep this up?")) {
                        onAsk(String(localized: "Look back at my week. What went well, and how do I keep it up next week?"))
                    }
                    ForgeChip(title: String(localized: "Plan next week")) {
                        onAsk(String(localized: "Look back at my week and help me plan next week: training, sleep and one focus."))
                    }
                }
            }
        }
        .forgeCard(radius: 24, padding: 16)
    }

    /// One of the week's averages as an organic ring, its name, and the change against last week's average.
    private func weekRing(_ metric: OrganicScoreMetric, _ value: Double?, _ previous: Double?, name: String,
                          tint: Color, ink: Color, scaleMaximum: Double, decimals: Int, frame: OrganicScoreFrame,
                          format: (Double) -> String) -> some View {
        VStack(spacing: 4) {
            ScoreRing(model: OrganicScoreVisualModel.resolve(metric: metric, value: value, scaleMaximum: scaleMaximum),
                             tint: value == nil ? StrandPalette.organicMissing : tint, score: value, decimals: decimals,
                             frame: frame, diameter: 84, hitDiameter: 108)
                .frame(width: 108, height: 96)
            Text(name).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ink)
            if let value, let previous {
                let delta = value - previous
                HStack(spacing: 2) {
                    Image(systemName: delta >= 0 ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .bold))
                    Text("\(format(abs(delta))) vs last week").lineLimit(1).minimumScaleFactor(0.8)
                }
                .font(.system(.caption, weight: .medium)).foregroundStyle(ink)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The week's hardest session: the workout with the highest Effort inside this week.
    private func hardestSession(_ week: ForgeWeekly.Week) -> WorkoutRow? {
        let keys = Set(week.days)
        return workouts
            .filter { keys.contains(Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs)))) }
            .filter { $0.strain != nil }
            .max { ($0.strain ?? 0) < ($1.strain ?? 0) }
    }

    private func highlights(_ w: (this: ForgeWeekly.Week, last: ForgeWeekly.Week)) -> some View {
        let week = w.this
        return VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "Highlights")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                if let i = week.bestIndex(\.charge), let day = Self.parse(week.days[i]),
                   let value = week.values[i].charge {
                    highlightTile(String(localized: "Best day"), "sun.max.fill", ForgeColor.chargeInk,
                                  value: day.formatted(.dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale)),
                                  unit: nil, detail: String(localized: "Charge \(Int(value.rounded())) %"))
                }
                if let row = hardestSession(week), let strain = row.strain {
                    let day = Date(timeIntervalSince1970: TimeInterval(row.startTs))
                    NavigationLink(value: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) {
                        highlightTile(String(localized: "Hardest session"), "dumbbell.fill", ForgeColor.effortInk,
                                      value: ForgeToday.effortText(strain, scale: effortScale),
                                      unit: DomainTheme.effort.productName,
                                      detail: "\(WorkoutSource.localizedDisplaySport(row.sport)), \(day.formatted(.dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale)))")
                    }
                    .buttonStyle(.plain)
                }
                if let asleep = week.mean(\.asleepMin) {
                    highlightTile(String(localized: "Sleep"), "moon.fill", ForgeColor.restInk,
                                  value: ForgeTodayView.hoursMinutes(asleep), unit: String(localized: "h avg"),
                                  detail: w.last.mean(\.asleepMin).map {
                                      let d = Int((asleep - $0).rounded())
                                      return String(localized: "\(d >= 0 ? "+" : "−")\(abs(d)) min vs last week")
                                  })
                }
                if let steps = week.mean(\.steps) {
                    highlightTile(String(localized: "Steps"), "shoeprints.fill", ForgeColor.chargeInk,
                                  value: Int(steps.rounded()).formatted(.number.locale(AppLanguage.activeLocale)),
                                  unit: String(localized: "avg"),
                                  detail: w.last.mean(\.steps).flatMap { last -> String? in
                                      guard last > 0 else { return nil }
                                      let pct = Int(((steps - last) / last * 100).rounded())
                                      return String(localized: "\(pct >= 0 ? "+" : "−")\(abs(pct)) % vs last week")
                                  })
                }
            }
        }
    }

    private func highlightTile(_ label: String, _ icon: String, _ tint: Color, value: String, unit: String?,
                               detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon).font(.system(.footnote, weight: .semibold)).foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(ForgeFont.rounded(24, .semibold)).foregroundStyle(ForgeColor.text)
                if let unit { Text(unit).font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary) }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.system(.footnote)).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .forgeCard(radius: 20, padding: 12)
        .accessibilityElement(children: .combine)
    }

    private func chargeChart(_ w: (this: ForgeWeekly.Week, last: ForgeWeekly.Week)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(DomainTheme.charge.productName).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                Spacer()
                Text("this week vs last week").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
            Chart {
                ForEach(0..<7, id: \.self) { i in
                    if let v = w.last.values[i].charge {
                        LineMark(x: .value("Day", i), y: .value("Charge", v), series: .value("Week", "last"))
                            .foregroundStyle(ForgeColor.tertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                    if let v = w.this.values[i].charge {
                        LineMark(x: .value("Day", i), y: .value("Charge", v), series: .value("Week", "this"))
                            .foregroundStyle(ForgeColor.charge)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                        PointMark(x: .value("Day", i), y: .value("Charge", v)).foregroundStyle(ForgeColor.charge)
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis(.hidden)
            .chartXAxis { weekdayAxis(w.this) }
            .frame(height: 150)
            legend([(String(localized: "This week"), ForgeColor.charge, false), (String(localized: "Last week"), ForgeColor.tertiary, true)])
        }
        .forgeCard(radius: 22, padding: 14)
    }

    private func sleepBars(_ week: ForgeWeekly.Week) -> some View {
        let need = Double(WindDownNudge.sleepNeedMinutes) / 60
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sleep").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                Spacer()
                Text("hours against your need").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
            Chart {
                ForEach(0..<7, id: \.self) { i in
                    BarMark(x: .value("Day", i), y: .value("Hours", (week.values[i].asleepMin ?? 0) / 60), width: .ratio(0.78))
                        .foregroundStyle(ForgeColor.rest.opacity(i == week.bestIndex(\.asleepMin) ? 1 : 0.55))
                        .cornerRadius(6)
                }
                RuleMark(y: .value("Need", need))
                    .foregroundStyle(ForgeColor.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartYAxis(.hidden)
            .chartXAxis { weekdayAxis(week) }
            .frame(height: 140)
            legend([(String(localized: "Asleep"), ForgeColor.rest, false),
                    (String(localized: "Need \(ForgeTodayView.hoursMinutes(need * 60)) h"), ForgeColor.secondary, true)])
        }
        .forgeCard(radius: 22, padding: 14)
    }

    private func effortBars(_ week: ForgeWeekly.Week) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Training load").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
            Chart {
                ForEach(0..<7, id: \.self) { i in
                    BarMark(x: .value("Day", i),
                            y: .value("Effort", UnitFormatter.effortValue(week.values[i].effort ?? 0, scale: effortScale)))
                        .foregroundStyle(ForgeColor.effort.opacity(i == week.bestIndex(\.effort) ? 1 : 0.55))
                        .cornerRadius(6)
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis { weekdayAxis(week) }
            .frame(height: 140)
        }
        .forgeCard(radius: 22, padding: 14)
    }

    private func legend(_ items: [(String, Color, Bool)]) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Capsule().fill(item.1).frame(width: 14, height: item.2 ? 2 : 3)
                    Text(item.0).font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func weekdayAxis(_ week: ForgeWeekly.Week) -> some AxisContent {
        AxisMarks(values: Array(0..<7)) { value in
            AxisValueLabel {
                if let i = value.as(Int.self), let day = Self.parse(week.days[i]) {
                    Text(day, format: .dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
                }
            }
        }
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func parse(_ key: String?) -> Date? { key.flatMap { parser.date(from: $0) } }
}
#endif
