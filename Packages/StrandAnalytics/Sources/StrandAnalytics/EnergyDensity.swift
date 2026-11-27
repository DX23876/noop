import Foundation

/// What a kilogram of body weight lost or gained holds, from how much fat the body carries (owner decisions
/// 2026-11-27, Q24 and Q25).
///
/// The 7,700 kcal/kg convention (Wishnofsky 1958) fits nobody exactly. A body with much fat loses almost only
/// fat; a lean body loses a larger share of fat-free mass, which holds far less energy. Forbes's relation puts
/// the fat-free share of a change at 10.4 / (10.4 + fat mass in kg), and Hall (2008) prices fat at 39.5 MJ/kg
/// (9,440 kcal) and fat-free mass at 7.6 MJ/kg (1,816 kcal). One value for the plan's deficit, its forecast,
/// the weight page and the scale's burn, so none of them can disagree about what a kilogram is worth.
public enum EnergyDensity {
    public static let fatKcalPerKg = 9_440.0
    public static let fatFreeKcalPerKg = 1_816.0
    /// Forbes's constant, in kilograms of fat.
    public static let forbesC = 10.4
    /// The range a figure is kept to, so a body-fat value from a typing mistake cannot swing the plan.
    public static let plausible: ClosedRange<Double> = 4_500...9_300

    /// kcal per kilogram of weight change for a body of `weightKg` at `bodyFatPercent`.
    public static func kcalPerKg(weightKg: Double, bodyFatPercent: Double) -> Double? {
        guard weightKg.isFinite, weightKg > 0, bodyFatPercent.isFinite, (3...70).contains(bodyFatPercent)
        else { return nil }
        let fatMass = weightKg * bodyFatPercent / 100
        let fatFreeShare = forbesC / (forbesC + fatMass)
        let value = (1 - fatFreeShare) * fatKcalPerKg + fatFreeShare * fatFreeKcalPerKg
        return min(plausible.upperBound, max(plausible.lowerBound, value))
    }
}

/// Body fat from BMI, age and sex when nothing better exists: CUN-BAE (Gómez-Ambrosi et al. 2012, Diabetes
/// Care; 6,510 adults against air-displacement plethysmography, r = 0.89). Not separately validated above a BMI
/// of 50, which is why a measurement or the tape method wins over it (Q28).
public enum BodyFatEstimate {
    /// Percent body fat. `female` is nil for an unknown sex, which takes the middle of the two.
    public static func cunBae(bmi: Double, age: Double, female: Bool?) -> Double? {
        guard bmi.isFinite, (15...80).contains(bmi), age.isFinite, (18...100).contains(age) else { return nil }
        func value(_ sex: Double) -> Double {
            -44.988 + 0.503 * age + 10.689 * sex + 3.172 * bmi - 0.026 * bmi * bmi
                + 0.181 * bmi * sex - 0.02 * bmi * age - 0.005 * bmi * bmi * sex + 0.00021 * bmi * bmi * age
        }
        let estimate: Double
        switch female {
        case .some(true): estimate = value(1)
        case .some(false): estimate = value(0)
        case .none: estimate = (value(0) + value(1)) / 2
        }
        return min(70, max(3, estimate))
    }

    /// The body fat a day is reckoned with: a measurement, else the tape method, else CUN-BAE.
    public static func resolve(measured: Double?, tape: Double?, weightKg: Double, heightCm: Double, age: Double,
                               female: Bool?) -> Double? {
        if let measured, measured.isFinite, (3...70).contains(measured) { return measured }
        if let tape, tape.isFinite, (3...70).contains(tape) { return tape }
        guard heightCm > 0 else { return nil }
        return cunBae(bmi: weightKg / pow(heightCm / 100, 2), age: age, female: female)
    }
}
