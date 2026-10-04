import SwiftUI
import StrandDesign

/// The one-line facts a goal can be summarised with, and the tone its health reads in — defined ONCE
/// and read by every surface that shows a goal.
///
/// These lived privately inside `CoachGoalJourneyView`, which meant the Today tile could only have
/// them by copying them. That is exactly how the journey page ended up computing its own progress
/// fraction and its own week colours, and how one goal came to read 50% on one screen and 67% on the
/// next. A shared extension is the cheap way not to make that mistake a third time.
extension GoalTrackingSnapshot {

    /// Date style shared by every route line — short, no year, because a waypoint is months away at
    /// most and "12 Oct" reads faster than a full date.
    static let waypointDate: Date.FormatStyle = .dateTime.day().month(.abbreviated)

    /// "72.4 kg now · target 70.0 kg", or just the current value when the goal has no target. Nil when
    /// there is no measurement at all — there is nothing honest to put on the line.
    var measurementLine: String? {
        guard let value = measurement?.value else { return nil }
        let amount = Self.amountText
        let unit = goal.kind.displayUnit
        if let target = goal.target {
            return String(localized: "\(amount(value, goal.kind)) \(unit) now · target \(amount(target, goal.kind)) \(unit)")
        }
        return String(localized: "\(amount(value, goal.kind)) \(unit) now")
    }

    /// Counted units (sessions, sets, minutes per week) read as whole numbers: "12.0 sessions/week"
    /// suggested a fraction of a session. Measured units keep one decimal ("78.0 kg"), in the reader's
    /// number format.
    static func amountText(_ value: Double, _ kind: CoachGoal.Kind) -> String {
        switch kind {
        case .consistency, .hardSets, .strength: return Int(value.rounded()).formatted()
        default: return value.formatted(.number.precision(.fractionLength(1)))
        }
    }

    /// `nextAction` in the reader's language. The engine keeps English for the coach; the sentences
    /// are fixed, so each is looked up here with its own catalog key.
    var localizedNextAction: String {
        switch nextAction {
        case "Resume when this goal fits again.": return String(localized: "Resume when this goal fits again.")
        case "Mark it achieved, extend the date, or set it aside.":
            return String(localized: "Mark it achieved, extend the date, or set it aside.")
        case "Confirm what happened in Your plan.": return String(localized: "Confirm what happened in Your plan.")
        case "Review the target, date, or next plan with the coach.":
            return String(localized: "Review the target, date, or next plan with the coach.")
        case "Make the next week smaller or easier to schedule.":
            return String(localized: "Make the next week smaller or easier to schedule.")
        case "Adjust the remaining plan instead of trying to catch up blindly.":
            return String(localized: "Adjust the remaining plan instead of trying to catch up blindly.")
        case "Check what would make the next commitment easier to keep.":
            return String(localized: "Check what would make the next commitment easier to keep.")
        case "Complete the next planned commitment.": return String(localized: "Complete the next planned commitment.")
        case "Keep the next step realistic.": return String(localized: "Keep the next step realistic.")
        case "Plan a concrete step, or talk it through with the coach.":
            return String(localized: "Plan a concrete step, or talk it through with the coach.")
        case "Keep the planned steps going.": return String(localized: "Keep the planned steps going.")
        case "Plan one concrete step for this goal.": return String(localized: "Plan one concrete step for this goal.")
        case "Keep building evidence.": return String(localized: "Keep building evidence.")
        default: return nextAction.localizedCatalogValue
        }
    }

    /// Next waypoint plus the course verdict, or nil when the goal has no route.
    ///
    /// Deliberately says nothing at all when there is nothing honest to say: a goal without a
    /// start/target/date has no plan to be measured against, and silence beats a hedged sentence.
    var routeLine: String? {
        let unit = goal.kind.displayUnit
        var parts: [String] = []
        if let next = nextMilestone {
            let value = next.value.formatted(.number.precision(.fractionLength(0...1)))
            parts.append(String(localized: "Next \(value) \(unit) by \(next.expectedDate.formatted(Self.waypointDate))"))
        }
        if let course {
            switch course.verdict {
            case .onCourse:
                parts.append(String(localized: "on course"))
            case .ahead, .behind:
                let off = abs(course.deviation).formatted(.number.precision(.fractionLength(1)))
                let word = course.verdict == .ahead
                    ? String(localized: "ahead of plan") : String(localized: "behind plan")
                if let late = course.daysLate, late != 0 {
                    let days = abs(late)
                    parts.append(late > 0
                                 ? String(localized: "\(off) \(unit) \(word) · about \(days) days late")
                                 : String(localized: "\(off) \(unit) \(word) · about \(days) days early"))
                } else {
                    parts.append("\(off) \(unit) \(word)")
                }
            case .movingAway:
                parts.append(String(localized: "currently moving away from the target"))
            case .unforeseeable:
                parts.append(String(localized: "too slow to project an arrival"))
            case .notEnoughData:
                break   // the planned line alone is not worth a sentence yet
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The tightest true sentence about this goal, for a surface that has room for exactly one line:
    /// the route if there is one, otherwise where the measurement stands, otherwise the next step.
    var headlineLine: String {
        routeLine ?? measurementLine ?? localizedNextAction
    }

    /// The goal's own title, or its kind when the user left the title blank.
    var displayTitle: String {
        goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title
    }

    /// Why there is no percentage — in the user's terms, and NOT all the same sentence.
    ///
    /// `progressFraction` goes nil for three quite different reasons, and saying "tracked, not
    /// scored" for all of them is a lie in two of the three cases: a weight goal with no scale
    /// readings yet IS scored, it just has nothing to score. Nil when a fraction exists.
    var unscoredReason: String? {
        guard progressFraction == nil else { return nil }
        if !goal.kind.isQuantified { return String(localized: "tracked, not scored") }
        if measurement == nil { return String(localized: "no reading yet") }
        return String(localized: "no start or target set")
    }
}

extension CoachGoal.Kind {
    /// `unit` for the screen, in the reader's language. `unit` itself stays English: the coach context
    /// and stored goals use it.
    var displayUnit: String {
        switch self {
        case .consistency: return String(localized: "sessions/week")
        case .strength:    return String(localized: "min/week")
        case .hardSets:    return String(localized: "sets/week")
        default:           return unit
        }
    }
}

extension GoalTrackingSnapshot.Health {
    /// Health → the shared pill's tone. Colour is never the only carrier: every surface that uses this
    /// keeps the state's word next to it.
    var tone: StrandTone {
        switch self {
        case .onTrack:                    return .positive
        case .attention:                  return .warning
        case .atRisk, .decisionNeeded:    return .critical
        case .building, .paused:          return .neutral
        }
    }
}
