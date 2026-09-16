import Foundation
import StrandTraining
import WhoopStore

/// Localized presentation of NOOP's stable training identifiers. Stored ids never change; only the
/// name shown to the reader follows their language. Unknown provider ids fall back to a readable form.
enum TrainingDisplayNames {
    static func muscle(_ id: String?) -> String {
        guard let id else { return String(localized: "Other") }
        return localizedMuscle(id) ?? readable(id)
    }

    static func equipment(_ id: String) -> String {
        localizedEquipment(canonicalEquipment(id)) ?? readable(id)
    }

    /// Maps legacy and provider spellings onto the vocabulary offered in Settings › Training, so an
    /// exercise stored as `bar` still matches a selected `pull-up-bar`. The mapping itself lives in
    /// `StrandTraining`, so the catalogue validation and the app can never disagree about an id.
    static func canonicalEquipment(_ id: String) -> String {
        TrainingEquipmentCatalog.canonical(id)
    }

    static func region(_ region: TrainingBodyRegion) -> String {
        switch region {
        case .chest: return String(localized: "Chest")
        case .back: return String(localized: "Back")
        case .shoulders: return String(localized: "Shoulders")
        case .arms: return String(localized: "Arms")
        case .core: return String(localized: "Core")
        case .legs: return String(localized: "Legs")
        case .other: return String(localized: "Other")
        }
    }

    /// How an exercise is measured. This is the "kind of exercise" a filter means in practice, and it
    /// is the same wording the exercise detail uses.
    static func measurement(_ mode: TrainingMeasurementMode) -> String {
        switch mode {
        case .weightReps: return String(localized: "Weight and repetitions")
        case .bodyweightReps: return String(localized: "Bodyweight repetitions")
        case .weightedBodyweight: return String(localized: "Weighted bodyweight")
        case .assistedBodyweight: return String(localized: "Assisted bodyweight")
        case .repetitions: return String(localized: "Repetitions")
        case .duration: return String(localized: "Duration")
        case .distanceDuration: return String(localized: "Distance and duration")
        }
    }

    /// Where a logged session came from. Product names stay as they are written — they are names, not
    /// words — so only NOOP's own logger and the two generic cases are translated. Used wherever a
    /// session states its provenance, so a workout logged in NOOP can never be labelled as an import.
    static func strengthSource(_ source: StrengthDataSource) -> String {
        switch source {
        case .noopNative: return String(localized: "Logged in NOOP")
        case .hevyAPI, .hevyCSV: return "Hevy"
        case .liftosaur: return "Liftosaur"
        case .fitNotes: return "FitNotes"
        case .strong: return "Strong"
        case .imported: return String(localized: "Imported")
        case .manual: return String(localized: "Entered by hand")
        }
    }

    static func localizedMuscle(_ id: String) -> String? {
        switch id {
        case "chest": return String(localized: "Chest")
        case "upper_chest": return String(localized: "Upper chest")
        case "lower_chest": return String(localized: "Lower chest")
        case "serratus": return String(localized: "Serratus")
        case "front_delts": return String(localized: "Front delts")
        case "side_delts": return String(localized: "Side delts")
        case "rear_delts": return String(localized: "Rear delts")
        case "rotator_cuff": return String(localized: "Rotator cuff")
        case "triceps": return String(localized: "Triceps")
        case "biceps": return String(localized: "Biceps")
        case "forearms": return String(localized: "Forearms")
        case "lats": return String(localized: "Lats")
        case "upper_back": return String(localized: "Upper back")
        case "rhomboids": return String(localized: "Rhomboids")
        case "traps": return String(localized: "Traps")
        case "upper_traps": return String(localized: "Upper traps")
        case "lower_traps": return String(localized: "Lower traps")
        case "lower_back": return String(localized: "Lower back")
        case "abdominals": return String(localized: "Abdominals")
        case "upper_abs": return String(localized: "Upper abs")
        case "lower_abs": return String(localized: "Lower abs")
        case "obliques": return String(localized: "Obliques")
        case "quadriceps": return String(localized: "Quadriceps")
        case "inner_quadriceps": return String(localized: "Inner quadriceps")
        case "outer_quadriceps": return String(localized: "Outer quadriceps")
        case "hamstrings": return String(localized: "Hamstrings")
        case "glutes": return String(localized: "Glutes")
        case "hip_flexors": return String(localized: "Hip flexors")
        case "adductors": return String(localized: "Adductors")
        case "abductors": return String(localized: "Abductors")
        case "calves": return String(localized: "Calves")
        case "tibialis": return String(localized: "Tibialis")
        case "neck": return String(localized: "Neck")
        default: return nil
        }
    }

    static func localizedEquipment(_ canonicalId: String) -> String? {
        switch canonicalId {
        case "barbell": return String(localized: "Barbell")
        case "dumbbell": return String(localized: "Dumbbell")
        case "kettlebell": return String(localized: "Kettlebell")
        case "cable": return String(localized: "Cable")
        case "machine": return String(localized: "Machine")
        case "band": return String(localized: "Resistance band")
        case "bench": return String(localized: "Bench")
        case "pull-up-bar": return String(localized: "Pull-up bar")
        case "squat-rack": return String(localized: "Squat rack")
        case "weight-belt": return String(localized: "Weight belt")
        case "bodyweight": return String(localized: "Bodyweight")
        case "ez-bar": return String(localized: "EZ bar")
        case "trap-bar": return String(localized: "Trap bar")
        case "smith-machine": return String(localized: "Smith machine")
        case "stability-ball": return String(localized: "Stability ball")
        case "bosu-ball": return String(localized: "Bosu ball")
        case "foam-roller": return String(localized: "Foam roller")
        case "ab-wheel": return String(localized: "Ab wheel")
        case "rope": return String(localized: "Battle rope")
        case "tire": return String(localized: "Tyre")
        case "hammer": return String(localized: "Sledgehammer")
        case "dip-bar": return String(localized: "Dip bar")
        case "box": return String(localized: "Box")
        case "medicine-ball": return String(localized: "Medicine ball")
        case "sled": return String(localized: "Sled")
        case "rings": return String(localized: "Rings")
        default: return nil
        }
    }

    private static func readable(_ id: String) -> String {
        id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}
