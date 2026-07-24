import SwiftUI
import StrandDesign
import StrandAnalytics

/// The goal, made visible: where you stand, what's next, how the last stretch actually went.
///
/// The rule this whole page exists to honour: **no invented percentages.** A fraction only ever appears
/// here when it's built from a REAL measurement (a logged run, a synced weigh-in, sessions the user
/// actually did) compared against the goal's own baseline/target. Whenever that measurement isn't
/// available, the page falls back to what IS real — sessions completed and recovery context — rather
/// than showing a confident-looking bar built on nothing.
struct JourneyView: View {
    @EnvironmentObject private var coach: AICoachEngine
    @ObservedObject private var goalStore = CoachGoalStore.shared
    @ObservedObject private var planStore = CoachPlanStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Which goal this journey is for (#R-multi-goal — there can be several active at once now, so the
    /// page can no longer read a single implicit "the goal").
    let goalId: UUID

    @State private var evidence = GoalFeasibility.Evidence()
    @State private var latestWeightKg: Double?
    @State private var loaded = false
    @State private var showEditor = false
    @State private var showSetAsideDialog = false
    /// Which cards have their "How is this worked out?" note open. A Set rather than a Bool per card, so
    /// opening one explanation doesn't open all of them.
    @State private var openExplanations: Set<String> = []
    /// The manual "I did something for this goal" logger (see `logSessionCard`).
    @State private var showLogSession = false
    @State private var logSessionText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                if let goal = goalStore.goal(id: goalId) {
                    VStack(spacing: 16) {
                        closureOrExpiryCard(goal)
                        headerCard(goal)
                        progressCard(goal)
                        trendCard(goal)
                        milestonesCard(goal)
                        readinessCard
                        planHistoryCard
                        if !goal.history.isEmpty { historyCard(goal) }
                    }
                    .padding(16)
                } else {
                    noGoalState.padding(16)
                }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Your journey")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                evidence = await coach.goalEvidence()
                latestWeightKg = await coach.latestLoggedWeightKg()
            }
            .sheet(isPresented: $showEditor) { CoachGoalEditorView(isOnboarding: false, editingGoalId: goalId) }
            .confirmationDialog("Set this goal aside?", isPresented: $showSetAsideDialog, titleVisibility: .visible) {
                Button("Injury or health") { goalStore.setAside(goalId, reason: "injury or health") }
                Button("Life got busy") { goalStore.setAside(goalId, reason: "life got busy") }
                Button("Priorities changed") { goalStore.setAside(goalId, reason: "priorities changed") }
                Button("No particular reason") { goalStore.setAside(goalId, reason: "") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It stays in your history — nothing is lost, and there's nothing to justify.")
            }
        }
    }

    // MARK: - Closure & expiry: a goal must be able to END, and the page must say how it ended

    /// Matter-of-fact closure (milestone aesthetics, no gamification — setbacks are never shamed), or
    /// the passed-date fork for an active goal: reached / more time / set aside.
    @ViewBuilder
    private func closureOrExpiryCard(_ goal: CoachGoal) -> some View {
        switch goal.status {
        case .achieved:
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("You made it")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("This goal is closed as achieved. Everything below is its story — set a new one whenever you're ready.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .abandoned:
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.zzz")
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityHidden(true)
                        Text("This goal was set aside")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("Its story below stays yours. A new goal is one tap away in Coach settings.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .active where (ProactiveCoach.daysPastTarget(goal) ?? 0) >= 1:
            NoopCard(padding: 14, tint: StrandPalette.statusWarning) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityHidden(true)
                        Text("Your target date has passed")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("How did it go? Close it out, give it more time, or set it aside — your call.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button("I reached it") { goalStore.markAchieved(goalId) }
                            .foregroundStyle(StrandPalette.accent)
                        Button("Extend the date") { showEditor = true }
                            .foregroundStyle(StrandPalette.accent)
                        Button("Set aside") { showSetAsideDialog = true }
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .font(StrandFont.footnote)
                    .buttonStyle(.plain)
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Header: goal, time, phase

    private func headerCard(_ goal: CoachGoal) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "target").foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    // `goal.kind.label` is a fixed-set English label (#P14); `goal.title` is the user's
                    // own free text, harmlessly passed through unresolved.
                    Text(goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title)
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                if let timeLine = timeSummary(goal) {
                    Text(timeLine)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                if let ack = goal.acknowledgedRisk {
                    Text("Pace acknowledged: \"\(ack.reason)\"")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "N weeks to go · build phase" — built outside the view builder so it stays a single Text.
    /// A closed goal has no countdown; its closure card already says how it ended.
    private func timeSummary(_ goal: CoachGoal) -> String? {
        guard goal.status == .active else { return nil }
        var parts: [String] = []
        if let weeks = goal.weeksRemaining() {
            parts.append(weeks < 0 ? "target date has passed"
                                   : String(format: "%.0f weeks to go", weeks.rounded()))
        }
        if let phase = goal.phase() { parts.append("\(phase) phase") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Progress: real measurement or an honest fallback, never an invented percentage

    private func progressCard(_ goal: CoachGoal) -> some View {
        let measured = measuredProgress(goal)
        return NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Progress").strandOverline()
                if let measured {
                    if let fraction = measured.fraction {
                        ProgressView(value: fraction)
                            .tint(StrandPalette.accent)
                            .accessibilityLabel("Progress toward your goal")
                            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                    }
                    Text(measured.line)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The count is shown either way: for an unmeasurable goal it IS the progress, and for a
                // measured one it's the work behind the bar.
                Text(JourneyExplain.countLine(for: goal.kind, count: completedSessionCount(for: goal)))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                explanation(id: "progress", text: progressExplanationText(goal))
                if JourneyExplain.sessionRule(for: goal.kind).allowsManualLog, goal.status == .active {
                    logSessionRow(goal)
                }
            }
        }
    }

    /// The Progress card's full explanation: where the bar comes from AND what the count counts. Both
    /// come from `JourneyExplain`, so the card and its explanation can't drift apart.
    private func progressExplanationText(_ goal: CoachGoal) -> String {
        JourneyExplain.progressExplanation(for: goal.kind)
            + "\n\n"
            + JourneyExplain.sessionRule(for: goal.kind).definition
    }

    /// A real, measured fraction — only when there's an actual current value AND both ends of the range
    /// to place it in. Anything less falls through to `fallbackProgressLine`.
    private func measuredProgress(_ goal: CoachGoal) -> (fraction: Double?, line: String)? {
        func ranged(_ current: Double, unit: String) -> (fraction: Double?, line: String) {
            guard let baseline = goal.baseline, let target = goal.target, target != baseline else {
                return (nil, String(format: "Currently %.1f %@. Set a starting point and target to see a "
                                    + "progress bar.", current, unit))
            }
            let frac = min(1, max(0, (current - baseline) / (target - baseline)))
            let line = String(format: "%.1f %@ now, from %.1f toward %.1f %@.",
                              current, unit, baseline, target, unit)
            return (frac, line)
        }
        switch goal.kind {
        case .run:
            guard let km = evidence.longestRecentRunKm else { return nil }
            return ranged(km, unit: "km")
        case .sleep:
            guard let hrs = evidence.meanSleepHours else { return nil }
            return ranged(hrs, unit: "h")
        case .weight:
            guard let kg = latestWeightKg else { return nil }
            return ranged(kg, unit: "kg")
        case .consistency:
            guard let sessions = evidence.sessionsPerWeek, let target = goal.target, target > 0 else {
                return nil
            }
            let frac = min(1, max(0, sessions / target))
            return (frac, String(format: "Averaging %.1f sessions/week toward a target of %.0f.",
                                 sessions, target))
        case .strength, .stress, .recovery, .custom:
            return nil
        }
    }

    // MARK: - Explanations & manual logging

    /// A collapsed "How is this worked out?" note under a card.
    ///
    /// Every derived number on this page now carries one. The page's own rule is that it never invents a
    /// number; the corollary — learned from "No sessions completed" appearing under a stress goal with no
    /// definition of a session anywhere — is that a number nobody can derive is barely better than one
    /// that was invented.
    @ViewBuilder
    private func explanation(id: String, text: String) -> some View {
        let open = openExplanations.contains(id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(StrandMotion.fade) {
                    if open { openExplanations.remove(id) } else { openExplanations.insert(id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    Text("How is this worked out?")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide how this is worked out" : "Show how this is worked out")
            if open {
                Text(text)
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "I did something for this goal" — the counterpart to the session rule for the kinds NOOP cannot
    /// measure. Without it a custom or stress goal's counter can only ever sit at zero, which is exactly
    /// the dead end the rule is meant to resolve. Logs an already-accepted, already-completed session
    /// LINKED to this goal, so it lands in the same plan book as everything else rather than a side store.
    @ViewBuilder
    private func logSessionRow(_ goal: CoachGoal) -> some View {
        if showLogSession {
            VStack(alignment: .leading, spacing: 8) {
                TextField(logPlaceholder(goal.kind), text: $logSessionText)
                    .textFieldStyle(.plain)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .accessibilityLabel("What you did for this goal")
                HStack(spacing: 14) {
                    Button("Cancel") {
                        showLogSession = false
                        logSessionText = ""
                    }
                    .foregroundStyle(StrandPalette.textSecondary)
                    Button("Log it") { logSession(for: goal) }
                        .foregroundStyle(StrandPalette.accent)
                        .disabled(logSessionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer(minLength: 0)
                }
                .font(StrandFont.footnote)
                .buttonStyle(.plain)
            }
        } else {
            Button { showLogSession = true } label: {
                Label("Log something for this goal", systemImage: "plus.circle")
                    .font(StrandFont.footnote).labelStyle(.titleAndIcon)
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Log something you did for this goal")
        }
    }

    private func logPlaceholder(_ kind: CoachGoal.Kind) -> String {
        switch kind {
        case .stress:   return String(localized: "e.g. 10 min breathing")
        case .recovery: return String(localized: "e.g. full rest day")
        case .strength: return String(localized: "e.g. full-body session")
        default:        return String(localized: "what you did")
        }
    }

    private func logSession(for goal: CoachGoal) {
        let what = logSessionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !what.isEmpty else { return }
        planStore.addUserSession(day: Repository.localDayKey(Date()), time: nil,
                                 sport: what, intent: .easy, goalId: goal.id)
        // It already happened — a thing you're reporting afterwards is completed, not scheduled.
        if let logged = planStore.proposals.first(where: { $0.goalId == goal.id && $0.sport == what }) {
            planStore.complete(logged.id)
        }
        showLogSession = false
        logSessionText = ""
    }

    // MARK: - Trend towards the goal

    private func trendCard(_ goal: CoachGoal) -> some View {
        let trend = JourneyExplain.trend(goal: goal, current: currentMeasurement(goal))
        return NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Trend towards the goal").strandOverline()
                    Spacer()
                    // Word, not colour: the verdict has to be readable without seeing the pill's tint.
                    Text(JourneyExplain.label(for: trend.verdict))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(StrandPalette.surfaceInset))
                }
                Text(trend.line)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                explanation(id: "trend", text: JourneyExplain.trendExplanation)
            }
        }
    }

    /// The one real measurement this goal's progress is read from, or nil when there isn't one. The same
    /// values `measuredProgress` places on the bar, so the bar and the trend can never disagree.
    private func currentMeasurement(_ goal: CoachGoal) -> Double? {
        switch goal.kind {
        case .run:         return evidence.longestRecentRunKm
        case .sleep:       return evidence.meanSleepHours
        case .weight:      return latestWeightKg
        case .consistency: return evidence.sessionsPerWeek
        case .strength, .stress, .recovery, .custom: return nil
        }
    }

    // MARK: - Milestones

    private func milestonesCard(_ goal: CoachGoal) -> some View {
        let inputs = milestoneInputs(goal)
        let achieved = JourneyMilestones.achieved(inputs)
        return NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Milestones").strandOverline()
                if achieved.isEmpty {
                    Text("Nothing yet — that's normal for a goal this new.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                } else {
                    ForEach(achieved) { m in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(StrandPalette.chargeColor)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.title).font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                                Text(m.detail).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Divider().overlay(StrandPalette.hairline)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.forward.circle").foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(JourneyMilestones.nextSuggestion(inputs))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                explanation(id: "milestones", text: milestoneExplanation(goal))
            }
        }
    }

    /// What a milestone is here — facts about what happened, not a streak or a score — and which inputs
    /// each one reads. Mirrors `JourneyMilestones.achieved`.
    private func milestoneExplanation(_ goal: CoachGoal) -> String {
        let rule = JourneyExplain.sessionRule(for: goal.kind)
        return String(localized: "Milestones are statements about what has already happened, never streaks or scores: a first week with at least one \(rule.noun) done, the \(rule.pluralNoun) you've completed, your longest recorded run, a week without a pain or illness skip, and a week whose average Charge ran higher than the one before it.")
    }

    private func milestoneInputs(_ goal: CoachGoal) -> JourneyMilestones.Inputs {
        let days = Calendar.current.dateComponents([.day], from: goal.createdAt, to: Date()).day ?? 0
        return JourneyMilestones.Inputs(
            daysSinceGoalCreated: max(0, days),
            completedSessionCount: completedSessionCount(for: goal),
            longestRunKm: evidence.longestRecentRunKm,
            recentAvgCharge: coach.meanTrustedCharge(lastDays: 7),
            priorAvgCharge: coach.meanTrustedCharge(lastDays: 7, endingDaysAgo: 7),
            hasRecentCautionSkip: planStore.recentCautionSkip() != nil)
    }

    /// Sessions completed FOR THIS GOAL: anything linked to it, plus unlinked sessions since it was set.
    /// The linkage is what stops one goal's work from being counted as another's now that several can be
    /// active at once — see `CoachPlanStore.completedSessions(forGoal:since:)`.
    private func completedSessionCount(for goal: CoachGoal) -> Int {
        planStore.completedSessions(forGoal: goal.id,
                                    since: Repository.localDayKey(goal.createdAt)).count
    }

    // MARK: - Readiness context (same engine the coach itself reads — never a second opinion)

    private var readinessCard: some View {
        let readiness = coach.currentReadiness()
        return NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Readiness").strandOverline()
                    Spacer()
                    Text(readinessLabel(readiness.level))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(StrandPalette.surfaceInset))
                }
                Text(readiness.summary)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // This card looks goal-specific because of where it sits. It isn't, and saying so is the
                // whole point of the note.
                explanation(id: "readiness", text: JourneyExplain.readinessExplanation)
            }
        }
    }

    /// Mirrors `LiquidTodayView.readinessWord` so this page can never disagree with what Today shows.
    private func readinessLabel(_ level: ReadinessEngine.Level) -> String {
        switch level {
        case .primed:                  return "Push"
        case .balanced:                 return "Maintain"
        case .strained, .rundown:      return "Rest"
        case .insufficient:            return "Calibrating"
        }
    }

    // MARK: - Planned vs actual

    private var planHistoryCard: some View {
        let today = Repository.localDayKey(Date())
        let recent = planStore.proposals
            .filter { $0.day < today && $0.status.isDecided }
            .sorted { $0.day > $1.day }
            .prefix(10)
        let upcoming = planStore.commitments(fromDay: today)

        return NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Planned vs actual").strandOverline()
                if upcoming.isEmpty && recent.isEmpty {
                    Text("Nothing planned yet.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                } else {
                    ForEach(upcoming.prefix(5)) { p in planRow(p) }
                    if !upcoming.isEmpty && !recent.isEmpty {
                        Divider().overlay(StrandPalette.hairline)
                    }
                    ForEach(Array(recent)) { p in planRow(p) }
                }
            }
        }
    }

    /// Deliberately neutral wording — a skip states its reason, it doesn't editorialise. Never
    /// color-only: every status pairs an icon + word, same rule the app uses everywhere else.
    private func planRow(_ p: PlanProposal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: planIcon(p.status))
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.summary()).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                Text(planStatusLine(p)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 4)
            Text(p.day).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.summary()), \(planStatusLine(p)), \(p.day)")
    }

    private func planIcon(_ status: PlanProposal.Status) -> String {
        switch status {
        case .completed:      return "checkmark.circle.fill"
        case .skipped:        return "xmark.circle"
        case .declined:       return "hand.thumbsdown"
        case .paused:         return "pause.circle"
        case .modifiedByUser: return "arrow.triangle.2.circlepath"
        case .rescheduled:    return "calendar.badge.clock"
        case .accepted:       return "calendar"
        case .proposed:       return "sparkles"
        }
    }

    /// Same restructuring as `CoachPlanView.statusLine` (#P14): every branch resolves via
    /// `String(localized:)`, with `SkipReason.label` pre-resolved through `.localizedCatalogValue` so the
    /// embedded word follows the system language too, not just the sentence around it.
    private func planStatusLine(_ p: PlanProposal) -> String {
        switch p.status {
        case .skipped:
            if let reason = p.skipReason {
                return String(localized: "didn't happen — \(reason.label.localizedCatalogValue)")
            }
            return String(localized: "didn't happen")
        case .declined:    return String(localized: "passed on this one")
        case .rescheduled: return String(localized: "moved to another day")
        default:           return p.status.rawValue
        }
    }

    // MARK: - Adjustment history

    private func historyCard(_ goal: CoachGoal) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Changes to this goal").strandOverline()
                ForEach(Array(goal.history.reversed().prefix(10).enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.date.formatted(date: .abbreviated, time: .omitted))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(event.what)
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - No goal

    private var noGoalState: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No goal set")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text("Set one from Coach settings to see your journey here.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}
