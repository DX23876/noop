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
