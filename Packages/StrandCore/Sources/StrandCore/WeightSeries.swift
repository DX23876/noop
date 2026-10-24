import Foundation
import StrandAnalytics
import WhoopStore

// WeightSeries.swift — THE one place body weight is resolved from its sources.
//
// Weight arrives from two places that will never be merged into one store:
//
//   • `apple-health` — a daily `metricSeries` cell, latest-of-day, imported from HealthKit. Mutable
//     at the source: a sample can be corrected or deleted in Health long after it synced.
//   • `noop-weight` — the daily projection of `bodyWeightEntry` (v43), the weigh-ins the user typed
//     into NOOP, which are editable and deletable here and carry a precise instant.
//
// Apple's readings are deliberately NOT copied into `bodyWeightEntry`. A copy would need permanent
// reconciliation against a source that changes behind it, and would produce exactly the duplicates
// the natural key exists to prevent. Instead the two are UNIONED per day — the same "one source wins
// a day, never a sum" model `MetricResolver.sourceCandidates` already applies to every other metric.
//
// Why this file exists at all: every weight read in the app used to name `source: "apple-health"`
// literally — goal tracking, the goal-setup tool, both Today screens, the Apple Health screen. A
// weigh-in typed into NOOP would have been invisible to all of them. This is the single canonical
// resolver those call sites now share, in the spirit of CLAUDE.md's rule for
// `DeviceFamily.forRegistryModel`: one resolver, never a scattered string compare.

/// Where a resolved weight value came from. Display-facing: the detail list labels each row with it.
public enum WeightSource: String, Equatable, Sendable {
    /// Typed into NOOP (editable here).
    case manual
    /// Imported from Apple Health (read-only here — edit it in Health).
    case appleHealth

    /// The `bodyWeightEntry.source` token this corresponds to, for rows NOOP itself writes.
    public var storageToken: String {
        switch self {
        case .manual:      return BodyWeightRow.Source.manual.rawValue
        case .appleHealth: return BodyWeightRow.Source.appleHealth.rawValue
        }
    }
}

/// One resolved day of the weight series.
public struct WeightPoint: Equatable, Sendable {
    public let day: String        // yyyy-MM-dd
    public let value: Double      // kg
    public let source: WeightSource

    public init(day: String, value: Double, source: WeightSource) {
        self.day = day; self.value = value; self.source = source
    }
}

/// One row in the weigh-in history list. A `manual` entry carries the id and instant needed to edit
/// or delete it; an Apple-imported day carries neither, because NOOP does not own it.
public struct WeightEntry: Equatable, Identifiable, Sendable {
    /// Stable row identity: the entry id for a NOOP weigh-in, the day key for an Apple import.
    public let id: String
    public let day: String
    public let value: Double
    public let source: WeightSource
    /// Precise instant, when the source records one. Apple's daily cell does not.
    public let takenAt: Date?
    public let note: String?

    /// Whether this row can be edited or deleted in NOOP. False for Apple-imported days: the
    /// measurement lives in Health, and pretending to delete it here would delete nothing.
    public var isEditable: Bool { source == .manual }

    public init(id: String, day: String, value: Double, source: WeightSource, takenAt: Date?, note: String?) {
        self.id = id; self.day = day; self.value = value; self.source = source; self.takenAt = takenAt
        self.note = note
    }
}

/// The pure half — merging, so it can be unit-tested with no store, no HealthKit and no clock.
public enum WeightSeries {

    /// A `yyyy-MM-dd` day key as a Date, anchored at NOON so a timezone shift can never move a
    /// weigh-in onto the neighbouring day. Same anchor `GoalTrackingEngine.parseDay` uses, because
    /// the two feed the same trend maths and must place a reading on the same day.
    public static func date(forDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.autoupdatingCurrent.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// Union two per-day series into one, NOOP's own weigh-in winning any day both cover.
    ///
    /// Manual wins because a person typed it: if someone corrects a scale reading in NOOP for a day
    /// Health also has, the correction is the newer intent. It is a per-day choice, never a sum —
    /// two sources describing one body on one day are the same quantity measured twice.
    ///
    /// Both inputs may be in any order; the result is oldest day first.
    public static func merge(manual: [(day: String, value: Double)],
                      appleHealth: [(day: String, value: Double)]) -> [WeightPoint] {
        var byDay: [String: WeightPoint] = [:]
        // Apple first, so a manual entry on the same day overwrites it rather than the reverse.
        for p in appleHealth {
            byDay[p.day] = WeightPoint(day: p.day, value: p.value, source: .appleHealth)
        }
        for p in manual {
            byDay[p.day] = WeightPoint(day: p.day, value: p.value, source: .manual)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Merge into the history LIST, which is finer-grained than the daily series: every NOOP weigh-in
    /// is its own row (several on one day are all shown, each with its instant), while Apple
    /// contributes one row per day it covers and none for a day NOOP already has a weigh-in on —
    /// otherwise the same morning appears twice, once uneditable.
    ///
    /// Newest first: a history list is read from the top.
    public static func mergeEntries(manual: [BodyWeightRow],
                             appleHealth: [(day: String, value: Double)]) -> [WeightEntry] {
        let daysWithManual = Set(manual.map(\.day))
        var out: [WeightEntry] = manual.map { row in
            WeightEntry(id: row.id, day: row.day, value: row.weightKg, source: .manual,
                        takenAt: Date(timeIntervalSince1970: TimeInterval(row.takenAt)),
                        note: row.note)
        }
        out += appleHealth
            .filter { !daysWithManual.contains($0.day) }
            .map { WeightEntry(id: "apple-\($0.day)", day: $0.day, value: $0.value,
                               source: .appleHealth, takenAt: nil, note: nil) }
        // Instant first where both have one, day key otherwise — an Apple day sorts against a NOOP
        // weigh-in by day alone, which is all the resolution Apple's daily cell actually carries.
        return out.sorted { a, b in
            if a.day != b.day { return a.day > b.day }
            switch (a.takenAt, b.takenAt) {
            case let (x?, y?): return x > y
            case (_?, nil):    return true      // a precise weigh-in sorts above the day's import
            case (nil, _?):    return false
            case (nil, nil):   return a.id > b.id
            }
        }
    }
}

/// Which of the three tiers a displayed body weight actually came from. The Today tiles caption
/// themselves with it, because "80.0 kg" means three different things depending on the answer.
public enum WeightDisplayTier: Equatable, Sendable {
    /// The smoothed trend — what the weight goal is judged on. Only when the fold has settled.
    case trend
    /// The newest real measurement, because the trend is still cold-starting.
    case measured
    /// `ProfileStore.weightKg`: self-reported, never measured. The honest bottom tier.
    case profile
}

extension WeightSeries {

    /// The weight a Today tile should show, and what it is.
    ///
    /// The trend wins when it has settled, because that is the number the goal card measures against —
    /// showing the raw scale reading beside a goal judged on the trend put two different weights for
    /// one body on the same screen. But a trend folded from two weigh-ins is not a trend, so an
    /// unsettled one falls back to the last real measurement rather than dressing up a cold start.
    ///
    /// The `> 10 kg` floor is the same guard `Repository.resolveWeightKg` applies: it rejects a stray
    /// 0/garbage sample, not a real reading.
    public static func displayWeight(summary: WeightTrendSummary?,
                              profileWeightKg: Double) -> (kg: Double, tier: WeightDisplayTier) {
        if let s = summary {
            if s.isTrendReliable, s.trendKg > 10 { return (s.trendKg, .trend) }
            if s.latestKg > 10 { return (s.latestKg, .measured) }
        }
        return (profileWeightKg, .profile)
    }

    /// The newest MEASUREMENT, for a surface with no room to say it is showing something else.
    ///
    /// The sibling of `displayWeight`, minus its trend tier — and the difference is the point. The
    /// trend is the right number to judge a goal on and the wrong number for a tile: it lags the
    /// scale by design, so a tile showing it reads as a stale reading, and a tile has no space for
    /// the "TREND" label the detail screen puts beside it. Reported as a dashboard tile disagreeing
    /// with the weight screen when neither was wrong — they were answering different questions.
    ///
    /// Carries WHEN it was taken so a caller can caption an old reading rather than passing it off
    /// as today's, and the same `> 10 kg` floor against a stray 0 sample.
    public static func currentWeight(summary: WeightTrendSummary?,
                              profileWeightKg: Double) -> (kg: Double, at: Date?, tier: WeightDisplayTier) {
        if let s = summary, s.latestKg > 10 { return (s.latestKg, s.latestAt, .measured) }
        return (profileWeightKg, nil, .profile)
    }
}

extension WeightSeries {
    /// The canonical daily weight series of `[from, to]`, oldest first: NOOP weigh-ins unioned over Apple Health.
    public static func series(reader: StoreReader, from: String, to: String) async -> [WeightPoint] {
        async let manual = reader.series(key: WhoopStore.bodyWeightMetricKey, source: WhoopStore.noopWeightSourceId,
                                         from: from, to: to, suppressedSleepWakeDays: [])
        async let apple = reader.series(key: WhoopStore.bodyWeightMetricKey, source: MetricResolver.appleHealthSource,
                                        from: from, to: to, suppressedSleepWakeDays: [])
        return merge(manual: await manual, appleHealth: await apple)
    }
}
