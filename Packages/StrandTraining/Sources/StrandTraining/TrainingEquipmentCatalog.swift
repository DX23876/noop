import Foundation

/// NOOP's equipment vocabulary. Stored ids never change; provider and legacy spellings are folded onto
/// one canonical id so a stored exercise, the catalogue and the wearer's equipment list can be compared.
public enum TrainingEquipmentCatalog {
    public static let known: Set<String> = [
        "barbell", "ez-bar", "trap-bar", "smith-machine", "dumbbell", "kettlebell", "cable", "machine",
        "band", "bench", "pull-up-bar", "dip-bar", "squat-rack", "weight-belt", "box", "medicine-ball",
        "sled", "rings", "bodyweight", "stability-ball", "bosu-ball", "foam-roller", "ab-wheel",
        "rope", "tire", "hammer"
    ]

    /// Implements that carry external load. Benches, racks and belts support a lift without being the
    /// load, which is why a weight-and-repetitions exercise is not defined by them.
    public static let loadBearing: Set<String> = [
        "barbell", "ez-bar", "trap-bar", "smith-machine", "dumbbell", "kettlebell", "cable", "machine",
        "band", "medicine-ball", "sled"
    ]

    public static func canonical(_ id: String) -> String {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        switch key {
        case "bar", "pullup-bar", "chin-up-bar": return "pull-up-bar"
        case "rack", "power-rack": return "squat-rack"
        case "resistance-band", "bands": return "band"
        case "body-weight", "none": return "bodyweight"
        case "ez-curl-bar", "ezbar", "ez-barbell": return "ez-bar"
        case "dipbar", "parallel-bars": return "dip-bar"
        case "olympic-barbell": return "barbell"
        case "leverage-machine", "sled-machine", "upper-body-ergometer", "skierg-machine",
             "stationary-bike", "elliptical-machine", "stepmill-machine":
            return "machine"
        case "exercise-ball", "swiss-ball": return "stability-ball"
        case "wheel-roller": return "ab-wheel"
        case "roller": return "foam-roller"
        default: return key
        }
    }

    public static func isKnown(_ id: String) -> Bool { known.contains(canonical(id)) }

    public static func carriesExternalLoad(_ ids: [String]) -> Bool {
        !loadBearing.isDisjoint(with: ids.map(canonical))
    }
}

/// Coarse grouping used for browsing and filtering. It is derived from the muscles an exercise trains,
/// so it can never disagree with the muscle mapping the analytics use.
public enum TrainingBodyRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case chest, back, shoulders, arms, core, legs, other

    public var id: String { rawValue }

    public static func forMuscle(_ muscleId: String) -> TrainingBodyRegion {
        switch muscleId {
        case "chest", "upper_chest", "lower_chest": return .chest
        case "lats", "upper_back", "rhomboids", "traps", "upper_traps", "lower_traps", "lower_back":
            return .back
        case "front_delts", "side_delts", "rear_delts", "rotator_cuff", "neck": return .shoulders
        case "biceps", "triceps", "forearms": return .arms
        case "abdominals", "upper_abs", "lower_abs", "obliques", "serratus": return .core
        case "quadriceps", "inner_quadriceps", "outer_quadriceps", "hamstrings", "glutes",
             "hip_flexors", "adductors", "abductors", "calves", "tibialis":
            return .legs
        default: return .other
        }
    }

    /// The region of the first primary muscle, which is the muscle the exercise is named for.
    public static func forMuscles(_ muscleIds: [String]) -> TrainingBodyRegion {
        muscleIds.lazy.map(forMuscle).first { $0 != .other } ?? .other
    }
}
