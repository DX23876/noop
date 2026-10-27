import Foundation
import StrandTraining
import WhoopStore

/// Finds the NOOP exercise a Hevy exercise is. The order mirrors the shared strength history: an
/// exercise an earlier import already made, the wearer's own alias, the reviewed anatomy catalogue,
/// then an exact name. Only when all of them miss is a new exercise made from Hevy's description.
public struct HevyRoutineExerciseMatcher {
    private let byAnatomy: [String: TrainingExercise]
    private let byTitle: [String: TrainingExercise]
    private let byHevyId: [String: TrainingExercise]
    private let templates: [String: HevyExerciseTemplate]
    private let aliases: [TrainingExerciseAnatomyAlias]

    public init(exercises: [TrainingExercise], templates: [String: HevyExerciseTemplate],
         aliases: [TrainingExerciseAnatomyAlias]) {
        // Several NOOP exercises can be one movement (a starter exercise and its catalogue entry). The
        // wearer's own comes first, then NOOP's starter set, then the catalogue.
        func rank(_ exercise: TrainingExercise) -> Int {
            switch exercise.source {
            case .user: 0
            case .noop: 1
            case .exerciseDB: 2
            case .imported: 3
            }
        }
        var byAnatomy: [String: TrainingExercise] = [:]
        var byTitle: [String: TrainingExercise] = [:]
        var byHevyId: [String: TrainingExercise] = [:]
        for exercise in exercises.sorted(by: { rank($0) < rank($1) }) {
            if let anatomy = TrainingMuscleProjection.anatomy(for: exercise),
               !anatomy.id.hasPrefix("exercise:"), byAnatomy[anatomy.id] == nil {
                byAnatomy[anatomy.id] = exercise
            }
            let title = ExerciseAnatomyCatalog.normalize(exercise.title)
            if byTitle[title] == nil { byTitle[title] = exercise }
            if exercise.id.hasPrefix("imported:hevy:"), let sourceId = exercise.sourceId {
                byHevyId[sourceId] = exercise
            }
        }
        self.byAnatomy = byAnatomy
        self.byTitle = byTitle
        self.byHevyId = byHevyId
        self.templates = templates
        self.aliases = aliases
    }

    /// Hevy names an exercise "Bench Press (Barbell)"; NOOP and its catalogue say "Barbell Bench Press".
    /// The equipment-first spelling is tried first, then Hevy's own. The bare name is not: "Squat" alone
    /// would match a barbell squat for a Smith machine one.
    public static func candidateNames(_ title: String) -> [String] {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("), open > trimmed.startIndex else {
            return [trimmed]
        }
        let base = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let equipment = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !equipment.isEmpty else { return [trimmed] }
        return ["\(equipment) \(base)", trimmed]
    }

    public func match(title: String, templateId: String?) -> HevyRoutineExerciseMatch? {
        if let templateId, let earlier = byHevyId[templateId] { return .init(exercise: earlier, isNew: false) }
        let template = templateId.flatMap { templates[$0] }
        let name = template?.title ?? title
        guard !name.isEmpty else { return nil }
        let normalized = ExerciseAnatomyCatalog.normalize(name)
        let mode = HevyExerciseMetadata.measurementMode(template?.type)
        let equipment = HevyExerciseMetadata.equipmentIds(template?.equipment)
        let alias = aliases.first { alias in
            if alias.origin == "user" { return alias.normalizedTitle == normalized }
            return alias.source == .hevyAPI && alias.sourceExerciseId != nil
                && alias.sourceExerciseId == templateId
        }?.anatomy
        let names = Self.candidateNames(name)
        let anatomy = alias ?? names.lazy.compactMap { candidate in
            ExerciseAnatomyCatalog.resolve(title: candidate, source: .hevyAPI, sourceId: templateId,
                                           equipmentIds: equipment, mode: mode)
        }.first
        if let anatomy, let known = byAnatomy[anatomy.id] { return .init(exercise: known, isNew: false) }
        if let known = names.lazy.compactMap({ byTitle[ExerciseAnatomyCatalog.normalize($0)] }).first {
            return .init(exercise: known, isNew: false)
        }

        guard let mode else { return nil }
        let primary = template?.primaryMuscleGroup.trainingMuscleIds ?? []
        let secondary = (template?.secondaryMuscleGroups ?? []).flatMap(\.trainingMuscleIds)
        let key = templateId ?? normalized.replacingOccurrences(of: " ", with: "-")
        return .init(exercise: TrainingExercise(
            id: "imported:hevy:\(key)", title: name, mode: mode,
            primaryMuscleId: primary.first,
            secondaryMuscleIds: (primary.dropFirst() + secondary).filter { $0 != primary.first },
            equipmentIds: equipment, source: .imported, sourceId: templateId,
            canonicalId: anatomy?.id, attribution: "Hevy"), isNew: true)
    }
}

/// Provider metadata conversions shared by history resolution and routine matching.
public enum HevyExerciseMetadata {
    public static func measurementMode(_ raw: String?) -> TrainingMeasurementMode? {
        guard let raw else { return nil }
        if let exact = TrainingMeasurementMode(rawValue: raw) { return exact }
        return raw == "reps_only" ? .repetitions : nil
    }
    public static func equipmentIds(_ equipment: HevyEquipment?) -> [String] {
        guard let equipment else { return [] }
        switch equipment {
        case .none: return ["bodyweight"]
        case .resistanceBand: return ["resistance-band"]
        default: return [equipment.rawValue]
        }
    }
}
