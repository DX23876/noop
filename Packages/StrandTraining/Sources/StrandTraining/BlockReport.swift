import Foundation

/// What a block came to, worked out from the workout log every time it is shown.
///
/// Nothing here is stored. `TrainingBlockRun` keeps only when a block ran; the figures are derived
/// from the sessions inside that window, so the history can never claim something the log does not
/// say. It is the same reason a day's scores are not copied into a second table.
///
/// Deliberately no estimated one-repetition maximum: that figure belongs to the strength analytics,
/// and a second implementation of it here would be a second answer to one question.
public struct BlockReport: Equatable, Sendable {
    public let run: TrainingBlockRun
    /// Sessions the plan asked for over the whole block, when the plan says how many a week.
    public let plannedSessions: Int?
    public let doneSessions: Int
    /// Days with at least one session, which is not the same as sessions when two fall on one day.
    public let daysTrained: Int
    public let workSets: Int
    /// Weight times repetitions over completed work sets, in kilograms. Sets with no weight are not
    /// in it, and `unpricedWorkSets` says how many those were rather than quietly leaving them out.
    public let loadKg: Double
    public let unpricedWorkSets: Int
    public let setsByRegion: [TrainingBodyRegion: Double]
    /// The mean whole-session effort the wearer gave, where they gave one.
    public let averageSessionRPE: Double?

    public init(run: TrainingBlockRun, plannedSessions: Int?, doneSessions: Int, daysTrained: Int,
                workSets: Int, loadKg: Double, unpricedWorkSets: Int,
                setsByRegion: [TrainingBodyRegion: Double], averageSessionRPE: Double?) {
        self.run = run
        self.plannedSessions = plannedSessions
        self.doneSessions = doneSessions
        self.daysTrained = daysTrained
        self.workSets = workSets
        self.loadKg = loadKg
        self.unpricedWorkSets = unpricedWorkSets
        self.setsByRegion = setsByRegion
        self.averageSessionRPE = averageSessionRPE
    }

    /// The window a run covers: its start day, and its end day or today while it is still going.
    public static func window(_ run: TrainingBlockRun, today: String) -> (from: String, to: String) {
        (run.startedOn, run.endedOn ?? today)
    }

    /// Builds the report from the sessions that fall inside the run's own window.
    ///
    /// - Parameter sessionsPerWeek: what the plan asks of a week, for the planned figure. Nil leaves
    ///   it out rather than guessing from the sessions that happened, which would compare the log
    ///   with itself.
    public static func make(run: TrainingBlockRun, workouts: [NativeWorkout],
                            exercises: [String: TrainingExercise], sessionsPerWeek: Int?,
                            today: String) -> BlockReport {
        let window = window(run, today: today)
        let inside = workouts.filter { workout in
            let day = TrainingBlockState.dayKey(Date(timeIntervalSince1970: TimeInterval(workout.startedAt)))
            return day >= window.from && day <= window.to
        }
        var sets = 0
        var load = 0.0
        var unpriced = 0
        var regions: [TrainingBodyRegion: Double] = [:]
        var efforts: [Double] = []
        var days = Set<String>()
        for workout in inside {
            days.insert(TrainingBlockState.dayKey(
                Date(timeIntervalSince1970: TimeInterval(workout.startedAt))))
            if let rpe = workout.sessionRPE { efforts.append(rpe) }
            for (muscleId, credit) in TrainingMuscleProjection.workout(workout, exercises: exercises) {
                regions[TrainingBodyRegion.forMuscle(muscleId), default: 0] += credit
            }
            for exercise in workout.exercises {
                for set in exercise.sets where set.phase == .work && set.isCompleted {
                    sets += 1
                    if let weight = set.weightKg, let reps = set.reps, weight > 0 {
                        load += weight * Double(reps)
                    } else {
                        unpriced += 1
                    }
                }
            }
        }
        let weeks = max(1, (TrainingBlockState.dayDifference(from: window.from, to: window.to) ?? 0) / 7 + 1)
        return BlockReport(
            run: run, plannedSessions: sessionsPerWeek.map { $0 * min(run.weeks, weeks) },
            doneSessions: inside.count, daysTrained: days.count, workSets: sets, loadKg: load,
            unpricedWorkSets: unpriced, setsByRegion: regions,
            averageSessionRPE: efforts.isEmpty ? nil : efforts.reduce(0, +) / Double(efforts.count))
    }

    /// Two blocks of one plan side by side. Positive means the later block was the bigger one.
    public struct Comparison: Equatable, Sendable {
        public let sessions: Int
        public let workSets: Int
        public let loadKg: Double
        public let setsByRegion: [TrainingBodyRegion: Double]

        public init(sessions: Int, workSets: Int, loadKg: Double,
                    setsByRegion: [TrainingBodyRegion: Double]) {
            self.sessions = sessions
            self.workSets = workSets
            self.loadKg = loadKg
            self.setsByRegion = setsByRegion
        }
    }

    public static func compare(previous: BlockReport, current: BlockReport) -> Comparison {
        var regions: [TrainingBodyRegion: Double] = [:]
        for region in TrainingBodyRegion.allCases {
            let delta = (current.setsByRegion[region] ?? 0) - (previous.setsByRegion[region] ?? 0)
            if delta != 0 { regions[region] = delta }
        }
        return Comparison(sessions: current.doneSessions - previous.doneSessions,
                          workSets: current.workSets - previous.workSets,
                          loadKg: current.loadKg - previous.loadKg,
                          setsByRegion: regions)
    }
}
