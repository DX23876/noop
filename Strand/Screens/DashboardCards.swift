import Foundation
import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - "Your cards" customisable dashboard (WHOOP "My Dashboard")
//
// The Today screen's "Your cards" section was a fixed trio (Stress / Fitness age / Vitality). This turns
// it into a user-customisable dashboard faithful to WHOOP's "My Dashboard": the user chooses WHICH metric
// cards show and in WHAT order from a registry of the values Today already loads. Persistence is
// DISPLAY-ONLY, no metric is computed or stored differently; this just decides which already-loaded
// values render as WHOOP metric rows and in what sequence.
//
// Stored as a JSON-encoded [String] of card ids in @AppStorage (UserDefaults). Unknown ids are dropped on
// read; a known id missing from the saved list is offered (disabled) in the editor so a future card can't
// be lost. Mirrors the existing KeyMetric layout mechanism but as its own list so the two sections stay
// independent (Key Metrics grid vs. the Your-cards dashboard).

/// One available card in the "Your cards" dashboard. The `rawValue` is the stable persisted identifier,
/// keep it byte-identical to the Android `DashboardCard` ids so a backup/restore reads the same dashboard
/// on either OS.
enum DashboardCard: String, CaseIterable, Identifiable {
    case hrv
    case restingHr
    case respiratory
    case steps
    case stress
    case fitnessAge
    case vo2max
    case vitality
    case bloodOxygen
    case skinTemp
    case sleep
    case calories
    case hydration
    /// Optional, default-OFF (task #43): a tap-through to the Coupled view (the WHOOP-style day read). Unlike
    /// every other card this carries NO metric value of its own, it is a navigation row that opens the full
    /// CoupledView screen. It is NOT in `defaultSelection`, so a fresh install never shows it until the user
    /// adds it via CUSTOMISE, matching the manual-first / default-OFF posture.
    case coupled
    /// Current body weight — trend-smoothed when reliable, else the latest measurement, else the
    /// profile fallback (the same three-tier resolution `WeightSeries.displayWeight` already gives the
    /// classic Weight tile). Added for the Overview dashboard's "Deine Gesundheit" list, which names
    /// weight explicitly; not in `defaultSelection`, so nothing existing changes.
    case weight

    var id: String { rawValue }

    /// The card's display label (the UPPERCASE WHOOP metric-row label is derived from this). Localized via
    /// the String Catalog so the dashboard rows read in the user's language (the `.uppercased()` the row
    /// applies then uppercases the LOCALIZED word, with the current locale's casing rules).
    var title: String {
        switch self {
        case .hrv:         return String(localized: "HRV")
        case .restingHr:   return String(localized: "Resting HR")
        case .respiratory: return String(localized: "Respiratory")
        case .steps:       return String(localized: "Steps")
        case .stress:      return String(localized: "Stress")
        case .fitnessAge:  return String(localized: "Fitness Age")
        case .vo2max:      return String(localized: "VO₂ Max")
        case .vitality:    return String(localized: "Vitality")
        case .bloodOxygen: return String(localized: "Blood Oxygen")
        case .skinTemp:    return String(localized: "Skin Temp")
        case .sleep:       return String(localized: "Sleep")
        case .calories:    return String(localized: "Calories")
        case .hydration:   return String(localized: "Hydration")
        case .coupled:     return String(localized: "Coupled view")
        case .weight:      return String(localized: "Weight")
        }
    }

    /// A short grey baseline/caption shown under the row's value (the WHOOP "30-day baseline" line).
    /// Static descriptive text only, never invented data. Localized via the String Catalog.
    var subtitle: String {
        switch self {
        case .hrv:         return String(localized: "Heart-rate variability")
        case .restingHr:   return String(localized: "Resting heart rate")
        case .respiratory: return String(localized: "Breaths per minute")
        case .steps:       return String(localized: "Today")
        case .stress:      return String(localized: "Autonomic load")
        case .fitnessAge:  return String(localized: "Updated weekly")
        case .vo2max:      return String(localized: "Estimated, updated weekly")
        case .vitality:    return String(localized: "Wellness score")
        case .bloodOxygen: return String(localized: "Blood oxygen")
        case .skinTemp:    return String(localized: "Skin temperature")
        case .sleep:       return String(localized: "Last night")
        case .calories:    return String(localized: "Total burned so far")
        case .hydration:   return String(localized: "Today's fluid")
        case .coupled:     return String(localized: "Recovery, strain and sleep in one glance")
        case .weight:      return String(localized: "Current weight")
        }
    }

    /// The thin-line SF Symbol shown in the leading icon tile.
    var icon: String {
        switch self {
        case .hrv:         return "waveform.path.ecg"
        case .restingHr:   return "heart.fill"
        case .respiratory: return "lungs.fill"
        case .steps:       return "figure.walk"
        case .stress:      return "bolt.heart"
        case .fitnessAge:  return "figure.run"
        case .vo2max:      return "lungs"
        case .vitality:    return "sparkles"
        case .bloodOxygen: return "drop.fill"
        case .skinTemp:    return "thermometer.medium"
        case .sleep:       return "bed.double.fill"
        case .calories:    return "flame.fill"
        case .hydration:   return "waterbottle.fill"
        case .coupled:     return "circle.hexagongrid.fill"
        case .weight:      return "scalemass.fill"
        }
    }

    /// The unit suffix shown after the value (smaller weight). Empty when the value is already complete.
    var unit: String {
        switch self {
        case .hrv:         return "ms"
        case .restingHr:   return "bpm"
        // Respiratory rate is breaths per minute. `rpm` is commonly read as revolutions per minute
        // and was therefore ambiguous on the dashboard.
        case .respiratory: return String(localized: "/min")
        case .steps:       return ""
        case .stress:      return ""
        case .fitnessAge:  return String(localized: "yrs")
        case .vo2max:      return ""    // the estimated VO₂max number alone; ml/kg/min is too long for a tile
        case .vitality:    return ""
        case .bloodOxygen: return ""    // value carries the % itself
        case .skinTemp:    return ""    // value carries the ° itself
        case .sleep:       return ""    // value carries the h/m itself
        case .calories:    return "kcal"
        case .hydration:   return ""    // value bakes in "<total> / <goal> L" itself
        case .coupled:     return ""    // a tap-through row, no value, so no unit
        case .weight:      return ""    // UnitFormatter.massFromKilograms bakes the unit in
        }
    }

    /// The default set when the user hasn't customised the dashboard: the original Stress / Fitness age /
    /// Vitality trio plus HRV + Resting HR (per the task's "sensible default"). Cards with no value yet
    /// simply render "—", so the default set is safe on a fresh install.
    static let defaultSelection: [DashboardCard] = [
        .stress, .fitnessAge, .vitality, .hrv, .restingHr,
    ]

    /// Canonical order used to list the disabled remainder in the editor.
    static let canonicalOrder: [DashboardCard] = allCases

    /// Canonical first-hop destination. Several persisted card identifiers deliberately differ from
    /// MetricCatalog keys, so constructing a route from `rawValue` silently opens the wrong screen.
    var detailRoute: TabRoute {
        switch self {
        case .hrv:         return .metricSourced(key: "hrv", source: Repository.whoopSource)
        case .restingHr:   return .metricSourced(key: "rhr", source: Repository.whoopSource)
        case .respiratory: return .metricSourced(key: "resp_rate", source: "apple-health")
        case .steps:       return .metricSourced(key: "steps", source: "apple-health")
        case .bloodOxygen: return .metricSourced(key: "spo2", source: Repository.whoopSource)
        case .skinTemp:    return .metricSourced(key: "skin_temp", source: Repository.whoopSource)
        case .fitnessAge:  return .metricSourced(key: "fitness_age", source: Repository.whoopSource)
        case .vo2max:      return .metricSourced(key: "vo2max_est", source: Repository.whoopSource)
        case .vitality:    return .metricSourced(key: "vitality", source: Repository.whoopSource)
        case .sleep:       return .sleep
        case .calories:    return .energy
        case .stress:      return .stress
        case .hydration:   return .hydration
        case .coupled:     return .coupled
        case .weight:      return .weight
        }
    }

    /// Route to the provider that supplied the value this lightweight dashboard actually rendered.
    /// The static route remains the persistence/catalog default; this resolver handles the explicit
    /// Apple fallback used by dashboard rows.
    func detailRoute(day: DailyMetric?, appleDay: AppleDaily?) -> TabRoute {
        switch self {
        case .steps:
            return day?.steps != nil
                ? .metricSourced(key: "steps", source: Repository.whoopSource)
                : .metricSourced(key: "steps", source: "apple-health")
        case .respiratory:
            return day?.respRateBpm != nil
                ? .metricSourced(key: "resp_rate", source: Repository.whoopSource)
                : .metricSourced(key: "resp_rate", source: "apple-health")
        case .bloodOxygen:
            return day?.spo2Pct != nil
                ? .metricSourced(key: "spo2", source: Repository.whoopSource)
                : .metricSourced(key: "spo2", source: "apple-health")
        default: return detailRoute
        }
    }
}

/// Display-only persistence for the "Your cards" dashboard selection. Holds an ORDERED list of the enabled
/// cards as a JSON-encoded [String] of ids; a card not in the list is hidden. Stored in
/// @AppStorage("today.dashboardCards").
enum DashboardCardPrefs {
    /// UserDefaults key, a JSON array of `DashboardCard` ids in display order.
    static let selectionKey = "today.dashboardCards"

    /// Encode an ordered list of enabled cards into the stored JSON string. Falls back to a comma-joined
    /// string if JSON encoding ever fails (it won't for [String]), so the value is always decodable.
    static func encode(_ cards: [DashboardCard]) -> String {
        let ids = cards.map(\.rawValue)
        if let data = try? JSONEncoder().encode(ids), let json = String(data: data, encoding: .utf8) {
            return json
        }
        return ids.joined(separator: ",")
    }

    /// Decode the stored string into an ordered list of enabled cards. An empty/unset string yields the
    /// default selection (so a fresh install shows the sensible default). Accepts both the JSON-array form
    /// and a legacy comma-joined form. Unknown ids are dropped; duplicates are de-duped; this returns ONLY
    /// the enabled cards in their saved order, the editor pairs it with the disabled remainder.
    static func decodeEnabled(_ raw: String) -> [DashboardCard] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return DashboardCard.defaultSelection }

        let ids: [String]
        if let data = trimmed.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data) {
            ids = decoded
        } else {
            ids = trimmed.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }

        var seen = Set<DashboardCard>()
        var result: [DashboardCard] = []
        for token in ids {
            if let c = DashboardCard(rawValue: token), seen.insert(c).inserted {
                result.append(c)
            }
        }
        // An all-unknown / empty decode shouldn't blank the dashboard, fall back to the default set.
        return result.isEmpty ? DashboardCard.defaultSelection : result
    }
}

/// Overview owns its health-list selection independently from Today’s "Your cards" preference.
enum OverviewHealthCardsPrefs {
    static let selectionKey = "overview.healthCards"
    static let defaultSelection: [DashboardCard] = [.restingHr, .hrv, .respiratory, .fitnessAge, .calories, .weight]
    static let available = DashboardCard.canonicalOrder.filter { $0 != .coupled }
    static func decode(_ raw: String) -> [DashboardCard] {
        let ids = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? raw.split(separator: ",").map(String.init)
        let cards = ids.compactMap(DashboardCard.init(rawValue:)).filter { available.contains($0) }
        var seen = Set<DashboardCard>()
        let unique = cards.filter { seen.insert($0).inserted }
        return unique.isEmpty ? defaultSelection : unique
    }
    static func encode(_ cards: [DashboardCard]) -> String { DashboardCardPrefs.encode(cards) }
}

/// How a day's step figure was arrived at, and the rule for choosing it.
///
/// The rule is TodayView's (#843/#813, `TodayView.keyMetricTile(.steps)`), lifted out so a second screen
/// cannot ship a shorter version of it. Two things it exists to prevent, both of which have happened:
///
/// 1. **Never the latest imported Apple-Health row.** That row can be days stale, and using it froze the
///    tile on an old import — a number from another day presented as this day's.
/// 2. **An estimate is never passed off as a count.** A WHOOP 4.0 sends no step counter, so the
///    on-device estimate fills the gap — but it is labelled, so it cannot be mistaken for a measurement.
enum DailyStepsReading: Equatable {
    /// A real count for THIS day: the strap's own counter, or Apple Health for the same day.
    case measured(Int)
    /// The on-device estimate for this day (WHOOP 4.0 motion → calibrated steps). Always shown labelled.
    case estimated(Int)

    var steps: Int {
        switch self {
        case .measured(let n), .estimated(let n): return n
        }
    }

    var isEstimated: Bool { if case .estimated = self { return true }; return false }

    /// All three inputs must already be scoped to the SAME day — passing "the newest row I have" for
    /// `appleSteps` is the bug this type exists to stop.
    static func resolve(strapSteps: Int?, appleSteps: Int?, estimatedSteps: Int?) -> DailyStepsReading? {
        if let strapSteps { return .measured(strapSteps) }
        if let appleSteps { return .measured(appleSteps) }
        if let estimatedSteps { return .estimated(estimatedSteps) }
        return nil
    }
}

/// The most recent BANKED estimate as of a given day.
///
/// Fitness age, VO₂max and Vitality are slow-moving derived estimates, not per-day measurements: the
/// engine banks a new one when it has enough to say, which is not every day. TodayView reads them as
/// "the latest banked value" (`#1391: latest banked VO₂max estimate`); the dashboards asked for the value
/// dated exactly to the selected day and therefore showed "—" on every day the estimate had not been
/// rewritten — which is most days.
///
/// The `<=` is what makes one rule serve both cases: on today it IS the latest banked value, matching
/// Today; on a navigated past day it is the estimate as it stood then, rather than a number from after
/// the day being read.
///
/// This is deliberately NOT the rule for measurements — see `DailyStepsReading`, where reaching for the
/// newest row is the bug. A step count belongs to its day; a fitness age does not.
func latestBanked(_ series: [(day: String, value: Double)], asOf dayKey: String) -> Double? {
    series.last(where: { $0.day <= dayKey })?.value
}

/// The PER-FIELD vitals carry the dashboard cards use, mirroring `TodayView.dashboardValue`.
///
/// Three of these columns are sparse by construction, so "today's row has nothing" is not the same as
/// "nobody has measured this". The on-device engine writes `spo2Pct = nil` for WHOOP 5/MG entirely, and
/// computed rows write it nil even when an imported row holds a real reading — which is why the two
/// dashboards showed "—" for Blood Oxygen while Today, which carries, showed a number for the same day.
///
/// The rows come from `Repository`'s own selectors (`lastVitalsDay` / `lastSpo2Day` / `lastSkinTempDay` /
/// `lastRespDay`), never a locally invented "newest row with a value": #1331 is exactly that bug, where
/// two unbounded resolvers printed one CSV import's 15.6 as today's respiratory rate for a fortnight. The
/// respiratory carry is the staleness-BOUNDED one for that reason; SpO₂ and skin temperature are sparse
/// or import-fed, so last-known-of-any-age is the honest answer for them.
///
/// HRV and resting HR deliberately do NOT carry here: `TodayView.dashboardValue` reads them from the day
/// itself, and a dashboard card that carried them would disagree with Today.
struct DashboardVitalCarry {
    var vitals: DailyMetric?
    var spo2: DailyMetric?
    var skinTemp: DailyMetric?
    var resp: DailyMetric?

    /// Resolve all four carries for a day. Returns empty carries for a navigated past day, which shows
    /// its own row verbatim — carrying INTO the past would show a value recorded after the day being read.
    static func resolve(days: [DailyMetric], todayKey: String, isToday: Bool) -> DashboardVitalCarry {
        guard isToday else { return DashboardVitalCarry() }
        return DashboardVitalCarry(vitals: Repository.lastVitalsDay(days: days, todayKey: todayKey),
                                   spo2: Repository.lastSpo2Day(days: days, todayKey: todayKey),
                                   skinTemp: Repository.lastSkinTempDay(days: days, todayKey: todayKey),
                                   resp: Repository.lastRespDay(days: days, todayKey: todayKey))
    }

    func spo2Pct(_ day: DailyMetric?) -> Double? {
        day?.spo2Pct ?? vitals?.spo2Pct ?? spo2?.spo2Pct
    }

    func skinTempDevC(_ day: DailyMetric?) -> Double? {
        day?.skinTempDevC ?? vitals?.skinTempDevC ?? skinTemp?.skinTempDevC
    }

    func respRateBpm(_ day: DailyMetric?) -> Double? {
        day?.respRateBpm ?? resp?.respRateBpm
    }
}

/// Exactly three compact Overview focus cards. Coach stays available without being a default.
enum OverviewFocusItem: String, CaseIterable, Identifiable {
    case hrv, restingHr, steps, sleep, bloodOxygen, respiratory, stress, calories, hydration, fitnessAge, vo2max, coach
    var id: String { rawValue }
    var title: String { rawValue == "restingHr" ? String(localized: "Resting HR") : rawValue == "bloodOxygen" ? String(localized: "Blood Oxygen") : rawValue == "vo2max" ? String(localized: "VO₂ Max") : rawValue == "coach" ? String(localized: "Coach") : (DashboardCard(rawValue: rawValue)?.title ?? rawValue) }
    var icon: String { rawValue == "coach" ? "person.fill" : (DashboardCard(rawValue: rawValue)?.icon ?? "square.grid.2x2") }
    var tint: Color { rawValue == "coach" ? StrandPalette.accent : TrendsMetricStrip.tint(DashboardCard(rawValue: rawValue) ?? .hrv) }
}

enum OverviewFocusPrefs {
    static let slotKeys = ["overview.focus.slot1", "overview.focus.slot2", "overview.focus.slot3"]
    static let defaults: [OverviewFocusItem] = [.hrv, .restingHr, .steps]
}
