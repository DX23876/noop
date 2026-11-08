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

/// Tonight: the bedtime that gives the full night, and tomorrow's alarm. Opens Alarms.
struct ForgeTonightWidget: View {
    var body: some View {
        let bed = ForgeToday.plannedBedtime(now: Date())
        NavigationLink(value: MoreDestination.alarms) {
            ForgePictureTile(symbol: "moon.fill", accent: "alarm.fill", tint: ForgeColor.rest) {
                Text("Tonight").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                if let bed {
                    Text(bed, format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                        .font(ForgeFont.figure(26)).foregroundStyle(ForgeColor.text)
                    Text("In bed for a full night · alarm \(Self.wakeText)")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                } else {
                    Text("Set a wake time to plan the night.")
                        .font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                }
            }
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// Tomorrow's wake time from the planner the bedtime counts back from, in the reader's clock.
    private static var wakeText: String {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let minutes = WindDownNudge.wakeMinutes(forWeekday: cal.component(.weekday, from: tomorrow))
        let wake = cal.date(byAdding: .minute, value: minutes, to: cal.startOfDay(for: tomorrow)) ?? tomorrow
        return wake.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.activeLocale))
    }
}

/// Two calm minutes, one tap away. Opens the breathing exercise.
struct ForgeBreatheWidget: View {
    @EnvironmentObject private var router: NavRouter

    var body: some View {
        Button { router.openBreathe() } label: {
            ForgePictureTile(symbol: "wind", accent: "sparkle", tint: ForgeColor.charge) {
                Text("Breathe").font(.system(.headline)).foregroundStyle(ForgeColor.text)
                Text("Two calm minutes, guided").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
        .buttonStyle(LiquidPressStyle())
    }
}

/// The next planned routine of the coming week, today included, with its start button.
struct ForgeNextSessionWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var session: ActiveSessionController
    @State private var next: (day: Date, routine: TrainingRoutine)?
    @State private var loaded = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink(value: ForgeRoute.strength) {
                ForgePictureTile(symbol: "dumbbell.fill", accent: "calendar", tint: ForgeColor.trainingData) {
                    if let next {
                        Text("Next up · \(Self.dayText(next.day))").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        Text(verbatim: next.routine.title).font(.system(.headline)).foregroundStyle(ForgeColor.text)
                            .lineLimit(1)
                        Text("\(next.routine.exercises.count) exercises").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    } else {
                        Text("Next up").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        Text(loaded ? "Nothing planned this week" : " ")
                            .font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
        .overlay(alignment: .trailing) {
            if let next, Calendar.current.isDateInToday(next.day) {
                Button { session.requestStrength(routines: [next.routine]) } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(ForgeColor.onTrainingAccent)
                        .padding(.horizontal, 16).frame(minHeight: 40)
                        .background(Capsule().fill(ForgeColor.trainingAccent))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }
        }
        .task(id: repo.refreshSeq) {
            let plan = await repo.nativeTrainingPlan()
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            next = (0..<7).lazy.compactMap { offset -> (Date, TrainingRoutine)? in
                guard let day = cal.date(byAdding: .day, value: offset, to: today),
                      let routine = TrainingHubModel.routines(in: plan, on: day).first else { return nil }
                return (day, routine)
            }.first
            loaded = true
        }
    }

    private static func dayText(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
        if Calendar.current.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
    }
}

/// The last seven days against the seven before, in a word, as Trends' "What changed" opens. Opens Trends.
struct ForgeChangesWidget: View {
    @EnvironmentObject private var repo: Repository
    @State private var rows: [TrendsChangeSummary.Row] = []
    @State private var loaded = false

    var body: some View {
        let better = rows.filter { $0.verdict == .better }.count
        let worse = rows.filter { $0.verdict == .worse }.count
        NavigationLink(value: TabRoute.trends) {
            ForgePictureTile(symbol: "chart.line.uptrend.xyaxis", accent: "sparkle", tint: ForgeColor.accent) {
                Text("This week against last").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                if !rows.isEmpty {
                    let head = TrendsChangeSummary.headline(rows)
                    Text(verbatim: head.title).font(.system(.headline)).foregroundStyle(ForgeColor.text)
                    Text("\(better) better · \(worse) worse · \(head.detail)")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .lineLimit(2)
                } else {
                    Text(loaded ? "Not enough days yet" : " ")
                        .font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                }
            }
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) {
            rows = await TrendsChangeSummary.rows(repo: repo, span: 7)
            loaded = true
        }
    }
}

/// The habit that moved Charge the most in the wearer's own journal. Opens What works.
struct ForgeWhatWorksWidget: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = InsightsHubViewModel()

    var body: some View {
        let top = model.ranked.first
        let look = top.map { BehaviourLook.of($0.behavior) }
        NavigationLink(value: MoreDestination.insightsHub) {
            ForgePictureTile(symbol: look?.symbol ?? "lightbulb.fill", accent: look?.accent ?? "sparkle",
                             tint: look?.tint ?? ForgeColor.effort) {
                Text("What works").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                if let top {
                    Text(verbatim: top.behavior).font(.system(.headline)).foregroundStyle(ForgeColor.text)
                        .lineLimit(2)
                    Text(verbatim: ForgeEffectWording.line(delta: top.effect.delta, percent: top.effect.pctChange))
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .lineLimit(2)
                } else {
                    Text(model.loaded ? "Answer the journal for a few weeks to see what moves your Charge." : " ")
                        .font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                }
            }
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
    }
}

/// The strap at a glance: battery, last sync and, once the strap has said so on this link, whether it is
/// worn. Opens the battery page.
struct ForgeStrapWidget: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        NavigationLink(value: TabRoute.battery) {
            ForgePictureTile(symbol: "battery.75percent", accent: "dot.radiowaves.left.and.right",
                             tint: live.connected ? ForgeColor.charge : ForgeColor.secondary) {
                Text("Strap").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                if let pct = live.batteryPct {
                    Text(StrapBatteryCopy.percentText(pct)).font(ForgeFont.figure(26)).foregroundStyle(ForgeColor.text)
                } else {
                    Text(live.connected ? "Connected" : "Not connected")
                        .font(.system(.headline)).foregroundStyle(ForgeColor.text)
                }
                Text(verbatim: detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(2)
            }
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// Charging, the wrist (only from an event on this link: the stored default says nothing) and the sync.
    private var detail: String {
        var parts: [String] = []
        if live.charging == true { parts.append(String(localized: "Charging")) }
        if let onWrist = live.wristEventThisLink {
            parts.append(onWrist ? String(localized: "On the wrist") : String(localized: "Off the wrist"))
        }
        if let synced = live.lastSyncedAt {
            let date = Date(timeIntervalSince1970: synced)
            parts.append(String(localized: "Synced \(date.formatted(.relative(presentation: .named).locale(AppLanguage.activeLocale)))"))
        } else {
            parts.append(String(localized: "Not synced yet"))
        }
        return parts.joined(separator: " · ")
    }
}
#endif
