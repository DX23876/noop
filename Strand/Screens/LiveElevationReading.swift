import Foundation

/// The three live elevation figures, read together at one moment so the page never shows a gain from one
/// tick beside a height from another.
struct LiveElevationReading: Equatable {
    var ascentM: Double?
    var descentM: Double?
    var altitudeM: Double?
}
