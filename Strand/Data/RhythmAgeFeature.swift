import Foundation

/// The Lab switch for the daily-rhythm card (CosinorAge beta, WHOOP 5.0 and MG). Off by default.
enum RhythmAgeFeature {
    static let defaultsKey = "noopRhythmAge"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}
