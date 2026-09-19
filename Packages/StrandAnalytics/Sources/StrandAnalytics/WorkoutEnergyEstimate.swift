import Foundation

// WorkoutEnergyEstimate.swift — what one session cost, and how we know.
//
// A session arrives with energy, or it does not. A WHOOP workout and an Apple Health import carry a
// figure; a native strength session, a Hevy import and a manually entered bout carry none, and the
// Workouts screen printed a dash for them beside a full heart-rate curve. That was reported as
// "the training that u record, when viewed in workouts, it shows no calories burned" — with a
// screenshot of a 1 h 17 min session at an average of 103 bpm, which is more than enough to answer.
//
// The estimate existed already, in the energy day's own fallback. What did not exist was a way to
// SHOW it: that path returns a contribution with a window and a lane, and flattens the question
// "where did this number come from?" into a single `isEstimated` flag. A screen needs the specific
// answer, because "~420 kcal" from a heart rate and "~420 kcal" from a table of activity names are
// different claims, and the caption under the tile has to say which.
//
// So the precedence lives here, once, and both callers read it: strongest evidence first, each step
// weaker than the one before, and every step named in the result.
public enum WorkoutEnergyEstimate {

    /// Where a session's energy figure came from, strongest first.
    public enum Provenance: String, Equatable, Sendable {
        /// The session recorded it. Not an estimate.
        case recorded
        /// Keytel at the session's average heart rate — evidence about the person who did it.
        case heartRate
        /// The published activity cost for the sport's NAME. A population average, and the last
        /// resort: it knows what the activity usually costs, not what this one did.
        case metTable
    }

    public struct Resolved: Equatable, Sendable {
        public let kcal: Double
        public let provenance: Provenance

        public var isEstimated: Bool { provenance != .recorded }

        public init(kcal: Double, provenance: Provenance) {
            self.kcal = kcal
            self.provenance = provenance
        }
    }

    /// A session's energy, or nil when nothing can price it at all.
    ///
    /// Nil rather than zero, deliberately: a session with no duration and no body mass is a session
    /// nobody can cost, and reporting 0 kcal for it would be a measurement of nothing.
    ///
    /// **The figure is GROSS** in every estimated branch — `Calories.estimateBoutCalories` integrates
    /// the resting rate below its activity gate, and a MET is by definition a multiple of resting
    /// metabolism. That matches what the app's own strap, detected and manual lanes already store,
    /// so an estimated row reads on the same scale as a recorded one beside it. An Apple import is
    /// energy ABOVE resting and is returned untouched as `.recorded`: converting it here would
    /// silently restate a figure the wearer can also see in Apple's own app.
    public static func resolve(recordedKcal: Double?,
                               sport: String,
                               durationSeconds: Double,
                               averageHR: Int?,
                               profile: UserProfile,
                               hrMax: Double?,
                               restingHR: Double?) -> Resolved? {
        func valid(_ kcal: Double?, _ provenance: Provenance) -> Resolved? {
            guard let kcal, kcal.isFinite, kcal > 0 else { return nil }
            return Resolved(kcal: kcal, provenance: provenance)
        }

        if let resolved = valid(recordedKcal, .recorded) { return resolved }
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }

        if let averageHR, averageHR > 0,
           let resolved = valid(Calories.estimateBoutCalories(averageHR: averageHR,
                                                              durationSeconds: durationSeconds,
                                                              profile: profile, hrmax: hrMax,
                                                              restingHR: restingHR), .heartRate) {
            return resolved
        }

        return valid(ActivityMETCatalog.grossKcal(sport: sport, seconds: durationSeconds,
                                                  weightKg: profile.weightKg), .metTable)
    }
}
