import Foundation
import StrandTraining

enum TrainingEffortPreference: String, CaseIterable, Identifiable {
    case off, rir, rpe
    var id: String { rawValue }
}

/// When NOOP asks, by notification, how demanding a finished session felt. The Session Load card on a
/// session's detail is there either way; this governs only the push.
enum SessionRatingPrompt: String, CaseIterable, Identifiable {
    case off, whenUseful, always
    var id: String { rawValue }
}

enum TrainingMediaPresentation: String, CaseIterable, Identifiable {
    case large, small, hidden
    var id: String { rawValue }
}

enum TrainingPreferences {
    static let effortKey = "training.effortScale"
    static let sessionRatingPromptKey = "training.sessionRatingPrompt"
    static let defaultRestKey = "training.defaultRestSeconds"
    static let warmupRestKey = "training.warmupRestSeconds"
    static let restPauseKey = "training.restPauseSeconds"
    static let mediaPresentationKey = "training.mediaPresentation"
    static let soundKey = "training.timerSound"
    static let hapticsKey = "training.timerHaptics"
    static let timerFeedbackKey = "training.timerFeedback"
    static let weekStartKey = "training.weekStartsOn"
    static let activeLayoutKey = "training.activeWorkout.layout"
    static let equipmentKey = "training.availableEquipment"
    static let weightIncrementKey = "training.weightIncrementKg"
    static let platePairsKey = "training.plateCalculator.available"
    static let defaultPlatePairs = "25,20,15,10,5,2.5,1.25"
    static let defaultWeightIncrementKg = 2.5
    static let weightIncrementChoices: [Double] = [0.5, 1, 1.25, 2, 2.5, 5]

    static let defaultRestSeconds = 120
    static let defaultWarmupRestSeconds = 60
    static let defaultRestPauseSeconds = 20
    static let knownEquipment = [
        "barbell", "dumbbell", "kettlebell", "cable", "machine", "band",
        "bench", "pull-up-bar", "squat-rack", "weight-belt", "bodyweight"
    ]

    static var effort: TrainingEffortPreference {
        TrainingEffortPreference(rawValue: UserDefaults.standard.string(forKey: effortKey) ?? "") ?? .rpe
    }
    static var sessionRatingPrompt: SessionRatingPrompt {
        SessionRatingPrompt(rawValue: UserDefaults.standard.string(forKey: sessionRatingPromptKey) ?? "")
            ?? .whenUseful
    }
    static var timerSoundEnabled: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }
    static var timerFeedbackEnabled: Bool {
        UserDefaults.standard.object(forKey: timerFeedbackKey) as? Bool ?? true
    }
    static var weekStart: TrainingWeekStart {
        TrainingWeekStart(rawValue: UserDefaults.standard.string(forKey: weekStartKey) ?? "") ?? .monday
    }
    /// The chosen training week start in `Calendar.firstWeekday` terms: 1 = Sunday, 2 = Monday.
    static var firstWeekday: Int { weekStart == .sunday ? 1 : 2 }
    static var restPauseSeconds: Int {
        let value = UserDefaults.standard.integer(forKey: restPauseKey)
        return value > 0 ? value : defaultRestPauseSeconds
    }

    /// An empty selection means that no equipment filter is active.
    static var availableEquipment: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: equipmentKey) ?? []).map {
            $0.lowercased()
        })
    }

    /// Whether every piece of equipment the exercise lists is available. An empty selection disables
    /// the filter, and bodyweight never has to be selected.
    static func exercise(_ exercise: TrainingExercise, matches available: Set<String>) -> Bool {
        guard !available.isEmpty else { return true }
        let owned = Set(available.map(TrainingDisplayNames.canonicalEquipment))
        return exercise.equipmentIds.map(TrainingDisplayNames.canonicalEquipment)
            .allSatisfy { $0 == "bodyweight" || owned.contains($0) }
    }

    /// The − / + step for one exercise: two of the smallest saved plates for a barbell, otherwise the
    /// step chosen in Settings › Training.
    static func weightStep(for equipmentIds: [String]) -> Double {
        let configured = UserDefaults.standard.double(forKey: weightIncrementKey)
        let plates = (UserDefaults.standard.string(forKey: platePairsKey) ?? defaultPlatePairs)
            .split(separator: ",").compactMap { Double($0) }
        return WeightIncrement.step(equipmentIds: equipmentIds.map(TrainingDisplayNames.canonicalEquipment),
                                    platePairsKg: plates,
                                    fallbackKg: configured > 0 ? configured : defaultWeightIncrementKg)
    }

    static func setEquipment(_ values: Set<String>) {
        UserDefaults.standard.set(values.sorted(), forKey: equipmentKey)
    }
}
