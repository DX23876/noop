import Foundation
import WhoopStore

// MARK: - Balance — counting, not judging
//
// Three questions the set tally can answer by simple addition: how much pushing against how much
// pulling, how much upper body against how much lower, how much quad-dominant work against how much
// hip- and hamstring-dominant.
//
// ## The rule that keeps this honest
//
// NO TARGET RATIO IS SHIPPED. "Push and pull should be 1:1" is a coaching heuristic, not a measurement,
// and the moment a target appears on screen every reading becomes a pass or a fail against a number
// nobody validated for this wearer. What is offered instead is the same reference the rest of the
// Strength lane uses: THE WEARER'S OWN recent weeks, as a p25…p75 band. "1.6 : 1, and your usual is
// 1.1…1.4" is a fact about their training. "1.6 : 1, target 1.0" would be an opinion wearing a
// measurement's clothes.
//
// The groupings below ARE conventions — a triceps set counts as pushing, a biceps set as pulling — and
// they decide only how sets are ADDED UP. They are listed explicitly, in one place, so a reader can
// disagree with the grouping rather than having to reverse-engineer it out of a chart.
//
// Everything here counts PRIMARY muscle only, exactly like `hardSetsByMuscle`. Secondary involvement is
// not folded in with a fraction anywhere in this lane, and a balance figure is no place to start.

public enum StrengthBalance {

    /// One axis the tally can be split along.
    public enum Axis: String, CaseIterable, Sendable, Codable {
        case pushPull, upperLower, quadsPosterior

        /// Locale-stable keys. The display layer localizes both sides.
        public var sideLabels: (a: String, b: String) {
            switch self {
            case .pushPull:       return ("Push", "Pull")
            case .upperLower:     return ("Upper body", "Lower body")
            case .quadsPosterior: return ("Quads", "Hips & hamstrings")
            }
        }

        /// The muscle groups counted on each side. Conventions, stated once.
        public var sides: (a: Set<HevyMuscleGroup>, b: Set<HevyMuscleGroup>) {
            switch self {
            case .pushPull:
                return ([.chest, .shoulders, .triceps],
                        [.lats, .upperBack, .biceps])
            case .upperLower:
                return ([.chest, .shoulders, .triceps, .biceps, .lats, .upperBack, .traps, .forearms],
                        [.quadriceps, .hamstrings, .glutes, .calves, .abductors, .adductors])
            case .quadsPosterior:
                return ([.quadriceps],
                        [.hamstrings, .glutes])
            }
        }
    }

    /// One axis, read off a set tally.
    public struct Reading: Equatable, Sendable {
        public let axis: Axis
        public let setsA: Int
        public let setsB: Int
        /// `setsA / setsB`, or nil when one side has no sets at all — a ratio against zero is not a
        /// large number, it is an undefined one, and the caller says "no pulling logged" instead.
        public let ratio: Double?

        public init(axis: Axis, setsA: Int, setsB: Int) {
            self.axis = axis
            self.setsA = setsA
            self.setsB = setsB
            self.ratio = (setsA > 0 && setsB > 0) ? Double(setsA) / Double(setsB) : nil
        }

        public var total: Int { setsA + setsB }
        /// Share of the axis' sets on side A, 0…1 — what a two-sided bar is drawn from. Nil when the
        /// axis holds no sets, so an empty axis draws nothing rather than a half-full bar.
        public var shareA: Double? { total > 0 ? Double(setsA) / Double(total) : nil }
    }

    /// Read every axis off one tally of primary-muscle sets.
    public static func readings(setsByMuscle: [HevyMuscleGroup: Int]) -> [Reading] {
        Axis.allCases.map { axis in
            let (a, b) = axis.sides
            return Reading(axis: axis,
                           setsA: a.reduce(0) { $0 + (setsByMuscle[$1] ?? 0) },
                           setsB: b.reduce(0) { $0 + (setsByMuscle[$1] ?? 0) })
        }
    }

    /// The wearer's own usual ratio per axis, as a p25…p75 band over the last `weeks` COMPLETE weeks
    /// (the anchor week excluded — it is the thing being compared).
    ///
    /// Weeks where either side had no sets contribute nothing: an undefined ratio is not a low one, and
    /// counting it as zero would drag the band toward a number nobody trained at. Fewer than three
    /// usable weeks yields no band, matching `typicalWeeklySets` — three points is the least that can
    /// pretend to be a typical value.
    public static func typicalRatios(_ workouts: [HevyWorkout],
                                     templates: [String: HevyExerciseTemplate],
                                     endingBefore anchorDay: String,
                                     weeks: Int = 8,
                                     tzOffsetSeconds: Int = 0) -> [Axis: ClosedRange<Double>] {
        guard let thisMonday = WeeklyDigestEngine.mondayOfWeek(containing: anchorDay) else { return [:] }
        var byAxis: [Axis: [Double]] = [:]
        var monday = WeeklyDigestEngine.addDays(thisMonday, -7)
        for _ in 0..<max(weeks, 1) {
            let week = StrengthSession.week(containing: monday, workouts: workouts,
                                            templates: templates, tzOffsetSeconds: tzOffsetSeconds)
            if week.sessionCount > 0 {
                for reading in readings(setsByMuscle: week.setsByMuscle) {
                    if let ratio = reading.ratio { byAxis[reading.axis, default: []].append(ratio) }
                }
            }
            monday = WeeklyDigestEngine.addDays(monday, -7)
        }

        var out: [Axis: ClosedRange<Double>] = [:]
        for (axis, values) in byAxis where values.count >= 3 {
            let sorted = values.sorted()
            let lo = StrengthSession.percentile(sorted, 0.25)
            let hi = StrengthSession.percentile(sorted, 0.75)
            out[axis] = min(lo, hi)...max(lo, hi)
        }
        return out
    }

    /// Sets that land on NO axis, with the muscle groups they came from.
    ///
    /// A set reaches a side through its exercise's PRIMARY muscle, and the sides are explicit lists —
    /// so a group named in neither list contributes to nothing. That is not an oversight, it is the
    /// alternative to a negation: "pull = everything that is not push" would sweep every ab set and
    /// calf raise onto the pulling side and make the ratio describe work nobody did.
    ///
    /// But it does mean a reading can quietly cover less than the week. The clearest case is the
    /// DEADLIFT: Hevy files the conventional lift under `lower_back`, which is on no axis here, so a
    /// week built around heavy pulls could show a push:pull ratio that never saw them. Abs, calves,
    /// neck and the catch-all groups are in the same position.
    ///
    /// So the figure is reported rather than left implicit, exactly as `unattributedSetCount` is on the
    /// muscle list. The caller shows it beside the bars; what it must NOT do is fold these sets into a
    /// side to make the total add up.
    public static func setsOffAxis(setsByMuscle: [HevyMuscleGroup: Int])
        -> (sets: Int, groups: [HevyMuscleGroup]) {
        var covered: Set<HevyMuscleGroup> = []
        for axis in Axis.allCases {
            let (a, b) = axis.sides
            covered.formUnion(a)
            covered.formUnion(b)
        }
        var sets = 0
        var groups: [HevyMuscleGroup] = []
        for group in HevyMuscleGroup.allCases where !covered.contains(group) {
            let count = setsByMuscle[group] ?? 0
            guard count > 0 else { continue }
            sets += count
            groups.append(group)
        }
        return (sets, groups)
    }

    /// The muscle groups with no sets at all in a tally, in a stable order.
    ///
    /// `.cardio`, `.fullBody` and `.other` are left out: they are catch-alls in Hevy's own enumeration,
    /// not muscles someone forgot to train, and listing them would make every reader's "untrained"
    /// list permanently three entries long.
    public static func untrainedGroups(setsByMuscle: [HevyMuscleGroup: Int]) -> [HevyMuscleGroup] {
        HevyMuscleGroup.allCases
            .filter { $0 != .cardio && $0 != .fullBody && $0 != .other }
            .filter { (setsByMuscle[$0] ?? 0) == 0 }
    }
}
