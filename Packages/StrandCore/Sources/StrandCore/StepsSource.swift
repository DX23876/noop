import Foundation

/// Where the app's daily steps come from, as the wearer chose it in Settings (owner, 2026-11-11): automatically (the
/// strap's measured count, then the phone's, then the strap's motion estimate), the strap alone, or the phone alone
/// (Apple Health on the iPhone, Health Connect on Android). Read by the one steps resolver
/// (`MetricResolver.resolvedSteps`), so the Today tile, the steps page and AgeLess show the same count. Changing it
/// leaves stored scores alone; only the AgeLess weeks, which read steps, are rebuilt (`DailyAnalysis.deleteHealthspanWeeks`).
public enum StepsSource: String, CaseIterable, Sendable {
    case automatic, strap, phone

    /// The key in UserDefaults, on Android the core's own defaults (`CorePrefs`).
    public static let defaultsKey = "steps.source"

    public static var current: StepsSource {
        StepsSource(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
    }
}
