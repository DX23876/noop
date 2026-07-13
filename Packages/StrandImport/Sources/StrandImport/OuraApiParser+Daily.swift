import Foundation

public extension OuraApiParser {

    /// Parse a day-keyed summary endpoint's documents. `endpoint` selects the field mapping. Writes to
    /// `WearableDailyRow` columns only where the on-device schema already has a home (skin-temp dev,
    /// steps, calories, SpO2); everything else — and ALL of Oura's own scores — becomes `OuraDailyExtra`.
    /// Resting HR is deliberately NOT written here: `contributors.resting_heart_rate` on `daily_readiness`
    /// is a 0-100 readiness contributor SCORE, not bpm. The real resting HR comes from sleep's
    /// `lowest_heart_rate` (`OuraApiParser.parseSleep`).
    static func parseDaily(_ docs: [[String: Any]], endpoint: String) -> (days: [WearableDailyRow], extras: [OuraDailyExtra]) {
        var byDay: [String: WearableDailyRow] = [:]
        var extras: [OuraDailyExtra] = []
        func extra(_ day: String, _ key: String, _ v: Double?) {
            if let v { extras.append(OuraDailyExtra(day: day, key: key, value: v)) }
        }

        for doc in docs {
            guard let day = WearableJSON.str(doc, "day") else { continue }
            switch endpoint {

            case "daily_readiness":
                var r = byDay[day] ?? WearableDailyRow(day: day)
                if let c = doc["contributors"] as? [String: Any] {
                    // `resting_heart_rate` here is a 0-100 readiness contributor SCORE, not bpm — do not
                    // assign it to r.restingHr (that caused scores like 99/100/1 to be stored as "RHR").
                    // It still surfaces honestly below as the `oura_readiness_resting_heart_rate` extra.
                    for (k, _) in c { extra(day, "oura_readiness_\(k)", WearableJSON.posDbl(c, k)) }
                }
                r.skinTempDevC = WearableJSON.dbl(doc, "temperature_deviation") ?? r.skinTempDevC
                r.readinessScore = WearableJSON.posInt(doc, "score") ?? r.readinessScore
                extra(day, "ref_readiness_score", WearableJSON.posDbl(doc, "score"))
                byDay[day] = r

            case "daily_sleep":
                extra(day, "ref_sleep_score", WearableJSON.posDbl(doc, "score"))
                if let c = doc["contributors"] as? [String: Any] {
                    for (k, _) in c { extra(day, "oura_sleep_\(k)", WearableJSON.posDbl(c, k)) }
                }

            case "daily_activity":
                var r = byDay[day] ?? WearableDailyRow(day: day)
                r.steps = WearableJSON.posInt(doc, "steps") ?? r.steps
                r.activeKcal = WearableJSON.posDbl(doc, "active_calories") ?? r.activeKcal
                r.totalKcal = WearableJSON.posDbl(doc, "total_calories") ?? r.totalKcal
                extra(day, "ref_activity_score", WearableJSON.posDbl(doc, "score"))
                extra(day, "oura_equiv_walk_m", WearableJSON.posDbl(doc, "equivalent_walking_distance"))
                byDay[day] = r

            case "daily_spo2":
                var r = byDay[day] ?? WearableDailyRow(day: day)
                if let s = doc["spo2_percentage"] as? [String: Any] {
                    r.spo2Pct = WearableJSON.posDbl(s, "average") ?? r.spo2Pct
                    extra(day, "spo2", WearableJSON.posDbl(s, "average"))
                }
                extra(day, "oura_breathing_disturbance_index", WearableJSON.dbl(doc, "breathing_disturbance_index"))
                byDay[day] = r

            case "daily_stress":
                extra(day, "oura_stress_high_s", WearableJSON.posDbl(doc, "stress_high"))
                extra(day, "oura_recovery_high_s", WearableJSON.posDbl(doc, "recovery_high"))

            case "daily_resilience":
                if let c = doc["contributors"] as? [String: Any] {
                    for (k, _) in c { extra(day, "oura_resilience_\(k)", WearableJSON.dbl(c, k)) }
                }
                extra(day, "ref_resilience_level", resilienceLevel(WearableJSON.str(doc, "level")))

            case "daily_cardiovascular_age":
                extra(day, "oura_vascular_age", WearableJSON.dbl(doc, "vascular_age"))
                extra(day, "oura_pulse_wave_velocity", WearableJSON.dbl(doc, "pulse_wave_velocity"))

            case "vO2_max":
                extra(day, "vo2max", WearableJSON.posDbl(doc, "vo2_max"))

            default:
                break
            }
        }
        return (Array(byDay.values), extras)
    }

    /// Oura resilience level → an ordered reference number (1…5). Reference-only — never a NOOP score.
    static func resilienceLevel(_ s: String?) -> Double? {
        switch s {
        case "limited":     return 1
        case "adequate":    return 2
        case "solid":       return 3
        case "strong":      return 4
        case "exceptional": return 5
        default:            return nil
        }
    }
}
