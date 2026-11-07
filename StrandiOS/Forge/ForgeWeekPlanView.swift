#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopStore

/// The redesign's "This week's plan" page (prototype board "WeekPlan"): each day's Effort, done or planned,
/// and the week day by day. What is planned is the coach's agreed sessions (`CoachPlanStore`) and the
/// routines scheduled in the training plan (`TrainingHubModel`); what is done is the recorded workouts.
struct ForgeWeekPlanView: View {
    var onAsk: (String) -> Void = { _ in }
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var session: ActiveSessionController
    @ObservedObject private var store = CoachPlanStore.shared
    @StateObject private var hub = TrainingHubModel()
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage("training.weekStartsOn") private var weekStartRaw = TrainingWeekStart.monday.rawValue
    @State private var rows: [WorkoutRow] = []
    @State private var scrolledPast = false

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var weekStart: TrainingWeekStart { TrainingWeekStart(rawValue: weekStartRaw) ?? .monday }

    private var days: [Date] {
        var cal = Calendar.current
        cal.firstWeekday = weekStart == .monday ? 2 : 1
        let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// One day of the week as the page shows it.
    struct Day: Identifiable {
        let date: Date
        let done: [WorkoutRow]
        let planned: [String]
        let plannedEffort: Double?
        let effort: Double?
        var id: Date { date }
    }

    private var week: [Day] {
        let cal = Calendar.current
        let effortByDay = Dictionary(repo.days.map { ($0.day, $0.strain) }, uniquingKeysWith: { _, last in last })
        return days.map { date in
            let key = Repository.localDayKey(date)
            let done = rows.filter { cal.isDate(Date(timeIntervalSince1970: TimeInterval($0.startTs)), inSameDayAs: date) }
            let proposals = store.proposals(forDay: key).filter { $0.status.isCommitment || $0.status == .proposed }
            var planned = proposals.map { p in
                p.intent == .rest ? String(localized: "Rest day")
                    : [WorkoutSource.localizedDisplaySport(p.sport), p.durationMin.map { String(localized: "\($0) min") }]
                        .compactMap { $0 }.joined(separator: " · ")
            }
            if hub.loaded { planned += hub.routines(on: date).map(\.title) }
            return Day(date: date, done: done, planned: planned,
                       plannedEffort: proposals.compactMap(\.targetEffort).max(),
                       effort: effortByDay[key] ?? nil)
        }
    }

    var body: some View {
        let week = self.week
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: nil, title: String(localized: "This week's plan"),
                                  scrolledPast: $scrolledPast)
                effortColumns(week)
                ForgeSectionTitle(title: "This week")
                ForgeGroup {
                    ForEach(Array(week.enumerated()), id: \.element.id) { index, day in
                        if index > 0 { ForgeRowDivider() }
                        dayRow(day)
                    }
                }
                NavigationLink(value: MoreDestination.training) {
                    ForgeRow(systemImage: "calendar", tint: ForgeColor.accent, title: String(localized: "Schedule and routines"),
                             subtitle: String(localized: "Choose which routine goes on which day"))
                        .forgeCard(radius: ForgeRadius.card, padding: 0)
                }
                .buttonStyle(.plain)
                if coachFeatureEnabled {
                    ForgeChip(title: String(localized: "Change the plan with the coach"), systemImage: "bubble.left.and.text.bubble.right",
                              prominent: true) {
                        onAsk(String(localized: "Look at this week's plan, my Charge and what I have done so far, and suggest changes to the rest of the week."))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .training))
        .forgeDetailBar(title: String(localized: "This week's plan"), showsTitle: scrolledPast)
        .task(id: repo.refreshSeq) {
            await hub.load(repo: repo, session: session, weekStartsOn: weekStart)
            rows = await repo.workoutRows(days: 8, reconcileHrCap: 0)
        }
    }

    // MARK: Effort per day

    /// Effort per day on the stored 0 to 100 axis: a filled column for what was done, a dashed outline for
    /// what the plan targets on a day still to come.
    private func effortColumns(_ week: [Day]) -> some View {
        let cal = Calendar.current
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Effort").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                Spacer()
                Text("filled: done · dashed: planned").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(week) { day in
                    let future = cal.startOfDay(for: day.date) > cal.startOfDay(for: Date())
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ForgeColor.fill)
                            if let e = day.effort, !future, e > 0 {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ForgeColor.effort)
                                    .frame(height: 96 * min(1, e / 100))
                            } else if let p = day.plannedEffort {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(ForgeColor.effort, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                    .frame(height: 96 * min(1, p / 100))
                            }
                        }
                        .frame(height: 96)
                        Text(day.date, format: .dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
                            .font(.system(.caption, weight: cal.isDateInToday(day.date) ? .bold : .regular))
                            .foregroundStyle(cal.isDateInToday(day.date) ? ForgeColor.accent : ForgeColor.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(day.date.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))))
                    .accessibilityValue(Text(day.effort.map { ForgeToday.effortText($0, scale: effortScale) } ?? String(localized: "No Effort yet")))
                }
            }
        }
        .forgeCard(radius: ForgeRadius.card, padding: 14)
    }

    // MARK: Day rows

    private func dayRow(_ day: Day) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.startOfDay(for: day.date)
        let isToday = start == today
        let past = start < today
        let title: String = {
            if let first = day.done.first {
                let names = day.done.map { WorkoutSource.localizedDisplaySport($0.sport) }
                return names.count > 1 ? names.joined(separator: ", ") : WorkoutSource.localizedDisplaySport(first.sport)
            }
            return day.planned.first ?? (past ? String(localized: "No workout") : String(localized: "Nothing planned"))
        }()
        let detail: String? = {
            if !day.done.isEmpty, let e = day.effort { return String(localized: "done · Effort \(ForgeToday.effortText(e, scale: effortScale))") }
            if day.planned.count > 1 { return day.planned.dropFirst().joined(separator: " · ") }
            if let p = day.plannedEffort, !past { return String(localized: "target Effort about \(ForgeToday.effortText(p, scale: effortScale))") }
            return nil
        }()
        let tag: (String, ForgeBadge.Tone)? = !day.done.isEmpty ? (String(localized: "done"), .good)
            : isToday && !day.planned.isEmpty ? (String(localized: "today"), .attention)
            : nil
        return HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(day.date, format: .dateTime.day().locale(AppLanguage.activeLocale))
                    .font(ForgeFont.rounded(20, .semibold))
                    .foregroundStyle(past && day.done.isEmpty ? ForgeColor.secondary : ForgeColor.text)
                Text(day.date, format: .dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale))
                    .font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
            }
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.callout, weight: .semibold))
                    .foregroundStyle(past && day.done.isEmpty ? ForgeColor.secondary : ForgeColor.text)
                if let detail { Text(detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary) }
            }
            Spacer(minLength: 8)
            if let tag { ForgeBadge(text: tag.0, tone: tag.1) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
#endif
