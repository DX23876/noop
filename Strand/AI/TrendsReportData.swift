import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Range options

/// The export window choices offered in the picker. Mirrors the Trends range ethos
/// (trailing N days, or all history) but is its own type so the report's wording is
/// self-contained.
enum ReportRange: Int, CaseIterable, Identifiable {
    case days30 = 30, days90 = 90, days180 = 180, days365 = 365, all = 0
    var id: Int { rawValue }

    /// Short pill label.
    var label: String {
        switch self {
        case .days30:  return String(localized: "30d")
        case .days90:  return String(localized: "90d")
        case .days180: return String(localized: "6M")
        case .days365: return String(localized: "1Y")
        case .all:     return String(localized: "All")
        }
    }

    /// Long human label for the report title / picker description.
    var longName: String {
        switch self {
        case .days30:  return String(localized: "Last 30 days")
        case .days90:  return String(localized: "Last 90 days")
        case .days180: return String(localized: "Last 6 months")
        case .days365: return String(localized: "Last year")
        case .all:     return String(localized: "All history")
        }
    }

    /// Trailing-day window, or nil for "all history".
    var days: Int? { self == .all ? nil : rawValue }
}

/// Builds a `RangeReport` for a `ReportRange` from a DailyMetric history, plus the raw
/// per-metric sparkline series the page draws. Pure: no Repository, no I/O — give it the
/// `days` array and today's local day key.
enum TrendsReportData {

    /// The nine day→value maps the engine consumes, keyed by ReportMetric.
    ///
    /// `stressByDay` is the persisted daily stress series ("yyyy-MM-dd" → 0–3), the same
    /// stored series the Stress screen prioritises (#457). It isn't carried on `DailyMetric`,
    /// so the caller loads it and passes it in; absent days simply stay out of the report.
    static func metricMaps(from days: [DailyMetric],
                           stressByDay: [String: Double] = [:]) -> [ReportMetric: [String: Double]] {
        var workouts: [String: Double] = [:]
        var recovery: [String: Double] = [:]
        var sleepHours: [String: Double] = [:]
        var hrv: [String: Double] = [:]
        var restingHr: [String: Double] = [:]
        var strain: [String: Double] = [:]
        var respRate: [String: Double] = [:]
        var skinTempDev: [String: Double] = [:]
        for d in days {
            // Workouts logged that day (#457). The count is always present on a recorded day
            // (0 on a rest day), so the row reflects the full window's activity cadence.
            if let c = d.exerciseCount { workouts[d.day] = Double(c) }
            if let v = d.recovery { recovery[d.day] = v }
            // Sleep is reported in HOURS to match the metric's unit; totalSleepMin is the
            // persisted minutes asleep. Days with no in-bed sleep stay absent.
            if let m = d.totalSleepMin, m > 0 { sleepHours[d.day] = m / 60.0 }
            if let v = d.avgHrv { hrv[d.day] = v }
            if let v = d.restingHr { restingHr[d.day] = Double(v) }
            if let v = d.strain { strain[d.day] = v }
            // In-sleep physiology (v7 columns). Absent on days the strap didn't measure them.
            if let v = d.respRateBpm { respRate[d.day] = v }
            if let v = d.skinTempDevC { skinTempDev[d.day] = v }
        }
        // Daily stress score (#457), clamped to its 0–3 scale. Stored-only — the report never
        // re-derives a stress value (unlike the live Stress screen), so a day with no banked
        // stress simply has no Stress row contribution.
        let stress = stressByDay.mapValues { Swift.min(Swift.max($0, 0), 3) }
        return [
            .workouts: workouts, .stress: stress,
            .recovery: recovery, .sleepHours: sleepHours, .hrv: hrv,
            .restingHr: restingHr, .strain: strain,
            .respRate: respRate, .skinTempDev: skinTempDev,
        ]
    }

    /// The inclusive [start, end] "yyyy-MM-dd" window for a range, anchored to today's
    /// LOCAL day (so a 30-day export is the last 30 calendar days, not the last 30 rows —
    /// matching TrendsView's window rule). For `.all`, start is the earliest day present.
    static func window(for range: ReportRange, days: [DailyMetric],
                       today: String) -> (start: String, end: String) {
        let end = today
        guard let n = range.days else {
            // All history: from the earliest recorded day (or today if the history is empty).
            let start = days.map(\.day).min() ?? today
            return (start, end)
        }
        // Trailing N calendar days ending today, computed via the local-day key so the
        // window matches TrendsView (Calendar-based, phone-local), then clamped to the
        // ISO string the engine compares on.
        let startDate = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date()
        // Local-zone "yyyy-MM-dd" matching Repository.localDayKey, but self-contained so this stays a
        // nonisolated static (localDayKey is @MainActor-isolated and this runs off the main actor).
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let start = f.string(from: startDate)
        return (start, end)
    }

    /// Build the full report for a range from a DailyMetric history (+ the stored daily
    /// stress series, for the Stress row — #457).
    static func report(for range: ReportRange, days: [DailyMetric],
                       today: String, stressByDay: [String: Double] = [:],
                       units: ReportDisplayUnits = .stored) -> RangeReport {
        let (start, end) = window(for: range, days: days, today: today)
        return RangeReportEngine.build(metrics: metricMaps(from: days, stressByDay: stressByDay),
                                       start: start, end: end, units: units)
    }

    /// The in-range sparkline series (chronological values) for one metric — the same
    /// window the engine summarised, so the line and the stats agree.
    static func series(_ metric: ReportMetric, from days: [DailyMetric],
                       start: String, end: String, stressByDay: [String: Double] = [:]) -> [Double] {
        let map = metricMaps(from: days, stressByDay: stressByDay)[metric] ?? [:]
        return map.filter { $0.key >= start && $0.key <= end }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }
}
