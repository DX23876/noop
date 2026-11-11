import Foundation

/// What a measure tile on Today says beside its figure, shared by the iPhone and the Android core: the latest value
/// against the median of the 30 before it, as a signed whole step ("↗ +3", "±0"), and how that move reads for the
/// body. None for measures read as words or totals (stress, steps, sleep, energy) or with under a week of history.
/// Display only; nothing is stored. Analysis migration required: no.
enum MeasureTileReading {
    /// Green when it went the good way or held, yellow for a small move the wrong way, red for a large one.
    enum Tone: String, Sendable { case good, small, large }

    static func delta(key: String, values: [Double]) -> String? {
        guard let (last, usual) = lastAndUsual(key: key, values: values) else { return nil }
        let decimals = ["weight", "skin_temp"].contains(key) ? 1 : 0
        let step = decimals == 1 ? 0.1 : 1.0
        let diff = ((last - usual) / step).rounded() * step
        if diff == 0 { return "±0" }
        let number = diff.magnitude.formatted(.number.precision(.fractionLength(decimals)).locale(AppLanguage.activeLocale))
        return diff > 0 ? "↗ +\(number)" : "↘ −\(number)"
    }

    /// Resting heart rate: up 1 to 4 beats small, 5 or more large. HRV: down up to 15 % small, more large. Breathing:
    /// up half a breath small, a whole one large. Blood oxygen: down a point small, three large. Skin temperature,
    /// either way: 0.3 °C small, 0.6 large. Weight has none: whether up or down is good depends on the wearer's goal.
    static func tone(key: String, values: [Double]) -> Tone? {
        guard let (last, usual) = lastAndUsual(key: key, values: values) else { return nil }
        let diff = last - usual
        switch key {
        case "rhr": return diff < 0.5 ? .good : diff < 4.5 ? .small : .large
        case "hrv": return usual > 0 ? (diff / usual > -0.05 ? .good : diff / usual > -0.15 ? .small : .large) : nil
        case "resp_rate": return diff < 0.5 ? .good : diff < 1 ? .small : .large
        case "spo2": return diff > -1 ? .good : diff > -3 ? .small : .large
        case "skin_temp": return abs(diff) < 0.3 ? .good : abs(diff) < 0.6 ? .small : .large
        case "vo2max_est": return diff > -1 ? .good : diff > -3 ? .small : .large
        case "fitness_age": return diff < 1 ? .good : diff < 3 ? .small : .large
        default: return nil
        }
    }

    /// The latest value and the median of the 30 before it: the one reading both the figure and its colour come from.
    private static func lastAndUsual(key: String, values: [Double]) -> (last: Double, usual: Double)? {
        guard !["stress", "steps", "sleep_total_min", "active_kcal", "calories_in"].contains(key),
              let last = values.last, values.count >= 8 else { return nil }
        let before = values.dropLast().suffix(30).sorted()
        return (last, before[before.count / 2])
    }
}
