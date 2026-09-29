import Foundation
import WhoopProtocol

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
        /// The session's measured distance over its duration, on the speed curve the day model prices
        /// every walk with. For walking, running, hiking and rucking only.
        case pace
        /// The session's heart rate against the wearer's aerobic ceiling (`exerciseMET`), the curve the
        /// day model prices confirmed workouts on — evidence about the person who did it.
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
    /// **The figure is GROSS** in every estimated branch — the wearer's basal rate for the window plus
    /// the energy above it, as the day model's buckets are. That matches what the app's own strap, detected and manual lanes already store,
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
                               strapKcal: Double? = nil,
                               peakMET: Double? = nil,
                               distanceM: Double? = nil) -> Resolved? {
        func valid(_ kcal: Double?, _ provenance: Provenance) -> Resolved? {
            guard let kcal, kcal.isFinite, kcal > 0 else { return nil }
            return Resolved(kcal: kcal, provenance: provenance)
        }

        if let resolved = valid(recordedKcal, .recorded) { return resolved }
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        if let resolved = valid(strapKcal, .strapModel) { return resolved }

        let pricer = SessionPricer(sport: sport, profile: profile, hrMax: hrMax, restingHR: restingHR,
                                   peakMET: peakMET)
        if let pricer, let resolved = valid(pricer.paceKcal(distanceM: distanceM,
                                                              seconds: durationSeconds), .pace) {
            return resolved
        }
        if let pricer, let averageHR, averageHR > 0,
           let resolved = valid(pricer.heartRateKcal(bpm: Double(averageHR), seconds: durationSeconds),
                                 .heartRate) {
            return resolved
        }
        if let pricer { return valid(pricer.tableKcal(seconds: durationSeconds), .metTable) }
        return valid(ActivityMETCatalog.grossKcal(sport: sport, seconds: durationSeconds,
                                                  weightKg: profile.weightKg), .metTable)
    }
}

extension WorkoutEnergyEstimate {

    /// Gross energy from a session's average heart rate, or nil when it cannot be priced from heart
    /// rate (no aerobic ceiling for the day, or no body data).
    ///
    /// Linear in heart rate, so the average prices a session exactly as its samples would.
    static func heartRateKcal(averageHR: Int, sport: String, durationSeconds: Double,
                              profile: UserProfile, hrMax: Double?, restingHR: Double?,
                              peakMET: Double? = nil) -> Double? {
        SessionPricer(sport: sport, profile: profile, hrMax: hrMax, restingHR: restingHR,
                      peakMET: peakMET)?
            .heartRateKcal(bpm: Double(averageHR), seconds: durationSeconds)
    }

    /// Gross energy of a bout from its heart-rate SAMPLES — the figure NOOP stores for a session it
    /// timed itself: a live save, a detected bout, the rescore of an under-scored manual row.
    ///
    /// Priced the way the day model prices the same time: a session on foot with a measured distance
    /// by its pace; otherwise sample by sample on `exerciseMET` against the day's aerobic ceiling;
    /// without a ceiling, the sport's table MET over the samples' span. Keytel, which these paths used
    /// before, was fitted on 47–120 kg regular exercisers and read a 212 kg wearer's walk at three
    /// times its cost.
    ///
    /// Samples are weighted by the time to the next one, capped at `WorkoutDetector.mergeGapS`, so a
    /// sparse stream is not undercounted and a wear gap cannot be inflated. Zero with fewer than two
    /// samples, or without the body data to price basal.
    public static func boutKcal(_ samples: [HRSample], sport: String, profile: UserProfile,
                                hrMax: Double?, restingHR: Double?, peakMET: Double? = nil,
                                distanceM: Double? = nil) -> Double {
        let ordered = samples.sorted { $0.ts < $1.ts }
        guard ordered.count >= 2,
              let pricer = SessionPricer(sport: sport, profile: profile, hrMax: hrMax,
                                         restingHR: restingHR, peakMET: peakMET) else { return 0 }
        var weighted: [(bpm: Double, seconds: Double)] = []
        for index in ordered.indices {
            let seconds: Double
            if index < ordered.count - 1 {
                let gap = Double(ordered[index + 1].ts - ordered[index].ts)
                seconds = gap > 0 ? min(gap, WorkoutDetector.mergeGapS) : 1
            } else {
                seconds = 1
            }
            weighted.append((Double(ordered[index].bpm), seconds))
        }
        let span = weighted.reduce(0.0) { $0 + $1.seconds }
        if let pace = pricer.paceKcal(distanceM: distanceM, seconds: span) { return pace }
        if pricer.canPriceHeartRate {
            return weighted.reduce(0.0) { $0 + (pricer.heartRateKcal(bpm: $1.bpm, seconds: $1.seconds) ?? 0) }
        }
        return pricer.tableKcal(seconds: span)
    }

    /// The part of a gross session figure above the wearer's resting rate, which is what Apple Health
    /// means by active energy. Nil without the body data to price basal.
    public static func activeShare(grossKcal: Double, seconds: Double, profile: UserProfile) -> Double? {
        guard grossKcal.isFinite, seconds.isFinite, seconds > 0,
              let bmr = Calories.bmrKcalPerDay(profile: profile) else { return nil }
        return max(0, grossKcal - bmr / 86_400 * seconds)
    }

    /// One session's inputs, resolved once: the basal rate, the heart-rate bounds the bucket model
    /// applies, the aerobic ceiling and the sport's curve. Nil without the body data to price basal.
    struct SessionPricer {
        let basalPerSecond: Double
        let weightKg: Double
        let resting: Double
        let maximum: Double
        let peakMET: Double?
        let kind: EnergyWorkoutKind
        let onFoot: Bool
        let tableMET: Double

        init?(sport: String, profile: UserProfile, hrMax: Double?, restingHR: Double?,
              peakMET: Double?) {
            guard let bmr = Calories.bmrKcalPerDay(profile: profile), profile.weightKg > 0 else {
                return nil
            }
            basalPerSecond = bmr / 86_400
            weightKg = profile.weightKg
            resting = min(100, max(35, restingHR ?? 60))
            let fallbackMax = profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : 190
            maximum = max(resting + 20, hrMax ?? profile.maxHR ?? fallbackMax)
            self.peakMET = peakMET.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            kind = EnergyWorkoutKind.forSport(sport)
            onFoot = EnergyWorkoutKind.isOnFoot(sport: sport)
            tableMET = ActivityMETCatalog.met(forSport: sport)
        }

        var canPriceHeartRate: Bool { peakMET != nil }

        /// Average speeds a session on foot can plausibly have had. Outside them the distance is taken as
        /// a failed recording, not a pace: live GPS walks in real data carry 7 m or 47 m for half an hour,
        /// which would price the session at rest.
        static let plausibleKmh: ClosedRange<Double> = 1.5...25

        /// Basal plus the energy above it at the session's average speed, for a session on foot with a
        /// plausible measured distance; nil otherwise.
        func paceKcal(distanceM: Double?, seconds: Double) -> Double? {
            guard onFoot, let distanceM, distanceM.isFinite, distanceM > 0,
                  seconds.isFinite, seconds > 0 else { return nil }
            let kmh = distanceM / 1_000 / (seconds / 3_600)
            guard Self.plausibleKmh.contains(kmh) else { return nil }
            let met = WhoopEnergyModel.metForSpeed(kmh)
            return basalPerSecond * seconds
                + WhoopEnergyModel.activeKcal(met: met, seconds: seconds, weightKg: weightKg)
        }

        /// Basal plus `exerciseMET` energy for `seconds` at `bpm`; nil without an aerobic ceiling.
        func heartRateKcal(bpm: Double, seconds: Double) -> Double? {
            guard let peakMET, seconds.isFinite, seconds > 0 else { return nil }
            let met = WhoopEnergyModel.exerciseMET(hr: bpm, resting: resting, maximum: maximum,
                                                   kind: kind, peakMET: peakMET)
            return basalPerSecond * seconds
                + WhoopEnergyModel.activeKcal(met: met, seconds: seconds, weightKg: weightKg)
        }

        /// Basal plus the sport's table MET above rest, the bucket model's own table branch.
        func tableKcal(seconds: Double) -> Double {
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return basalPerSecond * seconds
                + WhoopEnergyModel.activeKcal(met: tableMET, seconds: seconds, weightKg: weightKg)
        }
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

// MARK: - Recognising a figure NOOP computed before model v8

/// Whether a stored session figure is one NOOP computed with a formula it no longer uses.
///
/// Manual rows carry no record of where their energy came from: the live recorder, the post-sync
/// rescore and the detector's backfill all wrote a computed figure, and the manual sheet stores one the
/// wearer typed, in the same column. The one-time correction of the Keytel figures therefore recognises
/// a computed value by reproducing it: a figure within `tolerance` of what an old formula gives on the
/// strap's heart rate for the same window was, with near certainty, produced by that formula. A typed
/// figure has no reason to land there, and is left alone. The tolerance absorbs what drifted since the
/// figure was written: body weight, the resting rate of that day, the live stream against the offloaded
/// one.
public enum LegacyWorkoutEnergy {

    /// Relative distance within which a stored figure counts as reproduced.
    public static let tolerance = 0.20

    /// The figures the old formulas give for this window: Keytel (every sport until model v8) and, for
    /// lifting, the v7 resistance curve with Uth's ceiling bounded to 7–16 MET.
    public static func candidates(_ samples: [HRSample], sport: String, profile: UserProfile,
                                  hrMax: Double?, restingHR: Double?) -> [Double] {
        var out = [Calories.estimateBoutCalories(samples, profile: profile, hrmax: hrMax,
                                                 restingHR: restingHR).0]
        if EnergyWorkoutKind.forSport(sport) == .resistance {
            let resting = min(100, max(35, restingHR ?? 60))
            let maximum = max(resting + 20, hrMax ?? 190)
            let uth = Calories.vo2maxFor(hrmax: maximum, restingHR: resting).map { $0 / 3.5 } ?? 10
            let v7Peak = min(16, max(7, uth))
            out.append(WorkoutEnergyEstimate.boutKcal(samples, sport: sport, profile: profile,
                                                      hrMax: hrMax, restingHR: restingHR,
                                                      peakMET: v7Peak))
        }
        return out.filter { $0.isFinite && $0 > 0 }
    }

    /// True when `stored` is within `tolerance` of any old formula's figure for the window.
    public static func looksComputed(stored: Double, samples: [HRSample], sport: String,
                                     profile: UserProfile, hrMax: Double?, restingHR: Double?) -> Bool {
        guard stored.isFinite, stored > 0, samples.count >= 2 else { return false }
        return candidates(samples, sport: sport, profile: profile, hrMax: hrMax, restingHR: restingHR)
            .contains { abs(stored - $0) <= tolerance * $0 }
    }

    /// Replays the live workout summary when a later strap offload has a different HR coverage.
    /// The live save persisted its mean HR and moving duration alongside the energy figure.
    public static func looksComputed(stored: Double, averageHR: Int?, durationSeconds: Double?,
                                     profile: UserProfile, hrMax: Double?, restingHR: Double?) -> Bool {
        guard stored.isFinite, stored > 0, let averageHR, let durationSeconds,
              let candidate = Calories.estimateBoutCalories(
                  averageHR: averageHR, durationSeconds: durationSeconds,
                  profile: profile, hrmax: hrMax, restingHR: restingHR) else { return false }
        return candidate.isFinite && candidate > 0 && abs(stored - candidate) <= tolerance * candidate
    }
}
