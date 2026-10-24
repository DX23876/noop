import Foundation
import StrandAnalytics
import WhoopStore

// Moved from `Repository` (Android plan B3 step 4): which source supplies a metric on each day. Imported WHOOP
// wins, NOOP-computed fills the days it doesn't cover, and Apple Health only fills declared-compatible vitals
// on days neither strap source has. `Repository.resolvedSeries` is the app's entry point and keeps the screens'
// view of it unchanged.

/// One day's resolved value plus the source that actually supplied it (so a caption can name it).
public struct ResolvedMetricPoint: Equatable, Sendable {
    public let day: String
    public let value: Double
    public let source: String
    public let sourceKey: String

    public init(day: String, value: Double, source: String, sourceKey: String) {
        self.day = day; self.value = value; self.source = source; self.sourceKey = sourceKey
    }
}

/// A candidate (source, key) pair the resolver will try, in precedence order.
public struct MetricSourceCandidate: Equatable, Hashable, Sendable {
    public let source: String
    public let key: String

    public init(source: String, key: String) { self.source = source; self.key = key }
}

/// The full result of resolving one metric: which sources were tried, and the merged per-day points.
public struct MetricSeriesResolution: Equatable, Sendable {
    public let requestedSource: String
    public let candidates: [MetricSourceCandidate]
    public let points: [ResolvedMetricPoint]

    public init(requestedSource: String, candidates: [MetricSourceCandidate], points: [ResolvedMetricPoint]) {
        self.requestedSource = requestedSource; self.candidates = candidates; self.points = points
    }

    /// Plain `(day, value)` rows , the shape the chart/correlation code already consumes.
    public var values: [(day: String, value: Double)] { points.map { ($0.day, $0.value) } }

    /// Distinct sources that actually contributed a point, in first-seen order (for a caption).
    public var usedSources: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for point in points where !seen.contains(point.source) {
            seen.insert(point.source)
            ordered.append(point.source)
        }
        return ordered
    }
}

/// The per-day source precedence for metric series, over a `WhoopStore`.
public enum MetricResolver {
    /// The canonical strap source id an imported WHOOP history is banked under.
    public static let whoopSource = "my-whoop"
    public static let appleHealthSource = "apple-health"
    public static let healthConnectSource = "health-connect"

    /// Resolves `key` over `sourceCandidates`: the first candidate wins per day, later ones only fill days
    /// no earlier one covered, and the sleep values of a wake-day in `suppressedSleepWakeDays` (an explicit
    /// sleep deletion) are hidden. A missing store resolves to no points.
    public static func resolve(store: WhoopStore?, key: String, preferredSource: String,
                               actualWhoopSource: String, from: String, to: String,
                               suppressedSleepWakeDays: Set<String>) async -> MetricSeriesResolution {
        let candidates = sourceCandidates(forKey: key, preferredSource: preferredSource,
                                          actualWhoopSource: actualWhoopSource)
        guard let store else {
            return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: [])
        }

        // First candidate wins per day; later candidates only fill days no earlier one covered.
        var byDay: [String: ResolvedMetricPoint] = [:]
        for candidate in candidates {
            let rows = await rows(store: store, candidate: candidate, from: from, to: to)
            for row in rows where byDay[row.day] == nil {
                byDay[row.day] = ResolvedMetricPoint(day: row.day, value: row.value,
                                                     source: candidate.source, sourceKey: candidate.key)
            }
        }
        let suppressed = isSleepDayMetricKey(key) ? suppressedSleepWakeDays : Set<String>()
        let points = byDay.values.filter { !suppressed.contains($0.day) }.sorted { $0.day < $1.day }
        return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: points)
    }

    /// The app's one daily-steps reading, shared by the steps detail, the rolling tile and AgeLess: the
    /// strap's measured count, then the phone's import, then the strap's motion estimate, first per day.
    public static func resolvedSteps(store: WhoopStore?, actualWhoopSource: String,
                                     from: String, to: String) async -> MetricSeriesResolution {
        async let strap = resolve(store: store, key: "steps", preferredSource: whoopSource,
                                  actualWhoopSource: actualWhoopSource, from: from, to: to,
                                  suppressedSleepWakeDays: [])
        async let phone = resolve(store: store, key: "steps", preferredSource: appleHealthSource,
                                  actualWhoopSource: actualWhoopSource, from: from, to: to,
                                  suppressedSleepWakeDays: [])
        async let estimate = resolve(store: store, key: "steps_est", preferredSource: whoopSource,
                                     actualWhoopSource: actualWhoopSource, from: from, to: to,
                                     suppressedSleepWakeDays: [])
        let resolutions = await [strap, phone, estimate]
        var byDay: [String: ResolvedMetricPoint] = [:]
        for resolution in resolutions {
            for point in resolution.points where byDay[point.day] == nil { byDay[point.day] = point }
        }
        return MetricSeriesResolution(requestedSource: whoopSource,
                                      candidates: resolutions.flatMap(\.candidates),
                                      points: byDay.values.sorted { $0.day < $1.day })
    }

    /// Read one candidate's rows for the window: its metricSeries, plus the matching DailyMetric column
    /// for any day the metricSeries doesn't carry (a Bluetooth-only WHOOP 5 user has values in the daily
    /// columns but not the long-format series). Ascending by day.
    ///
    /// The DailyMetric read uses a +1-day upper buffer (`Self.dayAfter(to)`). A night is keyed on its LOCAL
    /// WAKE day, so the row backing the SELECTED day's Rest can sort on the day AFTER the caller's `to`
    /// (a just-after-midnight wake, or a UTC+ user whose wake-day rolls a calendar day ahead of the
    /// requested bound). Without the buffer that banked row was excluded and Today fell back to the latest
    /// historical Rest (#614). The buffer only WIDENS the daily read; `byDay`'s metricSeries-first
    /// precedence is unchanged, so an imported series point still wins its day. Mirrors Android
    /// WhoopRepository.resolvedRows.
    static func rows(store: WhoopStore, candidate: MetricSourceCandidate,
                     from: String, to: String) async -> [(day: String, value: Double)] {
        let metricRows = (try? await store.metricSeries(deviceId: candidate.source, key: candidate.key,
                                                        from: from, to: to)) ?? []
        var byDay = Dictionary(metricRows.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        if let dailyRows = try? await store.dailyMetrics(deviceId: candidate.source,
                                                         from: from, to: Self.dayAfter(to)) {
            for row in dailyRows where byDay[row.day] == nil {
                if let value = Self.dailyColumn(key: candidate.key, day: row) { byDay[row.day] = value }
            }
        }
        return byDay.keys.sorted().compactMap { day in byDay[day].map { (day, $0) } }
    }

    /// The candidate (source, key) pairs to try for `key`, in precedence order, given the user's
    /// `preferredSource`. The strap's real id is `actualWhoopSource` (`deviceId`), so the computed
    /// sibling is `actualWhoopSource + "-noop"`.
    ///  • strap-preferred → [imported strap, computed strap, compatible Apple] (Apple only for vitals
    ///    that have a declared 1:1 mapping);
    ///  • Apple-preferred → [Apple] (+ computed strap ONLY for steps/active_kcal, which the strap
    ///    estimates and Apple may not carry);
    ///  • any other source → itself only (nutrition/mood are single-source by design).
    public static func sourceCandidates(forKey key: String, preferredSource: String,
                                        actualWhoopSource: String) -> [MetricSourceCandidate] {
        let computedSource = actualWhoopSource + "-noop"
        func uniqued(_ cs: [MetricSourceCandidate]) -> [MetricSourceCandidate] {
            var seen = Set<MetricSourceCandidate>(); var out: [MetricSourceCandidate] = []
            for c in cs where !seen.contains(c) { seen.insert(c); out.append(c) }
            return out
        }

        if preferredSource == whoopSource || preferredSource == actualWhoopSource {
            // Active strap first (live/measured wins per day), then the CANONICAL "my-whoop" import, THEN
            // the computed siblings, so history banked under the canonical id before a re-add still
            // resolves (the union model) and imports outrank computed estimates — the documented
            // `imported WHOOP > NOOP-computed` order. The computed sibling used to sit ahead of the
            // canonical import, so after a device re-add (active != canonical) the new strap's computed
            // estimates shadowed richer imported my-whoop history (Swift twin of the ryanbr/noop#240
            // precedence fix). `uniqued` collapses these to one pair per source on a single-device
            // install (active == canonical), so that path is byte-identical. Apple is the final
            // cross-source fallback.
            var candidates = [
                MetricSourceCandidate(source: actualWhoopSource, key: key),
                MetricSourceCandidate(source: whoopSource, key: key),
                MetricSourceCandidate(source: computedSource, key: key),
                MetricSourceCandidate(source: whoopSource + "-noop", key: key),
            ]
            if let appleKey = appleCompatibleKey(forWhoopKey: key) {
                candidates.append(MetricSourceCandidate(source: appleHealthSource, key: appleKey))
            }
            return uniqued(candidates)
        }
        if preferredSource == appleHealthSource {
            var candidates = [MetricSourceCandidate(source: appleHealthSource, key: key)]
            // Health Connect is an Apple-equivalent body-metric source (Android only , harmless no-op on
            // iOS/Mac, which never write a "health-connect" series). Kept here so the resolver is
            // byte-identical to Android's, where it makes a Health-Connect-only weight history resolve in
            // Compare (#443). A real Apple export still wins per day; HC fills the rest.
            candidates.append(MetricSourceCandidate(source: healthConnectSource, key: key))
            if noopComputedCanFillAppleMetric(key) {
                candidates.append(MetricSourceCandidate(source: computedSource, key: key))
            }
            return uniqued(candidates)
        }
        return [MetricSourceCandidate(source: preferredSource, key: key)]
    }

    /// The Apple-Health series key that carries the SAME physiological quantity as a WHOOP key , used
    /// only for the declared-compatible vitals; nil means "no Apple equivalent, don't fall back to it".
    public static func appleCompatibleKey(forWhoopKey key: String) -> String? {
        switch key {
        case "rhr":              return "resting_hr"
        case "hrv", "spo2", "resp_rate", "avg_hr", "max_hr", "in_bed_min", "active_kcal":
            return key
        case "sleep_total_min":  return "asleep_min"
        case "sleep_deep_min":   return "deep_min"
        case "sleep_rem_min":    return "rem_min"
        case "sleep_light_min":  return "core_min"
        default:                 return nil
        }
    }

    /// Daily values hidden by an explicit sleep deletion. Recovery/HRV and other non-sleep outcomes remain
    /// available; only the deleted day's sleep duration, stages, need/debt and Rest score disappear.
    public static func isSleepDayMetricKey(_ key: String) -> Bool {
        if key.hasPrefix("sleep_") { return true }
        switch key {
        case "asleep_min", "in_bed_min", "deep_min", "rem_min", "core_min": return true
        default: return false
        }
    }

    /// Whether the NOOP-computed strap source may fill an Apple-preferred metric. Only the two daily
    /// totals the strap genuinely estimates (steps, calories) , never a derived WHOOP score.
    private static func noopComputedCanFillAppleMetric(_ key: String) -> Bool {
        switch key {
        case "steps", "active_kcal": return true
        default:                     return false
        }
    }

    /// The merged DailyMetric column backing an Explore metric key, for the days the imported/computed
    /// metricSeries doesn't cover (strap-only WHOOP 5 users). Mirrors InsightsView.dailyOutcome and
    /// Android's dailyPick, extended to every Explore "my-whoop" key that maps to a daily column.
    /// Also handles the Apple-compatible sleep aliases (asleep_min / deep_min / rem_min / core_min) the
    /// resolver may request when filling an Apple candidate from its daily columns. Keys with no daily
    /// column (avg_hr / max_hr …) return nil , they resolve from metricSeries only.
    ///
    /// `sleep_performance` (the Rest composite, 0–100) is NOT a stored column: IntelligenceEngine persists
    /// it as a metricSeries point. But a Bluetooth-only WHOOP 5 user , and, crucially, the SELECTED
    /// (just-synced) day before the heavy daily pass has projected the series , has the night's totals
    /// banked on the DailyMetric row while the metricSeries point is still missing. Without this case the
    /// resolver returned no Rest for that day and Today borrowed the latest historical value (#614). Derive
    /// it on the fly from the same banked totals via the single source of truth
    /// `AnalyticsEngine.Rest.composite(daily:)` , the SAME composite the series carries (what
    /// IntelligenceEngine projects) , so the day resolves to its own Rest. Consistency is left to the
    /// scorer's neutral default here (the daily row carries no regularity term). Mirrors Android
    /// WhoopRepository.dailyColumn / RestScorer.restFromDaily.
    public static func dailyColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery":         return d.recovery
        case "hrv":              return d.avgHrv
        case "rhr", "resting_hr": return d.restingHr.map(Double.init)
        case "strain":           return d.strain
        case "resp_rate":        return d.respRateBpm
        case "spo2":             return d.spo2Pct
        case "skin_temp":        return d.skinTempDevC
        case "sleep_total_min", "asleep_min": return d.totalSleepMin
        case "sleep_efficiency": return d.efficiency
        case "sleep_deep_min", "deep_min": return d.deepMin
        case "sleep_rem_min", "rem_min":   return d.remMin
        case "sleep_light_min", "core_min": return d.lightMin
        case "sleep_performance": return AnalyticsEngine.Rest.composite(daily: d)
        case "steps":            return d.steps.map(Double.init)
        case "active_kcal", "energy_kcal": return d.activeKcalEst
        default:                 return nil
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The "yyyy-MM-dd" day one calendar day AFTER `day`, or `day` verbatim when it isn't a parseable
    /// ISO date (e.g. a wide-open sentinel already past every real day, so no buffer is needed). Backs the
    /// +1-day daily read buffer in `rows` so a wake-day-keyed night that sorts just past the requested
    /// upper bound still resolves the selected day (#614). Mirrors Android WhoopRepository.bufferDayAfter.
    public static func dayAfter(_ day: String) -> String {
        guard let d = dayFormatter.date(from: day),
              let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: d)
        else { return day }
        return dayFormatter.string(from: next)
    }
}
