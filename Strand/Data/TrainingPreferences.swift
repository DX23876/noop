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

enum TrainingWeightUnit: String, CaseIterable, Identifiable {
    case kilograms
    case pounds

    var id: String { rawValue }
    var system: UnitSystem { self == .pounds ? .imperial : .metric }
    var label: String { self == .pounds ? String(localized: "Pounds (lb)") : String(localized: "Kilograms (kg)") }
    var symbol: String { self == .pounds ? "lb" : "kg" }
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
    static let strapDoubleTapKey = "training.strapDoubleTapLogsSet"
    /// Set once the strap double-tap tip in a running session is dismissed or a set is logged from the strap.
    static let strapTapTipDoneKey = "training.strapTapTipDone"
    static let weekStartKey = "training.weekStartsOn"
    static let activeLayoutKey = "training.activeWorkout.layout"
    static let equipmentKey = "training.availableEquipment"
    static let weightIncrementKey = "training.weightIncrementKg"
    static let imperialWeightIncrementKey = "training.weightIncrementLbKg"
    static let weightUnitKey = "training.weightUnit"
    static let platePairsKey = "training.plateCalculator.available"
    static let imperialPlatePairsKey = "training.plateCalculator.availableLbKg"
    static let defaultPlatePairs = "25,20,15,10,5,2.5,1.25"
    static let defaultImperialPlatePairsKg = [55.0, 45, 35, 25, 10, 5, 2.5]
        .map { String($0 / UnitFormatter.poundsPerKilogram) }.joined(separator: ",")
    static let defaultWeightIncrementKg = 2.5
    static let defaultImperialWeightIncrementKg = 5 / UnitFormatter.poundsPerKilogram
    static let weightIncrementChoices: [Double] = [0.5, 1, 1.25, 2, 2.5, 5]
    static let imperialWeightIncrementChoicesKg: [Double] = [1, 2.5, 5, 10]
        .map { $0 / UnitFormatter.poundsPerKilogram }

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
    /// Whether a strap double-tap completes the next set during a strength session. Default on; off hands
    /// the gesture back to the configured double-tap action for the whole session.
    static var strapDoubleTapLogsSet: Bool {
        UserDefaults.standard.object(forKey: strapDoubleTapKey) as? Bool ?? true
    }
    static var weekStart: TrainingWeekStart {
        TrainingWeekStart(rawValue: UserDefaults.standard.string(forKey: weekStartKey) ?? "") ?? .monday
    }
    /// The chosen training week start in `Calendar.firstWeekday` terms: 1 = Sunday, 2 = Monday.
    static var firstWeekday: Int { weekStart == .sunday ? 1 : 2 }
    /// The local calendar with the training week start applied. Goal weeks, the goal week grid and
    /// the weekly digest all cut their seven days with this, so one workout can never fall into
    /// different weeks on different screens.
    static var weekCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// The wearer's regular rest days, as `Calendar` weekday numbers (1 = Sunday … 7 = Saturday).
    /// Set once in the training settings; every weekly goal leaves these days out of its pace unless
    /// the goal overrides them. Empty = no fixed rest days.
    static let restWeekdaysKey = "training.restWeekdays"
    static var restWeekdays: [Int] {
        let raw = UserDefaults.standard.array(forKey: restWeekdaysKey) as? [Int] ?? []
        return Array(Set(raw.filter { (1...7).contains($0) })).sorted()
    }
    static func setRestWeekdays(_ days: [Int]) {
        UserDefaults.standard.set(Array(Set(days.filter { (1...7).contains($0) })).sorted(),
                                  forKey: restWeekdaysKey)
    }
    static var restPauseSeconds: Int {
        let value = UserDefaults.standard.integer(forKey: restPauseKey)
        return value > 0 ? value : defaultRestPauseSeconds
    }
    static var weightUnit: TrainingWeightUnit {
        TrainingWeightUnit(rawValue: UserDefaults.standard.string(forKey: weightUnitKey) ?? "")
            ?? .kilograms
    }

    static func displayWeight(_ kilograms: Double, unit: TrainingWeightUnit? = nil) -> Double {
        LiftFormat.display(fromKilograms: kilograms, system: (unit ?? weightUnit).system)
    }

    static func kilograms(fromDisplay value: Double, unit: TrainingWeightUnit? = nil) -> Double {
        LiftFormat.kilograms(fromDisplay: value, system: (unit ?? weightUnit).system)
    }

    static func formattedWeight(_ kilograms: Double, unit: TrainingWeightUnit? = nil,
                                signed: Bool = false) -> String {
        let selected = unit ?? weightUnit
        // A kg value converted for read-only imperial summaries commonly lands on two noisy decimal
        // places (127.5 kg -> 281.09 lb). Half-pound precision is enough for plates and dumbbells;
        // editable fields still use LiftFormat.trim so a value the user typed can round-trip exactly.
        let maximumFractionDigits = selected == .pounds ? 1 : 2
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0...maximumFractionDigits))
            .sign(strategy: signed ? .always() : .automatic)
        return "\(displayWeight(kilograms, unit: selected).formatted(style)) \(selected.symbol)"
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
        let unit = weightUnit
        let incrementKey = unit == .pounds ? imperialWeightIncrementKey : weightIncrementKey
        let plateKey = unit == .pounds ? imperialPlatePairsKey : platePairsKey
        let defaultIncrement = unit == .pounds ? defaultImperialWeightIncrementKg : defaultWeightIncrementKg
        let defaultPlates = unit == .pounds ? defaultImperialPlatePairsKg : defaultPlatePairs
        let configured = UserDefaults.standard.double(forKey: incrementKey)
        let plates = (UserDefaults.standard.string(forKey: plateKey) ?? defaultPlates)
            .split(separator: ",").compactMap { Double($0) }
        return WeightIncrement.step(equipmentIds: equipmentIds.map(TrainingDisplayNames.canonicalEquipment),
                                    platePairsKg: plates,
                                    fallbackKg: configured > 0 ? configured : defaultIncrement)
    }

    static func setEquipment(_ values: Set<String>) {
        UserDefaults.standard.set(values.sorted(), forKey: equipmentKey)
    }
}
