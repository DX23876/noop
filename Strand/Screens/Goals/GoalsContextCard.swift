import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The goals that belong to a screen, at its top: training goals on the training hub, sleep goals on
/// the sleep screen (goals plan §2a, "goals where their context is"). Opens the goal in a sheet with
/// its own stack, so it works the same on iOS and in the macOS panes that have no navigation stack.
struct GoalsContextCard: View {
    enum Context { case training, sleep }
    let context: Context

    @ObservedObject private var tracking = GoalTrackingStore.shared
    @State private var open: Opened?

    private enum Opened: Identifiable {
        case goal(UUID), setup
        var id: String {
            switch self {
            case .goal(let id): return id.uuidString
            case .setup: return "setup"
            }
        }
    }

    private var goals: [PeriodGoalSnapshot] {
        tracking.periodSnapshots.filter { snapshot in
            guard snapshot.goal.status == .active, snapshot.goal.period == .week else { return false }
            switch context {
            case .training:
                return snapshot.goal.metric.isWorkoutBased || snapshot.goal.metric == .workingSets
                    || snapshot.goal.metric == .restDays
            case .sleep:
                return snapshot.goal.metric == .sleepNights || snapshot.goal.metric == .sleepAverage
            }
        }
    }

    var body: some View {
        let items = Array(goals.prefix(2))
        Group {
            if !items.isEmpty {
                NoopCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(context == .training ? "Training goals this week" : "Sleep goal this week")
                            .strandOverline()
                        ForEach(items) { snapshot in
                            Button { open = .goal(snapshot.id) } label: { PeriodGoalRow(snapshot: snapshot) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            } else if context == .training {
                Button { open = .setup } label: {
                    Label("Set a weekly training goal", systemImage: "target")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $open) { which in
            NavigationStack {
                Group {
                    switch which {
                    case .goal(let id): PeriodGoalDetailView(goalId: id)
                    case .setup: PeriodGoalSetupView(initialPeriod: .week)
                    }
                }
                .goalsRouteDestinations()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { open = nil } }
                }
            }
        }
    }
}

/// "Counts toward your weekly goal: Runs 3/4" under a saved workout and in its detail (goals plan §8a).
/// Reads the same snapshots as every goal surface; a workout the current period has not seen yet (just
/// saved, not refreshed) is matched by the goal's own sport rule.
struct GoalContributionNote: View {
    let row: WorkoutRow
    @ObservedObject private var tracking = GoalTrackingStore.shared

    private var matches: [PeriodGoalSnapshot] {
        let key = PlanWorkoutReference(row).workoutKey
        let day = Repository.localDayKey(Date(timeIntervalSince1970: Double(row.startTs)))
        return tracking.periodSnapshots.filter { snapshot in
            guard snapshot.goal.status == .active, snapshot.goal.metric.isWorkoutBased,
                  snapshot.periodDays.contains(day) else { return false }
            if snapshot.counted.contains(where: { $0.id == key }) { return true }
            if snapshot.notCounted.contains(where: { $0.id == key }) { return false }
            return PeriodGoalTracker.workoutMatches(snapshot.goal, row)
        }
    }

    var body: some View {
        let items = matches
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { snapshot in
                    HStack(spacing: 6) {
                        Image(systemName: "target").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                        Text("Counts toward \(GoalFormat.shortName(snapshot.goal)): \(GoalFormat.progress(snapshot))")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The energy plan and the weight goal each carried a kilograms-per-week rate of their own (goals plan
/// Q8). The weight goal leads: the plan shows the rate the goal implies and offers to take it. Never
/// written silently, and the coach still plans no nutrition — this is the wearer's own number.
struct WeightGoalRateHint: View {
    let currentRate: Double
    let apply: (Double) -> Void
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared

    /// The weekly change the weight goal needs from today's trend to its target by its date, clamped to
    /// the plan's slider range and rounded to its step.
    private var impliedRate: (goal: CoachGoal, rate: Double)? {
        guard let goal = goals.activeGoal(for: .weight), goal.status == .active,
              let target = goal.target, let weeks = goal.weeksRemaining(), weeks >= 1 else { return nil }
        let current = tracking.snapshot(for: goal.id)?.measurement?.value ?? goal.baseline
        guard let current else { return nil }
        let raw = (target - current) / weeks
        let stepped = (min(0.5, max(-1, raw)) / 0.05).rounded() * 0.05
        return (goal, stepped)
    }

    var body: some View {
        if let implied = impliedRate, abs(implied.rate - currentRate) >= 0.05 - 1e-9 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your weight goal needs about \(implied.rate.formatted(.number.precision(.fractionLength(2)))) kg a week to reach its date.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use it for the plan") {
                    apply(implied.rate)
                    StrandHaptic.commit.play()
                }
                .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StrandPalette.surfaceInset))
        }
    }
}

/// The optional week bar above the tab bar (iOS 26.1+): two or three weekly goals as mini tracks. Taps
/// open the goals overview. Off by default, switched on in goal settings.
struct GoalsWeekAccessory: View {
    static let enabledKey = "goals.weekAccessory"
    let onOpen: () -> Void
    @ObservedObject private var tracking = GoalTrackingStore.shared

    var body: some View {
        let week = Array(tracking.periodSnapshots
            .filter { $0.goal.status == .active && $0.goal.period == .week }.prefix(3))
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "target").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                ForEach(week) { snapshot in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(GoalFormat.shortName(snapshot.goal)).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(GoalFormat.progress(snapshot)).monospacedDigit()
                        }
                        .font(.system(size: 10))
                        PaceTrack(fraction: snapshot.result.fraction, tint: snapshot.trackTint, height: 4)
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(week.map { GoalFormat.accessibility($0) }.joined(separator: " ")))
    }
}
