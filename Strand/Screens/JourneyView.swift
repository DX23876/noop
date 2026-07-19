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

    @State private var evidence = GoalFeasibility.Evidence()
    @State private var latestWeightKg: Double?
    @State private var loaded = false
    @State private var showEditor = false
    @State private var showSetAsideDialog = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let goal = goalStore.goal {
                    VStack(spacing: 16) {
                        closureOrExpiryCard(goal)
                        headerCard(goal)
                        progressCard(goal)
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
            .sheet(isPresented: $showEditor) { CoachGoalEditorView(isOnboarding: false) }
            .confirmationDialog("Set this goal aside?", isPresented: $showSetAsideDialog, titleVisibility: .visible) {
                Button("Injury or health") { goalStore.setAside(reason: "injury or health") }
                Button("Life got busy") { goalStore.setAside(reason: "life got busy") }
                Button("Priorities changed") { goalStore.setAside(reason: "priorities changed") }
                Button("No particular reason") { goalStore.setAside(reason: "") }
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
        case .active where (goal.weeksRemaining() ?? 0) < 0:
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
                        Button("I reached it") { goalStore.markAchieved() }
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
                    Text(goal.title.isEmpty ? goal.kind.label : goal.title)
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

    @ViewBuilder
    private func progressCard(_ goal: CoachGoal) -> some View {
        if let measured = measuredProgress(goal) {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Progress").strandOverline()
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
            }
        } else {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Progress").strandOverline()
                    Text(fallbackProgressLine(goal))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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

    /// No fabricated percentage: consistency (sessions completed) plus recovery context, which are both
    /// real regardless of whether the goal has a measurable current value yet.
    private func fallbackProgressLine(_ goal: CoachGoal) -> String {
        let n = completedSessionCount(since: goal.createdAt)
        var line = n == 0
            ? "No sessions completed yet since you set this goal."
            : "\(n) session\(n == 1 ? "" : "s") completed since you set this goal."
        switch goal.kind {
        case .weight:
            line += " I track training, not diet, so this page won't guess at weight progress without "
                  + "a synced weigh-in."
        case .strength, .stress, .recovery, .custom:
            line += " This kind of goal isn't something I can measure from your strap — tell the coach "
                  + "how it's going and it'll factor that in."
        default:
            line += " Not enough measurements yet for a progress bar — that fills in as you log sessions."
        }
        return line
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
            }
        }
    }

    private func milestoneInputs(_ goal: CoachGoal) -> JourneyMilestones.Inputs {
        let days = Calendar.current.dateComponents([.day], from: goal.createdAt, to: Date()).day ?? 0
        return JourneyMilestones.Inputs(
            daysSinceGoalCreated: max(0, days),
            completedSessionCount: completedSessionCount(since: goal.createdAt),
            longestRunKm: evidence.longestRecentRunKm,
            recentAvgCharge: coach.meanTrustedCharge(lastDays: 7),
            priorAvgCharge: coach.meanTrustedCharge(lastDays: 7, endingDaysAgo: 7),
            hasRecentCautionSkip: planStore.recentCautionSkip() != nil)
    }

    private func completedSessionCount(since date: Date) -> Int {
        let cutoff = Repository.localDayKey(date)
        return planStore.proposals.filter { $0.status == .completed && $0.day >= cutoff }.count
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
            }
        }
        .accessibilityElement(children: .combine)
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

    private func planStatusLine(_ p: PlanProposal) -> String {
        switch p.status {
        case .skipped:     return p.skipReason.map { "didn't happen — \($0.label.lowercased())" } ?? "didn't happen"
        case .declined:    return "passed on this one"
        case .rescheduled: return "moved to another day"
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
