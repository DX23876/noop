import Foundation

// MARK: - Which basal formula applied, and when
//
// `Calories` states the rule this file has to honour: NOOP must have ONE basal rate, because a second
// formula anywhere lets two screens disagree about the same body. That rule is about one rate per body
// per DAY. It does not forbid the formula from changing over time — it forbids the change from being
// ambiguous or retroactive.
//
// So the formula becomes DATA: an append-only list of (effectiveFrom, formula), seeded at the
// beginning of time with the revised Harris–Benedict the app has always used. Switching APPENDS an
// entry; nothing is ever edited or removed. The energy path asks "which formula applied on day X" and
// gets a deterministic answer from stored data rather than from whatever Settings currently says.
//
// WHY THIS MATTERS MORE THAN IT LOOKS. Two surfaces consume the basal rate and they behave differently:
// `DailyMetric.activeKcalEst` bakes it in at scoring time, so old days already keep their value; but
// `EnergyEngine.summarize` recomputes on every build, so without this log a switch made today would
// silently rewrite yesterday's displayed history. The log exists for that second case.
//
// KATCH–MCARDLE IS NOT AUTOMATICALLY BETTER. It works from lean mass, so it beats a height/weight
// regression only when the body-fat number is good. Fed a Navy circumference estimate carrying ±4
// percentage points, its error can be comparable to what it replaced. The switch is therefore offered,
// never applied on NOOP's initiative, and the surface that offers it names what the number rests on —
// DEXA, scale, or tape.

/// A published basal-metabolic-rate formula.
public enum BasalFormula: String, Codable, Equatable, Sendable, CaseIterable {
    /// Roza & Shizgal's 1984 revision of Harris–Benedict. What NOOP has always used, and the seed of
    /// every log, so an untouched install behaves exactly as before.
    case revisedHarrisBenedict
    /// Mifflin-St Jeor (1990). Generally the better height/weight regression for modern populations,
    /// and the one most calorie calculators quote.
    case mifflinStJeor
    /// Katch-McArdle. Works from LEAN mass, so it needs a body-fat figure and is sex-independent —
    /// the same lean kilogram costs the same regardless of whose body it is on.
    case katchMcArdle

    /// Whether this formula needs a body-fat percentage. Only Katch-McArdle does.
    public var needsBodyFat: Bool { self == .katchMcArdle }
}

/// One entry in the formula log: the day a formula took effect.
public struct BmrFormulaEpoch: Equatable, Codable, Sendable {
    /// Local day (`yyyy-MM-dd`) from which this formula applies, inclusive.
    public let effectiveFrom: String
    public let formula: BasalFormula

    public init(effectiveFrom: String, formula: BasalFormula) {
        self.effectiveFrom = effectiveFrom
        self.formula = formula
    }
}

/// The append-only record of which basal formula applied when.
public struct BmrFormulaLog: Equatable, Codable, Sendable {

    /// The seed date. Sorts before any real day key, so the seeded formula covers all history without
    /// anyone having to know when the wearer's data starts.
    public static let beginningOfTime = "0000-01-01"

    /// Ascending by day; entries appended on the same day keep their append order, so the later one
    /// wins. Never edited in place.
    public private(set) var epochs: [BmrFormulaEpoch]

    /// An untouched log: revised Harris–Benedict, for all of time. What every install starts from.
    public static var seeded: BmrFormulaLog {
        BmrFormulaLog(epochs: [.init(effectiveFrom: beginningOfTime, formula: .revisedHarrisBenedict)])
    }

    /// Builds a log from stored entries. An empty list is seeded rather than left empty, so no caller
    /// can ever be handed a log with no answer.
    public init(epochs: [BmrFormulaEpoch]) {
        self.epochs = epochs.isEmpty ? Self.seeded.epochs : epochs
    }

    /// The formula in force on `day`.
    public func formula(onDay day: String) -> BasalFormula {
        var answer = epochs[0].formula
        for epoch in epochs where epoch.effectiveFrom <= day { answer = epoch.formula }
        return answer
    }

    /// The log with `formula` taking effect from `day`.
    ///
    /// Forward only, by construction: an entry dated before the newest one would rewrite history, so
    /// its date is carried forward to the newest entry's day instead. That case means a clock moved
    /// backwards or a restore brought a future-dated log — refusing outright would leave the wearer's
    /// choice unapplied with nothing to show for it, so the switch still happens, just not in the past.
    public func appending(_ formula: BasalFormula, effectiveFrom day: String) -> BmrFormulaLog {
        let earliest = epochs.last?.effectiveFrom ?? Self.beginningOfTime
        let effective = max(day, earliest)
        var next = epochs
        next.append(.init(effectiveFrom: effective, formula: formula))
        return BmrFormulaLog(epochs: next)
    }

    /// The formula the whole history is computed with.
    ///
    /// One formula for every day, not the one in force per day: the choice is a method, not a change
    /// in the body, and a curve that switches method at a date carries a step that reads as a
    /// metabolic change — in trends, 30-day means and the intake/weight comparison alike. What really
    /// changes over time (weight, body fat) is still resolved per day from its own history. An
    /// untouched log answers Mifflin–St Jeor, the more accurate height-and-weight regression; the
    /// Harris–Benedict seed only records what earlier versions used. `formula(onDay:)` remains for
    /// reading the log itself.
    public var current: BasalFormula {
        lastSwitchDay == nil ? .mifflinStJeor : (epochs.last?.formula ?? .mifflinStJeor)
    }

    /// The day the formula last changed, or nil for an untouched log. The chart marks this date, and
    /// the provenance sheet names it — an unexplained step of 50–200 kcal/day reads as a bug.
    public var lastSwitchDay: String? {
        epochs.count > 1 ? epochs.last?.effectiveFrom : nil
    }

    // MARK: - Backup

    /// JSON for the `.noopbak` whitelist, which carries Int/Double/String only.
    ///
    /// Without this in the whitelist a restore silently reverts to Harris–Benedict and the curve steps
    /// a second time with nobody having changed anything.
    public func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(epochs),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Rebuilds a log from `encodedJSON`. Unreadable or empty input seeds rather than throwing: a
    /// corrupt backup field must not leave the energy path with no basal formula at all.
    public static func decode(_ json: String) -> BmrFormulaLog {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([BmrFormulaEpoch].self, from: data) else {
            return .seeded
        }
        return BmrFormulaLog(epochs: entries)
    }
}

// MARK: - Computing each formula
//
// Harris–Benedict is NOT reimplemented here. It is asked of `Calories`, which owns it and whose
// coefficients the whole HR-calorie path already uses — a second copy would be exactly the divergence
// `Calories` warns about. The other two are added at their published form.

/// Evaluates a `BasalFormula` for one body.
public enum BasalRate {

    /// Basal rate in kcal/24 h, or nil when the inputs cannot support the chosen formula.
    ///
    /// `bodyFatPercent` is only read by Katch-McArdle, and callers resolve it through the measurement
    /// store's `asOf(day:)` so the rate tracks new readings forward without ever reaching backwards.
    /// Nil from Katch-McArdle means no body-fat reading was in force on that day, which the caller must
    /// handle deliberately — silently substituting another formula would put an unexplained step in the
    /// curve, which is precisely what the epoch log exists to prevent.
    public static func kcalPerDay(_ formula: BasalFormula, weightKg: Double, heightCm: Double,
                                  age: Double, sex: String, bodyFatPercent: Double? = nil) -> Double? {
        guard weightKg > 0, heightCm > 0, age > 0,
              weightKg.isFinite, heightCm.isFinite, age.isFinite else { return nil }

        let value: Double
        switch formula {
        case .revisedHarrisBenedict:
            value = Calories.bmrKcalPerDay(Calories.resolveCoeffs(sex), weightKg: weightKg,
                                           heightCm: heightCm, age: age)
        case .mifflinStJeor:
            value = 10 * weightKg + 6.25 * heightCm - 5 * age + mifflinConstant(sex)
        case .katchMcArdle:
            guard let bodyFatPercent, bodyFatPercent.isFinite,
                  NavyBodyFat.plausibleRange.contains(bodyFatPercent) else { return nil }
            let leanKg = weightKg * (1 - bodyFatPercent / 100)
            guard leanKg > 0 else { return nil }
            value = 370 + 21.6 * leanKg
        }
        return value > 0 ? value : nil
    }

    /// Mifflin-St Jeor's sex constant. Nonbinary takes the male/female midpoint — the same convention
    /// `Calories` already applies to its own coefficients, so the two formulas treat one wearer alike.
    private static func mifflinConstant(_ sex: String) -> Double {
        switch sex.lowercased() {
        case "male": return 5
        case "female": return -161
        default: return -78
        }
    }

    /// How much a switch moves the daily basal rate, in kcal/day, signed toward `to`.
    ///
    /// The chart marks the switch date and the sheet states this number. A step of this size with no
    /// explanation beside it reads as a bug, and the wearer is right to read it that way.
    public static func switchDelta(from: BasalFormula, to: BasalFormula, weightKg: Double,
                                   heightCm: Double, age: Double, sex: String,
                                   bodyFatPercent: Double? = nil) -> Double? {
        guard let before = kcalPerDay(from, weightKg: weightKg, heightCm: heightCm, age: age,
                                      sex: sex, bodyFatPercent: bodyFatPercent),
              let after = kcalPerDay(to, weightKg: weightKg, heightCm: heightCm, age: age,
                                     sex: sex, bodyFatPercent: bodyFatPercent) else { return nil }
        return after - before
    }
}
