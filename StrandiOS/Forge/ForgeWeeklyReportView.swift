#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

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

    private var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = weekStartRaw == "sunday" ? 1 : 2
        return cal
    }

    private var weeks: (this: ForgeWeekly.Week, last: ForgeWeekly.Week) {
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return ForgeWeekly.weeks(containing: Date(), calendar: calendar, dayKey: { Repository.localDayKey($0) }) { key in
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
                if let note = weeklyNote { coachCard(note) }
                averages(w)
                highlights(w.this)
                chargeChart(w)
                sleepBars(w.this)
                effortBars(w.this)
                GoalsContextCard(context: .training)
                GoalsContextCard(context: .sleep)
                if coachFeatureEnabled {
                    ForgeChip(title: String(localized: "Plan next week with the coach"), systemImage: "sparkles",
                              prominent: true) {
                        onAsk(String(localized: "Look back at my week and help me plan next week: training, sleep and one focus."))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .today))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let series = await repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource, days: 21)
            restByDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
    }

    private func header(_ week: ForgeWeekly.Week) -> some View {
        let first = Self.parse(week.days.first)
        let last = Self.parse(week.days.last)
        return VStack(alignment: .leading, spacing: 2) {
            if let first, let last {
                Text("\(first.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))) to \(last.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)))".uppercased(with: AppLanguage.activeLocale))
                    .font(ForgeFont.overDate).foregroundStyle(ForgeColor.secondary)
                Text("Week \(calendar.component(.weekOfYear, from: first))")
                    .font(ForgeFont.largeTitle).foregroundStyle(ForgeColor.text)
            }
        }
        .padding(.horizontal, 4)
    }

    private func coachCard(_ note: ChatMessage) -> some View {
        let split = ForgeTimeline.splitNote(note.text)
        return VStack(alignment: .leading, spacing: 8) {
            Label("Coach · weekly report", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(ForgeColor.accent)
            Text(split.headline).font(.system(size: 20, weight: .bold)).foregroundStyle(ForgeColor.text)
            if !split.body.isEmpty {
                Text(split.body).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            }
        }
        .forgeCard(radius: 24, padding: 16)
    }

    private func averages(_ w: (this: ForgeWeekly.Week, last: ForgeWeekly.Week)) -> some View {
        HStack(spacing: 10) {
            averageTile(DomainTheme.charge.productName, w.this.mean(\.charge), w.last.mean(\.charge),
                        format: { "\(Int($0.rounded())) %" }, tint: ForgeColor.charge)
            averageTile(DomainTheme.effort.productName, w.this.mean(\.effort), w.last.mean(\.effort),
                        format: { ForgeToday.effortText($0, scale: effortScale) }, tint: ForgeColor.effort)
            averageTile(DomainTheme.rest.productName, w.this.mean(\.rest), w.last.mean(\.rest),
                        format: { "\(Int($0.rounded())) %" }, tint: ForgeColor.rest)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func averageTile(_ label: String, _ value: Double?, _ previous: Double?,
                             format: (Double) -> String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text(value.map(format) ?? "–").font(ForgeFont.rounded(24, .bold)).foregroundStyle(ForgeColor.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let value, let previous {
                let delta = value - previous
                Text("\(delta >= 0 ? "+" : "−")\(format(abs(delta))) vs last week")
                    .font(.system(size: 11)).foregroundStyle(ForgeColor.secondary).lineLimit(2)
            } else {
                Text("daily average").font(.system(size: 11)).foregroundStyle(ForgeColor.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .forgeCard(radius: 20, padding: 12)
    }

    private func highlights(_ week: ForgeWeekly.Week) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "Highlights")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                if let i = week.bestIndex(\.charge), let day = Self.parse(week.days[i]),
                   let value = week.values[i].charge {
                    ForgeMetricTile(label: String(localized: "Best day"),
                                    value: day.formatted(.dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale)),
                                    unit: "", tint: ForgeColor.charge,
                                    badge: (String(localized: "Charge \(Int(value.rounded())) %"), .good))
                }
                if let i = week.bestIndex(\.effort), let value = week.values[i].effort, let day = Self.parse(week.days[i]) {
                    ForgeMetricTile(label: String(localized: "Hardest day"), value: ForgeToday.effortText(value, scale: effortScale),
                                    unit: DomainTheme.effort.productName, tint: ForgeColor.effort,
                                    badge: (day.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale)), .neutral))
                }
                if let asleep = week.mean(\.asleepMin) {
                    ForgeMetricTile(label: String(localized: "Sleep"), value: ForgeTodayView.hoursMinutes(asleep),
                                    unit: String(localized: "h avg"), tint: ForgeColor.rest)
                }
                if let steps = week.mean(\.steps) {
                    ForgeMetricTile(label: String(localized: "Steps"),
                                    value: Int(steps.rounded()).formatted(.number.locale(AppLanguage.activeLocale)),
                                    unit: String(localized: "avg"), tint: ForgeColor.charge)
                }
            }
        }
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
            .chartXAxis { weekdayAxis(w.this) }
            .frame(height: 150)
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
                    BarMark(x: .value("Day", i), y: .value("Hours", (week.values[i].asleepMin ?? 0) / 60))
                        .foregroundStyle(ForgeColor.rest.opacity(0.8))
                        .cornerRadius(5)
                }
                RuleMark(y: .value("Need", need))
                    .foregroundStyle(ForgeColor.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXAxis { weekdayAxis(week) }
            .frame(height: 140)
        }
        .forgeCard(radius: 22, padding: 14)
    }

    private func effortBars(_ week: ForgeWeekly.Week) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DomainTheme.effort.productName).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
            Chart {
                ForEach(0..<7, id: \.self) { i in
                    BarMark(x: .value("Day", i),
                            y: .value("Effort", UnitFormatter.effortValue(week.values[i].effort ?? 0, scale: effortScale)))
                        .foregroundStyle(ForgeColor.effort.opacity(0.85))
                        .cornerRadius(5)
                }
            }
            .chartXAxis { weekdayAxis(week) }
            .frame(height: 140)
        }
        .forgeCard(radius: 22, padding: 14)
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
