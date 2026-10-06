import Foundation

/// A location measurement and its optional motion evidence, without platform framework types.
struct RawFix: Equatable {
    let lat: Double
    let lon: Double
    let accuracyM: Double
    let tMs: Int64
    var speedMps: Double? = nil
    var speedAccuracyMps: Double? = nil
    var stationary = false

    /// An invalid or absent speed is unknown, rather than evidence that the phone is still.
    var hasValidSpeed: Bool {
        guard let speedMps, let speedAccuracyMps else { return false }
        return speedMps.isFinite && speedMps >= 0
            && speedAccuracyMps.isFinite && speedAccuracyMps >= 0
    }
}
