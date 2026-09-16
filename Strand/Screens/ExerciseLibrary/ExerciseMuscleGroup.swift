import Foundation
import MuscleMap
import StrandTraining

/// The muscle groups a wearer picks on the body to find exercises. Each group is a set of NOOP muscle
/// ids, so it matches exercises the same way the muscle analytics count them, and each draws on the body
/// through the one existing id-to-artwork mapping (`TrainingMuscleMapAppearance.muscle`).
///
/// A group here never splits one analytics group (`HevyMuscleGroup.forTrainingMuscle`) across two chips.
/// It may join two — upper back takes the lats, glutes take the abductors — exactly as the load map draws
/// them on one shape.
enum ExerciseMuscleGroup: String, CaseIterable, Identifiable, Sendable {
    case neck, traps, shoulders, chest, upperBack, serratus, biceps, triceps, forearms
    case abs, obliques, lowerBack, glutes, quads, hamstrings, adductors, hipFlexors, calves, shins

    var id: String { rawValue }

    /// Whether an exercise trains the group as its main target or also works it.
    enum Involvement: Int, Comparable, Sendable {
        case secondary = 0
        case primary = 1
        static func < (a: Involvement, b: Involvement) -> Bool { a.rawValue < b.rawValue }
    }

    var muscleIds: Set<String> {
        switch self {
        case .neck: return ["neck"]
        case .traps: return ["traps", "upper_traps", "lower_traps"]
        case .shoulders: return ["front_delts", "side_delts", "rear_delts", "rotator_cuff"]
        case .chest: return ["chest", "upper_chest", "lower_chest"]
        case .upperBack: return ["lats", "upper_back", "rhomboids"]
        case .serratus: return ["serratus"]
        case .biceps: return ["biceps"]
        case .triceps: return ["triceps"]
        case .forearms: return ["forearms"]
        case .abs: return ["abdominals", "upper_abs", "lower_abs"]
        case .obliques: return ["obliques"]
        case .lowerBack: return ["lower_back"]
        case .glutes: return ["glutes", "abductors"]
        case .quads: return ["quadriceps", "inner_quadriceps", "outer_quadriceps"]
        case .hamstrings: return ["hamstrings"]
        case .adductors: return ["adductors"]
        case .hipFlexors: return ["hip_flexors"]
        case .calves: return ["calves"]
        case .shins: return ["tibialis"]
        }
    }

    var title: String {
        switch self {
        case .neck: return String(localized: "Neck")
        case .traps: return String(localized: "Traps")
        case .shoulders: return String(localized: "Shoulders")
        case .chest: return String(localized: "Chest")
        case .upperBack: return String(localized: "Upper back")
        case .serratus: return String(localized: "Serratus")
        case .biceps: return String(localized: "Biceps")
        case .triceps: return String(localized: "Triceps")
        case .forearms: return String(localized: "Forearms")
        case .abs: return String(localized: "Abs")
        case .obliques: return String(localized: "Obliques")
        case .lowerBack: return String(localized: "Lower back")
        case .glutes: return String(localized: "Glutes")
        case .quads: return String(localized: "Quads")
        case .hamstrings: return String(localized: "Hamstrings")
        case .adductors: return String(localized: "Adductors")
        case .hipFlexors: return String(localized: "Hip flexors")
        case .calves: return String(localized: "Calves")
        case .shins: return String(localized: "Shins")
        }
    }

    /// The artwork regions lit for this group.
    var renderedMuscles: Set<Muscle> {
        Set(muscleIds.compactMap(TrainingMuscleMapAppearance.muscle))
    }

    /// The group a tapped part of the body belongs to.
    static func group(for muscle: Muscle) -> ExerciseMuscleGroup? {
        allCases.first { $0.renderedMuscles.contains(muscle) }
    }

    /// Main target when the exercise's primary muscle is in the group, "also trains" when only a secondary
    /// one is. The reviewed anatomy is consulted as well, like the library's muscle filter.
    func involvement(of exercise: TrainingExercise) -> Involvement? {
        let anatomy = TrainingMuscleProjection.anatomy(for: exercise)
        let primary = Set([exercise.primaryMuscleId].compactMap { $0 } + (anatomy?.primaryMuscleIds ?? []))
        if !primary.isDisjoint(with: muscleIds) { return .primary }
        let secondary = Set(exercise.secondaryMuscleIds + (anatomy?.secondaryMuscleIds ?? []))
        return secondary.isDisjoint(with: muscleIds) ? nil : .secondary
    }

    /// How many exercises train each group at all, computed once per exercise list.
    static func counts(_ exercises: [TrainingExercise]) -> [ExerciseMuscleGroup: Int] {
        var counts: [ExerciseMuscleGroup: Int] = [:]
        for exercise in exercises {
            for group in allCases where group.involvement(of: exercise) != nil {
                counts[group, default: 0] += 1
            }
        }
        return counts
    }
}
