import Foundation

/// Which measure tiles a wearer starts the new design's Today with (2026-11-18).
///
/// The rule lives here, in the shared folder, rather than in `ForgeTodayWidgetStore`: that store is
/// iOS-only, and a rule no test can reach is a rule that drifts. Android's twin is
/// `TodayWidgets.firstTiles`.
///
/// Analysis migration required: no. Which tiles are placed, nothing derived.
enum ForgeTodayTileSeed {

    /// The fixed set for an install that never arranged its Key Metrics, as Today has placed since the
    /// tiles were introduced.
    static let firstSet = ["hrv", "rhr", "steps", "sleep_total_min", "stress", "weight"]

    /// Measures that exist only across the whole row (2026-11-18): Charge, Effort and Rest.
    ///
    /// Derived from the metrics themselves rather than written out a second time, so this set and the
    /// metrics that are NOT carried into the tiles cannot drift apart: they are the same three, by
    /// construction. Android's twin is `TodayWidget.WHOLE_ROW_MEASURES`.
    static let wholeRowMeasures = Set(KeyMetric.allCases.compactMap(\.wholeRowMeasureKey))

    /// The measure keys to place, from a stored `today.keyMetrics` layout.
    ///
    /// With no layout saved this is `firstSet`. With one, it is THAT layout in ITS order, because the new
    /// design arrives for everyone at once and must not rearrange anybody's Today on the way in. Charge,
    /// Effort and Rest drop out (`KeyMetric.measureKey`): they exist as tiles only across the whole row,
    /// and silently turning someone's small tile into a full row is the rearrangement this avoids.
    static func measureKeys(selection: String?) -> [String] {
        let raw = (selection ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return firstSet }
        return KeyMetricPrefs.decodeEnabled(raw).compactMap(\.measureKey)
    }
}
