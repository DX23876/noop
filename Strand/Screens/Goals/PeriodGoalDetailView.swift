import SwiftUI
import StrandDesign
import StrandAnalytics

/// One weekly or monthly goal in full (design §7): where it stands, how to get there, how it went,
/// what counted, what it serves, and its settings.
struct PeriodGoalDetailView: View {
    let goalId: UUID

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @ObservedObject private var longTerm = CoachGoalStore.shared
    @ObservedObject private var corrections = GoalCountingCorrections.shared
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var appleColors = AppleInspiredColorsPrefs.defaultEnabled
    @Environment(\.dismiss) private var dismiss

    @State private var selectedHistory: String?
    @State private var showNotCounted = false
    @State private var showAdvanced = false
    @State private var showDeleteConfirm = false
    @State private var showPauseConfirm = false
    @State private var journeyId: UUID?
    @State private var draftTarget: Double?

    private var snapshot: PeriodGoalSnapshot? { tracking.periodSnapshot(for: goalId) }
    private var goal: PeriodGoal? { store.goal(id: goalId) }

    var body: some View {
        ScreenScaffold(title: nil) {
            if let snapshot, let goal {
                header(snapshot)
                hero(snapshot)
                facts(snapshot)
                if let ramp = snapshot.rampSuggestion { rampCard(snapshot, suggested: ramp) }
                planCard(snapshot)
                historyCard(snapshot)
                countedCard(snapshot)
                chainCard(goal)
                settingsCard(goal)
            } else if let goal {
                // Ended or not computed yet: the settings are still reachable.
                Text(GoalFormat.title(goal)).font(StrandFont.title2)
                settingsCard(goal)
            } else {
                Text("This goal no longer exists.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        // The header carries the goal's name; the bar names the kind of goal instead of repeating it.
        .navigationTitle(goal.map { $0.period == .week ? String(localized: "Weekly goal") : String(localized: "Monthly goal") }
                         ?? String(localized: "Goal"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await tracking.refresh(repo: repo) }
        .sheet(isPresented: Binding(get: { journeyId != nil }, set: { if !$0 { journeyId = nil } })) {
            if let journeyId { JourneyView(goalId: journeyId) }
        }
        .confirmationDialog("Delete this goal?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete goal", role: .destructive) {
                store.remove(goalId)
                refresh()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the goal and its history from the device. Ending it keeps the history.")
        }
        .confirmationDialog("Pause this goal?", isPresented: $showPauseConfirm, titleVisibility: .visible) {
            ForEach(CoachGoal.PauseReason.allCases) { reason in
                Button(reason.label.localizedCatalogValue) {
                    store.pause(goalId, reason: reason)
                    refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paused weeks are protected: they don't count as missed and your series stays.")
        }
    }

    private func refresh() { Task { await tracking.refresh(repo: repo) } }

    // MARK: - Header and hero

    private func header(_ s: PeriodGoalSnapshot) -> some View {
        let identity = goalIdentityColor(s.goal.metric, appleColors: appleColors)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: s.goal.metric.icon)
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(identity)
                .frame(width: 44, height: 44)
                .background(Circle().fill(identity.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                // The state sits above the title in the flow, never on top of it: a long goal name
                // ("6 nights of 7.5 h a week") used to run underneath an overlaid pill.
                StatePill(s.style.word, tone: s.style.tone)
                Text(GoalFormat.title(s.goal))
                    .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(GoalFormat.range(s.periodDays)) · \(GoalFormat.remainingLine(s))")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func hero(_ s: PeriodGoalSnapshot) -> some View {
        let r = s.result
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                switch s.goal.metric.aggregation {
                case .count, .hitDays:
                    if s.goal.period == .week {
                        DayDotStrip(days: s.dayDots(diameter: 28, withSymbols: true), tint: s.trackTint,
                                    diameter: 28, suggested: Set(s.suggestedDays))
                    } else {
                        GoalMonthCalendar(snapshot: s)
                    }
                    PaceTrack(fraction: r.fraction, paceFraction: s.state == .achieved ? nil : r.paceFraction,
                              tint: s.trackTint, height: 12, segments: s.trackSegments,
                              projectedFraction: r.projected.map { $0 / max(r.target, 0.0001) },
                              animationKey: "detail-\(s.id)-\(s.periodStart)")
                case .sum:
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(GoalFormat.number(r.current, s.goal.metric))
                            .font(StrandFont.heroNumber).foregroundStyle(StrandPalette.textPrimary).monospacedDigit()
                        Text(String(localized: "of \(GoalFormat.amount(r.target, s.goal.metric))"))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    PaceTrack(fraction: r.fraction, paceFraction: s.state == .achieved ? nil : r.paceFraction,
                              tint: s.trackTint, height: 12,
                              projectedFraction: r.projected.map { $0 / max(r.target, 0.0001) },
                              animationKey: "detail-\(s.id)-\(s.periodStart)")
                    if s.goal.period == .month { GoalMonthCalendar(snapshot: s) }
                case .average:
                    TargetColumns(values: s.dayValues.enumerated().map { $0.offset <= s.todayIndex ? $0.element : nil },
                                  target: r.target, tint: s.trackTint, height: 90)
                }
                // A projection only says something while days are left to change it; on the last day,
                // or once the period is out of reach, it would just repeat the count.
                if let projected = r.projected, s.daysLeft > 1,
                   ![.achieved, .outOfReach, .protected, .noData].contains(s.state),
                   s.goal.metric.aggregation != .average {
                    Text(s.goal.period == .week
                         ? String(localized: "At your pace: about \(GoalFormat.amount(projected, s.goal.metric)) by the end of the week")
                         : String(localized: "At your pace: about \(GoalFormat.amount(projected, s.goal.metric)) by the end of the month"))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func facts(_ s: PeriodGoalSnapshot) -> some View {
        let r = s.result
        let metric = s.goal.metric
        // One card with three columns, the same surface as every other card on the page (separate
        // opaque tiles floated on it as white blocks).
        return NoopCard(padding: 14) {
            HStack(spacing: 12) {
                fact(label: "So far", value: GoalFormat.amount(r.current, metric))
                factDivider
                if let pace = r.paceFraction, pace < 0.999 {
                    fact(label: "Target by today", value: GoalFormat.amount(pace * r.target, metric))
                } else {
                    fact(label: "Target", value: GoalFormat.amount(r.target, metric))
                }
                if let best = s.history.map(\.value).max(), metric.aggregation != .average {
                    factDivider
                    fact(label: "Best", value: GoalFormat.amount(max(best, r.current), metric))
                } else if let needed = r.requiredPerDay {
                    factDivider
                    fact(label: "Needed", value: GoalFormat.amount(needed, metric))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var factDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(width: 1).accessibilityHidden(true)
    }

    private func fact(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Plan and step-up

    @ViewBuilder
    private func planCard(_ s: PeriodGoalSnapshot) -> some View {
        if !s.suggestedDays.isEmpty || !s.restDays.isEmpty, s.state != .achieved {
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Plan to the end of the \(GoalFormat.periodWord(s.goal.period))").strandOverline()
                    if !s.suggestedDays.isEmpty {
                        Text("Suggested: \(dayNames(s.suggestedDays))")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                    }
                    let restLeft = s.restDays.filter { $0 >= (s.periodDays[safe: max(0, s.todayIndex)] ?? "") }.sorted()
                    if !restLeft.isEmpty {
                        Text("Rest days: \(dayNames(restLeft))")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                    if [.close, .behind].contains(s.state), let needed = s.result.requiredPerDay {
                        Text("That is \(GoalFormat.amount(needed, s.goal.metric)) per planned day.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }

    private func dayNames(_ days: [String]) -> String {
        let names = days.compactMap { day -> String? in
            guard let date = PeriodGoalTracker.date(day, calendar: .autoupdatingCurrent) else { return nil }
            return date.formatted(.dateTime.weekday(.wide))
        }
        return names.formatted(.list(type: .and))
    }

    private func rampCard(_ s: PeriodGoalSnapshot, suggested: Double) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Next step").strandOverline()
                Text("Your long-term plan suggests \(GoalFormat.amount(suggested, s.goal.metric)) this week instead of \(GoalFormat.amount(s.goal.target, s.goal.metric)).")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button(String(localized: "Take \(GoalFormat.number(suggested, s.goal.metric))")) {
                        store.setTarget(s.id, suggested, today: s.periodStart)
                        store.markRampAnswered(s.id, periodStart: s.periodStart)
                        StrandHaptic.commit.play()
                        refresh()
                    }
                    Button(String(localized: "Stay at \(GoalFormat.number(s.goal.target, s.goal.metric))")) {
                        store.markRampAnswered(s.id, periodStart: s.periodStart)
                        refresh()
                    }
                }
                .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private func historyCard(_ s: PeriodGoalSnapshot) -> some View {
        if !s.history.isEmpty {
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.goal.period == .week ? "Last weeks" : "Last months").strandOverline()
                    // Reached periods in the goal's colour, "almost" lighter, missed ones as a quiet grey:
                    // the eye counts the coloured columns. The dashed line is the target.
                    PeriodHistoryBars(bars: s.history.map {
                        .init(id: $0.periodStart, fraction: $0.fraction, tint: historyTint($0.outcome, s))
                    } + [.init(id: s.periodStart, fraction: s.result.fraction, tint: s.identityColor, isCurrent: true)],
                                      showsTarget: true, selection: $selectedHistory)
                    if let id = selectedHistory, let entry = s.history.first(where: { $0.periodStart == id }) {
                        let days = PeriodGoalTracker.periodDays(s.goal.period, containing: entry.periodStart,
                                                                calendar: TrainingPreferences.weekCalendar)
                        Text("\(GoalFormat.range(days)): \(GoalFormat.amount(entry.value, s.goal.metric)) of \(GoalFormat.amount(entry.target, s.goal.metric)) · \(GoalStatusStyle.of(entry.outcome).wordText)")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                    } else {
                        let reached = s.history.filter { $0.outcome == .achieved }.count
                        Text(s.goal.period == .week
                             ? String(localized: "Reached in \(reached) of the last \(s.history.count) weeks. Tap a column for details.")
                             : String(localized: "Reached in \(reached) of the last \(s.history.count) months. Tap a column for details."))
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A series of zero is not news. Say the running series when there is one, otherwise
                    // the best one so far, otherwise nothing.
                    if s.currentStreak > 0 || s.bestStreak > 0 {
                        Text(streakLine(s))
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        Text("A period at 80 % or more keeps the series as “Almost”. Paused periods don't break it.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func historyTint(_ outcome: PeriodOutcome, _ s: PeriodGoalSnapshot) -> Color {
        switch outcome {
        case .achieved: return s.identityColor
        case .almost: return s.identityColor.opacity(0.5)
        // Grey, not the hairline tokens: in light mode those read as a white gap, not as a missed period.
        case .missed: return StrandPalette.textTertiary.opacity(0.45)
        case .protected, .noData: return StrandPalette.textTertiary.opacity(0.2)
        }
    }

    private func streakLine(_ s: PeriodGoalSnapshot) -> String {
        let week = s.goal.period == .week
        if s.currentStreak > 0 {
            let running = week ? String(localized: "\(s.currentStreak) weeks in a row")
                               : String(localized: "\(s.currentStreak) months in a row")
            return s.bestStreak > s.currentStreak ? String(localized: "\(running) · best \(s.bestStreak)") : running
        }
        return week ? String(localized: "Best series so far: \(s.bestStreak) weeks")
                    : String(localized: "Best series so far: \(s.bestStreak) months")
    }

    // MARK: - What counted (Q20)

    @ViewBuilder
    private func countedCard(_ s: PeriodGoalSnapshot) -> some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("What counted").strandOverline()
                if s.counted.isEmpty {
                    Text("Nothing yet this \(GoalFormat.periodWord(s.goal.period)).")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach(s.counted) { item in contributionRow(item, goal: s.goal, counted: true) }
                if s.goal.metric.isWorkoutBased {
                    Text("Missing a workout? Add it as a manual workout and it counts here.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !s.notCounted.isEmpty {
                    Divider().overlay(StrandPalette.hairline)
                    Button { withAnimation(StrandMotion.fade) { showNotCounted.toggle() } } label: {
                        HStack {
                            Text("Not counted (\(s.notCounted.count))")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            Image(systemName: showNotCounted ? "chevron.up" : "chevron.down")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    if showNotCounted {
                        ForEach(s.notCounted) { item in contributionRow(item, goal: s.goal, counted: false) }
                    }
                }
            }
        }
    }

    private func contributionRow(_ item: PeriodGoalSnapshot.Contribution, goal: PeriodGoal, counted: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle(item, goal: goal))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                if let reason = item.reason {
                    Text(reason).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 6)
            if let source = item.source {
                Text(Self.sourceLabel(source))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(StrandPalette.surfaceInset))
            }
            if item.isManual {
                Image(systemName: "hand.raised.fill").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityLabel(Text("Corrected by you"))
            }
            if goal.metric.isWorkoutBased {
                Menu {
                    if counted {
                        Button("Doesn't count", systemImage: "minus.circle") {
                            corrections.set(goalId: goal.id, workoutKey: item.id, counts: false); refresh()
                        }
                    } else {
                        Button("Counts", systemImage: "plus.circle") {
                            corrections.set(goalId: goal.id, workoutKey: item.id, counts: true); refresh()
                        }
                    }
                    if item.isManual {
                        Button("Let NOOP decide", systemImage: "arrow.uturn.backward") {
                            corrections.set(goalId: goal.id, workoutKey: item.id, counts: nil); refresh()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(StrandPalette.textSecondary)
                }
                .accessibilityLabel(Text("Change whether this counts"))
            }
        }
    }

    /// Where a workout came from, as a short chip.
    static func sourceLabel(_ source: String) -> String {
        switch WorkoutSource.classify(source) {
        case .whoop:        return String(localized: "Strap")
        case .apple:        return String(localized: "Health")
        case .detected:     return String(localized: "Detected")
        case .manual:       return String(localized: "Manual")
        case .lifting:      return String(localized: "Lifting log")
        case .activityFile: return String(localized: "File")
        case .hevy:         return "Hevy"
        case .oura:         return "Oura"
        }
    }

    private func rowTitle(_ item: PeriodGoalSnapshot.Contribution, goal: PeriodGoal) -> String {
        let date = PeriodGoalTracker.date(item.day, calendar: .autoupdatingCurrent)?
            .formatted(.dateTime.weekday(.abbreviated).day()) ?? item.day
        switch goal.metric {
        case .workouts:
            return "\(date) · \(item.title)"
        case .trainingMinutes, .distance, .zoneMinutes:
            return "\(date) · \(item.title) · \(GoalFormat.amount(item.value, goal.metric))"
        case .stepDays:
            return "\(date) · \(Int(item.value).formatted()) \(String(localized: "steps"))"
        case .sleepNights, .sleepAverage:
            return "\(date) · \(item.value.formatted(.number.precision(.fractionLength(1)))) h"
        case .workingSets:
            return "\(date) · \(Int(item.value)) \(String(localized: "sets"))"
        case .activeEnergy:
            return "\(date) · \(Int(item.value).formatted()) kcal"
        case .hydrationDays:
            return "\(date) · \((item.value / 1000).formatted(.number.precision(.fractionLength(1)))) l"
        case .restDays, .habitDays:
            return date
        }
    }

    // MARK: - Chain

    @ViewBuilder
    private func chainCard(_ goal: PeriodGoal) -> some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Belongs to").strandOverline()
                if let parentId = goal.parentGoalId, let parent = longTerm.goal(id: parentId) {
                    Button { journeyId = parentId } label: {
                        HStack {
                            Image(systemName: parent.kind.icon).foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            Text(parent.title.isEmpty ? parent.kind.label.localizedCatalogValue : parent.title)
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Menu {
                    Button("No long-term goal") { link(nil) }
                    ForEach(longTerm.activeGoals) { parent in
                        Button(parent.title.isEmpty ? parent.kind.label.localizedCatalogValue : parent.title) { link(parent.id) }
                    }
                } label: {
                    Text(goal.parentGoalId == nil ? "Link to a long-term goal" : "Change link")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    private func link(_ parentId: UUID?) {
        guard let index = store.goals.firstIndex(where: { $0.id == goalId }) else { return }
        store.goals[index].parentGoalId = parentId
        refresh()
    }

    // MARK: - Settings (Q14: change the target right here)

    private func settingsCard(_ goal: PeriodGoal) -> some View {
        let range = goal.metric.range(for: goal.period)
        let step = goal.metric.step(for: goal.period)
        let target = Binding<Double>(
            get: { draftTarget ?? goal.target },
            set: { draftTarget = $0 })
        return NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings").strandOverline()
                Stepper(value: target, in: range, step: step) {
                    HStack {
                        Text("Target value")
                        Spacer()
                        Text(GoalFormat.amount(target.wrappedValue, goal.metric)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .font(StrandFont.footnote)
                }
                if let draft = draftTarget, draft != goal.target {
                    Button("Save new target") {
                        store.setTarget(goal.id, draft, today: Repository.localDayKey(Date()))
                        draftTarget = nil
                        StrandHaptic.commit.play()
                        refresh()
                    }
                    .font(StrandFont.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    Text("Applies from this \(GoalFormat.periodWord(goal.period)) on; earlier ones keep their target.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                if goal.metric.usesRestDays {
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        RestDaysPicker(selection: Binding(
                            get: { Set(goal.restWeekdaysOverride ?? TrainingPreferences.restWeekdays) },
                            set: { newValue in
                                guard let index = store.goals.firstIndex(where: { $0.id == goal.id }) else { return }
                                store.goals[index].restWeekdaysOverride = newValue.sorted()
                                refresh()
                            }))
                        if goal.restWeekdaysOverride != nil {
                            Button("Use my usual rest days") {
                                guard let index = store.goals.firstIndex(where: { $0.id == goal.id }) else { return }
                                store.goals[index].restWeekdaysOverride = nil
                                refresh()
                            }
                            .font(StrandFont.footnote)
                        }
                    } label: {
                        Text("Advanced: rest days for this goal").font(StrandFont.footnote)
                    }
                }
                Divider().overlay(StrandPalette.hairline)
                // Real buttons, not blue words: these change the goal.
                HStack(spacing: 8) {
                    if goal.status == .paused {
                        Button { store.resume(goal.id); refresh() } label: { Label("Resume", systemImage: "play.fill") }
                    } else if goal.status == .active {
                        Button { showPauseConfirm = true } label: { Label("Pause", systemImage: "pause.fill") }
                    }
                    if goal.isOpen {
                        Button { store.end(goal.id); refresh() } label: { Label("End goal", systemImage: "flag.checkered") }
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(Text("Delete"))
                    .tint(StrandPalette.statusCritical)
                }
                .font(StrandFont.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                #if os(iOS)
                .buttonBorderShape(.capsule)
                #endif
                .controlSize(.small)
                .tint(StrandPalette.accent)
            }
        }
    }
}

/// The days of a month as a calendar, one cell per day, filled by how much the day contributed.
struct GoalMonthCalendar: View {
    let snapshot: PeriodGoalSnapshot

    var body: some View {
        let first = snapshot.periodDays.first.flatMap(PeriodCalendar.weekday) ?? 2
        let firstWeekday = TrainingPreferences.firstWeekday
        let leading = (first - firstWeekday + 7) % 7
        let maxValue = max(1, snapshot.dayValues.compactMap { $0 }.max() ?? 1)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 22) }
            // Keyed by the day, not its position: the blank lead-in cells above are keyed 0, 1, 2…, and
            // two ForEach blocks sharing ids in one grid made SwiftUI drop the first days of the month.
            ForEach(Array(snapshot.periodDays.enumerated()), id: \.element) { index, day in
                let value = snapshot.dayValues[index] ?? 0
                let future = index > snapshot.todayIndex
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(future ? Color.clear : (value > 0 ? snapshot.trackTint.opacity(0.3 + 0.7 * min(1, value / maxValue))
                                                            : StrandPalette.hairline))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(index == snapshot.todayIndex ? StrandPalette.textPrimary
                                      : (future ? StrandPalette.hairline : Color.clear),
                                      lineWidth: index == snapshot.todayIndex ? 1.5 : 1))
                    .frame(height: 22)
                    .overlay(Text(String(Int(day.suffix(2)) ?? 0)).font(.system(size: 9))
                        .foregroundStyle(StrandPalette.textSecondary))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Seven weekday chips in the training week's order.
struct RestDaysPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let order = (0..<7).map { ((TrainingPreferences.firstWeekday - 1 + $0) % 7) + 1 }
        let symbols = Calendar.autoupdatingCurrent.shortStandaloneWeekdaySymbols
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { weekday in
                let on = selection.contains(weekday)
                Button {
                    if on { selection.remove(weekday) } else { selection.insert(weekday) }
                    StrandHaptic.selection.play()
                } label: {
                    Text(String(symbols[weekday - 1].prefix(2)))
                        .font(StrandFont.footnote)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(on ? StrandPalette.surfaceRaised : StrandPalette.textPrimary)
                        .background(Capsule().fill(on ? StrandPalette.accent : StrandPalette.surfaceInset))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(symbols[weekday - 1]))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
