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

/// Optional planning details for techniques that split one effort into several segments.
/// The segment rows remain ordinary `NativeWorkoutSet` values linked by their cluster metadata.
public struct SetIntensifierConfiguration: Codable, Equatable, Sendable {
    public var segmentCount: Int
    public var restPauseSeconds: Int?
    public var loadReductionPercent: Double?

    public init(segmentCount: Int = 2, restPauseSeconds: Int? = nil,
                loadReductionPercent: Double? = nil) {
        self.segmentCount = max(1, segmentCount)
        self.restPauseSeconds = restPauseSeconds.map { max(0, $0) }
        self.loadReductionPercent = loadReductionPercent.map { min(100, max(0, $0)) }
    }
}

/// What a stored load number means for this exercise. This is snapshotted into each workout so a
/// later routine or equipment edit cannot reinterpret historical kilograms.
public enum ExerciseLoadSemantics: String, Codable, CaseIterable, Sendable {
    case totalExternalLoad = "total_external_load"
    case perImplement = "per_implement"
    case addedBodyweight = "added_bodyweight"
    case assistance = "assistance"
    case machineValue = "machine_value"
    case bodyweightOnly = "bodyweight_only"
    case notApplicable = "not_applicable"

    public static func defaultValue(for mode: TrainingMeasurementMode,
                                    equipmentIds: [String] = []) -> Self {
        switch mode {
        case .weightedBodyweight: return .addedBodyweight
        case .assistedBodyweight: return .assistance
        case .bodyweightReps: return .bodyweightOnly
        case .duration, .distanceDuration, .repetitions: return .notApplicable
        case .weightReps:
            if equipmentIds.contains("dumbbell") || equipmentIds.contains("kettlebell") {
                return .perImplement
            }
            if equipmentIds.contains("machine") || equipmentIds.contains("cable") {
                return .machineValue
            }
            return .totalExternalLoad
        }
    }
}

/// Equipment facts captured when a workout starts. Exercise definitions may evolve; performed work
/// must retain the meaning it had on the gym floor.
public struct EquipmentSnapshot: Codable, Equatable, Sendable {
    public var equipmentIds: [String]
    public var loadSemantics: ExerciseLoadSemantics
    public var implementCount: Int?
    public var barWeightKg: Double?

    public init(equipmentIds: [String] = [], loadSemantics: ExerciseLoadSemantics,
                implementCount: Int? = nil, barWeightKg: Double? = nil) {
        self.equipmentIds = Array(Set(equipmentIds)).sorted()
        self.loadSemantics = loadSemantics
        self.implementCount = implementCount.map { max(1, $0) }
        self.barWeightKg = barWeightKg.map { max(0, $0) }
    }
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
    /// Identity in the reviewed anatomy catalogue. Provider ids and names resolve onto it, so the same
    /// movement logged from different sources is one exercise without rewriting any stored workout.
    public var canonicalId: String?
    /// Additional names this exercise is known by, used for search and import resolution.
    public var aliases: [String]
    /// The catalogue revision this definition was written for. 0 means "predates versioned content".
    public var contentVersion: Int
    /// Where the definition's text came from, when it did not come from NOOP itself.
    public var attribution: String?
    /// What a recorded weight means for this exercise. Nil keeps the value derived from mode and
    /// equipment, so an older definition behaves exactly as before.
    public var loadSemantics: ExerciseLoadSemantics?

    public var effectiveLoadSemantics: ExerciseLoadSemantics {
        loadSemantics ?? .defaultValue(for: mode, equipmentIds: equipmentIds)
    }

    public init(id: String, title: String, mode: TrainingMeasurementMode,
                primaryMuscleId: String? = nil, secondaryMuscleIds: [String] = [],
                equipmentIds: [String] = [], instructions: [String] = [],
                isUnilateral: Bool = false, source: TrainingContentSource = .noop,
                sourceId: String? = nil, mediaId: String? = nil,
                canonicalId: String? = nil, aliases: [String] = [], contentVersion: Int = 0,
                attribution: String? = nil, loadSemantics: ExerciseLoadSemantics? = nil) {
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
        self.canonicalId = canonicalId
        self.aliases = Array(Set(aliases)).sorted()
        self.contentVersion = contentVersion
        self.attribution = attribution
        self.loadSemantics = loadSemantics
    }

    /// A plan or catalogue archive written before canonical identity decodes unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        mode = try c.decode(TrainingMeasurementMode.self, forKey: .mode)
        primaryMuscleId = try c.decodeIfPresent(String.self, forKey: .primaryMuscleId)
        secondaryMuscleIds = try c.decodeIfPresent([String].self, forKey: .secondaryMuscleIds) ?? []
        equipmentIds = try c.decodeIfPresent([String].self, forKey: .equipmentIds) ?? []
        instructions = try c.decodeIfPresent([String].self, forKey: .instructions) ?? []
        isUnilateral = try c.decodeIfPresent(Bool.self, forKey: .isUnilateral) ?? false
        source = try c.decodeIfPresent(TrainingContentSource.self, forKey: .source) ?? .imported
        sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
        mediaId = try c.decodeIfPresent(String.self, forKey: .mediaId)
        canonicalId = try c.decodeIfPresent(String.self, forKey: .canonicalId)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        contentVersion = try c.decodeIfPresent(Int.self, forKey: .contentVersion) ?? 0
        attribution = try c.decodeIfPresent(String.self, forKey: .attribution)
        loadSemantics = try c.decodeIfPresent(ExerciseLoadSemantics.self, forKey: .loadSemantics)
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
    public var intensifierConfiguration: SetIntensifierConfiguration?

    public init(id: UUID = UUID(), phase: TrainingSetPhase = .work,
                intensifier: TrainingSetIntensifier = .none, targetWeightKg: Double? = nil,
                repsMin: Int? = nil, repsMax: Int? = nil, targetDurationS: Int? = nil,
                targetDistanceM: Double? = nil,
                intensifierConfiguration: SetIntensifierConfiguration? = nil) {
        self.id = id
        self.phase = phase
        self.intensifier = intensifier
        self.targetWeightKg = targetWeightKg
        self.repsMin = repsMin
        self.repsMax = repsMax
        self.targetDurationS = targetDurationS
        self.targetDistanceM = targetDistanceM
        self.intensifierConfiguration = intensifierConfiguration
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
    /// Optional effort boundary for a routine. Absent means recorded RIR/RPE is informative but cannot
    /// change success or failure of an otherwise completed prescription.
    public var targetEffort: TrainingEffortRating?

    public init(policy: ProgressionPolicy = .off, weightIncrementKg: Double = 2.5,
                durationIncrementS: Int = 5, repsMin: Int = 6, repsMax: Int = 10,
                failuresBeforeDeload: Int = 3, deloadFactor: Double = 0.9,
                bodyweightMaxSets: Int = 6, targetEffort: TrainingEffortRating? = nil) {
        self.policy = policy
        self.weightIncrementKg = max(0.1, weightIncrementKg)
        self.durationIncrementS = max(1, durationIncrementS)
        self.repsMin = max(1, min(repsMin, repsMax))
        self.repsMax = max(self.repsMin, repsMax)
        self.failuresBeforeDeload = max(1, failuresBeforeDeload)
        self.deloadFactor = min(0.95, max(0.5, deloadFactor))
        self.bodyweightMaxSets = max(1, bodyweightMaxSets)
        self.targetEffort = targetEffort
    }
}

public struct RoutineExercise: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var exerciseId: String
    public var sets: [RoutineSetPlan]
    public var restSeconds: Int
    public var warmupRestSeconds: Int?
    public var supersetId: UUID?
    public var progression: ProgressionConfiguration?
    public var barWeightKg: Double?
    public var loadSemantics: ExerciseLoadSemantics?
    public var note: String?

    public init(id: UUID = UUID(), exerciseId: String, sets: [RoutineSetPlan],
                restSeconds: Int = 120, warmupRestSeconds: Int? = nil, supersetId: UUID? = nil,
                progression: ProgressionConfiguration? = nil, barWeightKg: Double? = nil,
                loadSemantics: ExerciseLoadSemantics? = nil,
                note: String? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.sets = sets
        self.restSeconds = max(0, restSeconds)
        self.warmupRestSeconds = warmupRestSeconds.map { max(0, $0) }
        self.supersetId = supersetId
        self.progression = progression
        self.barWeightKg = barWeightKg
        self.loadSemantics = loadSemantics
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
    public var targetDurationS: Int?
    public var durationS: Int?
    public var distanceM: Double?
    public var effort: TrainingEffortRating?
    public var isCompleted: Bool
    public var clusterId: UUID?
    public var parentSetId: UUID?
    public var segmentIndex: Int?

    public init(id: UUID = UUID(), index: Int, phase: TrainingSetPhase = .work,
                intensifier: TrainingSetIntensifier = .none, weightKg: Double? = nil,
                reps: Int? = nil, leftReps: Int? = nil, rightReps: Int? = nil,
                targetDurationS: Int? = nil, durationS: Int? = nil, distanceM: Double? = nil,
                effort: TrainingEffortRating? = nil, isCompleted: Bool = false,
                clusterId: UUID? = nil, parentSetId: UUID? = nil, segmentIndex: Int? = nil) {
        self.id = id
        self.index = index
        self.phase = phase
        self.intensifier = intensifier
        self.weightKg = weightKg
        self.reps = reps
        self.leftReps = leftReps
        self.rightReps = rightReps
        self.targetDurationS = targetDurationS
        self.durationS = durationS
        self.distanceM = distanceM
        self.effort = effort
        self.isCompleted = isCompleted
        self.clusterId = clusterId
        self.parentSetId = parentSetId
        self.segmentIndex = segmentIndex
    }

    public var isClusterSegment: Bool { parentSetId != nil }
}

/// The relationship of one drop-set or rest-pause row to its originating set.
public struct SetSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let setId: UUID
    public let parentSetId: UUID
    public let index: Int

    public init(id: UUID = UUID(), setId: UUID, parentSetId: UUID, index: Int) {
        self.id = id
        self.setId = setId
        self.parentSetId = parentSetId
        self.index = max(1, index)
    }
}

/// One logical working effort and any technique segments that belong to it.
public struct SetCluster: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let originSetId: UUID
    public let segmentSetIds: [UUID]

    public init(id: UUID, originSetId: UUID, segmentSetIds: [UUID]) {
        self.id = id
        self.originSetId = originSetId
        self.segmentSetIds = segmentSetIds
    }
}

public struct NativeWorkoutExercise: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var exerciseId: String
    public var routineId: UUID?
    public var sets: [NativeWorkoutSet]
    public var restSeconds: Int
    public var warmupRestSeconds: Int?
    public var supersetId: UUID?
    public var excludeFromProgression: Bool
    public var equipmentSnapshot: EquipmentSnapshot?
    public var note: String?
    /// Why the prefilled targets are what they are, shown beside the exercise while logging. Draft-only
    /// context: optional so older drafts decode, and not part of the finished workout's stored rows.
    public var progressionReason: ProgressionReason?

    public init(id: UUID = UUID(), exerciseId: String, routineId: UUID? = nil,
                sets: [NativeWorkoutSet] = [], restSeconds: Int = 120,
                warmupRestSeconds: Int? = nil, supersetId: UUID? = nil,
                excludeFromProgression: Bool = false,
                equipmentSnapshot: EquipmentSnapshot? = nil,
                note: String? = nil, progressionReason: ProgressionReason? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.routineId = routineId
        self.sets = sets
        self.restSeconds = max(0, restSeconds)
        self.warmupRestSeconds = warmupRestSeconds.map { max(0, $0) }
        self.supersetId = supersetId
        self.excludeFromProgression = excludeFromProgression
        self.equipmentSnapshot = equipmentSnapshot
        self.note = note
        self.progressionReason = progressionReason
    }
}

public enum ActiveStrengthWorkoutState: String, Codable, CaseIterable, Sendable {
    case active
    case paused
    case interrupted
    case completing
}

public typealias WorkoutDraftState = ActiveStrengthWorkoutState

public struct ActiveExerciseCursor: Codable, Equatable, Sendable {
    public var exerciseId: UUID?
    public var setId: UUID?

    public init(exerciseId: UUID? = nil, setId: UUID? = nil) {
        self.exerciseId = exerciseId
        self.setId = setId
    }
}

public enum WorkoutTimerKind: String, Codable, CaseIterable, Sendable {
    case rest
    case restPause = "rest_pause"
    case timedSet = "timed_set"
}

public struct WorkoutTimerState: Codable, Equatable, Sendable {
    public var kind: WorkoutTimerKind
    public var exerciseId: UUID?
    public var setId: UUID?
    public var startedAtTs: Int
    public var endsAtTs: Int
    public var pausedRemainingSeconds: Int?

    public init(kind: WorkoutTimerKind, exerciseId: UUID? = nil, setId: UUID? = nil,
                startedAtTs: Int, endsAtTs: Int, pausedRemainingSeconds: Int? = nil) {
        self.kind = kind
        self.exerciseId = exerciseId
        self.setId = setId
        self.startedAtTs = startedAtTs
        self.endsAtTs = max(startedAtTs, endsAtTs)
        self.pausedRemainingSeconds = pausedRemainingSeconds.map { max(0, $0) }
    }
}

public enum WorkoutInterruptionReason: String, Codable, CaseIterable, Sendable {
    case userPaused = "user_paused"
    case appBackgrounded = "app_backgrounded"
    case systemInterruption = "system_interruption"
    case trackerDisconnected = "tracker_disconnected"
    case appTerminated = "app_terminated"
    case unknown
}

public enum WorkoutPhysiologyProvider: String, Codable, CaseIterable, Sendable {
    case noopBand = "noop_band"
    case appleWatch = "apple_watch"
    case externalTracker = "external_tracker"
    case none
}

public struct WorkoutPauseInterval: Codable, Equatable, Sendable {
    public var startedAtTs: Int
    public var endedAtTs: Int?

    public init(startedAtTs: Int, endedAtTs: Int? = nil) {
        self.startedAtTs = startedAtTs
        self.endedAtTs = endedAtTs
    }
}

public enum WorkoutCompletionState: String, Codable, CaseIterable, Sendable {
    case empty
    case partial
    case complete
}

public struct WorkoutCompletionValidation: Codable, Equatable, Sendable {
    public let state: WorkoutCompletionState
    public let completedSetCount: Int
    public let incompleteSetCount: Int
    public let completedExerciseCount: Int

    public init(state: WorkoutCompletionState, completedSetCount: Int,
                incompleteSetCount: Int, completedExerciseCount: Int) {
        self.state = state
        self.completedSetCount = completedSetCount
        self.incompleteSetCount = incompleteSetCount
        self.completedExerciseCount = completedExerciseCount
    }

    public var canComplete: Bool { completedSetCount > 0 }
}

/// Facts shown after a saved native workout. This is intentionally independent of Training Load:
/// it describes this session, while load interpretation remains in its dedicated subsystem.
public struct NativeWorkoutSummary: Equatable, Sendable {
    public let exerciseCount: Int
    public let workingSetCount: Int
    public let warmupSetCount: Int
    public let loadedVolumeKg: Double
    public let elapsedDurationS: Int
    public let activeDurationS: Int
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
    public var cursor: ActiveExerciseCursor?
    public var timer: WorkoutTimerState?
    public var interruptionReason: WorkoutInterruptionReason?
    public var lifecycleVersion: Int?
    public var trainingSessionId: UUID?
    public var physiologyProvider: WorkoutPhysiologyProvider?
    public var physiologyComponentKey: String?
    public var lastConfirmedWatchRevision: Int?
    public var pauseIntervals: [WorkoutPauseInterval]?
    public var note: String?
    public var updatedAt: Int

    public init(id: UUID = UUID(), title: String, startedAt: Int,
                plannedDay: String, routineIds: [UUID] = [],
                exercises: [NativeWorkoutExercise] = [],
                tracker: SessionTrackerAttribution? = nil,
                plannedEndTs: Int? = nil,
                state: WorkoutDraftState = .active, note: String? = nil,
                cursor: ActiveExerciseCursor? = nil, timer: WorkoutTimerState? = nil,
                interruptionReason: WorkoutInterruptionReason? = nil,
                lifecycleVersion: Int? = 1,
                trainingSessionId: UUID? = nil,
                physiologyProvider: WorkoutPhysiologyProvider? = nil,
                physiologyComponentKey: String? = nil,
                lastConfirmedWatchRevision: Int? = nil,
                pauseIntervals: [WorkoutPauseInterval]? = nil,
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
        self.cursor = cursor
        self.timer = timer
        self.interruptionReason = interruptionReason
        self.lifecycleVersion = lifecycleVersion
        self.trainingSessionId = trainingSessionId
        self.physiologyProvider = physiologyProvider
        self.physiologyComponentKey = physiologyComponentKey
        self.lastConfirmedWatchRevision = lastConfirmedWatchRevision
        self.pauseIntervals = pauseIntervals
        self.note = note
        self.updatedAt = updatedAt ?? startedAt
    }
}

public enum SessionRPEOrigin: String, Codable, CaseIterable, Sendable {
    case workoutCompletion = "workout_completion"
    case later
    case legacyUnknown = "legacy_unknown"
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
    public var sessionRPEOrigin: SessionRPEOrigin?
    public var note: String?
    public var trainingSessionId: UUID?
    public var physiologyProvider: WorkoutPhysiologyProvider?
    public var physiologyComponentKey: String?
    public var hrCoverage: Double?
    public var lifecycleVersion: Int?
    /// Pauses recorded by the active-workout lifecycle, retained so the summary can distinguish
    /// elapsed from active time without maintaining a second timer history.
    public var pauseIntervals: [WorkoutPauseInterval]?

    public init(id: UUID, title: String, startedAt: Int, endedAt: Int,
                plannedDay: String, routineIds: [UUID], exercises: [NativeWorkoutExercise],
                tracker: SessionTrackerAttribution?, sessionRPE: Double? = nil,
                sessionRPEOrigin: SessionRPEOrigin? = nil,
                note: String? = nil, source: TrainingRecordSource = .noopNative,
                pauseIntervals: [WorkoutPauseInterval]? = nil) {
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
        self.sessionRPEOrigin = sessionRPE == nil ? nil : (sessionRPEOrigin ?? .legacyUnknown)
        self.note = note
        self.trainingSessionId = nil
        self.physiologyProvider = nil
        self.physiologyComponentKey = nil
        self.hrCoverage = nil
        self.lifecycleVersion = nil
        self.pauseIntervals = pauseIntervals
    }


    public init(id: UUID, title: String, startedAt: Int, endedAt: Int,
                plannedDay: String, routineIds: [UUID], exercises: [NativeWorkoutExercise],
                tracker: SessionTrackerAttribution?, sessionRPE: Double? = nil,
                sessionRPEOrigin: SessionRPEOrigin? = nil, note: String? = nil,
                source: TrainingRecordSource = .noopNative, trainingSessionId: UUID?,
                physiologyProvider: WorkoutPhysiologyProvider?, physiologyComponentKey: String?,
                hrCoverage: Double?, lifecycleVersion: Int?,
                pauseIntervals: [WorkoutPauseInterval]? = nil) {
        self.init(id: id, title: title, startedAt: startedAt, endedAt: endedAt,
                  plannedDay: plannedDay, routineIds: routineIds, exercises: exercises,
                  tracker: tracker, sessionRPE: sessionRPE, sessionRPEOrigin: sessionRPEOrigin,
                  note: note, source: source)
        self.trainingSessionId = trainingSessionId
        self.physiologyProvider = physiologyProvider
        self.physiologyComponentKey = physiologyComponentKey
        self.hrCoverage = hrCoverage.map { min(1, max(0, $0)) }
        self.lifecycleVersion = lifecycleVersion
        self.pauseIntervals = pauseIntervals
    }
}
