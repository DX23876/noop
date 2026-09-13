import Foundation
import WhoopStore

// MARK: - Weekly working sets against a deliberately qualified research reference
//
// The rest of the Strength screen compares a muscle with the wearer's OWN recent habit: "usual 12–16
// for you". That is the honest comparison when nothing external is known, and it is also circular — a
// muscle trained four sets a week forever looks perfectly normal, because four sets is what its owner
// usually does. This file adds the one external reference the strength literature does support, and
// nothing more.
//
// WHAT THE EVIDENCE SAYS. Schoenfeld, Ogborn & Krieger's 2017 dose-response meta-analysis found weekly
// set volume graded with hypertrophy, with more than ~10 challenging sets per muscle per week
// outperforming fewer than 5. Later systematic reviews (Baz-Valle et al. 2022) put the useful span at
// roughly 12–20, and find the evidence thinning above it rather than reversing. So the displayed
// reference is 10 to 20.
//
// WHAT IT IS NOT, and the card must say so:
//   • It is a HYPERTROPHY range. Strength and power are trained closer to maximal loads at lower
//     volumes, and someone peaking for a heavy single is not underdoing it at 8 sets.
//   • It is not a safety threshold in either direction. Above 20 is "beyond what the studies can
//     speak for", not "dangerous"; below 10 is "less than the growth studies used", not "wasted".
//   • The studies count challenging sets. NOOP counts logged working sets with warm-ups excluded, but
//     cannot prove proximity to failure when RPE is missing. The display therefore calls this rough
//     context rather than presenting every counted set as a verified hard set.
//   • Individual response varies enough that published ranges do not transfer to one person.

/// Where a muscle's weekly logged working sets sit against the qualified research reference.
public enum WeeklyVolumeVerdict: String, Sendable, CaseIterable {
    /// Fewer sets than the hypertrophy studies used.
    case below
    /// Inside the range those studies support.
    case inside
    /// More than the studies can speak for — not a warning, an absence of evidence.
    case above
}

/// One muscle group's week, judged against the range.
public struct WeeklyVolumeReading: Equatable, Sendable {
    public let group: HevyMuscleGroup
    public let sets: Int
    public let verdict: WeeklyVolumeVerdict

    public init(group: HevyMuscleGroup, sets: Int, verdict: WeeklyVolumeVerdict) {
        self.group = group
        self.sets = sets
        self.verdict = verdict
    }
}

public enum StrengthVolume {

    /// Weekly working-set reference derived from the range used in hypertrophy literature.
    public static let productiveRange = 10...20

    /// Groups that are never judged against a weekly set range.
    ///
    /// `cardio`, `fullBody` and `other` are not muscles anyone prescribes weekly sets for — they are
    /// filing categories in the exercise catalogue. Scoring them would put a verdict on a bucket rather
    /// than on a body part, and the same three are already left off the body map for the same reason.
    public static let unjudgedGroups: Set<HevyMuscleGroup> = [.cardio, .fullBody, .other]

    public static func verdict(sets: Int) -> WeeklyVolumeVerdict {
        if sets < productiveRange.lowerBound { return .below }
        if sets > productiveRange.upperBound { return .above }
        return .inside
    }

    /// Every muscle group the week actually trained, judged, busiest first.
    ///
    /// Groups with NO sets this week are left out rather than reported as below the range. A muscle
    /// nobody trained is not underdosed — it is untrained, which is a different statement and one
    /// `StrengthBalance.untrainedGroups` already makes. Reporting it here would mean the neck and the
    /// forearms of every lifter alive sat permanently in the red, and a warning that is always on is a
    /// warning nobody reads.
    public static func readings(setsByMuscle: [HevyMuscleGroup: Int]) -> [WeeklyVolumeReading] {
        var out: [WeeklyVolumeReading] = []
        for (group, sets) in setsByMuscle where sets > 0 && !unjudgedGroups.contains(group) {
            out.append(WeeklyVolumeReading(group: group, sets: sets, verdict: verdict(sets: sets)))
        }
        return out.sorted { lhs, rhs in
            lhs.sets == rhs.sets ? lhs.group.rawValue < rhs.group.rawValue : lhs.sets > rhs.sets
        }
    }

    /// How the week's trained muscles fall across the range — the one line a card can lead with.
    public static func summary(setsByMuscle: [HevyMuscleGroup: Int])
        -> (below: Int, inside: Int, above: Int, trained: Int) {
        let all = readings(setsByMuscle: setsByMuscle)
        var below = 0, inside = 0, above = 0
        for reading in all {
            switch reading.verdict {
            case .below:  below += 1
            case .inside: inside += 1
            case .above:  above += 1
            }
        }
        return (below: below, inside: inside, above: above, trained: all.count)
    }
}
