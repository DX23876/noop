import Foundation

// CardioFitness.swift — the aerobic ceiling a heart-rate energy estimate is scaled to.
//
// Heart rate says what share of someone's reserve they are using; turning that share into energy needs
// the top of the scale, VO₂max. The energy model used Uth et al. 2004 (15.3 · HRmax / HRrest) for it.
// Uth is validated in well-trained men only, and it has no body term: a 212 kg wearer with an Apple Watch
// VO₂max of 19 ml/kg/min read 47, which the model then multiplied by 212 kg. Walks came out at three
// times what the watch and the ACSM walking equation say they cost (docs/fork/decisions.md, 2026-09-29).
//
// This file replaces it with an order of evidence, strongest first:
//   1. a value the wearer entered (a lab test, another device), for 183 days from the day it was entered;
//   2. the Apple Watch reading, at most 30 days old;
//   3. Jurca et al. 2005, a non-exercise estimate that knows body size and resting heart rate.
// A measured value is stored per kilogram of the body it was measured on. Losing fat leaves the absolute
// uptake roughly where it was and raises the per-kilogram figure, so 1 and 2 are rescaled by the weight
// then over the weight now. Every lookup is causal: nothing after the day being priced is read.

/// Jurca et al. 2005, "Assessing cardiorespiratory fitness without performing exercise testing",
/// Am J Prev Med 29(3):185–193. NASA model (Table 5, measured VO₂max by gas analysis), the same coefficients
/// the paper's worksheet (Figure 1) prints, so they are read twice:
///
///   METs = 18.07 + 2.77·male − 0.10·age − 0.17·BMI − 0.03·restingHR + activity score
///
/// Cross-validated in three cohorts (NASA n = 1,859; ACLS n = 46,190; ADNFS n = 1,706), about 11,600 of them
/// women; R = 0.81, SEE 1.45 MET. The worked example in the paper's text (45 y man, 87.7 kg, 172 cm, resting
/// 72, level 2) states 9.02 MET; the printed coefficients give 9.46. Table and worksheet agree with each
/// other, so they are taken and the example is treated as the misprint.
///
/// Resting HR in the study was an ECG reading after five minutes supine. NOOP's is the lowest five-minute
/// bin of the main night, a few beats lower; at 0.03 MET per beat that reads a few tenths of a MET fitter.
public enum JurcaFitness {

    static let intercept = 18.07
    static let male = 2.77
    static let perYear = 0.10
    static let perBMI = 0.17
    static let perRestingBeat = 0.03

    /// The worksheet's five self-report categories.
    public enum ActivityLevel: Int, CaseIterable, Codable, Sendable {
        /// Inactive, or little activity beyond usual daily activities.
        case level1 = 1
        /// Regularly, at least five days a week, low-exertion activity for at least ten minutes at a time.
        case level2 = 2
        /// Aerobic exercise such as brisk walking, jogging, cycling for 20 to 60 minutes per week.
        case level3 = 3
        /// The same for one to three hours per week.
        case level4 = 4
        /// The same for over three hours per week.
        case level5 = 5

        /// The score the worksheet adds for the category.
        public var score: Double {
            switch self {
            case .level1: return 0
            case .level2: return 0.32
            case .level3: return 1.06
            case .level4: return 1.76
            case .level5: return 3.03
            }
        }
    }

    /// Maximal aerobic capacity in METs, unbounded. Nil when a body input is missing or not finite:
    /// a formula fed an invented height or resting rate is worse than no estimate, because the caller then
    /// prices from the activity table instead of from a number nobody measured.
    ///
    /// Sex follows the paper (man 1, woman 0). Nonbinary takes the midpoint, the convention `Calories` and
    /// `BasalRate` already apply, so one wearer is treated alike by every formula in the module.
    public static func estimateMET(sex: String, age: Double, weightKg: Double, heightCm: Double,
                                   restingHR: Double, activityLevel: ActivityLevel) -> Double? {
        guard age > 0, weightKg > 0, heightCm > 0, restingHR > 0,
              age.isFinite, weightKg.isFinite, heightCm.isFinite, restingHR.isFinite else { return nil }
        let metres = heightCm / 100
        let bmi = weightKg / (metres * metres)
        let sexTerm: Double
        switch sex.lowercased() {
        case "male": sexTerm = male
        case "female": sexTerm = 0
        default: sexTerm = male / 2
        }
        return intercept + sexTerm - perYear * age - perBMI * bmi - perRestingBeat * restingHR
            + activityLevel.score
    }

    /// Weekly aerobic minutes above which each category applies (the worksheet's 20, 60 and 180).
    static let level3Minutes = 20.0
    static let level4Minutes = 60.0
    static let level5Minutes = 180.0
    /// Days per week with ten continuous minutes of movement that make an otherwise inactive week level 2.
    static let level2DaysPerWeek = 5.0

    /// The category the wearer's own measured week falls in.
    ///
    /// `weeklyAerobicMinutes` is time in bouts of at least 20 minutes at moderate intensity or above;
    /// `lightActivityDaysPerWeek` counts days with at least ten continuous minutes of movement. The
    /// worksheet's aerobic bands take precedence; level 2 is reserved for a week with none of them.
    public static func level(weeklyAerobicMinutes: Double, lightActivityDaysPerWeek: Double)
        -> ActivityLevel {
        if weeklyAerobicMinutes > level5Minutes { return .level5 }
        if weeklyAerobicMinutes >= level4Minutes { return .level4 }
        if weeklyAerobicMinutes >= level3Minutes { return .level3 }
        return lightActivityDaysPerWeek >= level2DaysPerWeek ? .level2 : .level1
    }
}

/// One day's measured activity, as `WhoopEnergyModel.estimate` reports it and the store keeps it.
public struct DailyActivityEvidence: Equatable, Sendable {
    public let day: String
    public let aerobicSeconds: Int
    public let hadLightActivity: Bool

    public init(day: String, aerobicSeconds: Int, hadLightActivity: Bool) {
        self.day = day
        self.aerobicSeconds = aerobicSeconds
        self.hadLightActivity = hadLightActivity
    }
}

/// The aerobic ceiling for one day and where it came from.
public struct PeakMETResolution: Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case manual
        case appleWatch
        case jurca
    }

    /// Maximal aerobic capacity in METs, bounded.
    public let peakMET: Double
    public let source: Source
    /// The day the value was measured or entered. Nil for Jurca.
    public let sourceDay: String?
    /// The value as measured, in ml/kg/min of the body it was measured on. Nil for Jurca.
    public let measuredVO2max: Double?
    /// The weight the measurement was per kilogram of. Nil when unknown or for Jurca.
    public let measuredWeightKg: Double?
    /// The category Jurca was evaluated with. Nil for a measured value.
    public let activityLevel: JurcaFitness.ActivityLevel?

    /// VO₂max in ml/kg/min of today's body.
    public var vo2max: Double { peakMET * PeakMETResolver.mlPerMET }
}

public enum PeakMETResolver {

    /// One MET in ml O₂ per kg per minute, the convention every MET table and the model share.
    public static let mlPerMET = 3.5
    /// How long a value the wearer entered stands in for a measurement.
    public static let manualValidityDays = 183
    /// How old an Apple Watch reading may be and still describe today: as long as an entered value.
    ///
    /// It was 30 days until 2026-09-30. A Watch worn rarely then left most days to Jurca, which for a
    /// 212 kg wearer measured at 18.9 ml/kg/min read about 33: the formula's cohorts end near a BMI of
    /// 40, and its activity score counts brisk walking at full weight. A months-old measurement of the
    /// wearer's own body, rescaled by the weight at the time, is the better estimate than a population
    /// formula applied well outside its range.
    public static let appleFreshnessDays = manualValidityDays
    /// The BMI above which the formula has no support: Jurca's cohorts end near it.
    public static let formulaBMILimit = 40.0

    /// Whether a ceiling should carry the hint that a measurement would be more accurate: it came from
    /// the formula, for a body outside the range the formula was fitted on. For a 212 kg wearer measured
    /// at 18.9 ml/kg/min the formula read about 33. Nil source or missing body data: no hint.
    public static func measurementAdvised(source: PeakMETResolution.Source?, weightKg: Double,
                                          heightCm: Double) -> Bool {
        guard source == .jurca, weightKg.isFinite, weightKg > 0, heightCm.isFinite, heightCm > 0 else {
            return false
        }
        let meters = heightCm / 100
        return weightKg / (meters * meters) > formulaBMILimit
    }

    /// Window over which the activity category is measured, the worksheet's "past four weeks".
    public static let activityWindowDays = 28
    /// Bounds for the formula, a coarse population estimate.
    public static let estimateRange: ClosedRange<Double> = 3.5...16
    /// Bounds for a measured or entered value, which may belong to an endurance athlete.
    public static let measuredRange: ClosedRange<Double> = 3.5...25

    /// A value the wearer entered, with the day and the weight it was entered at.
    public struct ManualEntry: Equatable, Sendable {
        public let vo2max: Double
        public let day: String
        public let weightKg: Double?

        public init(vo2max: Double, day: String, weightKg: Double?) {
            self.vo2max = vo2max
            self.day = day
            self.weightKg = weightKg
        }
    }

    /// The activity category for `day` from the evidence of that day and the 27 before it.
    ///
    /// The day itself is included: a week is known by its end, and excluding it would leave the first day
    /// a strap is worn with no category at all. Days without a record in the window are not counted as
    /// inactive days; the rate is taken over the days that were observed, so a strap bought last week is
    /// judged on last week. Nil when no day in the window was observed.
    public static func activityLevel(for day: String, evidence: [DailyActivityEvidence])
        -> JurcaFitness.ActivityLevel? {
        let inWindow = evidence.filter {
            $0.day <= day && StrengthSession.daysBetween($0.day, and: day) < activityWindowDays
        }
        let observedDays = Set(inWindow.map(\.day)).count
        guard observedDays > 0 else { return nil }
        let weeks = Double(observedDays) / 7
        let aerobicMinutes = Double(inWindow.reduce(0) { $0 + $1.aerobicSeconds }) / 60
        let lightDays = Double(inWindow.filter(\.hadLightActivity).count)
        return JurcaFitness.level(weeklyAerobicMinutes: aerobicMinutes / weeks,
                                  lightActivityDaysPerWeek: lightDays / weeks)
    }

    /// The strongest available ceiling for `day`, or nil when nothing can supply one.
    ///
    /// - Parameters:
    ///   - profile: the day's profile; `weightKg` must already be the weight in force on that day.
    ///   - apple: Apple Watch VO₂max readings in ml/kg/min.
    ///   - weightOnDay: the weight in force on a past day, for rescaling a measurement to today's body.
    ///   - activityLevel: an override, or the measured category from `activityLevel(for:evidence:)`.
    public static func resolve(day: String, profile: UserProfile, restingHR: Double?,
                               manual: ManualEntry?, apple: [VO2maxReading],
                               weightOnDay: (String) -> Double?,
                               activityLevel: JurcaFitness.ActivityLevel?) -> PeakMETResolution? {
        if let manual, manual.vo2max.isFinite, manual.vo2max > 0, manual.day <= day,
           StrengthSession.daysBetween(manual.day, and: day) <= manualValidityDays {
            return measured(manual.vo2max, measuredWeight: manual.weightKg,
                            todayWeight: profile.weightKg, source: .manual, day: manual.day)
        }
        let fresh = apple
            .filter {
                $0.value.isFinite && $0.value > 0 && $0.day <= day
                    && StrengthSession.daysBetween($0.day, and: day) <= appleFreshnessDays
            }
            .max { $0.day < $1.day }
        if let fresh {
            return measured(fresh.value, measuredWeight: weightOnDay(fresh.day),
                            todayWeight: profile.weightKg, source: .appleWatch, day: fresh.day)
        }
        guard let restingHR, let activityLevel,
              let met = JurcaFitness.estimateMET(sex: profile.sex, age: profile.age,
                                                 weightKg: profile.weightKg, heightCm: profile.heightCm,
                                                 restingHR: restingHR, activityLevel: activityLevel)
        else { return nil }
        return PeakMETResolution(peakMET: clamp(met, estimateRange), source: .jurca, sourceDay: nil,
                                 measuredVO2max: nil, measuredWeightKg: nil, activityLevel: activityLevel)
    }

    /// A measured per-kilogram value moved onto today's body. Without a known weight at the time of
    /// measurement it is taken as it stands rather than rescaled against a guess.
    private static func measured(_ vo2max: Double, measuredWeight: Double?, todayWeight: Double,
                                 source: PeakMETResolution.Source, day: String) -> PeakMETResolution {
        var rescaled = vo2max
        if let measuredWeight, measuredWeight.isFinite, measuredWeight > 0,
           todayWeight.isFinite, todayWeight > 0 {
            rescaled = vo2max * measuredWeight / todayWeight
        }
        return PeakMETResolution(peakMET: clamp(rescaled / mlPerMET, measuredRange), source: source,
                                 sourceDay: day, measuredVO2max: vo2max,
                                 measuredWeightKg: measuredWeight, activityLevel: nil)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
