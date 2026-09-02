import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The "Optimal"/"Achtung" status word behind the Overview dashboard's "Deine Gesundheit" list.
///
/// Driven by the SAME personal-baseline engine (`VitalBands` + `Baselines.metricCfg`) the Health
/// Monitor's own vital tiles use — the population ranges below are copied VERBATIM from
/// `VitalSignsSummary.swift`, not re-guessed, so this list can never disagree with that screen about
/// whether a reading is in range.
///
/// `nil` for a card with no baseline configuration at all (fitness age, calories, weight, VO₂max,
/// vitality, sleep, stress, hydration, the Coupled tap-through). Fabricating an "Optimal" for those
/// would be a status the engine never actually computed — the row then shows no status dot, honestly,
/// rather than a fake green.
enum OverviewHealthStatus {

    static func status(for card: DashboardCard, day: DailyMetric?,
                       recentDays: [DailyMetric]) -> (word: String, tone: StrandTone)? {
        switch card {
        case .hrv:
            return wordFor(VitalBands.band(value: day?.avgHrv,
                                           history: recentDays.map(\.avgHrv),
                                           populationRange: 40...120, cfg: Baselines.hrvCfg))
        case .restingHr:
            return wordFor(VitalBands.band(value: day?.restingHr.map(Double.init),
                                           history: recentDays.map { $0.restingHr.map(Double.init) },
                                           populationRange: 40...60, cfg: Baselines.restingHRCfg))
        case .respiratory:
            return wordFor(VitalBands.band(value: day?.respRateBpm,
                                           history: recentDays.map(\.respRateBpm),
                                           populationRange: 12...20, cfg: Baselines.respCfg))
        case .bloodOxygen:
            // Population-only, same as the Health Monitor: no personal-baseline config exists for SpO2,
            // an absolute <95% floor is meaningful regardless of anyone's own history.
            return wordFor(VitalBands.band(value: day?.spo2Pct, history: [],
                                           populationRange: 95...100, cfg: nil))
        case .skinTemp:
            return wordFor(VitalBands.band(value: day?.skinTempDevC,
                                           history: recentDays.map(\.skinTempDevC),
                                           populationRange: (-0.6)...0.6,
                                           cfg: VitalBands.skinTempDeviationCfg))
        case .steps, .stress, .sleep, .fitnessAge, .vo2max, .vitality, .calories, .hydration,
             .coupled, .weight:
            return nil
        }
    }

    private static func wordFor(_ result: VitalBands.Result) -> (word: String, tone: StrandTone)? {
        switch result.band {
        case .inRange:    return (String(localized: "Optimal"), .positive)
        case .outOfRange: return (String(localized: "Attention"), .warning)
        case .noData:     return nil
        }
    }
}
