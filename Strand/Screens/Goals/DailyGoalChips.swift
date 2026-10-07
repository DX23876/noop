import SwiftUI
import StrandDesign
import StrandAnalytics

/// Today's daily goals as one wrapping row of chips: "7,328 / 10,000", "6.8 / 7 h", "Creatine".
/// They replace the activity rings on Today and the goals page: the long-term and weekly goals are what a
/// glance should show, the day's ticks only need to be there. A goal ticked by hand toggles with a tap.
struct DailyGoalChips: View {
    let occurrences: [GoalActionOccurrence]
    /// Tick or untick a goal done by hand. nil leaves every chip read-only.
    var onToggleManual: ((GoalActionOccurrence) -> Void)?

    /// How far a chip that toggles reaches past its edges for taps: the chip stays small, its target
    /// reaches the 44 pt minimum.
    private let tapOutset: CGFloat = NoopMetrics.space3

    /// The fixed order every small goal surface uses (steps, active kcal, sleep, workouts, ticks).
    private var ordered: [GoalActionOccurrence] {
        let spot = GoalSpotlight.make(todayActions: occurrences, periodSnapshots: [], longTerm: [], pinnedLongTerm: [])
        return spot.rings + spot.checks
    }

    var body: some View {
        FlowLayout(spacing: NoopMetrics.space2) {
            ForEach(ordered) { occurrence in
                if onToggleManual != nil, case .manual = occurrence.action.requirement {
                    Button { toggle(occurrence) } label: {
                        DailyGoalChip(occurrence: occurrence)
                            .padding(tapOutset)
                            .contentShape(Rectangle())
                            .padding(-tapOutset)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(occurrence.isCompleted ? Text("Marks it not done") : Text("Marks it done"))
                } else {
                    DailyGoalChip(occurrence: occurrence)
                }
            }
        }
    }

    private func toggle(_ occurrence: GoalActionOccurrence) {
        onToggleManual?(occurrence)
    }
}

extension GoalActionOccurrence {
    /// The chip's words: today's reading against the target where the goal has numbers, else its name.
    var chipText: String {
        guard let measured, let target = measuredTarget else { return action.title }
        switch action.requirement {
        case .steps:
            return "\(Int(measured.rounded()).formatted()) / \(Int(target.rounded()).formatted())"
        case .sleep:
            let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
            return String(localized: "\(measured.formatted(style)) / \(target.formatted(style)) h")
        case .activeCalories:
            // Active energy is NOOP's own estimate from heart rate; it never reads like a measured count.
            return String(localized: "≈ \(Int(measured.rounded()).formatted()) / \(Int(target.rounded()).formatted()) kcal")
        case .workout:
            return String(localized: "\(Int(measured.rounded())) / \(Int(target.rounded())) min")
        case .manual, .journal:
            return action.title
        }
    }
}
