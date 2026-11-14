import Foundation

/// What a plan amounts to in a week, and what stands out about it.
///
/// **It warns, it never blocks**, and every threshold is measured against THIS WEARER'S OWN recent
/// training, never against a textbook. The same reasoning `StrengthPlanGate` sets out for a drafted
/// routine: "ten sets of chest" means one thing for someone averaging four and another for someone
/// averaging eighteen, and nothing in NOOP knows what anyone's right number is. What it does know is
/// what they have actually been doing, which is enough to notice a step change and say so.
///
/// Findings are DATA, not sentences. Each one carries the figures it compared so the screen can say
/// what it compared, in the reader's own language, and so Android says the same thing from the same
/// numbers.
public struct PlanReview: Equatable, Sendable {

    /// What stood out. Nothing here is an error: a big step up can be entirely deliberate.
    public enum Finding: Equatable, Sendable {
        /// A region the week does not train at all.
        case regionUntrained(TrainingBodyRegion)
        /// A region prescribed well above what this wearer has been doing lately.
        case regionAboveUsual(region: TrainingBodyRegion, weeklySets: Double, usualWeeklySets: Double)
        /// Two sessions in a row that both lean on the legs.
        case heavyDaysBackToBack(first: TrainingWeekday, second: TrainingWeekday)
        /// A session that takes longer than the wearer said they had.
        case sessionLongerThanAsked(routineId: UUID, minutes: Int, askedMinutes: Int)
    }

    /// Working sets a week per region, counting a routine once for every day it is scheduled on.
    /// A secondary muscle counts half, exactly as the muscle map and the completed-workout analytics
    /// count it, so the plan and the history are measured the same way.
    public let weeklySetsByRegion: [TrainingBodyRegion: Double]
    /// Minutes per session, by routine.
    public let sessionMinutes: [UUID: Int]
    public let findings: [Finding]

    public var weeklySessionCount: Int { sessionMinutes.count }

    public init(weeklySetsByRegion: [TrainingBodyRegion: Double], sessionMinutes: [UUID: Int],
                findings: [Finding]) {
        self.weeklySetsByRegion = weeklySetsByRegion
        self.sessionMinutes = sessionMinutes
        self.findings = findings
    }
}

/// What the plan is compared against: this wearer's own recent weeks, already derived.
public struct PlanHistory: Equatable, Sendable {
    /// Working sets per region over the window, and how many weeks that window spans.
    public let setsByRegion: [TrainingBodyRegion: Double]
    public let weeks: Double

    public init(setsByRegion: [TrainingBodyRegion: Double], weeks: Double) {
        self.setsByRegion = setsByRegion
        self.weeks = weeks
    }

    public static let none = PlanHistory(setsByRegion: [:], weeks: 0)

    public func weeklySets(_ region: TrainingBodyRegion) -> Double? {
        guard weeks > 0, let total = setsByRegion[region] else { return nil }
        return total / weeks
    }

    /// Built from the sessions the wearer has actually logged, through the same muscle projection the
    /// plan is measured with.
    public static func from(workouts: [NativeWorkout], exercises: [String: TrainingExercise],
                            windowDays: Int = 28, now: Int = Int(Date().timeIntervalSince1970))
        -> PlanHistory {
        let cutoff = now - windowDays * 86_400
        var totals: [TrainingBodyRegion: Double] = [:]
        for workout in workouts where workout.startedAt >= cutoff {
            for (muscleId, sets) in TrainingMuscleProjection.workout(workout, exercises: exercises) {
                totals[TrainingBodyRegion.forMuscle(muscleId), default: 0] += sets
            }
        }
        return PlanHistory(setsByRegion: totals, weeks: Double(windowDays) / 7)
    }
}

extension PlanReview {

    // MARK: - Thresholds (documented, not magic)

    /// Above this multiple of the wearer's own weekly average, a region is worth mentioning. The same
    /// 1.5 `StrengthPlanGate` uses and for its reason: ordinary progression adds a set or two a week,
    /// which from a base of eight is about 1.2, while a doubling is what this should catch.
    public static let aboveUsualFactor = 1.5
    /// Below this many sets a week the multiple means nothing: one set to three is 3 times and also
    /// unremarkable.
    public static let aboveUsualFloor = 6.0
    /// Weeks of history needed before the comparison runs at all. With less, "unusual" is a statement
    /// about how thin the data is dressed up as one about the plan, and a warning that fires on
    /// everyone teaches people to ignore warnings.
    public static let minimumHistoryWeeks = 2.0
    /// A session may run this much over the time asked for before it is worth saying. Rounding and a
    /// slow set should not raise a finding.
    public static let overTimeTolerance = 1.15

    /// Reviews a plan as it stands.
    ///
    /// - Parameters:
    ///   - askedMinutesPerSession: what the wearer said a session may take, when they said anything.
    ///   - history: their own recent weeks. `PlanHistory.none` keeps the comparison silent.
    public static func evaluate(program: TrainingProgram, routines: [TrainingRoutine],
                                exercises: [String: TrainingExercise],
                                askedMinutesPerSession: Int? = nil,
                                history: PlanHistory = .none) -> PlanReview {
        let byId = Dictionary(routines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var weekly: [TrainingBodyRegion: Double] = [:]
        var minutes: [UUID: Int] = [:]

        for weekday in TrainingWeekday.allCases {
            for id in program.schedule[weekday] ?? [] {
                guard let routine = byId[id] else { continue }
                for (muscleId, sets) in TrainingMuscleProjection.routine(routine, exercises: exercises) {
                    weekly[TrainingBodyRegion.forMuscle(muscleId), default: 0] += sets
                }
            }
        }
        for routine in routines { minutes[routine.id] = SessionEstimate.minutes(routine) }

        var findings: [Finding] = []
        findings += untrainedRegions(weekly)
        findings += aboveUsual(weekly, history: history)
        findings += backToBackHeavyDays(program: program, routines: byId, exercises: exercises)
        if let asked = askedMinutesPerSession {
            findings += overTime(minutes, asked: asked, routines: routines)
        }
        return PlanReview(weeklySetsByRegion: weekly, sessionMinutes: minutes, findings: findings)
    }

    /// Regions the week never touches. Reported in a fixed order so the list does not reshuffle
    /// between two readings of the same plan.
    private static func untrainedRegions(_ weekly: [TrainingBodyRegion: Double]) -> [Finding] {
        guard weekly.values.reduce(0, +) > 0 else { return [] }
        return TrainingBodyRegion.allCases
            .filter { $0 != .other && (weekly[$0] ?? 0) <= 0 }
            .map { Finding.regionUntrained($0) }
    }

    private static func aboveUsual(_ weekly: [TrainingBodyRegion: Double],
                                   history: PlanHistory) -> [Finding] {
        guard history.weeks >= minimumHistoryWeeks else { return [] }
        return TrainingBodyRegion.allCases.compactMap { region in
            guard let prescribed = weekly[region], prescribed >= aboveUsualFloor,
                  let usual = history.weeklySets(region), usual > 0,
                  prescribed > usual * aboveUsualFactor else { return nil }
            return .regionAboveUsual(region: region, weeklySets: prescribed, usualWeeklySets: usual)
        }
    }

    /// Two scheduled days in a row whose sessions both lean on the legs. Mentioned, not prevented:
    /// plenty of plans do it on purpose.
    private static func backToBackHeavyDays(program: TrainingProgram,
                                            routines: [UUID: TrainingRoutine],
                                            exercises: [String: TrainingExercise]) -> [Finding] {
        func leansOnLegs(_ weekday: TrainingWeekday) -> Bool {
            var legs = 0.0
            var total = 0.0
            for id in program.schedule[weekday] ?? [] {
                guard let routine = routines[id] else { continue }
                for (muscleId, sets) in TrainingMuscleProjection.routine(routine, exercises: exercises) {
                    total += sets
                    if TrainingBodyRegion.forMuscle(muscleId) == .legs { legs += sets }
                }
            }
            return total > 0 && legs / total > 0.5
        }
        let days = TrainingWeekday.allCases
        return zip(days, days.dropFirst()).compactMap { first, second in
            leansOnLegs(first) && leansOnLegs(second)
                ? .heavyDaysBackToBack(first: first, second: second) : nil
        }
    }

    private static func overTime(_ minutes: [UUID: Int], asked: Int,
                                 routines: [TrainingRoutine]) -> [Finding] {
        routines.compactMap { routine in
            guard let estimate = minutes[routine.id],
                  Double(estimate) > Double(asked) * overTimeTolerance else { return nil }
            return .sessionLongerThanAsked(routineId: routine.id, minutes: estimate,
                                           askedMinutes: asked)
        }
    }
}
