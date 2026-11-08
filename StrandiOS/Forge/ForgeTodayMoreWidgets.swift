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
private struct ForgeWidgetCard<Route: Hashable, Content: View>: View {
    let title: String
    let route: Route
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(verbatim: title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(ForgeColor.tertiary)
                }
                content()
            }
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        }
        .buttonStyle(LiquidPressStyle())
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
                    (Text(verbatim: ForgeTodayView.hoursMinutes(max(0, wake.timeIntervalSince(bed)) / 60)) + Text(verbatim: " ") + Text("h"))
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
                    Text("Bedtime for a full night").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    Spacer(minLength: 8)
                    Text("Alarm \(wakeText)")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            } else {
                Text("Set a wake time to plan the night.").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
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
    @State private var loaded = false

    private var next: (day: Date, routine: TrainingRoutine)? {
        week.lazy.compactMap { entry in entry.routine.map { (entry.day, $0) } }.first
    }

    var body: some View {
        let title = next.map { String(localized: "Next up · \(Self.dayText($0.day))") } ?? String(localized: "Next session")
        ForgeWidgetCard(title: title, route: ForgeRoute.strength) {
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
            } else {
                Text(loaded ? "Nothing planned this week" : " ").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
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
        ForgeWidgetCard(title: String(localized: "What changed"), route: TabRoute.trends) {
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
            }
        }
        .task(id: repo.refreshSeq) {
            rows = await TrendsChangeSummary.rows(repo: repo, span: 7)
            loaded = true
        }
    }

    private func legend(_ count: Int, _ word: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: "\(count) \(word)").font(ForgeFont.caption.monospacedDigit()).foregroundStyle(ForgeColor.secondary)
        }
    }
}

/// The habit that moved Charge the most: its mark, the change as the figure, and the reading. Opens What works.
struct ForgeWhatWorksWidget: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = InsightsHubViewModel()

    var body: some View {
        ForgeWidgetCard(title: String(localized: "What works"), route: MoreDestination.insightsHub) {
            if let top = model.ranked.first {
                let look = BehaviourLook.of(top.behavior)
                let e = top.effect
                HStack(alignment: .top, spacing: 12) {
                    TrendsChangeSummary.categoryMark(look.symbol, tint: look.tint, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: top.behavior).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        if e.delta != 0 {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Image(systemName: e.delta > 0 ? "arrow.up" : "arrow.down").font(.system(size: 15, weight: .bold))
                                Text(verbatim: e.pctChange.map { "\(Int(abs($0).rounded())) %" } ?? String(format: "%.1f", abs(e.delta)))
                                    .font(ForgeFont.figure(24))
                                Text("Charge").font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                            }
                            .foregroundStyle(ForgeColor.text)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(verbatim: ForgeEffectWording.line(delta: e.delta, percent: e.pctChange))
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(2)
            } else {
                Text(model.loaded ? "Answer the journal for a few weeks to see what moves your Charge." : " ")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
    }
}

/// The strap as a small tile beside the measures: its level, and the last sync under it. Opens the
/// battery page.
struct ForgeStrapWidget: View {
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
        if let onWrist = live.wristEventThisLink, !onWrist { return String(localized: "Off the wrist") }
        if live.charging == true { return String(localized: "Charging") }
        guard let synced = live.lastSyncedAt else { return String(localized: "Not synced yet") }
        let date = Date(timeIntervalSince1970: synced)
        return String(localized: "Synced \(date.formatted(.relative(presentation: .named).locale(AppLanguage.activeLocale)))")
    }
}
#endif
