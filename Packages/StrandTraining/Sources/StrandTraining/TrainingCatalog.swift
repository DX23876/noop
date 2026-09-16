import Foundation

/// NOOP's native anatomy vocabulary. The identifiers are stable storage keys; names are display
/// fallbacks for imported content and can be localized by the app without rewriting history.
public enum TrainingMuscleCatalog {
    public static let all: [TrainingMuscle] = [
        .init(id: "chest", name: "Chest"),
        .init(id: "upper_chest", name: "Upper chest", parentId: "chest"),
        .init(id: "lower_chest", name: "Lower chest", parentId: "chest"),
        .init(id: "serratus", name: "Serratus", parentId: "core"),
        .init(id: "front_delts", name: "Front delts", parentId: "shoulders"),
        .init(id: "side_delts", name: "Side delts", parentId: "shoulders"),
        .init(id: "rear_delts", name: "Rear delts", parentId: "shoulders"),
        .init(id: "rotator_cuff", name: "Rotator cuff", parentId: "shoulders"),
        .init(id: "triceps", name: "Triceps"),
        .init(id: "biceps", name: "Biceps"),
        .init(id: "forearms", name: "Forearms"),
        .init(id: "lats", name: "Lats", parentId: "back"),
        .init(id: "upper_back", name: "Upper back", parentId: "back"),
        .init(id: "rhomboids", name: "Rhomboids", parentId: "back"),
        .init(id: "traps", name: "Traps", parentId: "back"),
        .init(id: "upper_traps", name: "Upper traps", parentId: "traps"),
        .init(id: "lower_traps", name: "Lower traps", parentId: "traps"),
        .init(id: "lower_back", name: "Lower back", parentId: "back"),
        .init(id: "abdominals", name: "Abdominals", parentId: "core"),
        .init(id: "upper_abs", name: "Upper abs", parentId: "abdominals"),
        .init(id: "lower_abs", name: "Lower abs", parentId: "abdominals"),
        .init(id: "obliques", name: "Obliques", parentId: "core"),
        .init(id: "quadriceps", name: "Quadriceps", parentId: "legs"),
        .init(id: "inner_quadriceps", name: "Inner quadriceps", parentId: "quadriceps"),
        .init(id: "outer_quadriceps", name: "Outer quadriceps", parentId: "quadriceps"),
        .init(id: "hamstrings", name: "Hamstrings", parentId: "legs"),
        .init(id: "glutes", name: "Glutes", parentId: "legs"),
        .init(id: "hip_flexors", name: "Hip flexors", parentId: "legs"),
        .init(id: "adductors", name: "Adductors", parentId: "legs"),
        .init(id: "abductors", name: "Abductors", parentId: "legs"),
        .init(id: "calves", name: "Calves", parentId: "legs"),
        .init(id: "tibialis", name: "Tibialis", parentId: "legs"),
        .init(id: "neck", name: "Neck")
    ]
}

/// A compact, rights-clean starter catalog written for NOOP. It makes native logging useful offline;
/// optional providers may add exercises later without replacing user-created definitions.
public enum TrainingStarterCatalog {
    /// Bumped when a starter definition changes in a way stored copies should pick up, so the app
    /// re-seeds the starters. 2: media references.
    public static let contentVersion = 2

    public static let exercises: [TrainingExercise] = [
        exercise("barbell-bench-press", "Barbell Bench Press", .weightReps, "chest", ["triceps", "front_delts"], ["barbell", "bench"]),
        exercise("incline-dumbbell-press", "Incline Dumbbell Press", .weightReps, "upper_chest", ["triceps", "front_delts"], ["dumbbell", "bench"]),
        exercise("overhead-press", "Overhead Press", .weightReps, "front_delts", ["triceps", "side_delts"], ["barbell"]),
        exercise("lateral-raise", "Lateral Raise", .weightReps, "side_delts", ["front_delts"], ["dumbbell"]),
        exercise("triceps-pushdown", "Triceps Pushdown", .weightReps, "triceps", [], ["cable"]),
        exercise("push-up", "Push-up", .bodyweightReps, "chest", ["triceps", "front_delts"], ["bodyweight"]),
        exercise("pull-up", "Pull-up", .bodyweightReps, "lats", ["biceps", "upper_back"], ["bar" ]),
        exercise("weighted-pull-up", "Weighted Pull-up", .weightedBodyweight, "lats", ["biceps", "upper_back"], ["bar", "weight-belt"]),
        exercise("lat-pulldown", "Lat Pulldown", .weightReps, "lats", ["biceps", "upper_back"], ["cable"]),
        exercise("barbell-row", "Barbell Row", .weightReps, "upper_back", ["lats", "biceps", "rear_delts"], ["barbell"]),
        exercise("seated-cable-row", "Seated Cable Row", .weightReps, "upper_back", ["lats", "biceps"], ["cable"]),
        exercise("face-pull", "Face Pull", .weightReps, "rear_delts", ["upper_back"], ["cable"]),
        exercise("barbell-curl", "Barbell Curl", .weightReps, "biceps", ["forearms"], ["barbell"]),
        exercise("back-squat", "Back Squat", .weightReps, "quadriceps", ["glutes", "hamstrings", "lower_back"], ["barbell", "rack"]),
        exercise("front-squat", "Front Squat", .weightReps, "quadriceps", ["glutes", "abdominals"], ["barbell", "rack"]),
        exercise("deadlift", "Deadlift", .weightReps, "glutes", ["hamstrings", "lower_back", "upper_back"], ["barbell"]),
        exercise("romanian-deadlift", "Romanian Deadlift", .weightReps, "hamstrings", ["glutes", "lower_back"], ["barbell"]),
        exercise("leg-press", "Leg Press", .weightReps, "quadriceps", ["glutes", "hamstrings"], ["machine"]),
        exercise("leg-curl", "Leg Curl", .weightReps, "hamstrings", [], ["machine"]),
        exercise("leg-extension", "Leg Extension", .weightReps, "quadriceps", [], ["machine"]),
        exercise("calf-raise", "Calf Raise", .weightReps, "calves", [], ["machine"]),
        exercise("bulgarian-split-squat", "Bulgarian Split Squat", .weightReps, "quadriceps", ["glutes", "hamstrings"], ["dumbbell", "bench"], unilateral: true),
        exercise("hip-thrust", "Hip Thrust", .weightReps, "glutes", ["hamstrings"], ["barbell", "bench"]),
        exercise("plank", "Plank", .duration, "abdominals", ["obliques"], ["bodyweight"]),
        exercise("farmer-carry", "Farmer Carry", .distanceDuration, "forearms", ["traps", "abdominals"], ["dumbbell"])
    ]

    /// Media for the starter exercises, borrowed from the bundled catalogue entry that shows the same
    /// movement (starter id → upstream media id). Reviewed by hand, one movement at a time; where the
    /// catalogue has no faithful equivalent (a plain plank) the exercise keeps no media rather than a
    /// misleading one. Only the media reference is shared — the starter text stays NOOP's own.
    public static let mediaReferences: [String: String] = [
        "barbell-bench-press": "EIeI8Vf",      // exdb:0025 barbell bench press
        "incline-dumbbell-press": "ns0SIbU",   // exdb:0314 dumbbell incline bench press
        "overhead-press": "wdRZISl",           // exdb:1456 barbell standing close grip military press
        "lateral-raise": "DsgkuIt",            // exdb:0334 dumbbell lateral raise
        "triceps-pushdown": "3ZflifB",         // exdb:0201 cable pushdown
        "push-up": "I4hDWkc",                  // exdb:0662 push-up
        "pull-up": "lBDjFxJ",                  // exdb:0652 pull-up
        "weighted-pull-up": "HMzLjXx",         // exdb:0841 weighted pull-up
        "lat-pulldown": "LEprlgG",             // exdb:2330 cable lat pulldown full range of motion
        "barbell-row": "eZyBC3j",              // exdb:0027 barbell bent over row
        "seated-cable-row": "fUBheHs",         // exdb:0861 cable seated row
        "face-pull": "wqNPGCg",                // exdb:0203 cable rear delt row (with rope)
        "barbell-curl": "25GPyDY",             // exdb:0031 barbell curl
        "back-squat": "qXTaZnJ",               // exdb:0043 barbell full squat
        "front-squat": "zG0zs85",              // exdb:0042 barbell front squat
        "deadlift": "ila4NZS",                 // exdb:0032 barbell deadlift
        "romanian-deadlift": "wQ2c4XD",        // exdb:0085 barbell romanian deadlift
        "leg-press": "2Qh2J1e",                // exdb:1463 sled 45° leg press (side pov)
        "leg-curl": "17lJ1kr",                 // exdb:0586 lever lying leg curl
        "leg-extension": "my33uHU",            // exdb:0585 lever leg extension
        "calf-raise": "8ozhUIZ",               // exdb:1372 barbell standing calf raise
        "bulgarian-split-squat": "qx4fgX7",    // exdb:0410 dumbbell single leg split squat
        "hip-thrust": "qKBpF7I",               // exdb:1409 barbell glute bridge
        "farmer-carry": "qPEzJjA",             // exdb:2133 farmers walk
    ]

    public static func starterRoutines(now: Int = Int(Date().timeIntervalSince1970)) -> [TrainingRoutine] {
        [
            routine("Full Body A", ["back-squat", "barbell-bench-press", "barbell-row", "plank"], now: now),
            routine("Full Body B", ["deadlift", "overhead-press", "pull-up", "bulgarian-split-squat"], now: now),
            routine("Push", ["barbell-bench-press", "overhead-press", "incline-dumbbell-press", "lateral-raise", "triceps-pushdown"], now: now),
            routine("Pull & Legs", ["deadlift", "pull-up", "barbell-row", "back-squat", "leg-curl", "calf-raise"], now: now)
        ]
    }

    /// The shipped starter definitions are NOOP's own text. Their canonical id is the reviewed
    /// anatomy entry where one exists, so an import of the same movement resolves to one exercise.
    private static func exercise(_ id: String, _ title: String, _ mode: TrainingMeasurementMode,
                                 _ primary: String, _ secondary: [String], _ equipment: [String],
                                 unilateral: Bool = false) -> TrainingExercise {
        let canonical = ExerciseAnatomyCatalog.resolve(title: title, equipmentIds: equipment, mode: mode)?.id
        return TrainingExercise(id: "noop:\(id)", title: title, mode: mode, primaryMuscleId: primary,
                                secondaryMuscleIds: secondary, equipmentIds: equipment,
                                isUnilateral: unilateral, source: .noop,
                                mediaId: mediaReferences[id],
                                canonicalId: canonical, contentVersion: ExerciseAnatomyCatalog.version,
                                attribution: "NOOP",
                                loadSemantics: .defaultValue(for: mode, equipmentIds: equipment))
    }

    private static func routine(_ title: String, _ ids: [String], now: Int) -> TrainingRoutine {
        TrainingRoutine(title: title, exercises: ids.map { id in
            let duration = id == "plank"
            return RoutineExercise(exerciseId: "noop:\(id)", sets: (0..<3).map { index in
                RoutineSetPlan(phase: index == 0 && !duration ? .warmup : .work,
                               targetWeightKg: duration ? nil : 0,
                               repsMin: duration ? nil : 8, repsMax: duration ? nil : 12,
                               targetDurationS: duration ? 45 : nil)
            }, restSeconds: duration ? 60 : 120)
        }, defaultProgression: .init(policy: .doubleProgression), createdAt: now, updatedAt: now)
    }
}
