import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The three long-term start packs (plan §9): a catalog goal plus the weekly goals that carry it, sized
/// from the wearer's last weeks. Built by the same `CatalogGoalDraft` the coach uses, so a pack makes the
/// goal the walkthrough would.
struct LongTermStartPack: Identifiable {
    let id: String
    let title: String
    let icon: String
    let goal: CoachGoal
    /// The weekly goal a weekly-rhythm template is measured by. It comes with the goal, never optional.
    let measuringWeekly: PeriodGoal?
    /// Further weekly goals that serve the goal; each can be left out.
    let extraWeekly: [PeriodGoal]

    var allWeekly: [PeriodGoal] { (measuringWeekly.map { [$0] } ?? []) + extraWeekly }

    static func packs(inputs: PeriodGoalInputs, weight: Double?, now: Date = Date(),
                      calendar: Calendar = TrainingPreferences.weekCalendar) -> [LongTermStartPack] {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let fourWeeksAgo = calendar.date(byAdding: .weekOfYear, value: -4, to: weekStart) ?? weekStart
        func recent(_ sports: [String]) -> [WorkoutRow] {
            inputs.workouts.filter {
                let date = Date(timeIntervalSince1970: Double($0.startTs))
                return date >= fourWeeksAgo && date < weekStart && GoalActionEvaluator.matches($0, any: sports)
            }
        }
        func weekly(_ metric: PeriodMetric, _ target: Double, sports: [String] = [], parent: UUID) -> PeriodGoal {
            PeriodGoal(metric: metric, period: .week, target: target, threshold: metric.defaultThreshold,
                       sportFilter: sports, parentGoalId: parent)
        }
        var out: [LongTermStartPack] = []

        // Start running: the next round distance past the longest run of the last twelve weeks.
        let twelveWeeks = now.addingTimeInterval(-84 * 86_400).timeIntervalSince1970
        let longest = inputs.workouts.filter { Double($0.startTs) >= twelveWeeks && GoalActionEvaluator.matches($0, any: ["Running"]) }
            .compactMap(\.distanceM).max().map { $0 / 1_000 } ?? 0
        let distance = [5.0, 10, 21.1].first { $0 > longest + 0.5 } ?? 42.2
        var run = CatalogGoalDraft.Input()
        run.target = distance
        // The route starts where the wearer already is, as in the walkthrough: a 7 km runner aiming for
        // 10 km sees 7.5, 8, … rather than 1 km marks long behind them.
        run.baseline = longest
        run.sports = ["Running"]
        run.targetDate = calendar.date(byAdding: .weekOfYear, value: 12, to: now)
        run.title = String(localized: "Run \(LongTermFormat.value(distance, .longestDistance))")
        if case .success(let made) = CatalogGoalDraft.make(.longest, run, now: now) {
            let runs = recent(["Running"])
            let km = runs.compactMap(\.distanceM).reduce(0, +) / 1_000 / 4
            out.append(.init(id: "run", title: String(localized: "Start running"), icon: "figure.run",
                             goal: made.goal, measuringWeekly: nil,
                             extraWeekly: [weekly(.workouts, min(4, max(2, (Double(runs.count) / 4).rounded())), sports: ["Running"], parent: made.goal.id),
                                           weekly(.distance, max(5, (km / 5).rounded() * 5), sports: ["Running"], parent: made.goal.id)]))
        }

        // Build strength: working sets from a lifting log, otherwise strength sessions a week.
        var strength = CatalogGoalDraft.Input()
        let template: GoalTemplateID
        if let sets = inputs.setsByDay {
            let from = Repository.localDayKey(fourWeeksAgo), to = Repository.localDayKey(weekStart)
            let perWeek = sets.filter { $0.key >= from && $0.key < to }.values.reduce(0, +) / 4
            strength.target = max(30, (perWeek / 5).rounded() * 5)
            template = .setsWeekly
        } else {
            strength.target = 3
            strength.sports = ["Strength"]
            template = .trainingWeekly
        }
        if case .success(let made) = CatalogGoalDraft.make(template, strength, now: now) {
            let extra = template == .setsWeekly
                // Two to four sessions: the sets are the measure, the sessions only carry them.
                ? [weekly(.workouts, min(4, max(2, (Double(recent(["Strength"]).count) / 4).rounded())), sports: ["Strength"], parent: made.goal.id)]
                : []
            out.append(.init(id: "strength", title: String(localized: "Build strength"), icon: "dumbbell.fill",
                             goal: made.goal, measuringWeekly: made.weekly, extraWeekly: extra))
        }

        // Lose weight: five percent at half a kilo a week, a pace the safety gate calls conservative.
        if let weight, weight > 30 {
            var lose = CatalogGoalDraft.Input()
            lose.baseline = (weight * 10).rounded() / 10
            let target = ((weight * 0.95) * 2).rounded() / 2
            lose.target = target
            let weeks = max(4, Int(((weight - target) / 0.5).rounded(.up)))
            lose.targetDate = calendar.date(byAdding: .weekOfYear, value: weeks, to: now)
            if case .success(let made) = CatalogGoalDraft.make(.weightLose, lose, now: now) {
                out.append(.init(id: "lose", title: String(localized: "Lose weight"), icon: "scalemass.fill",
                                 goal: made.goal, measuringWeekly: nil,
                                 extraWeekly: [weekly(.workouts, 3, parent: made.goal.id),
                                               weekly(.stepDays, 5, parent: made.goal.id)]))
            }
        }
        return out
    }
}

/// The packs as a row of cards above the areas.
struct LongTermStartPacksRow: View {
    let packs: [LongTermStartPack]
    var onAdded: () -> Void = {}
    @State private var open: LongTermStartPack?

    var body: some View {
        if !packs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Start packs").strandOverline().padding(.horizontal, 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(packs) { pack in
                            Button { open = pack } label: { card(pack) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .sheet(item: $open) { pack in LongTermStartPackSheet(pack: pack, onAdded: onAdded) }
        }
    }

    private func card(_ pack: LongTermStartPack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(pack.title, systemImage: pack.icon).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Text(verbatim: LongTermStartPackSheet.goalLine(pack.goal))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            // The measuring weekly goal says what the goal line already says; only the extras are new.
            ForEach(pack.extraWeekly) { goal in
                Text(GoalFormat.title(goal)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("Look").font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.accent)
        }
        .frame(width: 220, height: 130, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
            .fill(StrandPalette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }
}

struct LongTermStartPackSheet: View {
    let pack: LongTermStartPack
    var onAdded: () -> Void = {}

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var periodStore = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID> = []
    @State private var message: String?

    /// "10 km by 28 Dec", "91.0 kg by 12 Mar", "105 sets / week".
    static func goalLine(_ goal: CoachGoal) -> String {
        guard let metric = goal.measure?.metric, let target = goal.target else { return goal.title }
        let value: String
        switch metric {
        case .weeklyAdherence:
            let weekly = GoalCatalog.template(for: goal)?.id.weeklyMetric ?? .workouts
            value = LongTermFormat.perWeek(target, weekly)
        default:
            value = LongTermFormat.value(target, metric)
        }
        guard let date = goal.targetDate, metric != .weeklyAdherence else { return value }
        return String(localized: "\(value) by \(LongTermFormat.shortDate(date))")
    }

    private var sameGoal: CoachGoal? {
        goals.activeGoal(measuringLike: pack.goal, weeklyMetric: GoalCatalog.template(for: pack.goal)?.id.weeklyMetric)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(pack.goal.title) { Text(verbatim: Self.goalLine(pack.goal)) }
                    if let same = sameGoal {
                        Text("“\(same.title)” already measures this.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarningForeground)
                    }
                } header: {
                    Text("Long-term goal")
                }
                Section {
                    if let measuring = pack.measuringWeekly {
                        LabeledContent(GoalFormat.title(measuring)) {
                            Text("Measures the goal").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    ForEach(pack.extraWeekly) { goal in
                        Toggle(isOn: Binding(get: { chosen.contains(goal.id) },
                                             set: { if $0 { chosen.insert(goal.id) } else { chosen.remove(goal.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(GoalFormat.title(goal))
                                if periodStore.canAdd(goal) != nil {
                                    Text("Already a goal").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Every week")
                } footer: {
                    Text("Values are read from your last weeks. You can change each goal later.")
                }
                if let message { Section { Text(message).foregroundStyle(StrandPalette.statusCritical) } }
            }
            .navigationTitle(pack.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(sameGoal != nil)
                }
            }
            .onAppear { chosen = Set(pack.extraWeekly.filter { periodStore.canAdd($0) == nil }.map(\.id)) }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func add() {
        guard goals.hasRoom() else {
            message = String(localized: "Close or set aside a goal first, or raise the limit in the goal settings.")
            return
        }
        let today = Repository.localDayKey(Date())
        var goal = pack.goal
        // The measuring weekly goal first: without it a weekly-rhythm goal has nothing to read.
        if let measuring = pack.measuringWeekly {
            switch periodStore.canAdd(measuring) {
            case nil:
                periodStore.commit(measuring, today: today)
            case .duplicate(let existingId)?:
                // The same weekly slot is already tracked: the goal reads that one instead of a second.
                periodStore.link(existingId, to: goal.id)
                goal.measure?.weeklyGoalId = existingId
            case .limitReached?:
                message = String(localized: "You have reached your limit of \(GoalPrefs.periodLimit) weekly and monthly goals.")
                return
            }
        }
        for weekly in pack.extraWeekly where chosen.contains(weekly.id) {
            switch periodStore.canAdd(weekly) {
            case nil: periodStore.commit(weekly, today: today)
            case .duplicate(let existingId)?:
                if periodStore.goal(id: existingId)?.parentGoalId == nil { periodStore.link(existingId, to: goal.id) }
            case .limitReached?: break
            }
        }
        goals.commit(goal)
        StrandHaptic.commit.play()
        Task { await tracking.refresh(repo: repo) }
        onAdded()
        dismiss()
    }
}
