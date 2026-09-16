import Foundation

/// A movement family used for routine previews and filtering. It is descriptive metadata and does
/// not alter the load assigned to a completed set.
public enum TrainingMovementPattern: String, Codable, CaseIterable, Sendable {
    case horizontalPush, verticalPush, horizontalPull, verticalPull
    case squat, hinge, lunge, kneeFlexion, kneeExtension
    case elbowFlexion, elbowExtension, shoulderIsolation
    case calfRaise, carry, trunkFlexion, trunkExtension, trunkStability, other
}

public enum ExerciseMappingConfidence: String, Codable, Sendable {
    case reviewed
    case sourceFallback
    case userConfirmed
}

/// Reviewed anatomy shipped with the app. Provider names and aliases are lookup keys only; workout
/// history keeps the source's original exercise name and set data.
public struct ExerciseAnatomy: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let mode: TrainingMeasurementMode
    public let movementPattern: TrainingMovementPattern
    public let primaryMuscleIds: [String]
    public let secondaryMuscleIds: [String]
    public let stabilizerMuscleIds: [String]
    public let equipmentIds: [String]
    public let aliases: [String]
    /// Stable identifiers where a provider publishes one. Keys use `TrainingRecordSource.rawValue`.
    public let providerIds: [String: String]
    public let confidence: ExerciseMappingConfidence

    /// Browsing category and body region are derived, never stored twice: the muscles are the source
    /// of truth, so a filter can never disagree with the analytics.
    public var category: TrainingMovementPattern { movementPattern }
    public var bodyRegion: TrainingBodyRegion { TrainingBodyRegion.forMuscles(primaryMuscleIds) }

    public init(id: String, title: String, mode: TrainingMeasurementMode,
                movementPattern: TrainingMovementPattern, primaryMuscleIds: [String],
                secondaryMuscleIds: [String] = [], stabilizerMuscleIds: [String] = [],
                equipmentIds: [String] = [], aliases: [String] = [],
                providerIds: [String: String] = [:],
                confidence: ExerciseMappingConfidence = .reviewed) {
        self.id = id
        self.title = title
        self.mode = mode
        self.movementPattern = movementPattern
        self.primaryMuscleIds = Self.unique(primaryMuscleIds)
        self.secondaryMuscleIds = Self.unique(secondaryMuscleIds)
        self.stabilizerMuscleIds = Self.unique(stabilizerMuscleIds)
        self.equipmentIds = Self.unique(equipmentIds)
        self.aliases = Self.unique(aliases)
        self.providerIds = providerIds
        self.confidence = confidence
    }

    private static func unique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

/// Versioned, rights-clean mapping generated during development and reviewed before shipping.
/// Runtime lookup is entirely local and never sends exercise names or workouts to an AI service.
public enum ExerciseAnatomyCatalog {
    public static let version = 1

    public static let all: [ExerciseAnatomy] = [
        e("barbell-bench-press", "Barbell Bench Press", .weightReps, .horizontalPush,
          ["chest"], ["triceps", "front_delts"], ["serratus"], ["barbell", "bench"],
          ["bench press", "flat bench press", "bankdrücken", "langhantel bankdrücken"]),
        e("dumbbell-bench-press", "Dumbbell Bench Press", .weightReps, .horizontalPush,
          ["chest"], ["triceps", "front_delts"], ["serratus"], ["dumbbell", "bench"],
          ["dumbbell press", "kurzhantel bankdrücken"]),
        e("incline-press", "Incline Press", .weightReps, .horizontalPush,
          ["upper_chest"], ["triceps", "front_delts"], ["serratus"], ["bench"],
          ["incline bench press", "incline dumbbell press", "schrägbankdrücken", "incline chest press"]),
        e("decline-press", "Decline Press", .weightReps, .horizontalPush,
          ["lower_chest"], ["triceps", "front_delts"], [], ["bench"],
          ["decline bench press", "negativ bankdrücken"]),
        e("chest-press", "Chest Press", .weightReps, .horizontalPush,
          ["chest"], ["triceps", "front_delts"], [], ["machine"],
          ["machine chest press", "brustpresse"]),
        e("chest-fly", "Chest Fly", .weightReps, .horizontalPush,
          ["chest"], ["front_delts"], [], ["cable"],
          ["cable fly", "dumbbell fly", "pec deck", "butterfly", "fliegende"]),
        e("push-up", "Push-up", .bodyweightReps, .horizontalPush,
          ["chest"], ["triceps", "front_delts"], ["serratus", "abdominals"], ["bodyweight"],
          ["push up", "press up", "liegestütz", "liegestütze"]),
        e("dip", "Dip", .bodyweightReps, .horizontalPush,
          ["lower_chest", "triceps"], ["front_delts"], ["serratus"], ["bodyweight"],
          ["chest dip", "parallel bar dip", "dips"]),
        e("overhead-press", "Overhead Press", .weightReps, .verticalPush,
          ["front_delts"], ["triceps", "side_delts"], ["upper_traps", "abdominals"], ["barbell"],
          ["military press", "shoulder press", "schulterdrücken", "standing overhead press"]),
        e("lateral-raise", "Lateral Raise", .weightReps, .shoulderIsolation,
          ["side_delts"], [], ["upper_traps"], ["dumbbell"],
          ["side lateral raise", "cable lateral raise", "seitheben"]),
        e("rear-delt-fly", "Rear Delt Fly", .weightReps, .shoulderIsolation,
          ["rear_delts"], ["rhomboids", "upper_back"], ["rotator_cuff"], ["dumbbell"],
          ["reverse fly", "reverse pec deck", "rear delt raise", "butterfly reverse"]),
        e("face-pull", "Face Pull", .weightReps, .horizontalPull,
          ["rear_delts"], ["rhomboids", "upper_back", "lower_traps"], ["rotator_cuff"], ["cable"],
          ["facepull", "face pulls"]),
        e("triceps-pushdown", "Triceps Pushdown", .weightReps, .elbowExtension,
          ["triceps"], [], [], ["cable"],
          ["cable pushdown", "tricep pushdown", "trizepsdrücken"]),
        e("triceps-extension", "Triceps Extension", .weightReps, .elbowExtension,
          ["triceps"], [], ["front_delts"], ["dumbbell"],
          ["overhead triceps extension", "skull crusher", "lying triceps extension", "french press"]),
        e("pull-up", "Pull-up", .bodyweightReps, .verticalPull,
          ["lats"], ["biceps", "upper_back"], ["forearms", "abdominals"], ["bodyweight", "bar"],
          ["pull up", "chin up", "chin-up", "klimmzug", "klimmzüge"]),
        e("weighted-pull-up", "Weighted Pull-up", .weightedBodyweight, .verticalPull,
          ["lats"], ["biceps", "upper_back"], ["forearms", "abdominals"], ["bar", "weight-belt"],
          ["weighted pull up", "weighted chin up", "klimmzug mit zusatzgewicht"]),
        e("assisted-pull-up", "Assisted Pull-up", .assistedBodyweight, .verticalPull,
          ["lats"], ["biceps", "upper_back"], ["forearms"], ["machine"],
          ["assisted pull up", "band assisted pull up", "unterstützter klimmzug"]),
        e("weighted-dip", "Weighted Dip", .weightedBodyweight, .horizontalPush,
          ["lower_chest", "triceps"], ["front_delts"], ["serratus"], ["weight-belt"],
          ["weighted dips", "dip with added weight", "dips mit zusatzgewicht"]),
        e("assisted-dip", "Assisted Dip", .assistedBodyweight, .horizontalPush,
          ["lower_chest", "triceps"], ["front_delts"], [], ["machine"],
          ["assisted dips", "unterstützte dips"]),
        e("lat-pulldown", "Lat Pulldown", .weightReps, .verticalPull,
          ["lats"], ["biceps", "upper_back"], ["forearms"], ["cable"],
          ["pulldown", "lat pull down", "latziehen", "latzug"]),
        e("barbell-row", "Barbell Row", .weightReps, .horizontalPull,
          ["upper_back", "lats"], ["biceps", "rear_delts", "rhomboids"], ["lower_back", "forearms"], ["barbell"],
          ["bent over row", "pendlay row", "langhantelrudern", "barbell bent over row"]),
        e("cable-row", "Seated Cable Row", .weightReps, .horizontalPull,
          ["upper_back", "lats"], ["biceps", "rear_delts", "rhomboids"], ["forearms"], ["cable"],
          ["seated row", "cable row", "sitzendes kabelrudern"]),
        e("dumbbell-row", "Dumbbell Row", .weightReps, .horizontalPull,
          ["lats", "upper_back"], ["biceps", "rear_delts"], ["forearms", "lower_back"], ["dumbbell"],
          ["one arm dumbbell row", "single arm row", "kurzhantelrudern"]),
        e("chest-supported-row", "Chest-supported Row", .weightReps, .horizontalPull,
          ["upper_back", "lats"], ["biceps", "rear_delts", "rhomboids"], ["forearms"], ["machine"],
          ["machine row", "t bar row", "t-bar row", "supported row"]),
        e("shrug", "Shrug", .weightReps, .shoulderIsolation,
          ["upper_traps"], [], ["forearms"], ["dumbbell"], ["shrugs", "barbell shrug", "schulterheben"]),
        e("barbell-curl", "Barbell Curl", .weightReps, .elbowFlexion,
          ["biceps"], ["forearms"], [], ["barbell"], ["ez bar curl", "biceps curl", "langhantelcurl"]),
        e("dumbbell-curl", "Dumbbell Curl", .weightReps, .elbowFlexion,
          ["biceps"], ["forearms"], [], ["dumbbell"],
          ["alternating dumbbell curl", "incline dumbbell curl", "kurzhantelcurl"]),
        e("hammer-curl", "Hammer Curl", .weightReps, .elbowFlexion,
          ["biceps", "forearms"], [], [], ["dumbbell"], ["hammer curls", "hammercurl"]),
        e("back-squat", "Back Squat", .weightReps, .squat,
          ["quadriceps", "glutes"], ["hamstrings", "adductors"], ["lower_back", "abdominals"], ["barbell", "rack"],
          ["barbell squat", "squat", "kniebeuge", "high bar squat", "low bar squat"]),
        e("front-squat", "Front Squat", .weightReps, .squat,
          ["quadriceps"], ["glutes", "adductors"], ["upper_back", "abdominals"], ["barbell", "rack"],
          ["frontkniebeuge"]),
        e("goblet-squat", "Goblet Squat", .weightReps, .squat,
          ["quadriceps", "glutes"], ["adductors"], ["abdominals"], ["dumbbell"], ["goblet kniebeuge"]),
        e("hack-squat", "Hack Squat", .weightReps, .squat,
          ["quadriceps"], ["glutes", "adductors"], [], ["machine"], ["hackenschmidt", "hack squat machine"]),
        e("deadlift", "Deadlift", .weightReps, .hinge,
          ["glutes", "hamstrings"], ["lower_back", "upper_back", "quadriceps"], ["forearms", "abdominals", "lats"], ["barbell"],
          ["conventional deadlift", "kreuzheben"]),
        e("sumo-deadlift", "Sumo Deadlift", .weightReps, .hinge,
          ["glutes", "adductors"], ["quadriceps", "hamstrings", "lower_back"], ["forearms", "abdominals"], ["barbell"],
          ["sumo kreuzheben"]),
        e("romanian-deadlift", "Romanian Deadlift", .weightReps, .hinge,
          ["hamstrings", "glutes"], ["lower_back"], ["forearms", "lats"], ["barbell"],
          ["rdl", "romanian dead lift", "rumänisches kreuzheben", "stiff leg deadlift"]),
        e("good-morning", "Good Morning", .weightReps, .hinge,
          ["hamstrings", "glutes"], ["lower_back"], ["abdominals"], ["barbell"], ["good mornings"]),
        e("hip-thrust", "Hip Thrust", .weightReps, .hinge,
          ["glutes"], ["hamstrings"], ["abdominals"], ["barbell", "bench"], ["hip thrusts", "hüftheben"]),
        e("glute-bridge", "Glute Bridge", .bodyweightReps, .hinge,
          ["glutes"], ["hamstrings"], ["abdominals"], ["bodyweight"], ["glute bridges"]),
        e("leg-press", "Leg Press", .weightReps, .squat,
          ["quadriceps", "glutes"], ["hamstrings", "adductors"], [], ["machine"], ["beinpresse"]),
        e("lunge", "Lunge", .weightReps, .lunge,
          ["quadriceps", "glutes"], ["hamstrings", "adductors"], ["abdominals"], ["dumbbell"],
          ["walking lunge", "reverse lunge", "ausfallschritt", "lunges"]),
        e("bulgarian-split-squat", "Bulgarian Split Squat", .weightReps, .lunge,
          ["quadriceps", "glutes"], ["hamstrings", "adductors"], ["abdominals"], ["dumbbell", "bench"],
          ["rear foot elevated split squat", "bulgarian squat", "bulgarische kniebeuge"]),
        e("step-up", "Step-up", .weightReps, .lunge,
          ["quadriceps", "glutes"], ["hamstrings"], ["abdominals"], ["dumbbell", "bench"], ["step up", "box step up"]),
        e("leg-extension", "Leg Extension", .weightReps, .kneeExtension,
          ["quadriceps"], [], [], ["machine"], ["beinstrecker", "leg extensions"]),
        e("leg-curl", "Leg Curl", .weightReps, .kneeFlexion,
          ["hamstrings"], [], ["calves"], ["machine"], ["hamstring curl", "beinbeuger", "lying leg curl", "seated leg curl"]),
        e("hip-abduction", "Hip Abduction", .weightReps, .other,
          ["abductors", "glutes"], [], [], ["machine"], ["abductor machine", "abduktorenmaschine"]),
        e("hip-adduction", "Hip Adduction", .weightReps, .other,
          ["adductors"], [], [], ["machine"], ["adductor machine", "adduktorenmaschine"]),
        e("calf-raise", "Calf Raise", .weightReps, .calfRaise,
          ["calves"], [], [], ["machine"], ["standing calf raise", "seated calf raise", "wadenheben"]),
        e("tibialis-raise", "Tibialis Raise", .bodyweightReps, .calfRaise,
          ["tibialis"], [], [], ["bodyweight"], ["tib raise", "tibialis raises"]),
        e("plank", "Plank", .duration, .trunkStability,
          ["abdominals"], ["obliques"], ["glutes", "serratus"], ["bodyweight"], ["front plank", "unterarmstütz"]),
        e("side-plank", "Side Plank", .duration, .trunkStability,
          ["obliques"], ["abdominals"], ["glutes"], ["bodyweight"], ["seitstütz"]),
        e("crunch", "Crunch", .bodyweightReps, .trunkFlexion,
          ["upper_abs"], ["lower_abs"], [], ["bodyweight"], ["crunches", "bauchpresse"]),
        e("leg-raise", "Leg Raise", .bodyweightReps, .trunkFlexion,
          ["lower_abs", "hip_flexors"], ["upper_abs"], [], ["bodyweight"],
          ["hanging leg raise", "lying leg raise", "beinheben"]),
        e("back-extension", "Back Extension", .bodyweightReps, .trunkExtension,
          ["lower_back"], ["glutes", "hamstrings"], [], ["bodyweight"], ["hyperextension", "back extensions"]),
        e("farmer-carry", "Farmer Carry", .distanceDuration, .carry,
          ["forearms", "upper_traps"], ["abdominals", "obliques"], ["upper_back", "glutes", "calves"], ["dumbbell"],
          ["farmers walk", "farmer's carry", "farmer walk", "koffertragen"])
    ]

    private static let byProviderId: [String: ExerciseAnatomy] = {
        var out: [String: ExerciseAnatomy] = [:]
        for item in all {
            out["noop_native|noop:\(item.id)"] = item
            out["exercise_db|\(item.id)"] = item
            for (provider, id) in item.providerIds { out["\(provider)|\(id)"] = item }
        }
        return out
    }()

    private static let byAlias: [String: [ExerciseAnatomy]] = {
        var out: [String: [ExerciseAnatomy]] = [:]
        for item in all {
            for alias in [item.title, item.id] + item.aliases {
                let key = normalize(alias)
                if !(out[key] ?? []).contains(where: { $0.id == item.id }) {
                    out[key, default: []].append(item)
                }
            }
        }
        return out
    }()

    /// Resolve provider identity first, then an unambiguous local name. Equipment and measurement mode
    /// break ties but never force a match when two variants remain plausible.
    public static func resolve(title: String, source: TrainingRecordSource? = nil,
                               sourceId: String? = nil, equipmentIds: [String] = [],
                               mode: TrainingMeasurementMode? = nil,
                               canonicalId: String? = nil) -> ExerciseAnatomy? {
        // An explicit canonical id is a decision already taken; nothing may override it.
        if let canonicalId, let exact = byId[canonicalId] { return exact }
        if let source, let sourceId,
           let exact = byProviderId["\(source.rawValue)|\(sourceId)"] { return exact }
        let candidates = byAlias[normalize(title)] ?? []
        if candidates.count == 1 { return candidates[0] }
        let equipment = Set(equipmentIds.map(normalize))
        let narrowed = candidates.filter { candidate in
            let modeMatches = mode == nil || candidate.mode == mode
            let equipmentMatches = equipment.isEmpty || !equipment.isDisjoint(with: candidate.equipmentIds)
            return modeMatches && equipmentMatches
        }
        return narrowed.count == 1 ? narrowed[0] : nil
    }

    public static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let byId: [String: ExerciseAnatomy] = {
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// Validation used by tests and development tooling before a catalogue revision ships. It covers
    /// what review cannot see reliably: a duplicated id, an unknown muscle or equipment id, an alias
    /// two entries claim, a contradiction between measurement mode and equipment, and missing
    /// provenance on shipped content.
    public static func validationIssues(_ entries: [ExerciseAnatomy] = all) -> [String] {
        let valid = Set(TrainingMuscleCatalog.all.map(\.id))
        var issues: [String] = []
        var aliases: [String: String] = [:]
        var ids = Set<String>()
        for item in entries {
            if !ids.insert(item.id).inserted { issues.append("\(item.id): duplicate exercise id") }
            if item.primaryMuscleIds.isEmpty { issues.append("\(item.id): no primary muscle") }
            if item.bodyRegion == .other { issues.append("\(item.id): primary muscle has no body region") }
            if item.confidence != .reviewed { issues.append("\(item.id): shipped entry is not reviewed") }
            for equipment in item.equipmentIds where !TrainingEquipmentCatalog.isKnown(equipment) {
                issues.append("\(item.id): unknown equipment \(equipment)")
            }
            if item.mode == .bodyweightReps,
               TrainingEquipmentCatalog.carriesExternalLoad(item.equipmentIds) {
                issues.append("\(item.id): bodyweight repetitions with a loaded implement")
            }
            let groups = item.primaryMuscleIds + item.secondaryMuscleIds + item.stabilizerMuscleIds
            for id in groups where !valid.contains(id) { issues.append("\(item.id): unknown muscle \(id)") }
            if Set(item.primaryMuscleIds).count != item.primaryMuscleIds.count
                || Set(item.secondaryMuscleIds).count != item.secondaryMuscleIds.count
                || Set(item.stabilizerMuscleIds).count != item.stabilizerMuscleIds.count {
                issues.append("\(item.id): duplicate muscle")
            }
            let credited = Set(item.primaryMuscleIds).intersection(item.secondaryMuscleIds)
            if !credited.isEmpty { issues.append("\(item.id): muscle is both primary and secondary") }
            for alias in [item.title] + item.aliases {
                let key = normalize(alias)
                if let old = aliases[key], old != item.id { issues.append("\(key): ambiguous alias") }
                else { aliases[key] = item.id }
            }
        }
        return issues.sorted()
    }

    private static func e(_ id: String, _ title: String, _ mode: TrainingMeasurementMode,
                          _ pattern: TrainingMovementPattern, _ primary: [String],
                          _ secondary: [String] = [], _ stabilizers: [String] = [],
                          _ equipment: [String] = [], _ aliases: [String] = []) -> ExerciseAnatomy {
        ExerciseAnatomy(id: id, title: title, mode: mode, movementPattern: pattern,
                        primaryMuscleIds: primary, secondaryMuscleIds: secondary,
                        stabilizerMuscleIds: stabilizers, equipmentIds: equipment,
                        aliases: aliases)
    }
}

/// A single anatomy projection for previews and completed-set summaries. It uses the same reviewed
/// catalogue and the same primary/secondary credits as the shared history, while stabilizers remain
/// descriptive metadata only.
public enum TrainingMuscleProjection {
    public static func anatomy(for exercise: TrainingExercise) -> ExerciseAnatomy? {
        if let resolved = ExerciseAnatomyCatalog.resolve(
            title: exercise.title,
            source: exercise.source == .noop ? .noopNative : nil,
            sourceId: exercise.sourceId ?? exercise.id,
            equipmentIds: exercise.equipmentIds,
            mode: exercise.mode,
            canonicalId: exercise.canonicalId
        ) { return resolved }
        guard let primary = exercise.primaryMuscleId else { return nil }
        return ExerciseAnatomy(
            id: "exercise:\(exercise.id)", title: exercise.title, mode: exercise.mode,
            movementPattern: .other, primaryMuscleIds: [primary],
            secondaryMuscleIds: exercise.secondaryMuscleIds,
            equipmentIds: exercise.equipmentIds,
            confidence: exercise.source == .user ? .userConfirmed : .sourceFallback)
    }

    public static func routine(_ routine: TrainingRoutine,
                               exercises: [String: TrainingExercise]) -> [String: Double] {
        var result: [String: Double] = [:]
        for planned in routine.exercises {
            guard let definition = exercises[planned.exerciseId],
                  let anatomy = anatomy(for: definition) else { continue }
            let sets = Double(planned.sets.filter { $0.phase == .work }.count)
            credit(anatomy, sets: sets, into: &result)
        }
        return result
    }

    public static func workout(_ workout: NativeWorkout,
                               exercises: [String: TrainingExercise]) -> [String: Double] {
        var result: [String: Double] = [:]
        for logged in workout.exercises {
            guard let definition = exercises[logged.exerciseId],
                  let anatomy = anatomy(for: definition) else { continue }
            let sets = Double(logged.sets.filter { $0.phase == .work && $0.isCompleted }.count)
            credit(anatomy, sets: sets, into: &result)
        }
        return result
    }

    private static func credit(_ anatomy: ExerciseAnatomy, sets: Double,
                               into result: inout [String: Double]) {
        for id in anatomy.primaryMuscleIds { result[id, default: 0] += sets }
        for id in anatomy.secondaryMuscleIds { result[id, default: 0] += sets * 0.5 }
    }
}
