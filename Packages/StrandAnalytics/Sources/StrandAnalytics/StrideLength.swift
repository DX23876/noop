import Foundation

// MARK: - How long is THIS person's step?
//
// `WhoopEnergyModel.movementMET` turns a step count into a speed before pricing it against the
// Compendium curve, and that conversion needs a step length. Until now it used 0.75 m — a documented
// population average, and the honest choice while nothing better was wired up. But the cadence branch
// is the one that actually runs (`refreshWhoopEnergyModel` populates `steps`, not `distanceM`), so
// that placeholder sits in the hot path: for a short person it prices every walk too high, for a tall
// one too low, all day, every day.
//
// The iPhone already measures the real figure. Apple's `walkingStepLength` comes from the phone's own
// motion processing and needs no watch; it is read, bucketed and stored today (`HealthKitBridge`,
// `healthEnergyBucket.strideM`) and simply never reaches the model.
//
// TERMINOLOGY, because the stored name is misleading: this is STEP length — one foot to the other —
// not a stride, which is conventionally two steps. `movementMET` multiplies it by a per-STEP cadence,
// so metres-per-step is the quantity that belongs here. The `strideM` spelling is kept only for
// continuity with the database column and the row types that already carry it.
//
// Two rules make the estimate refuse to guess:
//
//   • MEDIAN, not mean. The samples are per walking bout, and bouts are not alike: shuffling in a
//     queue, a treadmill's belt, a phone carried in a bag. A mean lets any of those drag the figure;
//     a median needs half the day to be unusual before it moves.
//   • DISCARD out-of-range readings, never clamp them. Clamping converts an implausible sample into a
//     confident wrong one sitting exactly on the boundary, which then looks like evidence. A reading
//     outside the plausible range is not a small error to be trimmed — it is a sample about something
//     other than walking, and the estimate is better off never having seen it.
//
// When too little survives those rules the answer is nil, and the caller keeps the population average.
// That is the same behaviour as today, so a person the phone never measures is no worse off.

/// A measured personal step length, with the evidence it rests on.
public struct StepLengthEstimate: Equatable, Sendable {
    /// Metres covered by ONE step.
    public let metersPerStep: Double
    /// How many plausible readings the median was taken over. Carried so provenance can say what the
    /// figure rests on rather than presenting every estimate as equally settled.
    public let sampleCount: Int

    public init(metersPerStep: Double, sampleCount: Int) {
        self.metersPerStep = metersPerStep
        self.sampleCount = sampleCount
    }
}

/// Turns raw step-length readings into a personal figure, or into nothing.
public enum StrideLength {

    /// The population average that has been in `movementMET` all along, and still the answer whenever
    /// a personal figure cannot be established. Roughly an adult's step at an ordinary walking pace.
    public static let populationAverageM = 0.75

    /// The range a single reading must fall in to count. Chosen to span adult step length from a short
    /// person ambling to a tall one striding out, and to exclude what is plainly not walking. Readings
    /// outside it are dropped, not pulled to the edge.
    public static let plausibleRangeM: ClosedRange<Double> = 0.5...1.1

    /// How many plausible readings a figure needs. A median of three is already resistant to one odd
    /// bout, but three bouts is a thin basis for a number that reprices a whole day, so the bar sits
    /// higher than bare robustness requires.
    public static let minimumSamples = 5

    /// The personal step length implied by `samples`, or nil when too few readings are plausible.
    ///
    /// Non-finite and out-of-range values are discarded before counting, so `minimumSamples` is a
    /// floor on USABLE evidence rather than on how much arrived.
    public static func personal(from samples: [Double]) -> StepLengthEstimate? {
        let usable = samples.filter { $0.isFinite && plausibleRangeM.contains($0) }.sorted()
        guard usable.count >= minimumSamples else { return nil }
        return StepLengthEstimate(metersPerStep: median(usable), sampleCount: usable.count)
    }

    /// The step length to price a bucket with: the measured one when there is one, else the population
    /// average. One place decides this, so no caller can quietly invent a third answer.
    public static func metersPerStep(_ measured: Double?) -> Double {
        guard let measured, measured.isFinite, plausibleRangeM.contains(measured) else {
            return populationAverageM
        }
        return measured
    }

    /// Median of an already-sorted, non-empty array. Even counts average the two middle values, which
    /// is what `AdaptiveExpenditureEngine` and `EnergyCalibrationEngine` do with the same shape of data.
    private static func median(_ sorted: [Double]) -> Double {
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

// MARK: - Which step length applied on a given day?
//
// `walkingStepLength` arrives per walking bout, so a day the wearer barely walked — or carried the
// phone in a bag — can hold too few plausible readings to establish anything. Falling straight back to
// the population average on those days would make the figure flicker between measured and assumed from
// one day to the next, which reads as the wearer's stride changing when only the sampling did.
//
// So a measurement CARRIES FORWARD, and only forward. Two properties matter:
//
//   • Forward only. A day is never priced with a measurement taken after it. This is what keeps the
//     rescore honest: re-running the window cannot rewrite an old day using something learned later,
//     the same trap `EnergySeries` documents for body weight.
//   • Bounded. Step length is stable but not fixed — injury, ageing and large fitness changes all move
//     it. Past the window the honest answer is the documented population average rather than an
//     assertion about this person that may have expired. The trade is deliberate: a stale personal
//     figure is probably still closer than 0.75 m, but "probably" is not a basis for a daily number.

/// Per-day step length, resolved from dated readings without ever looking forward in time.
public struct StepLengthTimeline: Sendable {

    /// How long a measurement stays usable. A month of ordinary life does not change how a person
    /// walks; much beyond it, nobody should be asserting that on their behalf.
    public static let carryForwardDays = 30

    /// Ascending by day. Only days that established a figure appear.
    private let points: [(day: String, estimate: StepLengthEstimate)]

    /// Builds the timeline from raw readings grouped by local day. Days whose readings are too thin
    /// simply do not appear, and are answered by whatever earlier day is still in range.
    public init(samplesByDay: [String: [Double]]) {
        points = samplesByDay
            .compactMap { day, samples in
                StrideLength.personal(from: samples).map { (day: day, estimate: $0) }
            }
            .sorted { $0.day < $1.day }
    }

    public var isEmpty: Bool { points.isEmpty }

    /// The measurement that applied on `day` — that day's own, or the most recent earlier one still
    /// inside the carry-forward window. Nil when nothing qualifies, which the caller reads as the
    /// population average.
    public func estimate(onDay day: String) -> StepLengthEstimate? {
        // Last point at or before `day`; anything later is in this day's future and must not be used.
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].day <= day { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = points[low - 1]
        guard StrengthSession.daysBetween(candidate.day, and: day) <= Self.carryForwardDays else {
            return nil
        }
        return candidate.estimate
    }

    /// The step length to price `day` with, always answerable: measured when it can be, population
    /// average otherwise.
    public func metersPerStep(onDay day: String) -> Double {
        StrideLength.metersPerStep(estimate(onDay: day)?.metersPerStep)
    }
}
