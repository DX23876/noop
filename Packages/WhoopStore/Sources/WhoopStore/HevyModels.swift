import Foundation

/// Provenance for a detailed strength session. API and file imports share the same model so every
/// consumer can work offline without losing exercise/set detail.
public enum StrengthDataSource: String, Codable, Sendable, CaseIterable {
    case noopNative = "noop_native"
    case hevyAPI = "hevy_api"
    case hevyCSV = "hevy_csv"
    case liftosaur
    case fitNotes = "fitnotes"
    case strong
    case imported
    case manual
}

public struct StrengthExerciseMapping: Equatable, Codable, Sendable {
    public let normalizedTitle: String
    public let displayTitle: String
    public let primaryMuscleGroup: HevyMuscleGroup
    public let secondaryMuscleGroups: [HevyMuscleGroup]

    public init(normalizedTitle: String, displayTitle: String, primaryMuscleGroup: HevyMuscleGroup,
                secondaryMuscleGroups: [HevyMuscleGroup]) {
        self.normalizedTitle = normalizedTitle
        self.displayTitle = displayTitle
        self.primaryMuscleGroup = primaryMuscleGroup
        self.secondaryMuscleGroups = secondaryMuscleGroups
    }
}

// MARK: - Hevy strength models (v54)
//
// The value types behind NOOP's Hevy lane: a logged strength session down to the individual set, plus
// the exercise catalogue that gives a set its meaning (which muscle a movement trains, what equipment
// it needs).
//
// WHY THEY LIVE IN WhoopStore RATHER THAN StrandImport: two packages need them and neither depends on
// the other. `StrandImport` parses the API's JSON into these; `StrandAnalytics` derives working-set
// counts, volume and e1RM from them. Both already depend on WhoopStore, so this is the one place that
// does not force a duplicate model — and it is where they are persisted anyway, exactly like
// `WorkoutRow` and `DailyMetric`.
//
// EVERY ENUM HAS AN `other` CASE AND EVERY DECODE FALLS BACK TO IT. Hevy's own API documentation says
// the project may "completely change the structure or abandon" it; a strict decode would then turn a
// renamed set type into a failed sync rather than one unclassified set.

/// What a logged set WAS, per Hevy's `type` field.
///
/// `warmup` is the one that changes arithmetic: it is excluded from working sets, volume and e1RM
/// everywhere. `dropset` and `failure` are working sets — they are harder than a normal set, not
/// softer, so dropping them would understate the session.
public enum HevySetType: String, Codable, Sendable, CaseIterable {
    case normal, warmup, dropset, failure
    case restPause = "rest_pause"
    case amrap
    /// A type this build does not know. Counted AS WORK, deliberately: the only type that must not
    /// count is `warmup`, and guessing that an unrecognised label means "not real work" would silently
    /// shrink a session. An unknown type is far more likely to be a new kind of working set.
    case other

    public static func parse(_ raw: String?) -> HevySetType {
        guard let raw = raw?.lowercased() else { return .other }
        return HevySetType(rawValue: raw) ?? .other
    }

    /// True for every set that counts as work. The single place this distinction is made.
    public var countsAsWork: Bool { self != .warmup }
}

/// The muscle a movement trains: Hevy's `MuscleGroup` enum (20 values as of this writing), plus
/// `serratus`, `obliques`, `hipFlexors` and `shins`, which NOOP's own anatomy distinguishes and Hevy
/// does not. An import from Hevy never produces those four; they come from `forTrainingMuscle`.
public enum HevyMuscleGroup: String, Codable, Sendable, CaseIterable {
    case abdominals, shoulders, biceps, triceps, forearms, quadriceps, hamstrings, calves
    case glutes, abductors, adductors, lats, upperBack = "upper_back", traps
    case lowerBack = "lower_back", chest, cardio, neck, fullBody = "full_body", other
    case serratus, obliques, hipFlexors = "hip_flexors", shins

    public static func parse(_ raw: String?) -> HevyMuscleGroup {
        guard let raw = raw?.lowercased() else { return .other }
        return HevyMuscleGroup(rawValue: raw) ?? .other
    }

    /// The groups Hevy itself uses — what a search of a synced Hevy catalogue can actually match.
    public static let hevyGroups: [HevyMuscleGroup] = allCases.filter {
        ![.serratus, .obliques, .hipFlexors, .shins].contains($0)
    }

    /// The group one of NOOP's muscle ids (`TrainingMuscleCatalog`) is counted under. The only place
    /// that mapping is written: the Strength analytics, the muscle model and the native-workout
    /// projection all read it, so a muscle cannot land in one group on one screen and another elsewhere.
    public static func forTrainingMuscle(_ id: String?) -> HevyMuscleGroup {
        switch id {
        case "chest", "upper_chest", "lower_chest": return .chest
        case "front_delts", "side_delts", "rear_delts", "rotator_cuff", "shoulders": return .shoulders
        case "serratus": return .serratus
        case "triceps": return .triceps
        case "biceps": return .biceps
        case "forearms": return .forearms
        case "lats": return .lats
        case "upper_back", "rhomboids": return .upperBack
        case "traps", "upper_traps", "lower_traps": return .traps
        case "neck": return .neck
        case "lower_back": return .lowerBack
        case "abdominals", "upper_abs", "lower_abs", "core": return .abdominals
        case "obliques": return .obliques
        case "quadriceps", "inner_quadriceps", "outer_quadriceps": return .quadriceps
        case "hamstrings": return .hamstrings
        case "glutes": return .glutes
        case "abductors": return .abductors
        case "adductors": return .adductors
        case "hip_flexors": return .hipFlexors
        case "calves": return .calves
        case "tibialis": return .shins
        default: return .other
        }
    }

    /// The muscle ids a group stands for when only the group is known — a Hevy template or a mapping the
    /// wearer chose. Deliberately the main heads only (no rotator cuff under shoulders): attributing a
    /// group-level set to every small muscle in it would claim detail the source never had.
    public var trainingMuscleIds: [String] {
        switch self {
        case .abdominals: return ["abdominals"]
        case .shoulders: return ["front_delts", "side_delts", "rear_delts"]
        case .biceps: return ["biceps"]
        case .triceps: return ["triceps"]
        case .forearms: return ["forearms"]
        case .quadriceps: return ["quadriceps"]
        case .hamstrings: return ["hamstrings"]
        case .calves: return ["calves"]
        case .glutes: return ["glutes"]
        case .abductors: return ["abductors"]
        case .adductors: return ["adductors"]
        case .lats: return ["lats"]
        case .upperBack: return ["upper_back"]
        case .traps: return ["traps"]
        case .lowerBack: return ["lower_back"]
        case .chest: return ["chest"]
        case .neck: return ["neck"]
        case .serratus: return ["serratus"]
        case .obliques: return ["obliques"]
        case .hipFlexors: return ["hip_flexors"]
        case .shins: return ["tibialis"]
        case .cardio, .fullBody, .other: return []
        }
    }

    /// A human label. Deliberately NOT localized here: this is a storage/analytics type, and the
    /// display layer localizes. Keeping it locale-stable means a muscle-group key never varies by
    /// the user's language, which is what a grouping key must guarantee.
    public var label: String {
        switch self {
        case .upperBack:  return "Upper back"
        case .lowerBack:  return "Lower back"
        case .fullBody:   return "Full body"
        case .hipFlexors: return "Hip flexors"
        default:          return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// What a movement is performed with, per Hevy's `EquipmentCategory`.
public enum HevyEquipment: String, Codable, Sendable, CaseIterable {
    case none, barbell, dumbbell, kettlebell, machine, plate
    case resistanceBand = "resistance_band", suspension, other

    public static func parse(_ raw: String?) -> HevyEquipment {
        guard let raw = raw?.lowercased() else { return .other }
        return HevyEquipment(rawValue: raw) ?? .other
    }
}

/// One logged set. Every measurement is optional because Hevy's own schema declares them nullable —
/// a bodyweight set has no `weightKg`, a plank has no `reps`, and most sets carry no `rpe` at all.
public struct HevySet: Equatable, Codable, Sendable {
    /// Order within the exercise, as Hevy numbers it.
    public let index: Int
    public let type: HevySetType
    public let weightKg: Double?
    public let reps: Int?
    public let distanceM: Double?
    public let durationS: Double?
    /// Rate of perceived exertion as the user logged it, typically 6–10 in half steps. NEVER imputed:
    /// an absent RPE means the user did not rate that set, which is different from an easy one.
    public let rpe: Double?
    /// Hevy's catch-all numeric slot (floors/steps on stair machines today).
    public let customMetric: Double?
    /// Optional native relationship metadata. Imported providers leave these nil. The analytics layer
    /// can identify technique segments without treating them as unrelated ordinary sets.
    public let clusterId: String?
    public let parentSetId: String?
    public let segmentIndex: Int?

    public init(index: Int, type: HevySetType, weightKg: Double?, reps: Int?,
                distanceM: Double?, durationS: Double?, rpe: Double?, customMetric: Double?,
                clusterId: String? = nil, parentSetId: String? = nil, segmentIndex: Int? = nil) {
        self.index = index
        self.type = type
        self.weightKg = weightKg
        self.reps = reps
        self.distanceM = distanceM
        self.durationS = durationS
        self.rpe = rpe
        self.customMetric = customMetric
        self.clusterId = clusterId
        self.parentSetId = parentSetId
        self.segmentIndex = segmentIndex
    }

    public var isTechniqueSegment: Bool { parentSetId != nil }

    /// The set's contribution to volume load, in kilogram-reps, or nil when it has no weight×reps to
    /// contribute (a warmup, a bodyweight set, a timed hold). Nil rather than 0 so a caller can tell
    /// "no volume claimed" from "genuinely zero".
    public var volumeLoadKg: Double? {
        guard type.countsAsWork, let w = weightKg, w > 0, let r = reps, r > 0 else { return nil }
        return w * Double(r)
    }
}

/// One exercise within a logged workout, with its sets in order.
public struct HevyExercise: Equatable, Codable, Sendable {
    /// Order within the workout, as Hevy numbers it.
    public let index: Int
    public let title: String
    /// Joins to `HevyExerciseTemplate.id`. Optional because a workout can in principle name an
    /// exercise this account's catalogue no longer holds; the analytics then simply cannot attribute
    /// a muscle group to it, which is honest.
    public let templateId: String?
    /// Non-nil when this exercise is part of a superset; exercises sharing a value are one superset.
    public let supersetId: Int?
    public let notes: String?
    public let sets: [HevySet]

    public init(index: Int, title: String, templateId: String?, supersetId: Int?,
                notes: String?, sets: [HevySet]) {
        self.index = index
        self.title = title
        self.templateId = templateId
        self.supersetId = supersetId
        self.notes = notes
        self.sets = sets
    }

    /// Sets that count as work — everything but warmups.
    public var workingSets: [HevySet] { sets.filter { $0.type.countsAsWork } }
}

/// One logged Hevy workout. `id` is Hevy's own UUID and the primary key throughout: it is what makes
/// a re-sync idempotent and what a `deleted` event names.
public struct HevyWorkout: Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    /// The routine this session was performed from, when it came from one.
    public let routineId: String?
    /// Hevy calls this `description`; renamed here because `description` collides with
    /// `CustomStringConvertible` on every Swift type.
    public let notes: String?
    /// Unix seconds. Hevy sends ISO-8601; the parser converts once so every consumer compares integers.
    public let startTs: Int
    public let endTs: Int
    /// Unix seconds of Hevy's own `updated_at`. This is the incremental-sync cursor: the coordinator
    /// remembers the largest value it has seen and asks `events?since=` for anything newer.
    public let updatedAtTs: Int
    public let createdAtTs: Int
    public let exercises: [HevyExercise]
    public let source: StrengthDataSource

    public init(id: String, title: String, routineId: String?, notes: String?,
                startTs: Int, endTs: Int, updatedAtTs: Int, createdAtTs: Int,
                exercises: [HevyExercise], source: StrengthDataSource = .hevyAPI) {
        self.id = id
        self.title = title
        self.routineId = routineId
        self.notes = notes
        self.startTs = startTs
        self.endTs = endTs
        self.updatedAtTs = updatedAtTs
        self.createdAtTs = createdAtTs
        self.exercises = exercises
        self.source = source
    }

    public var durationS: Double? {
        let d = Double(endTs - startTs)
        return d > 0 ? d : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, routineId, notes, startTs, endTs, updatedAtTs, createdAtTs, exercises, source
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        routineId = try values.decodeIfPresent(String.self, forKey: .routineId)
        notes = try values.decodeIfPresent(String.self, forKey: .notes)
        startTs = try values.decode(Int.self, forKey: .startTs)
        endTs = try values.decode(Int.self, forKey: .endTs)
        updatedAtTs = try values.decode(Int.self, forKey: .updatedAtTs)
        createdAtTs = try values.decode(Int.self, forKey: .createdAtTs)
        exercises = try values.decode([HevyExercise].self, forKey: .exercises)
        source = try values.decodeIfPresent(StrengthDataSource.self, forKey: .source) ?? .hevyAPI
    }
}

/// One entry of the exercise catalogue: what a movement is, and what it trains.
///
/// The catalogue is mirrored IN FULL rather than only for exercises the user has already performed.
/// A coach that can only name movements already in the history could never suggest a new one, which
/// is most of the point of asking it for a routine.
public struct HevyExerciseTemplate: Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    /// Hevy's own type token, e.g. "weight_reps", "reps_only", "duration". Kept as a raw string: the
    /// API does not enumerate it, and inventing an enum would mean guessing at values.
    public let type: String
    public let primaryMuscleGroup: HevyMuscleGroup
    /// Movements also involve these, less directly. Reported SEPARATELY from the primary group and
    /// never folded into it with a weighting factor — see `StrengthSession`.
    public let secondaryMuscleGroups: [HevyMuscleGroup]
    public let equipment: HevyEquipment
    public let isCustom: Bool

    public init(id: String, title: String, type: String, primaryMuscleGroup: HevyMuscleGroup,
                secondaryMuscleGroups: [HevyMuscleGroup], equipment: HevyEquipment, isCustom: Bool) {
        self.id = id
        self.title = title
        self.type = type
        self.primaryMuscleGroup = primaryMuscleGroup
        self.secondaryMuscleGroups = secondaryMuscleGroups
        self.equipment = equipment
        self.isCustom = isCustom
    }

    /// True when a set of this exercise carries both a weight and a rep count — the only shape an
    /// e1RM estimate is defined for.
    public var isWeightAndReps: Bool { type.lowercased() == "weight_reps" }
}

/// One saved routine (a plan, not a performed session).
///
/// `rawJSON` is the server's own response, kept verbatim. Hevy's `PUT /v1/routines/{id}` is a FULL
/// REPLACE, not a patch: anything omitted from the body is dropped. Editing a routine therefore means
/// rebuilding the whole document, and a field this build does not model would be silently deleted
/// unless the original is still available to merge into. This is that original.
public struct HevyRoutine: Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let folderId: Int?
    public let notes: String?
    public let updatedAtTs: Int
    public let exercises: [HevyExercise]
    public let rawJSON: String

    public init(id: String, title: String, folderId: Int?, notes: String?,
                updatedAtTs: Int, exercises: [HevyExercise], rawJSON: String) {
        self.id = id
        self.title = title
        self.folderId = folderId
        self.notes = notes
        self.updatedAtTs = updatedAtTs
        self.exercises = exercises
        self.rawJSON = rawJSON
    }
}

/// One entry from `GET /v1/workouts/events?since=` — the incremental feed.
///
/// Deletes matter as much as updates: a workout the user removed in Hevy has to disappear here too,
/// including the `WorkoutRow` that mirrors it, or the app keeps showing a session that no longer
/// exists and keeps scoring the day around it.
public enum HevyWorkoutEvent: Equatable, Sendable {
    case updated(HevyWorkout)
    case deleted(id: String, atTs: Int)

    /// The `updated_at`/`deleted_at` instant this event carries, which is what advances the cursor.
    public var timestamp: Int {
        switch self {
        case .updated(let w):    return w.updatedAtTs
        case .deleted(_, let t): return t
        }
    }
}
