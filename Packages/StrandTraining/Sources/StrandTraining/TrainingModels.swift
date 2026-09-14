import Foundation

public enum TrainingMeasurementMode: String, Codable, CaseIterable, Sendable {
    case weightReps = "weight_reps"
    case bodyweightReps = "bodyweight_reps"
    case weightedBodyweight = "weighted_bodyweight"
    case assistedBodyweight = "assisted_bodyweight"
    case repetitions
    case duration
    case distanceDuration = "distance_duration"
}

public enum TrainingSetPhase: String, Codable, CaseIterable, Sendable {
    case warmup
    case work
}

public enum TrainingSetIntensifier: String, Codable, CaseIterable, Sendable {
    case none
    case dropSet = "drop_set"
    case restPause = "rest_pause"
    case amrap
    case failure
}

public enum TrainingEffortScale: String, Codable, CaseIterable, Sendable {
    case rpe
    case rir
}

public struct TrainingEffortRating: Codable, Equatable, Sendable {
    public let scale: TrainingEffortScale
    public let value: Double

    public init?(scale: TrainingEffortScale, value: Double) {
        let range = scale == .rpe ? 1.0...10.0 : 0.0...10.0
        guard value.isFinite, range.contains(value) else { return nil }
        self.scale = scale
        self.value = value
    }

    public var proximityToFailure: Double {
        let rir = scale == .rir ? value : 10 - value
        return min(1, max(0, 1 - rir / 5))
    }
}

public enum TrainingContentSource: String, Codable, CaseIterable, Sendable {
    case noop
    case exerciseDB = "exercise_db"
    case imported
    case user
}

public enum TrainingRecordSource: String, Codable, CaseIterable, Sendable {
    case noopNative = "noop_native"
    case hevyAPI = "hevy_api"
    case hevyCSV = "hevy_csv"
    case liftosaur
    case fitNotes = "fitnotes"
    case strong
    case imported
}

public struct TrainingMuscle: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var parentId: String?

    public init(id: String, name: String, parentId: String? = nil) {
        self.id = id
        self.name = name
        self.parentId = parentId
    }
}

public struct TrainingExercise: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var mode: TrainingMeasurementMode
    public var primaryMuscleId: String?
    public var secondaryMuscleIds: [String]
    public var equipmentIds: [String]
    public var instructions: [String]
    public var isUnilateral: Bool
    public var source: TrainingContentSource
    public var sourceId: String?
    public var mediaId: String?

    public init(id: String, title: String, mode: TrainingMeasurementMode,
                primaryMuscleId: String? = nil, secondaryMuscleIds: [String] = [],
                equipmentIds: [String] = [], instructions: [String] = [],
                isUnilateral: Bool = false, source: TrainingContentSource = .noop,
                sourceId: String? = nil, mediaId: String? = nil) {
        self.id = id
        self.title = title
        self.mode = mode
        self.primaryMuscleId = primaryMuscleId
        self.secondaryMuscleIds = Array(Set(secondaryMuscleIds)).sorted()
        self.equipmentIds = Array(Set(equipmentIds)).sorted()
        self.instructions = instructions
        self.isUnilateral = isUnilateral
        self.source = source
        self.sourceId = sourceId
        self.mediaId = mediaId
    }
}

public struct RoutineSetPlan: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var phase: TrainingSetPhase
    public var intensifier: TrainingSetIntensifier
    public var targetWeightKg: Double?
    public var repsMin: Int?
    public var repsMax: Int?
    public var targetDurationS: Int?
    public var targetDistanceM: Double?

    public init(id: UUID = UUID(), phase: TrainingSetPhase = .work,
                intensifier: TrainingSetIntensifier = .none, targetWeightKg: Double? = nil,
                repsMin: Int? = nil, repsMax: Int? = nil, targetDurationS: Int? = nil,
                targetDistanceM: Double? = nil) {
        self.id = id
        self.phase = phase
        self.intensifier = intensifier
        self.targetWeightKg = targetWeightKg
        self.repsMin = repsMin
        self.repsMax = repsMax
        self.targetDurationS = targetDurationS
        self.targetDistanceM = targetDistanceM
    }
}

public enum ProgressionPolicy: String, Codable, CaseIterable, Sendable {
    case off
    case linear
    case doubleProgression = "double_progression"
    case greyskullLP = "greyskull_lp"
    case time
}

public struct ProgressionConfiguration: Codable, Equatable, Sendable {
    public var policy: ProgressionPolicy
    public var weightIncrementKg: Double
    public var durationIncrementS: Int
    public var repsMin: Int
    public var repsMax: Int
    public var failuresBeforeDeload: Int
    public var deloadFactor: Double
    public var bodyweightMaxSets: Int

    public init(policy: ProgressionPolicy = .off, weightIncrementKg: Double = 2.5,
                durationIncrementS: Int = 5, repsMin: Int = 6, repsMax: Int = 10,
                failuresBeforeDeload: Int = 3, deloadFactor: Double = 0.9,
                bodyweightMaxSets: Int = 6) {
        self.policy = policy
        self.weightIncrementKg = max(0.1, weightIncrementKg)
        self.durationIncrementS = max(1, durationIncrementS)
        self.repsMin = max(1, min(repsMin, repsMax))
        self.repsMax = max(self.repsMin, repsMax)
        self.failuresBeforeDeload = max(1, failuresBeforeDeload)
        self.deloadFactor = min(0.95, max(0.5, deloadFactor))
        self.bodyweightMaxSets = max(1, bodyweightMaxSets)
    }
}

public struct RoutineExercise: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var exerciseId: String
    public var sets: [RoutineSetPlan]
    public var restSeconds: Int
    public var supersetId: UUID?
    public var progression: ProgressionConfiguration?
    public var barWeightKg: Double?
    public var note: String?

    public init(id: UUID = UUID(), exerciseId: String, sets: [RoutineSetPlan],
                restSeconds: Int = 120, supersetId: UUID? = nil,
                progression: ProgressionConfiguration? = nil, barWeightKg: Double? = nil,
                note: String? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.sets = sets
        self.restSeconds = max(0, restSeconds)
        self.supersetId = supersetId
        self.progression = progression
        self.barWeightKg = barWeightKg
        self.note = note
    }
}

public struct TrainingRoutine: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var notes: String?
    public var exercises: [RoutineExercise]
    public var defaultProgression: ProgressionConfiguration
    public var excludeFromProgression: Bool
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: UUID = UUID(), title: String, notes: String? = nil,
                exercises: [RoutineExercise] = [],
                defaultProgression: ProgressionConfiguration = .init(),
                excludeFromProgression: Bool = false,
                createdAt: Int = Int(Date().timeIntervalSince1970),
                updatedAt: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id
        self.title = title
        self.notes = notes
        self.exercises = exercises
        self.defaultProgression = defaultProgression
        self.excludeFromProgression = excludeFromProgression
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NativeWorkoutSet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var index: Int
    public var phase: TrainingSetPhase
    public var intensifier: TrainingSetIntensifier
    public var weightKg: Double?
    public var reps: Int?
    public var leftReps: Int?
    public var rightReps: Int?
    public var durationS: Int?
    public var distanceM: Double?
    public var effort: TrainingEffortRating?
    public var isCompleted: Bool

    public init(id: UUID = UUID(), index: Int, phase: TrainingSetPhase = .work,
                intensifier: TrainingSetIntensifier = .none, weightKg: Double? = nil,
                reps: Int? = nil, leftReps: Int? = nil, rightReps: Int? = nil,
                durationS: Int? = nil, distanceM: Double? = nil,
                effort: TrainingEffortRating? = nil, isCompleted: Bool = false) {
        self.id = id
        self.index = index
        self.phase = phase
        self.intensifier = intensifier
        self.weightKg = weightKg
        self.reps = reps
        self.leftReps = leftReps
        self.rightReps = rightReps
        self.durationS = durationS
        self.distanceM = distanceM
        self.effort = effort
        self.isCompleted = isCompleted
    }
}

public struct NativeWorkoutExercise: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var exerciseId: String
    public var routineId: UUID?
    public var sets: [NativeWorkoutSet]
    public var restSeconds: Int
    public var supersetId: UUID?
    public var excludeFromProgression: Bool
    public var note: String?

    public init(id: UUID = UUID(), exerciseId: String, routineId: UUID? = nil,
                sets: [NativeWorkoutSet] = [], restSeconds: Int = 120,
                supersetId: UUID? = nil, excludeFromProgression: Bool = false,
                note: String? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.routineId = routineId
        self.sets = sets
        self.restSeconds = max(0, restSeconds)
        self.supersetId = supersetId
        self.excludeFromProgression = excludeFromProgression
        self.note = note
    }
}

public enum WorkoutDraftState: String, Codable, CaseIterable, Sendable {
    case active
    case paused
}

public struct WorkoutDraft: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var startedAt: Int
    public var plannedDay: String
    public var routineIds: [UUID]
    public var exercises: [NativeWorkoutExercise]
    public var tracker: SessionTrackerAttribution?
    /// Fixed end for a deliberately backdated entry. Live workouts keep this nil.
    public var plannedEndTs: Int?
    public var state: WorkoutDraftState
    public var note: String?
    public var updatedAt: Int

    public init(id: UUID = UUID(), title: String, startedAt: Int,
                plannedDay: String, routineIds: [UUID] = [],
                exercises: [NativeWorkoutExercise] = [],
                tracker: SessionTrackerAttribution? = nil,
                plannedEndTs: Int? = nil,
                state: WorkoutDraftState = .active, note: String? = nil,
                updatedAt: Int? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.plannedDay = plannedDay
        self.routineIds = routineIds
        self.exercises = exercises
        self.tracker = tracker
        self.plannedEndTs = plannedEndTs
        self.state = state
        self.note = note
        self.updatedAt = updatedAt ?? startedAt
    }
}

public struct NativeWorkout: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var startedAt: Int
    public var endedAt: Int
    public var plannedDay: String
    public var routineIds: [UUID]
    public var exercises: [NativeWorkoutExercise]
    public var tracker: SessionTrackerAttribution?
    public var source: TrainingRecordSource
    public var sessionRPE: Double?
    public var note: String?

    public init(id: UUID, title: String, startedAt: Int, endedAt: Int,
                plannedDay: String, routineIds: [UUID], exercises: [NativeWorkoutExercise],
                tracker: SessionTrackerAttribution?, sessionRPE: Double? = nil,
                note: String? = nil, source: TrainingRecordSource = .noopNative) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedDay = plannedDay
        self.routineIds = routineIds
        self.exercises = exercises
        self.tracker = tracker
        self.source = source
        self.sessionRPE = sessionRPE
        self.note = note
    }
}
