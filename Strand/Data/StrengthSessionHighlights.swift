import Foundation
import StrandAnalytics
import StrandTraining

/// What was new in one completed session: records that exceed everything logged before it, and how
/// each exercise moved against its own previous session. Warm-up sets never contribute.
///
/// A record needs an earlier comparable session. The first time an exercise is logged there is
/// nothing to exceed, and calling that a personal record would make every first session a celebration
/// and every later real record worth less. Estimated one-rep maxima use the same Epley estimate and
/// the same RIR correction as the Strength screen, and only for weight-and-repetition movements.
struct StrengthSessionHighlights: Sendable {
    struct Record: Identifiable, Sendable {
        enum Kind: String, Sendable {
            case estimatedOneRepMax
            case heaviestSet
        }

        let exerciseId: String
        let exerciseTitle: String
        let kind: Kind
        let valueKg: Double
        let previousKg: Double

        var id: String { "\(exerciseId)|\(kind.rawValue)" }
    }

    struct Change: Identifiable, Sendable {
        let exerciseId: String
        let exerciseTitle: String
        let deltaKg: Double?
        let deltaReps: Int?
        let previousTs: Int

        var id: String { exerciseId }
    }

    let records: [Record]
    let changes: [Change]

    var isEmpty: Bool { records.isEmpty && changes.isEmpty }

    static func make(workout: NativeWorkout, exercises: [String: TrainingExercise],
                     history: TrainingPerformanceHistory) -> Self {
        var records: [Record] = []
        var changes: [Change] = []

        for exercise in workout.exercises {
            let definition = exercises[exercise.exerciseId]
            let mode = definition?.mode ?? .weightReps
            let title = definition?.title ?? exercise.exerciseId
            let performed = exercise.sets
                .filter { $0.phase == .work && $0.isCompleted }
                .map(TrainingPerformanceHistory.PerformedSet.init)
            guard !performed.isEmpty else { continue }

            let earlier = history.entries(for: exercise.exerciseId)
                .filter { $0.startTs < workout.startedAt }
            let earlierSets = earlier.flatMap(\.workingSets)

            if let best = performed.compactMap({ oneRepMax($0, mode: mode) }).max(),
               let previous = earlierSets.compactMap({ oneRepMax($0, mode: mode) }).max(),
               best > previous + 0.01 {
                records.append(.init(exerciseId: exercise.exerciseId, exerciseTitle: title,
                                     kind: .estimatedOneRepMax, valueKg: best, previousKg: previous))
            }
            if let best = heaviest(performed, mode: mode), let previous = heaviest(earlierSets, mode: mode),
               best > previous + 0.01 {
                records.append(.init(exerciseId: exercise.exerciseId, exerciseTitle: title,
                                     kind: .heaviestSet, valueKg: best, previousKg: previous))
            }

            if let previousSession = earlier.last {
                let previousSets = previousSession.workingSets
                let deltaKg = difference(heaviest(performed, mode: mode), heaviest(previousSets, mode: mode))
                let deltaReps = difference(performed.compactMap(\.completedReps).max(),
                                           previousSets.compactMap(\.completedReps).max())
                if deltaKg != nil || deltaReps != nil {
                    changes.append(.init(exerciseId: exercise.exerciseId, exerciseTitle: title,
                                         deltaKg: deltaKg, deltaReps: deltaReps,
                                         previousTs: previousSession.startTs))
                }
            }
        }
        return .init(records: records, changes: changes)
    }

    /// Only weight-and-repetition work carries a defined one-rep maximum, exactly as on the Strength
    /// screen. Added-load and assisted movements keep their history without an invented estimate.
    private static func oneRepMax(_ set: TrainingPerformanceHistory.PerformedSet,
                                  mode: TrainingMeasurementMode) -> Double? {
        guard mode == .weightReps, let weight = set.weightKg, weight > 0,
              let reps = set.completedReps else { return nil }
        guard let effort = set.effort else { return OneRepMax.epley(weightKg: weight, reps: reps) }
        let rir = effort.scale == .rir ? effort.value : 10 - effort.value
        return OneRepMax.epley(weightKg: weight, reps: reps, rir: rir)
            ?? OneRepMax.epley(weightKg: weight, reps: reps)
    }

    /// Assisted work is deliberately absent: there, less load is the better set, so "heaviest" would
    /// reward the worst one.
    private static func heaviest(_ sets: [TrainingPerformanceHistory.PerformedSet],
                                 mode: TrainingMeasurementMode) -> Double? {
        guard mode == .weightReps || mode == .weightedBodyweight else { return nil }
        return sets.compactMap(\.weightKg).filter { $0 > 0 }.max()
    }

    private static func difference(_ value: Double?, _ previous: Double?) -> Double? {
        guard let value, let previous, abs(value - previous) > 0.01 else { return nil }
        return value - previous
    }

    private static func difference(_ value: Int?, _ previous: Int?) -> Int? {
        guard let value, let previous, value != previous else { return nil }
        return value - previous
    }
}
