import MuscleMap

/// How a muscle group draws on Apple's body artwork; the groups themselves are shared (`Strand/Data`).
extension ExerciseMuscleGroup {
    /// The artwork regions lit for this group.
    var renderedMuscles: Set<Muscle> {
        Set(muscleIds.compactMap(TrainingMuscleMapAppearance.muscle))
    }

    /// The group a tapped part of the body belongs to.
    static func group(for muscle: Muscle) -> ExerciseMuscleGroup? {
        allCases.first { $0.renderedMuscles.contains(muscle) }
    }
}
