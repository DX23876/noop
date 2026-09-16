import Foundation
import StrandAnalytics
import StrandTraining
import WhoopStore

/// Read-only compatibility projection from NOOP's source-neutral native log into the established
/// strength analytics vocabulary. Native tables remain authoritative; no second workout is stored.
enum NativeTrainingProjection {
    struct StrengthDetails: Sendable {
        let workouts: [HevyWorkout]
        let templates: [String: HevyExerciseTemplate]
    }

    static func strength(workouts: [NativeWorkout], exercises: [TrainingExercise]) -> StrengthDetails {
        let definitions = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let templates = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, template($0)) })
        let projected = workouts.map { workout in
            var groups: [UUID: Int] = [:]
            var nextGroup = 1
            let entries = workout.exercises.enumerated().map { index, exercise -> HevyExercise in
                let superset: Int?
                if let id = exercise.supersetId {
                    if let existing = groups[id] { superset = existing }
                    else { groups[id] = nextGroup; superset = nextGroup; nextGroup += 1 }
                } else { superset = nil }
                let definition = definitions[exercise.exerciseId]
                return HevyExercise(
                    index: index, title: definition?.title ?? exercise.exerciseId,
                    templateId: exercise.exerciseId, supersetId: superset, notes: exercise.note,
                    sets: exercise.sets.enumerated().map { setIndex, set in
                        HevySet(index: setIndex, type: setType(set), weightKg: set.weightKg,
                                reps: completedReps(set), distanceM: set.distanceM,
                                durationS: set.durationS.map(Double.init), rpe: rpe(set.effort),
                                customMetric: nil, clusterId: set.clusterId?.uuidString,
                                parentSetId: set.parentSetId?.uuidString,
                                segmentIndex: set.segmentIndex)
                    })
            }
            return HevyWorkout(
                id: "noop-native:\(workout.id.uuidString)", title: workout.title,
                routineId: workout.routineIds.first?.uuidString, notes: workout.note,
                startTs: workout.startedAt, endTs: workout.endedAt,
                updatedAtTs: workout.endedAt, createdAtTs: workout.startedAt,
                exercises: entries, source: source(workout.source))
        }
        return StrengthDetails(workouts: projected, templates: templates)
    }

    static func workoutRow(_ workout: NativeWorkout) -> WorkoutRow {
        let trackerSuffix = workout.tracker?.trackerId.map { ":\($0)" } ?? ""
        return WorkoutRow(startTs: workout.startedAt, endTs: workout.endedAt,
                          sport: "Strength Training", source: "native-training\(trackerSuffix)",
                          durationS: Double(max(0, workout.endedAt - workout.startedAt)),
                          energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                          distanceM: nil, zonesJSON: nil, notes: workout.note, steps: nil)
    }

    private static func template(_ exercise: TrainingExercise) -> HevyExerciseTemplate {
        HevyExerciseTemplate(
            id: exercise.id, title: exercise.title, type: measurementType(exercise.mode),
            primaryMuscleGroup: muscle(exercise.primaryMuscleId),
            secondaryMuscleGroups: Array(Set(exercise.secondaryMuscleIds.map(muscle)))
                .sorted { $0.rawValue < $1.rawValue },
            equipment: equipment(exercise.equipmentIds), isCustom: exercise.source == .user)
    }

    private static func measurementType(_ mode: TrainingMeasurementMode) -> String {
        switch mode {
        case .weightReps: return "weight_reps"
        case .bodyweightReps: return "bodyweight_reps"
        case .weightedBodyweight: return "weighted_bodyweight"
        case .assistedBodyweight: return "assisted_bodyweight"
        case .repetitions: return "reps_only"
        case .duration: return "duration"
        case .distanceDuration: return "distance_duration"
        }
    }

    private static func muscle(_ id: String?) -> HevyMuscleGroup {
        switch id {
        case "upper_chest", "lower_chest", "chest": return .chest
        case "front_delts", "side_delts", "rear_delts", "shoulders": return .shoulders
        case "upper_back": return .upperBack
        case "lower_back": return .lowerBack
        case "abdominals", "obliques", "core": return .abdominals
        case "quadriceps": return .quadriceps
        case "hamstrings": return .hamstrings
        case "glutes": return .glutes
        case "adductors": return .adductors
        case "abductors": return .abductors
        case "calves", "tibialis": return .calves
        case "lats": return .lats
        case "traps": return .traps
        case "triceps": return .triceps
        case "biceps": return .biceps
        case "forearms": return .forearms
        case "neck": return .neck
        default: return .other
        }
    }

    private static func equipment(_ ids: [String]) -> HevyEquipment {
        let set = Set(ids)
        if set.contains("barbell") { return .barbell }
        if set.contains("dumbbell") { return .dumbbell }
        if set.contains("kettlebell") { return .kettlebell }
        if set.contains("machine") || set.contains("cable") { return .machine }
        if set.contains("plate") { return .plate }
        if set.contains("resistance-band") { return .resistanceBand }
        if set.contains("bodyweight") { return .none }
        return .other
    }

    private static func setType(_ set: NativeWorkoutSet) -> HevySetType {
        if set.phase == .warmup { return .warmup }
        switch set.intensifier {
        case .dropSet: return .dropset
        case .failure: return .failure
        case .restPause: return .restPause
        case .amrap: return .amrap
        case .none: return .normal
        }
    }

    private static func completedReps(_ set: NativeWorkoutSet) -> Int? {
        if let reps = set.reps { return reps }
        if let left = set.leftReps, let right = set.rightReps { return min(left, right) }
        return set.leftReps ?? set.rightReps
    }

    private static func rpe(_ effort: TrainingEffortRating?) -> Double? {
        guard let effort else { return nil }
        return effort.scale == .rpe ? effort.value : max(1, min(10, 10 - effort.value))
    }

    private static func source(_ value: TrainingRecordSource) -> StrengthDataSource {
        switch value {
        case .noopNative: return .noopNative
        case .hevyAPI: return .hevyAPI
        case .hevyCSV: return .hevyCSV
        case .liftosaur: return .liftosaur
        case .fitNotes: return .fitNotes
        case .strong: return .strong
        case .imported: return .imported
        }
    }
}

extension Repository {
    /// Pins the native set component and its chosen physiological component to one canonical session.
    /// This is additive metadata; neither workout row nor heart-rate buckets are copied.
    func linkNativeWorkoutPhysiology(_ workout: NativeWorkout) async {
        guard let sessionId = workout.trainingSessionId, let store = await storeHandle() else { return }
        let native = NativeTrainingProjection.workoutRow(workout)
        let nativeKey = "\(native.source)|\(native.startTs)|\(WorkoutSource.sportKey(native.sport))"
        var keys = [nativeKey]
        if let physiology = workout.physiologyComponentKey { keys.append(physiology) }
        let now = Int(Date().timeIntervalSince1970)
        try? await store.upsertTrainingSessionLinks(keys.map {
            .init(componentKey: $0, sessionId: sessionId.uuidString,
                  origin: "native-lifecycle", updatedAtTs: now)
        })
        if let primary = workout.physiologyComponentKey {
            try? await store.upsertTrainingSessionPreference(.init(
                sessionId: sessionId.uuidString, activityKind: TrainingActivityKind.strength.rawValue,
                primaryComponentKey: primary, updatedAtTs: now))
        }
    }
}
