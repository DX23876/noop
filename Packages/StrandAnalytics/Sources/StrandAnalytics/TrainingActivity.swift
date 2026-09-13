import Foundation

/// Broad purpose of a recorded workout. The stable family decides where a session is presented;
/// cardiovascular load remains eligible for every family when measured heart-rate coverage exists.
public enum TrainingActivityKind: String, Codable, CaseIterable, Sendable {
    case endurance
    case strength
    case conditioning
    case mobilityRecovery = "mobility_recovery"
    case outdoorRecreation = "outdoor_recreation"
    case multisport
    case other
}

/// One stable activity description shared by HealthKit, manual workouts and imported files.
/// `id` and `storedName` are locale-independent; display layers localize `displayKey`.
public struct TrainingActivityDescriptor: Equatable, Codable, Sendable {
    public let id: String
    public let storedName: String
    public let displayKey: String
    public let kind: TrainingActivityKind
    public let supportsDistance: Bool
    public let supportsRoute: Bool

    public init(id: String, storedName: String, displayKey: String,
                kind: TrainingActivityKind, supportsDistance: Bool, supportsRoute: Bool) {
        self.id = id
        self.storedName = storedName
        self.displayKey = displayKey
        self.kind = kind
        self.supportsDistance = supportsDistance
        self.supportsRoute = supportsRoute
    }
}

/// Locale-stable fallback classification for legacy and free-text workout names.
/// Platform adapters should prefer their native identifier mapping and use this only when no identifier exists.
public enum TrainingActivityClassifier {
    public static func kind(forStoredName name: String) -> TrainingActivityKind {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        func has(_ values: String...) -> Bool { values.contains { key.contains($0) } }

        if has("strength", "weightlift", "powerlift", "bodybuild", "lifting", "calisthen", "kraft",
               "coretraining") {
            return .strength
        }
        if has("triathlon", "swimbikerun", "multisport", "transition") { return .multisport }
        if has("run", "jog", "walk", "hik", "treadmill", "cycl", "bike", "swim", "row",
               "elliptical", "stair", "steptraining", "paddl", "kayak", "canoe", "ski",
               "snowboard", "skating", "wheelchair", "waterfitness", "handcycling") {
            return .endurance
        }
        if has("yoga", "pilates", "barre", "flexibility", "stretch", "mobility", "recovery",
               "cooldown", "taichi", "meditation", "mindbody", "mindandbody") {
            return .mobilityRecovery
        }
        if has("archery", "bowling", "curling", "equestrian", "horse", "fishing", "golf", "hunting",
               "sailing", "diving", "snowsports", "watersports") {
            return .outdoorRecreation
        }
        if has("hiit", "crossfit", "crosstraining", "mixedcardio", "mixedmetabolic", "football", "soccer", "basketball",
               "baseball", "boxing", "cricket", "fencing", "gymnastics", "handball", "hockey", "lacrosse",
               "martial", "rugby", "softball", "squash", "surf", "tennis", "volleyball", "wrestling",
               "dance", "pickleball", "badminton", "jumprope", "fitnessgaming", "climbing", "play",
               "racquetball", "discsport", "waterpolo", "trackandfield", "kickboxing") {
            return .conditioning
        }
        return .other
    }
}
