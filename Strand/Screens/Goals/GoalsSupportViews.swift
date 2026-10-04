import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Explainer (design §8.1)

/// Four pages on how goals work, each led by the real building blocks rather than pictures, so what is
/// learned here is exactly what Today shows. Opens once on the first visit of the overview, then from
/// its "?" button.
struct GoalsIntroSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var demo = 0
    private let pages = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                TabView(selection: $page) {
                    introPage(title: "Your goals belong together",
                              text: "A long-term goal, the month that serves it and the week you can change today.") {
                        chainDemo
                    }.tag(0)
                    introPage(title: "How to read the bar",
                              text: "The mark moves through the week and shows where your plan stands today. If the bar is longer, you are ahead.") {
                        trackDemo
                    }.tag(1)
                    introPage(title: "What the states mean",
                              text: "Every state is a word and a symbol, never colour alone.") {
                        statesDemo
                    }.tag(2)
                    introPage(title: "Time off is planned in",
                              text: "Ill or paused, the week is protected: it doesn't count as missed and your series stays.") {
                        protectedDemo
                    }.tag(3)
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                #endif
                Button {
                    if page < pages - 1 { withAnimation(StrandMotion.fade) { page += 1 } } else { finish() }
                } label: {
                    Text(page < pages - 1 ? "Next" : "Let's go").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { finish() } }
            }
            .task {
                guard !reduceMotion else { demo = 2; return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    withAnimation(.easeOut(duration: 0.6)) { demo = (demo + 1) % 3 }
                }
            }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: GoalPrefs.introSeenKey)
        dismiss()
    }

    private func introPage<Demo: View>(title: LocalizedStringKey, text: LocalizedStringKey,
                                       @ViewBuilder demo: () -> Demo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            demo()
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 170)
                .background(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                    .fill(StrandPalette.surfaceRaised))
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(text).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var chainDemo: some View {
        VStack(alignment: .leading, spacing: 8) {
            demoRow(icon: "flag.checkered", text: "Half marathon in March", indent: 0)
            demoRow(icon: "calendar", text: "60 km in October", indent: 18)
            demoRow(icon: "calendar.badge.clock", text: "3 runs a week", indent: 36)
            demoRow(icon: "checkmark.circle", text: "Today: run 30 min", indent: 54)
        }
    }

    private func demoRow(icon: String, text: LocalizedStringKey, indent: CGFloat) -> some View {
        Label(text, systemImage: icon)
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
            .padding(.leading, indent)
    }

    private var trackDemo: some View {
        let states: [(Double, Double, PeriodGoalState)] = [(0.2, 0.45, .close), (0.55, 0.45, .onTrack), (1.0, 0.8, .achieved)]
        let current = states[demo]
        let style = GoalStatusStyle.of(current.2)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Runs", systemImage: "figure.run").font(StrandFont.subhead)
                Spacer()
                Label { Text(style.word) } icon: { Image(systemName: style.symbol) }
                    .font(StrandFont.footnote).foregroundStyle(style.foreground)
            }
            PaceTrack(fraction: current.0, paceFraction: current.2 == .achieved ? nil : current.1,
                      tint: style.color, height: 10)
            Text(current.2 == .close ? "Bar behind the mark: catch up a little"
                 : current.2 == .onTrack ? "Bar past the mark: you're ahead of plan" : "Bar full: goal reached")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var statesDemo: some View {
        let shown: [PeriodGoalState] = [.achieved, .onTrack, .close, .behind, .outOfReach, .protected]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(shown, id: \.self) { state in
                let style = GoalStatusStyle.of(state)
                Label { Text(style.word) } icon: { Image(systemName: style.symbol) }
                    .font(StrandFont.footnote).foregroundStyle(style.foreground)
            }
        }
    }

    private var protectedDemo: some View {
        VStack(alignment: .leading, spacing: 10) {
            DayDotStrip(days: [
                .init(id: "1", state: .met, label: "M"), .init(id: "2", state: .noData, label: "T"),
                .init(id: "3", state: .noData, label: "W"), .init(id: "4", state: .noData, label: "T"),
                .init(id: "5", state: .met, label: "F"), .init(id: "6", state: .rest, label: "S"),
                .init(id: "7", state: .met, label: "S"),
            ], tint: StrandPalette.statusPositive, diameter: 20)
            PeriodHistoryBars(bars: [
                .init(id: "a", fraction: 1, tint: StrandPalette.statusPositive),
                .init(id: "b", fraction: 0.85, tint: StrandPalette.statusPositive),
                .init(id: "c", fraction: 0.3, tint: StrandPalette.accent.opacity(0.45)),
                .init(id: "d", fraction: 1, tint: StrandPalette.statusPositive),
            ], height: 34)
            Label("Protected week: series kept", systemImage: "shield")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
        }
    }
}

// MARK: - List per period

struct PeriodGoalsListView: View {
    let period: PeriodGoal.Period
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @State private var reordering = false

    private var snapshots: [PeriodGoalSnapshot] {
        tracking.periodSnapshots.filter { $0.goal.period == period && $0.goal.isOpen }
    }

    var body: some View {
        let items = snapshots
        let days = items.first?.periodDays ?? PeriodGoalTracker.periodDays(
            period, containing: Repository.localDayKey(Date()), calendar: TrainingPreferences.weekCalendar)
        let onCourse = items.filter { [.onTrack, .ahead, .achieved].contains($0.state) }.count
        ScreenScaffold(title: period == .week ? "Weekly goals" : "Monthly goals",
                       trailing: {
                           if items.count > 1 {
                               Button(reordering ? "Done" : "Arrange") { withAnimation { reordering.toggle() } }
                                   .font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                           }
                       }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(items.isEmpty ? String(localized: "No goals yet")
                                   : String(localized: "\(onCourse) of \(items.count) on course"))
                    .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Text(GoalFormat.range(days)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            if reordering {
                arrangeList(items)
            } else {
                group(String(localized: "Needs attention"), items.filter { GoalStatusStyle.needsAttention($0.state) })
                group(String(localized: "On course"), items.filter { !GoalStatusStyle.needsAttention($0.state) && $0.state != .achieved })
                group(String(localized: "Achieved"), items.filter { $0.state == .achieved })
            }
            NavigationLink(value: GoalsRoute.setup(period)) {
                Label(period == .week ? "Add a weekly goal" : "Add a monthly goal", systemImage: "plus")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [PeriodGoalSnapshot]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary).padding(.horizontal, 2)
                ForEach(items) { snapshot in
                    NavigationLink(value: GoalsRoute.detail(snapshot.id)) {
                        NoopCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 12) {
                                PeriodGoalCard(snapshot: snapshot)
                                if !snapshot.history.isEmpty {
                                    GoalWeekHistoryStrip(snapshot: snapshot)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Q13: the order Today shows, set by moving goals up and down.
    private func arrangeList(_ items: [PeriodGoalSnapshot]) -> some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Today shows the first three.").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, snapshot in
                    HStack {
                        Text("\(index + 1).").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Text(GoalFormat.title(snapshot.goal)).font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button { move(index, by: -1, count: items.count) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0)
                            .accessibilityLabel(Text("Move up"))
                        Button { move(index, by: 1, count: items.count) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == items.count - 1)
                            .accessibilityLabel(Text("Move down"))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    private func move(_ index: Int, by delta: Int, count: Int) {
        let target = index + delta
        guard target >= 0, target < count else { return }
        store.move(fromOffsets: IndexSet(integer: index), toOffset: delta > 0 ? target + 1 : target, within: period)
        StrandHaptic.selection.play()
        Task { await tracking.refresh(repo: repo) }
    }
}

/// The last periods as compact chips under a card (the evolved `GoalWeekGrid`).
struct GoalWeekHistoryStrip: View {
    let snapshot: PeriodGoalSnapshot

    var body: some View {
        HStack(spacing: 4) {
            ForEach(snapshot.history.suffix(8)) { entry in
                Capsule(style: .continuous).fill(GoalStatusStyle.of(entry.outcome).color.opacity(entry.outcome == .noData ? 0.3 : 1))
                    .frame(width: 18, height: 6)
            }
            Spacer().frame(width: 4)
            Capsule(style: .continuous).strokeBorder(snapshot.trackTint, lineWidth: 1.5).frame(width: 18, height: 6)
            Spacer()
            if snapshot.currentStreak > 0 {
                Text(snapshot.goal.period == .week ? String(localized: "\(snapshot.currentStreak) weeks in a row")
                                                   : String(localized: "\(snapshot.currentStreak) months in a row"))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(snapshot.history.suffix(8).map { GoalStatusStyle.of($0.outcome).wordText }.joined(separator: ", ")))
    }
}

// MARK: - Archive

struct GoalsArchiveView: View {
    @ObservedObject private var store = PeriodGoalStore.shared
    @ObservedObject private var longTerm = CoachGoalStore.shared

    var body: some View {
        let ended = store.goals.filter { $0.status == .ended }.sorted { ($0.endedAt ?? $0.createdAt) > ($1.endedAt ?? $1.createdAt) }
        let past = longTerm.goals.filter { [.achieved, .abandoned, .archived].contains($0.status) }
        ScreenScaffold(title: "Ended goals", subtitle: "Ended goals keep their history here.") {
            if ended.isEmpty && past.isEmpty {
                Text("Nothing here yet.").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            if !ended.isEmpty {
                NoopCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Weekly and monthly").strandOverline()
                        ForEach(ended) { goal in
                            let results = store.results(for: goal.id)
                            let achieved = results.filter { $0.outcome == .achieved }.count
                            VStack(alignment: .leading, spacing: 2) {
                                Text(GoalFormat.title(goal)).font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(results.isEmpty ? String(localized: "No finished period")
                                                     : String(localized: "Reached \(achieved) of \(results.count)"))
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) { store.remove(goal.id) }
                            }
                        }
                    }
                }
            }
            if !past.isEmpty {
                NavigationLink(value: GoalsRoute.longTerm) {
                    Label("Past long-term goals: \(past.count)", systemImage: "flag.checkered")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Review (also embedded in the weekly digest)

/// "Your goals" for a finished week or month: what was reached, against the period before, and a
/// one-tap way to adjust the next one. The digest embeds it so there is one review, not two (Q: §12.4).
struct GoalsReviewBlock: View {
    let period: PeriodGoal.Period
    /// Day key of any day in the reviewed period; nil = the last finished one.
    var anyDay: String?
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared

    private struct Line: Identifiable {
        let id: UUID
        let goal: PeriodGoal
        let entry: PeriodGoalSnapshot.HistoryEntry
        let previous: PeriodGoalSnapshot.HistoryEntry?
        /// The live snapshot, for next-period suggestions; nil for an older week read from frozen results.
        let snapshot: PeriodGoalSnapshot?
    }

    private var lines: [Line] {
        if let anyDay {
            // A browsed week: the frozen results of every goal that ran then, ended goals included, so a
            // week from last spring still shows the goals it had.
            let calendar = TrainingPreferences.weekCalendar
            guard let start = PeriodGoalTracker.periodDays(period, containing: anyDay, calendar: calendar).first
            else { return [] }
            let previousStart = PeriodGoalTracker.periodDays(
                period, containing: PeriodGoalTracker.previousPeriodAnyDay(period, start: start), calendar: calendar).first
            return store.goals.filter { $0.period == period }.compactMap { goal in
                let results = store.results(for: goal.id)
                let live = tracking.periodSnapshot(for: goal.id)?.history
                func entry(_ s: String?) -> PeriodGoalSnapshot.HistoryEntry? {
                    guard let s else { return nil }
                    if let r = results.first(where: { $0.periodStart == s }) {
                        return .init(periodStart: s, target: r.target, value: r.value, outcome: r.outcome)
                    }
                    return live?.first { $0.periodStart == s }
                }
                guard let current = entry(start) else { return nil }
                return Line(id: goal.id, goal: goal, entry: current, previous: entry(previousStart), snapshot: nil)
            }
        }
        return tracking.periodSnapshots.filter { $0.goal.period == period }.compactMap { snapshot in
            guard let index = snapshot.history.indices.last else { return nil }
            return Line(id: snapshot.id, goal: snapshot.goal, entry: snapshot.history[index],
                        previous: index > 0 ? snapshot.history[index - 1] : nil, snapshot: snapshot)
        }
    }

    var body: some View {
        let items = lines
        if !items.isEmpty {
            let achieved = items.filter { $0.entry.outcome == .achieved }.count
            let previousAchieved = items.compactMap(\.previous).filter { $0.outcome == .achieved }.count
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your goals").strandOverline()
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(achieved) of \(items.count) achieved")
                            .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        if items.contains(where: { $0.previous != nil }) {
                            let delta = achieved - previousAchieved
                            Text(delta == 0 ? String(localized: "same as before")
                                 : (delta > 0 ? String(localized: "+\(delta) on the period before")
                                              : String(localized: "\(delta) on the period before")))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    ForEach(items) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(GoalFormat.shortName(line.goal)).font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                let style = GoalStatusStyle.of(line.entry.outcome)
                                Label { Text(style.word) } icon: { Image(systemName: style.symbol) }
                                    .font(StrandFont.caption).foregroundStyle(style.foreground)
                            }
                            PaceTrack(fraction: line.entry.fraction, tint: GoalStatusStyle.of(line.entry.outcome).color,
                                      height: 6)
                            Text("\(GoalFormat.amount(line.entry.value, line.goal.metric)) of \(GoalFormat.amount(line.entry.target, line.goal.metric))")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    if let sentence = summarySentence(items) {
                        Text(sentence).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if anyDay == nil { nextPeriodSuggestions(items) }
                }
            }
        }
    }

    /// One rule-based sentence on what went well (the coach can say more in its own words).
    private func summarySentence(_ items: [Line]) -> String? {
        if let best = items.filter({ $0.entry.outcome == .achieved }).max(by: { $0.entry.fraction < $1.entry.fraction }) {
            return String(localized: "\(GoalFormat.shortName(best.goal)) went best: \(Int((best.entry.fraction * 100).rounded())) % of the target.")
        }
        if let closest = items.max(by: { $0.entry.fraction < $1.entry.fraction }), closest.entry.fraction > 0 {
            return String(localized: "Closest: \(GoalFormat.shortName(closest.goal)) at \(Int((closest.entry.fraction * 100).rounded())) %.")
        }
        return nil
    }

    @ViewBuilder
    private func nextPeriodSuggestions(_ items: [Line]) -> some View {
        let adjustable = items.compactMap { line -> (Line, Double)? in
            guard let snapshot = line.snapshot, let suggestion = GoalMaintenance.adjustment(for: snapshot) else { return nil }
            return (line, suggestion)
        }
        if !adjustable.isEmpty {
            Divider().overlay(StrandPalette.hairline)
            Text(period == .week ? "Next week" : "Next month").font(StrandFont.subhead)
            ForEach(adjustable, id: \.0.id) { line, value in
                HStack {
                    Text("\(GoalFormat.shortName(line.goal)): \(GoalFormat.amount(value, line.goal.metric))?")
                        .font(StrandFont.footnote)
                    Spacer()
                    Button("Take it") {
                        store.setTarget(line.id, value, today: Repository.localDayKey(Date()))
                        StrandHaptic.commit.play()
                        Task { await tracking.refresh(repo: repo) }
                    }
                    .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct GoalsReviewScreen: View {
    var body: some View {
        ScreenScaffold(title: "Looking back", subtitle: "How your last week and month went.") {
            GoalsReviewBlock(period: .week)
            GoalsReviewBlock(period: .month)
            Text("Earlier weeks are in Trends, in the week in review.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

// MARK: - Settings

struct GoalsSettingsView: View {
    @AppStorage(GoalPrefs.longTermLimitKey) private var longTermLimit = GoalPrefs.defaultLongTermLimit
    @AppStorage(GoalPrefs.periodLimitKey) private var periodLimit = GoalPrefs.defaultPeriodLimit
    @AppStorage(GoalsTodaySection.inviteDismissedKey) private var inviteDismissed = false
    @AppStorage(GoalsWeekAccessory.enabledKey) private var weekBar = false
    @State private var restDays: Set<Int> = Set(TrainingPreferences.restWeekdays)
    @State private var notify: [GoalPrefs.NotificationKind: Bool] = [:]
    @EnvironmentObject private var repo: Repository

    var body: some View {
        ScreenScaffold(title: "Goal settings") {
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How many goals").strandOverline()
                    Stepper(value: $longTermLimit, in: GoalPrefs.longTermLimitRange) {
                        Text("Long-term goals: up to \(longTermLimit)").font(StrandFont.footnote)
                    }
                    Stepper(value: $periodLimit, in: GoalPrefs.periodLimitRange) {
                        Text("Weekly and monthly goals: up to \(periodLimit)").font(StrandFont.footnote)
                    }
                    Text("Today always shows the three most important. Fewer goals are easier to keep.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("My rest days").strandOverline()
                    RestDaysPicker(selection: $restDays)
                        .onChange(of: restDays) { value in
                            TrainingPreferences.setRestWeekdays(Array(value))
                            Task { await GoalTrackingStore.shared.refresh(repo: repo) }
                        }
                    Text("Training goals spread their pace over the other days. The week starts on the day set in the training settings.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Notifications").strandOverline()
                    ForEach(GoalPrefs.NotificationKind.allCases) { kind in
                        Toggle(kind.label.localizedCatalogValue, isOn: Binding(
                            get: { notify[kind] ?? GoalPrefs.notifies(kind) },
                            set: { notify[kind] = $0; GoalPrefs.setNotifies(kind, $0)
                                if $0 { GoalNotifier.requestAuthorization() } }))
                            .font(StrandFont.footnote)
                    }
                    Text("Off by default. Hints and reviews always appear in the app. Quiet hours from the notification settings apply.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Goal invitation on Today", isOn: Binding(get: { !inviteDismissed }, set: { inviteDismissed = !$0 }))
                        .font(StrandFont.footnote)
                    #if os(iOS)
                    if #available(iOS 26.1, *) {
                        Toggle("Week bar above the tab bar", isOn: $weekBar).font(StrandFont.footnote)
                    }
                    #endif
                    Button("Show the explainer again") {
                        UserDefaults.standard.set(false, forKey: GoalPrefs.introSeenKey)
                    }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }
}
