import Foundation

// MARK: - Planning intake, without inventing a second calorie model
//
// `EnergyEngine`'s third rule is that sources are CHOSEN per day and never summed: two devices on one
// wrist measure the same body, and adding them invents a person who burned twice. A planner that
// derived its own burn from heart rate or steps would be exactly that second computation. So nothing
// here computes a burn. This file does three things instead:
//
//   1. Evaluates PAL conventions on top of a basal rate — a PREDICTION from a published formula,
//      which is a different question from what was measured, not a competing answer to it.
//   2. Summarises measured burn that already exists, with its provenance, and refuses to call a
//      mostly-modelled average "measured".
//   3. Puts the three available answers side by side and reports the spread.
//
// ON NOT WEIGHTING. It is tempting to average days with per-source weights. That would require
// inventing the weights, and an invented number that looks like evidence is worse than an honest
// filter. So the measured figure is a plain mean over days that MEET A STATED CRITERION, and the days
// that did not meet it are counted and shown rather than folded in at a discount.

/// A physical-activity-level multiplier applied to a basal rate.
///
/// These steps are CONVENTIONS, not measurements — the values are the ones the literature and every
/// calorie calculator quote, and a person does not actually come with a PAL of exactly 1.55. Every
/// surface showing them says so, the same treatment the Strength screen gives its stimulus anchors.
public enum ActivityLevel: String, Codable, Equatable, Sendable, CaseIterable {
    case sedentary
    case light
    case moderate
    case high
    case veryHigh

    /// The conventional multiplier.
    public var factor: Double {
        switch self {
        case .sedentary: return 1.2
        case .light: return 1.375
        case .moderate: return 1.55
        case .high: return 1.725
        case .veryHigh: return 1.9
        }
    }
}

/// How much of a burn average actually rests on measurement.
public enum MeasuredBurnQuality: String, Equatable, Sendable {
    /// Most days carry a measured source. The figure may be called measured.
    case measured
    /// A real mix. The figure is reported with its composition and not labelled measured.
    case mixed
    /// Mostly modelled — a formula calculation with extra steps, and named as one.
    case mostlyModelled
}

/// One day of burn as `EnergyEngine` produced it.
public struct BurnDay: Equatable, Sendable {
    public let day: String
    public let totalKcal: Double
    public let source: EnergySource
    /// Fraction of the day backed by data, as `EnergyEngine` reports it.
    ///
    /// Nil means the figure does not EXIST for this day, not that the day was poorly covered — an
    /// `appleSplit` day on a platform without the reference stream leaves it nil, and `EnergyCoverage`
    /// is explicit that such a day must not be marked down for a platform gap it did not create.
    /// Treating nil as zero excluded every one of those days from the measured mean while still
    /// counting them in the composition, which read as "0 of 30 days were measured" beside a list
    /// saying all 30 came from Apple.
    public let coverage: Double?

    public init(day: String, totalKcal: Double, source: EnergySource, coverage: Double?) {
        self.day = day
        self.totalKcal = totalKcal
        self.source = source
        self.coverage = coverage
    }

    /// Whether this day's burn rests on a measurement rather than on a model. `mixed` is deliberately
    /// excluded: it means part of the day was modelled, and the point of the label is to be strict.
    public var isMeasured: Bool {
        source == .appleSplit || source == .strapWornTime
    }
}

/// A burn average with the provenance needed to say what it is.
public struct MeasuredBurn: Equatable, Sendable {
    /// Mean over days that met the criterion. Nil when none did.
    public let measuredMeanKcal: Double?
    /// Mean over every day supplied, for comparison. Always present when any day was supplied.
    public let allDaysMeanKcal: Double?
    public let measuredDays: Int
    public let totalDays: Int
    public let composition: [EnergySource: Int]
    public let quality: MeasuredBurnQuality
}

/// Three answers to one question, and how far apart they are.
///
/// Nobody can say how accurately a wearable measures, so the honest output is a corridor with named
/// sources rather than a single figure presented as the truth.
public struct EnergyCorridor: Equatable, Sendable {
    /// What a published formula predicts.
    public let formulaKcal: Double?
    /// What the wearable measured.
    public let measuredKcal: Double?
    /// What intake and weight change imply — the only figure that does not inherit the strap's
    /// conversion error, which makes it the check value rather than a third opinion.
    public let balanceKcal: Double?

    /// Every figure that exists, ascending.
    public var present: [Double] {
        [formulaKcal, measuredKcal, balanceKcal].compactMap { $0 }.sorted()
    }

    /// Distance between the highest and lowest available figure. Nil below two figures — a spread of
    /// one number is not a spread.
    public var spreadKcal: Double? {
        let values = present
        guard values.count >= 2, let low = values.first, let high = values.last else { return nil }
        return high - low
    }

    public init(formulaKcal: Double?, measuredKcal: Double?, balanceKcal: Double?) {
        self.formulaKcal = formulaKcal
        self.measuredKcal = measuredKcal
        self.balanceKcal = balanceKcal
    }
}

/// Turns existing measurements into planning figures. Owns no calorie model.
public enum EnergyPlanning {

    /// The Wishnofsky convention: 7 700 kcal per kilogram of body mass. Named as a convention because
    /// that is what it is — a 1958 approximation that is demonstrably optimistic over longer horizons,
    /// since it ignores the metabolic adaptation that accompanies sustained loss.
    public static let wishnofskyKcalPerKg = 7_700.0

    /// What a kilogram of body mass can credibly cost.
    ///
    /// Adipose tissue runs about 7 700 kcal/kg — the convention — and a real window mixes in some lean
    /// tissue and some water, which pulls the figure either side of it. But not far: a result of 2 300
    /// kcal/kg does not mean this person's fat is cheap, it means the window's weight change was mostly
    /// WATER, and dividing a deficit by a water swing measures nothing. An implausibly HIGH figure is
    /// the same failure from the other end — a barely-moved weight in the denominator.
    ///
    /// The first version of this band ran from 2 000, which let exactly that artefact through and
    /// printed it beside the convention as though it were the wearer's own metabolism.
    public static let plausibleKcalPerKg: ClosedRange<Double> = 4_000...15_000

    /// The share of days that must be measured before an average may be called measured.
    public static let measuredDayFraction = 0.70

    /// The share below which an average is named mostly modelled.
    public static let modelledDayFraction = 0.30

    /// Least coverage a day needs to count toward the measured mean. A day that was barely recorded
    /// is not evidence of what that day cost.
    public static let minimumDayCoverage = 0.5

    /// What a published formula predicts for a whole day: basal rate times a PAL convention.
    public static func formulaTdee(basalKcal: Double, activity: ActivityLevel) -> Double? {
        guard basalKcal > 0, basalKcal.isFinite else { return nil }
        return basalKcal * activity.factor
    }

    /// Summarises measured burn over `days`, refusing the "measured" label when it is not earned.
    public static func measuredBurn(days: [BurnDay]) -> MeasuredBurn {
        let usable = days.filter { $0.totalKcal > 0 && $0.totalKcal.isFinite }
        var composition: [EnergySource: Int] = [:]
        for day in usable { composition[day.source, default: 0] += 1 }

        // A day qualifies unless its coverage is KNOWN to be poor. Absence of a coverage figure is not
        // evidence of poor coverage.
        let measured = usable.filter { day in
            day.isMeasured && (day.coverage.map { $0 >= minimumDayCoverage } ?? true)
        }
        let measuredMean = measured.isEmpty
            ? nil : measured.reduce(0) { $0 + $1.totalKcal } / Double(measured.count)
        let allMean = usable.isEmpty
            ? nil : usable.reduce(0) { $0 + $1.totalKcal } / Double(usable.count)

        let fraction = usable.isEmpty ? 0 : Double(measured.count) / Double(usable.count)
        let quality: MeasuredBurnQuality
        if fraction >= measuredDayFraction {
            quality = .measured
        } else if fraction <= modelledDayFraction {
            quality = .mostlyModelled
        } else {
            quality = .mixed
        }

        return MeasuredBurn(measuredMeanKcal: measuredMean, allDaysMeanKcal: allMean,
                            measuredDays: measured.count, totalDays: usable.count,
                            composition: composition, quality: quality)
    }

    /// The daily deficit or surplus implied by a target rate of weight change, under the Wishnofsky
    /// convention. Positive means a surplus.
    public static func dailyEnergyDelta(targetKgPerWeek: Double,
                                        kcalPerKg: Double = wishnofskyKcalPerKg) -> Double? {
        guard targetKgPerWeek.isFinite, kcalPerKg > 0, kcalPerKg.isFinite else { return nil }
        return targetKgPerWeek * kcalPerKg / 7
    }

    /// The rate a given daily delta implies, in kg per week — the inverse of `dailyEnergyDelta`.
    public static func weeklyRate(dailyDeltaKcal: Double,
                                  kcalPerKg: Double = wishnofskyKcalPerKg) -> Double? {
        guard dailyDeltaKcal.isFinite, kcalPerKg > 0, kcalPerKg.isFinite else { return nil }
        return dailyDeltaKcal * 7 / kcalPerKg
    }

    // MARK: - Thermic effect of food
    //
    // Digesting, absorbing and storing what was eaten costs energy, and it is not a small term:
    // roughly a tenth of daily expenditure. Almost no tracker shows it, because almost no tracker
    // knows what was eaten — NOOP does, from the food log, which is the only reason this can be
    // computed here at all.
    //
    // It is deliberately NOT part of `DailyEnergySummary.totalBurnedSoFar`. That field means "what a
    // device measured, plus what had to be modelled to fill the gaps", and digestion is neither: no
    // wearable observes it. Mixing it in would quietly redefine the one number every screen, the
    // widget and the coach already read. It belongs on the planning side, beside intake, where the
    // question is energy BALANCE rather than energy burned.

    /// Per-gram thermic cost as a fraction of the macronutrient's own energy. The published bands are
    /// wide (protein is quoted anywhere from 20% to 30%); these are their conventional midpoints.
    public static let thermicFractionProtein = 0.25
    public static let thermicFractionCarbs = 0.08
    public static let thermicFractionFat = 0.04

    /// The mixed-diet figure, used when the log carries calories but no macronutrients. Roughly what
    /// the per-macro model returns for an ordinary diet, which is the point: switching between them
    /// must not move the number much.
    public static let thermicFractionMixed = 0.10

    /// Energy spent digesting a day's intake, in kcal.
    ///
    /// Macro-specific when the log has macronutrients, mixed-diet otherwise. The macro path is capped
    /// at the logged calories: a log whose grams and calories disagree (rounding, a hand-typed entry,
    /// an import that dropped one field) must not be able to invent a thermic cost larger than the
    /// meal it came from.
    ///
    /// Nil when nothing was logged — an unlogged day has no known intake, and 0 would claim it did.
    public static func thermicEffect(intakeKcal: Double?, proteinG: Double? = nil,
                                     carbsG: Double? = nil, fatG: Double? = nil) -> Double? {
        guard let intakeKcal, intakeKcal.isFinite, intakeKcal > 0 else { return nil }
        func grams(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        let protein = grams(proteinG), carbs = grams(carbsG), fat = grams(fatG)
        guard protein != nil || carbs != nil || fat != nil else {
            return intakeKcal * thermicFractionMixed
        }
        // 4/4/9 kcal per gram — the Atwater factors every food label is built on.
        let fromMacros = (protein ?? 0) * 4 * thermicFractionProtein
            + (carbs ?? 0) * 4 * thermicFractionCarbs
            + (fat ?? 0) * 9 * thermicFractionFat
        return min(fromMacros, intakeKcal * thermicFractionProtein)
    }

    /// The wearer's OWN observed kcal per kilogram, from what they ate, what they burned and what
    /// their weight actually did. Shown beside the 7 700 convention once enough data exists.
    ///
    /// Nil unless the weight moved enough to divide by: near zero change, the quotient explodes and
    /// would report a confident absurdity. `minimumWeightChangeKg` is what the window must show.
    public static func observedKcalPerKg(intakeKcal: Double, burnKcal: Double, weightChangeKg: Double,
                                         minimumWeightChangeKg: Double = 0.5) -> Double? {
        guard intakeKcal.isFinite, burnKcal.isFinite, weightChangeKg.isFinite,
              abs(weightChangeKg) >= minimumWeightChangeKg else { return nil }
        let value = (intakeKcal - burnKcal) / weightChangeKg
        guard value.isFinite, plausibleKcalPerKg.contains(value) else { return nil }
        return value
    }
}
