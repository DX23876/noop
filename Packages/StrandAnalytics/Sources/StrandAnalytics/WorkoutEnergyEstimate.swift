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
        /// The strap's own energy model over the session's window — the same five-minute buckets the
        /// day's total and its training share are built from, heart rate and movement together.
        case strapModel
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
    ///
    /// `strapKcal` is `strapWindowKcal` for the session, when the strap model covered it. It outranks
    /// the heart-rate estimate because it is built from the same samples plus movement, with the
    /// session's own workout context — and because it is the figure the day's energy already counts,
    /// so the session tile and the day's training share cannot tell two stories about one workout.
    public static func resolve(recordedKcal: Double?,
                               sport: String,
                               durationSeconds: Double,
                               averageHR: Int?,
                               profile: UserProfile,
                               hrMax: Double?,
                               restingHR: Double?,
                               strapKcal: Double? = nil) -> Resolved? {
        func valid(_ kcal: Double?, _ provenance: Provenance) -> Resolved? {
            guard let kcal, kcal.isFinite, kcal > 0 else { return nil }
            return Resolved(kcal: kcal, provenance: provenance)
        }

        if let resolved = valid(recordedKcal, .recorded) { return resolved }
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        if let resolved = valid(strapKcal, .strapModel) { return resolved }

        if let averageHR, averageHR > 0,
           let resolved = valid(heartRateKcal(averageHR: averageHR, sport: sport,
                                              durationSeconds: durationSeconds, profile: profile,
                                              hrMax: hrMax, restingHR: restingHR), .heartRate) {
            return resolved
        }

        return valid(ActivityMETCatalog.grossKcal(sport: sport, seconds: durationSeconds,
                                                  weightKg: profile.weightKg), .metTable)
    }
}

extension WorkoutEnergyEstimate {

    /// Gross energy from a session's average heart rate.
    ///
    /// Keytel (2005) was fitted on steady endurance exercise, and for lifting it reads the pressor
    /// response as oxygen uptake: the reported 90-minute session at 108 bpm came out at ~783 kcal,
    /// about 5.7 MET, where the Compendium puts resistance training at 3.5–6. A resistance session is
    /// therefore priced on the strap model's own curve (`WhoopEnergyModel.exerciseMET`, with the
    /// resistance share) plus the profile's basal rate — the same arithmetic its buckets use, so a
    /// session without strap coverage lands on the scale of one with it. Everything else keeps Keytel.
    static func heartRateKcal(averageHR: Int, sport: String, durationSeconds: Double,
                              profile: UserProfile, hrMax: Double?, restingHR: Double?) -> Double? {
        guard EnergyWorkoutKind.forSport(sport) == .resistance,
              let bmr = Calories.bmrKcalPerDay(profile: profile), profile.weightKg > 0 else {
            return Calories.estimateBoutCalories(averageHR: averageHR, durationSeconds: durationSeconds,
                                                 profile: profile, hrmax: hrMax, restingHR: restingHR)
        }
        // The same bounds the bucket model applies to its resting and maximum rates.
        let resting = min(100, max(35, restingHR ?? 60))
        let maximum = max(resting + 20, hrMax ?? profile.maxHR
                          ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : 190))
        let met = WhoopEnergyModel.exerciseMET(hr: Double(averageHR), resting: resting,
                                               maximum: maximum, kind: .resistance)
        return bmr / 86_400 * durationSeconds
            + WhoopEnergyModel.activeKcal(met: met, seconds: durationSeconds, weightKg: profile.weightKg)
    }

    /// One stored five-minute bucket of the strap energy model, as a session window reads it.
    public struct StrapBucket: Equatable, Sendable {
        public let start: Int
        public let durationSeconds: Int
        public let basalKcal: Double
        public let activeKcal: Double
        /// Nil for a context string this build does not know; such a bucket covers the window but
        /// never counts as the model having seen the workout.
        public let context: EnergyContext?

        public init(start: Int, durationSeconds: Int, basalKcal: Double, activeKcal: Double,
                    context: EnergyContext?) {
            self.start = start
            self.durationSeconds = durationSeconds
            self.basalKcal = basalKcal
            self.activeKcal = activeKcal
            self.context = context
        }
    }

    /// Share of the session window the model must have priced from the strap before it may answer.
    public static let strapMinimumCoverage = 0.8
    /// Share of those seconds the model must have priced AS the workout.
    public static let strapMinimumWorkoutShare = 0.5

    /// What the strap energy model charged for `[startTs, endTs)`, GROSS (basal plus active), or nil
    /// when it cannot answer for this session.
    ///
    /// Gross because every other estimated branch here is gross, so the tile keeps one scale whatever
    /// branch priced it. The day's "Training" line is ACTIVE energy only; the two differ by exactly
    /// the basal share of the window, which is summed here from the same buckets.
    ///
    /// Two gates, each answering "did the model actually see this session?":
    ///   • **coverage** — buckets (off-wrist excluded) span at least `strapMinimumCoverage` of the
    ///     window. The uncovered remainder is charged at the covered seconds' mean rate, a short gap
    ///     inside a workout being part of the workout.
    ///   • **workout context** — at least `strapMinimumWorkoutShare` of the covered seconds were
    ///     priced as `confirmedWorkout`. Buckets computed before the session was saved carry
    ///     `unresolvedElevatedHR` instead; summing those would state the stale answer as the strap's.
    ///
    /// `activeFactor` is the opted-in Watch calibration, applied to active energy only, exactly as the
    /// day total and the burn-rate chart apply it.
    public static func strapWindowKcal(buckets: [StrapBucket], startTs: Int, endTs: Int,
                                       activeFactor: Double = 1) -> Double? {
        guard endTs > startTs, activeFactor.isFinite, activeFactor > 0 else { return nil }
        var covered = 0.0
        var workout = 0.0
        var kcal = 0.0
        for bucket in buckets where bucket.durationSeconds > 0 && bucket.context != .offWrist {
            let overlap = Double(min(endTs, bucket.start + bucket.durationSeconds)
                                 - max(startTs, bucket.start))
            guard overlap > 0, bucket.basalKcal.isFinite, bucket.activeKcal.isFinite else { continue }
            covered += overlap
            if bucket.context == .confirmedWorkout { workout += overlap }
            kcal += (max(0, bucket.basalKcal) + max(0, bucket.activeKcal) * activeFactor)
                * overlap / Double(bucket.durationSeconds)
        }
        let window = Double(endTs - startTs)
        guard covered > 0, covered >= window * strapMinimumCoverage,
              workout >= covered * strapMinimumWorkoutShare else { return nil }
        let total = kcal * window / covered
        return total.isFinite && total > 0 ? total : nil
    }
}
