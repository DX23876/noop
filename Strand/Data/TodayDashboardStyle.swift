import Foundation

/// Which Today layout the app shows: Classic, Liquid, or one of two additional reference-matched
/// dashboards (Trends / Overview). One setting rather than the old boolean plus a second, parallel
/// switch — the user picks exactly one of four looks, never two independent flags that could disagree
/// about which screen is actually showing.
enum TodayDashboardStyle: String, CaseIterable, Identifiable {
    case classic
    case liquid
    /// CHARGE/EFFORT/REST rings, a Coach card, a 14-day three-line trend chart, four configurable
    /// metric slots, and a recent-activity row.
    case trends
    /// "Heute im Überblick" (Erholung/Belastung/Schlaf rings with a state word + a sentence), a
    /// three-card "Heute wichtig" row, and a "Deine Gesundheit" list.
    case overview

    var id: String { rawValue }
    static let storageKey = "noop.todayDashboardStyle"
    /// The RETIRED boolean this replaces. Read once, at first launch under the new key, to carry an
    /// existing user's choice forward — `true` meant Liquid, `false` meant Classic. Never written again;
    /// left in place (not deleted) so a downgrade to an older build still finds its old preference.
    private static let legacyLiquidEnabledKey = "noop.liquidTodayEnabled"

    var label: String {
        switch self {
        case .classic:  return String(localized: "Classic")
        case .liquid:   return String(localized: "Liquid")
        case .trends:   return String(localized: "Trends Dashboard")
        case .overview: return String(localized: "Overview Dashboard")
        }
    }

    static func resolve(_ raw: String) -> TodayDashboardStyle? { TodayDashboardStyle(rawValue: raw) }

    /// Write the migrated value into `storageKey` exactly once, before any `@AppStorage` in a View reads
    /// it. `@AppStorage` cannot run arbitrary migration logic itself (its property-wrapper `init` just
    /// supplies a fallback default, it can't consult a SECOND key) — so this runs eagerly at app launch,
    /// the same place `DemoDayHarness.applyLaunchArgsIfNeeded()` does its one-time setup, before the
    /// first `TodayDashboardStyle`-reading view renders. Safe to call on every launch: a no-op once the
    /// new key exists.
    static func migrateLegacyBoolIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: storageKey) == nil else { return }
        // Legacy default (before this type existed) was Liquid-on.
        let wasLiquid = defaults.object(forKey: legacyLiquidEnabledKey) as? Bool ?? true
        defaults.set((wasLiquid ? TodayDashboardStyle.liquid : .classic).rawValue, forKey: storageKey)
    }
}
