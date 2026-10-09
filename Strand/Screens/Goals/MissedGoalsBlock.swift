import SwiftUI
import StrandDesign
import WhoopStore

/// "Still open from the last days": the next-day question for daily goals NOOP could not see done
/// (goals plan §17j). Yes and No in one tap each; a journal-linked goal says first what the answer
/// writes to the journal, a workout goal offers to add the workout instead. On Today it shows at most
/// `limit` questions with a link to the rest on the goals page.
struct MissedGoalsBlock: View {
    var limit: Int?
    /// Draws its own card (the goals page); inside Today's goals card it is a block of that card.
    var inCard = false

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @AppStorage(GoalMissedQuestions.answeredKey) private var answeredRaw = ""
    @State private var answering: Set<String> = []
    @State private var addingWorkout: GoalActionOccurrence?

    private var calendar: Calendar { TrainingPreferences.weekCalendar }

    /// One question per goal, its most recent open day first (`GoalMissedQuestions.onePerGoal`).
    private var open: [GoalActionOccurrence] {
        GoalMissedQuestions.onePerGoal(
            GoalMissedQuestions.open(tracking.recentActions, answered: GoalMissedQuestions.parse(answeredRaw),
                                     today: GoalActionEvaluator.dayKey(Date(), calendar: calendar), calendar: calendar)
                .filter { !answering.contains($0.id) })
    }

    var body: some View {
        let items = open
        if !items.isEmpty {
            let shown = limit.map { Array(items.prefix($0)) } ?? items
            let block = VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Still open from the last days").strandOverline()
                    Spacer()
                    if let limit, items.count > limit {
                        NavigationLink(value: TabRoute.goals) {
                            Text("All (\(items.count))").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(shown) { occurrence in row(occurrence) }
            }
            Group {
                if inCard { NoopCard(padding: 14) { block } } else { block }
            }
            .sheet(item: $addingWorkout) { occurrence in
                ManualWorkoutSheet(prefill: template(for: occurrence), hrSource: repo) { row, _ in
                    Task {
                        await repo.saveManualWorkout(row, replacing: nil)
                        await tracking.refresh(repo: repo)
                    }
                }
            }
        }
    }

    private func row(_ occurrence: GoalActionOccurrence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(occurrence.action.title)
                .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
            Text(question(occurrence)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            if let note = journalNote(occurrence) {
                Text(note).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { answer(occurrence, yes: true) } label: { Text("Yes").frame(minWidth: 44) }
                    .buttonStyle(.borderedProminent)
                Button { answer(occurrence, yes: false) } label: { Text("No").frame(minWidth: 44) }
                    .buttonStyle(.bordered)
                if case .workout = occurrence.action.requirement {
                    Button { addingWorkout = occurrence } label: {
                        Label("Add the workout", systemImage: "plus")
                            .font(StrandFont.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// "Done yesterday?", or the weekday for a day further back.
    private func question(_ occurrence: GoalActionOccurrence) -> String {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())
            .map { GoalActionEvaluator.dayKey($0, calendar: calendar) }
        if occurrence.day == yesterday { return String(localized: "Done yesterday?") }
        let weekday = PeriodGoalTracker.date(occurrence.day, calendar: calendar)?
            .formatted(.dateTime.weekday(.wide)) ?? occurrence.day
        return String(localized: "Done on \(weekday)?")
    }

    /// What Yes and No write to the journal, said before either is tapped (§17j Q10).
    private func journalNote(_ occurrence: GoalActionOccurrence) -> String? {
        guard let yes = GoalMissedQuestions.journalAnswer(occurrence.action.requirement, yes: true),
              let no = GoalMissedQuestions.journalAnswer(occurrence.action.requirement, yes: false) else { return nil }
        let habit = JournalLabel.display(yes.question)
        let word = { (value: Bool) in value ? String(localized: "Yes") : String(localized: "No") }
        return String(localized: "Yes logs “\(word(yes.answeredYes))” for “\(habit)” in the journal, No logs “\(word(no.answeredYes))”.")
    }

    private func answer(_ occurrence: GoalActionOccurrence, yes: Bool) {
        answering.insert(occurrence.id)
        StrandHaptic.selection.play()
        Task {
            await GoalMissedQuestions.answer(occurrence, yes: yes, repo: repo)
            answering.remove(occurrence.id)
        }
    }

    /// A 45 minute session in the evening of that day, of the goal's own sport when it names one.
    private func template(for occurrence: GoalActionOccurrence) -> WorkoutRow {
        let noon = PeriodGoalTracker.date(occurrence.day, calendar: calendar) ?? Date()
        let start = Int(noon.timeIntervalSince1970) + 6 * 3_600
        var sport = ""
        var minutes = 45
        if case .workout(let sports, let minimum) = occurrence.action.requirement {
            sport = sports.first ?? ""
            minutes = max(minutes, minimum ?? 0)
        }
        return WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport, source: "manual",
                          durationS: Double(minutes * 60), energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                          distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }
}
