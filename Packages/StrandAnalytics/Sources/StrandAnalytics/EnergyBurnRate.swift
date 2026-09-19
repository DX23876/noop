import Foundation

// EnergyBurnRate.swift — "when did you burn it", as opposed to "how much did you burn".
//
// The Energy detail screen already answers the second question twice: a total at the top and a
// 30-day history at the bottom. Between them sits the question neither answers — whether today's
// energy arrived in two sessions or was spread evenly across sixteen hours, and whether that is
// how this person's day normally goes. That is a RATE (kcal per minute against time of day), not a
// cumulative curve, and it is the only shape on which a workout band or a reference curve means
// anything: a cumulative line rises through a workout and keeps rising afterwards, so nothing on it
// marks where the workout was.
//
// Three properties are deliberate:
//
//   • The rate INCLUDES basal. The figure above the chart is a total, and a curve whose integral is
//     a different quantity than the number printed over it is a contradiction nobody finds until
//     they do the arithmetic. Basal is a low flat sockel; it costs the peaks nothing.
//   • A gap stays a gap. An hour the strap did not cover produces no slice, and this file does not
//     invent a basal-only one to close the line. A drawn line through unmeasured time is a claim
//     about that time.
//   • The reference curve is a MEDIAN over qualifying days, by the same admission test and for the
//     same reason as `ActivityShapeEngine`: one holiday, one forgotten charge or one marathon must
//     not redefine what this person's normal afternoon looks like.
//
// Pure: no store, no clock, no views. Every input is handed in, including the day's own length, so
// a DST day and a day at the far end of a 30-day window are as testable as today.
public enum EnergyBurnRate {

    // MARK: - Inputs

    /// One measured slice of a day — a stored energy bucket, placed by seconds from local midnight.
    ///
    /// `basalKcal` travels with the slice rather than being modelled here because the bucket model
    /// already decided how much of that window was resting; recomputing it from a BMR would be a
    /// second opinion on a question already answered, and the two would drift.
    public struct Slice: Equatable, Sendable {
        public let startSeconds: Double
        public let durationSeconds: Double
        public let basalKcal: Double
        public let activeKcal: Double

        public init(startSeconds: Double, durationSeconds: Double,
                    basalKcal: Double, activeKcal: Double) {
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
            self.basalKcal = basalKcal
            self.activeKcal = activeKcal
        }
    }

    /// One past day's active energy in 24 local hours — what `whoopEnergyHourly` stores.
    public struct DayHours: Equatable, Sendable {
        public let day: String
        /// 24 entries, hour 0...23, active kcal only. A day with any other count is dropped rather
        /// than padded: a short row is a storage fault, and padding it with zeros would quietly
        /// report those hours as measured and idle.
        public let activeKcalByHour: [Double]

        public init(day: String, activeKcalByHour: [Double]) {
            self.day = day
            self.activeKcalByHour = activeKcalByHour
        }
    }

    /// A half-open span of a local day, in seconds from its midnight. Used for workout windows,
    /// which is why it is clipped rather than validated: a session that started yesterday evening
    /// or runs past midnight is a normal session, not bad input.
    public struct Window: Equatable, Sendable {
        public let startSeconds: Double
        public let endSeconds: Double

        public init(startSeconds: Double, endSeconds: Double) {
            self.startSeconds = min(startSeconds, endSeconds)
            self.endSeconds = max(startSeconds, endSeconds)
        }
    }

    // MARK: - Outputs

    public struct Point: Equatable, Sendable {
        public let startSeconds: Double
        public let durationSeconds: Double
        public let kcalPerMinute: Double

        public init(startSeconds: Double, durationSeconds: Double, kcalPerMinute: Double) {
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
            self.kcalPerMinute = kcalPerMinute
        }
    }

    public struct Reference: Equatable, Sendable {
        /// 24 hourly points. Hourly and not finer on purpose: this is a median of several days, and
        /// five-minute resolution would render a precision the averaging has already removed.
        public let points: [Point]
        /// How many days actually qualified, so the screen can say "5 of 7" instead of implying 7.
        public let sampleDays: Int
        /// How many days were asked for. The pair is what makes the count honest.
        public let windowDays: Int

        public init(points: [Point], sampleDays: Int, windowDays: Int) {
            self.points = points
            self.sampleDays = sampleDays
            self.windowDays = windowDays
        }
    }

    /// Below this a reference curve is not offered at all. Two days is a pair of days, not a norm —
    /// and unlike `ActivityShapeEngine.minimumDays` this does not have to protect a forecast, only a
    /// dotted line the reader can see the sample count for.
    public static let minimumReferenceDays = 3

    // MARK: - The measured day

    /// The selected day's own burn rate, one point per stored slice.
    ///
    /// Slices are not merged, resampled or smoothed. The bucket grid IS the measurement's
    /// resolution, and a smoothing pass would lower exactly the peaks the chart exists to show.
    public static func measured(slices: [Slice]) -> [Point] {
        slices.compactMap { slice in
            guard slice.durationSeconds.isFinite, slice.durationSeconds > 0,
                  slice.startSeconds.isFinite, slice.startSeconds >= 0 else { return nil }
            let basal = slice.basalKcal.isFinite ? max(0, slice.basalKcal) : 0
            let active = slice.activeKcal.isFinite ? max(0, slice.activeKcal) : 0
            let perMinute = (basal + active) / (slice.durationSeconds / 60)
            guard perMinute.isFinite else { return nil }
            return Point(startSeconds: slice.startSeconds,
                         durationSeconds: slice.durationSeconds,
                         kcalPerMinute: perMinute)
        }
        .sorted { $0.startSeconds < $1.startSeconds }
    }

    // MARK: - The reference curve

    /// A typical day's rate for this person, as a median across `days`.
    ///
    /// `days` must already be filtered to the qualifying ones (`dayQualifies`) — this function
    /// cannot see a model version or a coverage figure and must not guess at one.
    ///
    /// Basal is added as a FLAT sockel from the profile rather than read back per day, because the
    /// hourly store keeps active energy only. Over a 7- or 30-day window a person's basal rate moves
    /// by a few kcal; carrying that approximation is cheaper than the alternative, which is a
    /// reference curve measuring a different quantity than the curve it is drawn against.
    public static func reference(days: [DayHours], windowDays: Int,
                                 basalKcalPerDay: Double?) -> Reference? {
        let usable = days
            .filter { $0.activeKcalByHour.count == 24 }
            .map { $0.activeKcalByHour.map { $0.isFinite && $0 > 0 ? $0 : 0 } }
        guard usable.count >= minimumReferenceDays else { return nil }

        let basalPerHour: Double = {
            guard let basalKcalPerDay, basalKcalPerDay.isFinite, basalKcalPerDay > 0 else { return 0 }
            return basalKcalPerDay / 24
        }()

        let points = (0..<24).map { hour -> Point in
            let active = ActivityShapeEngine.median(usable.map { $0[hour] })
            return Point(startSeconds: Double(hour) * 3_600,
                         durationSeconds: 3_600,
                         kcalPerMinute: (active + basalPerHour) / 60)
        }
        return Reference(points: points, sampleDays: usable.count, windowDays: windowDays)
    }

    /// The admission test for a day that is allowed to describe a norm: produced by the CURRENT
    /// model, and solidly covered.
    ///
    /// It lives here, and `Repository.activityShape` calls it too, so the two curves on the Energy
    /// screen cannot come to disagree about which days were good enough. Both halves matter: an old
    /// model version means the day's kcal are not comparable with today's at all, and a thin day
    /// reports the hours the strap was off as hours this person was still.
    public static func dayQualifies(modelVersion: String, representedSeconds: Int) -> Bool {
        modelVersion == WhoopDailyEnergyEstimate.modelVersion
            && Double(representedSeconds) >= 86_400 * EnergyEngine.solidCoverage
    }

    // MARK: - Training vs the rest of the day

    /// Splits a day's ACTIVE energy into the part that happened inside a logged session and the part
    /// that did not.
    ///
    /// Deliberately defined by INTERSECTION with the session windows the screen also draws as bands,
    /// rather than by the buckets' own `isWorkout` flag. The two disagree — a strap auto-detects
    /// differently from what the wearer logged — and when they do, the card would claim a training
    /// figure that the bands beneath it visibly do not add up to, with nothing on screen to explain
    /// the difference. One source, one number, and the band IS the tile.
    ///
    /// Basal is untouched: resting energy during a workout is resting energy, and moving it into
    /// "training" would make the four figures on the card stop summing to the total.
    public static func activeSplit(slices: [Slice], training windows: [Window])
        -> (training: Double, movement: Double) {
        let clean = windows.filter { $0.endSeconds > $0.startSeconds }
        var training = 0.0
        var movement = 0.0
        for slice in slices {
            guard slice.durationSeconds.isFinite, slice.durationSeconds > 0,
                  slice.activeKcal.isFinite, slice.activeKcal > 0 else { continue }
            let sliceEnd = slice.startSeconds + slice.durationSeconds
            // Overlapping sessions must not charge the same seconds twice — a strap session and an
            // imported twin that survived dedup would otherwise push the fraction above 1 and invent
            // energy. Union the windows against this slice instead of summing them.
            var covered = 0.0
            var cursor = slice.startSeconds
            for window in clean.sorted(by: { $0.startSeconds < $1.startSeconds }) {
                let start = max(window.startSeconds, cursor)
                let end = min(window.endSeconds, sliceEnd)
                guard end > start else { continue }
                covered += end - start
                cursor = end
            }
            let fraction = min(1, max(0, covered / slice.durationSeconds))
            training += slice.activeKcal * fraction
            movement += slice.activeKcal * (1 - fraction)
        }
        return (training, movement)
    }
}
