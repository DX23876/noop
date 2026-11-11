#if os(iOS)
import SwiftUI
import StrandDesign
import StrandTraining
import StrandAnalytics

// Today's further widgets: each one a doorway to a page that already exists, reading the same source that
// page reads, so a widget and its page never tell two stories.

/// Who the cycle widget is for: a woman, or someone whose body formulas follow the female reference.
enum ForgeCycleAudience {
    static func applies(sex: String, bodyFormulaSex: String) -> Bool {
        sex == "female" || (sex == "nonbinary" && bodyFormulaSex == "female")
    }
}

/// The cycle summary as a widget, shown only to the people it is for and only while cycle tracking is on.
struct ForgeCycleWidget: View {
    @EnvironmentObject private var profile: ProfileStore

    var body: some View {
        if ForgeCycleAudience.applies(sex: profile.sex, bodyFormulaSex: profile.bodyFormulaSex) {
            ForgeCycleSummaryCard(showsLogButtons: false)
        }
    }
}

/// A wide widget's frame, as Energy and Training load draw it: the name and a chevron on top, the graphic
/// and its figures under it, on a card. The whole card opens the page.
struct ForgeWidgetCard<Route: Hashable, Content: View>: View {
    let title: String
    let route: Route
    /// False when the body holds its own taps (rows, a start button): then only the header opens the page.
    var bodyOpens = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        if bodyOpens {
            NavigationLink(value: route) {
                VStack(alignment: .leading, spacing: 12) { header; content() }
                    .forgeCard(radius: ForgeRadius.card, padding: 16)
            }
            .buttonStyle(LiquidPressStyle())
        } else {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink(value: route) { header.contentShape(Rectangle()) }.buttonStyle(.plain)
                content()
            }
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        }
    }

    private var header: some View {
        HStack {
            Text(verbatim: title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
            Spacer()
            Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                .foregroundStyle(ForgeColor.tertiary)
        }
    }
}

/// Tonight: bedtime for the full night and tomorrow's alarm, drawn as the night they span. Opens Alarms.
struct ForgeTonightWidget: View {
    var body: some View {
        let bed = ForgeToday.plannedBedtime(now: Date())
        let wake = Self.wake
        let wakeText = wake.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.activeLocale))
        ForgeWidgetCard(title: String(localized: "Tonight"), route: MoreDestination.alarms) {
            if let bed {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bed, format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                        .font(ForgeFont.figure(28)).foregroundStyle(ForgeColor.text)
                    Text("in bed").font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: ForgeTodayView.hoursMinutes(max(0, wake.timeIntervalSince(bed)) / 60))
                        Text("h")
                    }
                    .font(.system(.subheadline, weight: .semibold).monospacedDigit()).foregroundStyle(ForgeColor.restInk)
                }
                // The night as one band from bedtime to the alarm.
                HStack(spacing: 8) {
                    Image(systemName: "moon.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(ForgeColor.rest)
                    Capsule().fill(LinearGradient(colors: [ForgeColor.rest, ForgeColor.rest.opacity(0.45), ForgeColor.effort.opacity(0.7)],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                    Image(systemName: "sun.max.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(ForgeColor.effort)
                }
                .accessibilityHidden(true)
                HStack {
                    Text(verbatim: Self.countdown(to: bed)).font(ForgeFont.caption.weight(.semibold))
                        .foregroundStyle(ForgeColor.restInk)
                    Spacer(minLength: 8)
                    Text("Alarm \(wakeText)")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            } else {
                Text("Set a wake time to plan the night.").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
    }

    /// How long until bedtime, in the evening; past it, that it is time; earlier in the day, what the
    /// time is for.
    private static func countdown(to bed: Date, now: Date = Date()) -> String {
        let minutes = Int(bed.timeIntervalSince(now) / 60)
        if minutes <= 0 { return String(localized: "Time for bed") }
        if minutes > 4 * 60 { return String(localized: "Bedtime for a full night") }
        if minutes < 60 { return String(localized: "In \(minutes) min") }
        let left = ForgeTodayView.hoursMinutes(Double(minutes))
        return String(localized: "In \(left) h")
    }

    /// Tomorrow's wake time from the planner the bedtime counts back from.
    private static var wake: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let minutes = WindDownNudge.wakeMinutes(forWeekday: cal.component(.weekday, from: tomorrow))
        return cal.date(byAdding: .minute, value: minutes, to: cal.startOfDay(for: tomorrow)) ?? tomorrow
    }
}

/// Two calm minutes as a small tile beside the measures. Opens the breathing exercise.
struct ForgeBreatheWidget: View {
    @EnvironmentObject private var router: NavRouter

    var body: some View {
        Button { router.openBreathe() } label: {
            ForgeTodayTile(label: String(localized: "Breathe"), symbol: "wind", value: "2", unit: String(localized: "min"),
                           caption: String(localized: "Tap to start"), tint: ForgeColor.charge)
        }
        .buttonStyle(LiquidPressStyle())
    }
}

/// The next planned routine and the coming week's planned days, with Start when it is today.
struct ForgeNextSessionWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var session: ActiveSessionController
    @State private var week: [(day: Date, routine: TrainingRoutine?)] = []
    @State private var names: [String: String] = [:]
    @State private var loaded = false

    private var next: (day: Date, routine: TrainingRoutine)? {
        week.lazy.compactMap { entry in entry.routine.map { (entry.day, $0) } }.first
    }

    var body: some View {
        let title = next.map { String(localized: "Next up · \(Self.dayText($0.day))") } ?? String(localized: "Next session")
        ForgeWidgetCard(title: title, route: ForgeRoute.strength, bodyOpens: false) {
            if let next {
                HStack(spacing: 12) {
                    TrendsChangeSummary.categoryMark("dumbbell.fill", tint: ForgeColor.trainingData, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: next.routine.title).font(.system(.headline)).foregroundStyle(ForgeColor.text).lineLimit(1)
                        Text("\(next.routine.exercises.count) exercises").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    Spacer(minLength: 8)
                    if Calendar.current.isDateInToday(next.day) {
                        Button { session.requestStrength(routines: [next.routine]) } label: {
                            Label("Start", systemImage: "play.fill")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(ForgeColor.onTrainingAccent)
                                .padding(.horizontal, 16).frame(minHeight: 40)
                                .background(Capsule().fill(ForgeColor.trainingAccent))
                        }
                        .buttonStyle(.plain)
                    }
                }
                // The first exercises by name, so the day reads as a workout and not as a title.
                let titles = next.routine.exercises.compactMap { names[$0.exerciseId] }
                if !titles.isEmpty {
                    FlowRows(spacing: 6) {
                        ForEach(Array(titles.prefix(3).enumerated()), id: \.offset) { _, name in
                            Text(verbatim: name).font(.system(.caption, weight: .medium)).foregroundStyle(ForgeColor.text)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(ForgeColor.fill))
                        }
                        if titles.count > 3 {
                            Text(verbatim: "+" + String(titles.count - 3)).font(.system(.caption, weight: .medium))
                                .foregroundStyle(ForgeColor.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(ForgeColor.fill))
                        }
                    }
                }
            } else if loaded {
                NavigationLink(value: ForgeRoute.weekPlan) {
                    Label("Plan this week", systemImage: "calendar.badge.plus")
                        .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.trainingAccent)
                }
                .buttonStyle(.plain)
            }
            // The coming seven days: a filled dot where a routine is planned.
            if !week.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, entry in
                        VStack(spacing: 4) {
                            Circle().fill(entry.routine == nil ? ForgeColor.fill : ForgeColor.trainingData)
                                .frame(width: 10, height: 10)
                            Text(entry.day, format: .dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
                                .font(.system(.caption2, weight: Calendar.current.isDateInToday(entry.day) ? .bold : .regular))
                                .foregroundStyle(ForgeColor.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .task(id: repo.refreshSeq) {
            let plan = await repo.nativeTrainingPlan()
            names = Dictionary((await repo.nativeTrainingExercises()).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            week = (0..<7).compactMap { offset in
                guard let day = cal.date(byAdding: .day, value: offset, to: today) else { return nil }
                return (day, TrainingHubModel.routines(in: plan, on: day).first)
            }
            loaded = true
        }
    }

    private static func dayText(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
        if Calendar.current.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
    }
}

/// The last seven days against the seven before: the word, the tally bar and its counts, as Trends opens.
struct ForgeChangesWidget: View {
    @EnvironmentObject private var repo: Repository
    @State private var rows: [TrendsChangeSummary.Row] = []
    @State private var loaded = false

    var body: some View {
        let better = rows.filter { $0.verdict == .better }.count
        let worse = rows.filter { $0.verdict == .worse }.count
        let steady = rows.count - better - worse
        ForgeWidgetCard(title: String(localized: "What changed"), route: TabRoute.trends, bodyOpens: false) {
            if rows.isEmpty {
                Text(loaded ? "Not enough days yet" : " ").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            } else {
                let head = TrendsChangeSummary.headline(rows)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: head.title).font(.system(.title3, weight: .bold)).foregroundStyle(ForgeColor.text)
                    Text(verbatim: head.detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                }
                GeometryReader { geo in
                    let total = CGFloat(max(1, rows.count))
                    let usable = geo.size.width - 4
                    HStack(spacing: 2) {
                        if better > 0 { Capsule().fill(StrandPalette.chargeColor).frame(width: usable * CGFloat(better) / total) }
                        if worse > 0 { Capsule().fill(StrandPalette.effortColor).frame(width: usable * CGFloat(worse) / total) }
                        if steady > 0 { Capsule().fill(ForgeColor.fill) }
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                HStack(spacing: 16) {
                    legend(better, String(localized: "better"), StrandPalette.chargeColor)
                    legend(worse, String(localized: "worse"), StrandPalette.effortColor)
                    legend(steady, String(localized: "steady"), ForgeColor.tertiary)
                    Spacer(minLength: 0)
                }
                // The measures that moved, each opening its own page.
                let moved = rows.filter { $0.verdict == .better || $0.verdict == .worse }.prefix(3)
                VStack(spacing: 0) {
                    ForEach(Array(moved.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5).padding(.leading, 40) }
                        NavigationLink(value: TabRoute.metricSourced(key: row.key, source: row.source)) { moverRow(row) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: repo.refreshSeq) {
            rows = await TrendsChangeSummary.rows(repo: repo, span: 7)
            loaded = true
        }
    }

    private func moverRow(_ row: TrendsChangeSummary.Row) -> some View {
        let verdict = row.verdict == .better ? StrandPalette.chargeColor : StrandPalette.effortColor
        return HStack(spacing: 12) {
            TrendsChangeSummary.categoryMark(TrendIllustration.symbol(row.key, up: row.change > 0),
                                             tint: TrendIllustration.color(row.key), size: 28)
            // The name over its change, so a long name ("Resting Heart Rate") and two values both fit.
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.title).font(.system(.subheadline, weight: .medium)).foregroundStyle(ForgeColor.text).lineLimit(1)
                Text(verbatim: "\(row.before) → \(row.now)").font(ForgeFont.caption.monospacedDigit())
                    .foregroundStyle(ForgeColor.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: row.change > 0 ? "arrow.up" : "arrow.down").font(.system(size: 11, weight: .bold))
                .foregroundStyle(verdict)
            Image(systemName: "chevron.right").font(.system(.caption2, weight: .semibold)).foregroundStyle(ForgeColor.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func legend(_ count: Int, _ word: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: "\(count) \(word)").font(ForgeFont.caption.monospacedDigit()).foregroundStyle(ForgeColor.secondary)
        }
    }
}

/// The three habits that moved Charge the most, each on a bar out from the middle: right raised it, left
/// lowered it, in the colours of better and worse. Opens What works.
struct ForgeWhatWorksWidget: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = InsightsHubViewModel()

    var body: some View {
        ForgeWidgetCard(title: String(localized: "What works for your Charge"), route: MoreDestination.insightsHub) {
            let top = Array(model.ranked.prefix(3))
            if top.isEmpty {
                Text(model.loaded ? "Answer the journal for a few weeks to see what moves your Charge." : " ")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            } else {
                let widest = max(1, top.map { abs($0.effect.pctChange ?? 0) }.max() ?? 1)
                VStack(spacing: 12) {
                    ForEach(Array(top.enumerated()), id: \.offset) { _, r in row(r, widest: widest) }
                }
            }
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
    }

    private func row(_ r: RankedEffect, widest: Double) -> some View {
        let look = BehaviourLook.of(r.behavior)
        let pct = r.effect.pctChange ?? 0
        // Charge: higher is better, so a raise is the good side.
        let tint = pct >= 0 ? StrandPalette.chargeColor : StrandPalette.effortColor
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TrendsChangeSummary.categoryMark(look.symbol, tint: look.tint, size: 24)
                Text(verbatim: r.behavior).font(.system(.footnote, weight: .medium)).foregroundStyle(ForgeColor.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: (pct >= 0 ? "+" : "−") + "\(Int(abs(pct).rounded())) %")
                    .font(.system(.footnote, weight: .semibold).monospacedDigit()).foregroundStyle(ForgeColor.text)
            }
            GeometryReader { geo in
                let half = geo.size.width / 2
                let width = max(4, half * CGFloat(abs(pct) / widest))
                ZStack(alignment: .leading) {
                    Capsule().fill(ForgeColor.fill)
                    Rectangle().fill(ForgeColor.separator).frame(width: 1).offset(x: half)
                    Capsule().fill(tint).frame(width: width).offset(x: pct >= 0 ? half : half - width)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The strap as a small tile beside the measures: its level, and the last sync under it. Opens the
/// battery page.
struct ForgeStrapWidget: View {
    /// Over two columns: the wrist or charging state and the last sync together.
    var detailed = false
    @EnvironmentObject private var live: LiveState

    var body: some View {
        NavigationLink(value: TabRoute.battery) {
            ForgeTodayTile(label: String(localized: "Strap"), symbol: live.charging == true ? "battery.100percent.bolt" : "battery.75percent",
                           value: live.batteryPct.map { "\(Int($0.rounded()))" }, unit: "%",
                           caption: caption, tint: live.connected ? ForgeColor.charge : ForgeColor.secondary)
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// The wrist only from an event on this link (the stored default says nothing), then the sync.
    private var caption: String {
        let state: String? = live.wristEventThisLink == false ? String(localized: "Off the wrist")
            : live.charging == true ? String(localized: "Charging") : nil
        let sync: String = live.lastSyncedAt.map {
            String(localized: "Synced \(Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named).locale(AppLanguage.activeLocale)))")
        } ?? String(localized: "Not synced yet")
        guard let state else { return sync }
        return detailed ? state + " · " + sync : state
    }
}
#endif
