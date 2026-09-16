import Foundation

/// The shipped offline exercise catalogue.
///
/// **Data:** ExerciseDB v1 via `hasaneyldrm/exercises-dataset`, pinned to one immutable revision and
/// normalized into NOOP's own domain by `Tools/build_exercise_catalog.py`. That repository's `LICENSE`
/// and `NOTICE.md` place the exercise DATA — names, categories, body parts, equipment, targets, muscle
/// groups and instructions — under the MIT licence.
///
/// **Media is not here and never will be through this path.** The same upstream states that the images
/// and animations belong to Gym visual and that cloning the repository grants no licence to them. An
/// entry therefore carries at most the upstream `mediaId` string; only a separately licensed media
/// provider could ever resolve it, and the one that would is withdrawn.
///
/// The catalogue is an `ExerciseCatalogArchive` — the same envelope a wearer-supplied catalogue uses —
/// so the app has one exercise-content format, not two.
public enum BundledExerciseCatalog {
    /// Bumped when the normalization changes what a stored definition means, so the app re-seeds.
    public static let contentVersion = 1

    public static let archive: ExerciseCatalogArchive = {
        guard let url = Bundle.module.url(forResource: "exercise-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? ExerciseCatalogArchive.decode(data)
        else {
            // An absent or unreadable resource must not crash a workout. The catalogue is then simply
            // empty, the wearer's own exercises still work, and the test below fails loudly in CI.
            return ExerciseCatalogArchive(
                provider: "exercisedb-v1",
                rights: ExerciseContentRights(provider: "", licence: "", allowsOfflineCache: false,
                                              allowsRedistribution: false),
                exercises: [])
        }
        return decoded
    }()

    public static var exercises: [TrainingExercise] { archive.exercises }
    public static var rights: ExerciseContentRights { archive.rights }
    public static var sourceRevision: String? { archive.sourceRevision }
    public static var sourceChecksum: String? { archive.sourceChecksum }

    /// The classes of mistake review cannot see reliably, applied to the shipped content: a duplicated
    /// id, an identifier outside NOOP's own vocabulary, a contradiction between how an exercise is
    /// measured and what it is performed with, an alias two exercises claim, and missing provenance.
    public static func validationIssues(_ entries: [TrainingExercise] = exercises) -> [String] {
        let muscles = Set(TrainingMuscleCatalog.all.map(\.id))
        var issues: [String] = []
        var ids = Set<String>()
        var aliases: [String: String] = [:]

        for exercise in entries {
            if !ids.insert(exercise.id).inserted { issues.append("\(exercise.id): duplicate exercise id") }
            if exercise.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(exercise.id): empty title")
            }
            if let primary = exercise.primaryMuscleId, !muscles.contains(primary) {
                issues.append("\(exercise.id): unknown muscle \(primary)")
            }
            for muscle in exercise.secondaryMuscleIds where !muscles.contains(muscle) {
                issues.append("\(exercise.id): unknown muscle \(muscle)")
            }
            if let primary = exercise.primaryMuscleId, exercise.secondaryMuscleIds.contains(primary) {
                issues.append("\(exercise.id): muscle is both primary and secondary")
            }
            for equipment in exercise.equipmentIds where !TrainingEquipmentCatalog.isKnown(equipment) {
                issues.append("\(exercise.id): unknown equipment \(equipment)")
            }
            let loaded = TrainingEquipmentCatalog.carriesExternalLoad(exercise.equipmentIds)
            if exercise.mode == .bodyweightReps, loaded {
                issues.append("\(exercise.id): bodyweight repetitions with a loaded implement")
            }
            if exercise.mode == .weightReps, !loaded {
                issues.append("\(exercise.id): weight and repetitions without a loaded implement")
            }
            if exercise.attribution?.isEmpty ?? true { issues.append("\(exercise.id): missing attribution") }
            if exercise.contentVersion <= 0 { issues.append("\(exercise.id): missing content version") }
            if exercise.sourceId?.isEmpty ?? true { issues.append("\(exercise.id): missing source id") }
            for alias in exercise.aliases {
                let key = ExerciseAnatomyCatalog.normalize(alias)
                if let owner = aliases[key], owner != exercise.id {
                    issues.append("\(key): ambiguous alias")
                } else {
                    aliases[key] = exercise.id
                }
            }
        }
        if entries.isEmpty { issues.append("catalogue: no exercises were loaded") }
        return issues.sorted()
    }
}
