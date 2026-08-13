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
        if let target = goal.target {
            return String(format: "%.1f %@ now · target %.1f %@",
                          value, goal.kind.unit, target, goal.kind.unit)
        }
        return String(format: "%.1f %@ now", value, goal.kind.unit)
    }

    /// Next waypoint plus the course verdict, or nil when the goal has no route.
    ///
    /// Deliberately says nothing at all when there is nothing honest to say: a goal without a
    /// start/target/date has no plan to be measured against, and silence beats a hedged sentence.
    var routeLine: String? {
        let unit = goal.kind.unit
        var parts: [String] = []
        if let next = nextMilestone {
            let value = String(format: "%.1f", next.value)
                .replacingOccurrences(of: ".0", with: "")
            parts.append(String(localized: "Next \(value) \(unit) by \(next.expectedDate.formatted(Self.waypointDate))"))
        }
        if let course {
            switch course.verdict {
            case .onCourse:
                parts.append(String(localized: "on course"))
            case .ahead, .behind:
                let off = String(format: "%.1f", abs(course.deviation))
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
        routeLine ?? measurementLine ?? nextAction
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
