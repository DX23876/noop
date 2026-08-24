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
// a day, never a sum" model `Repository.sourceCandidates` already applies to every other metric.
//
// Why this file exists at all: every weight read in the app used to name `source: "apple-health"`
// literally — goal tracking, the goal-setup tool, both Today screens, the Apple Health screen. A
// weigh-in typed into NOOP would have been invisible to all of them. This is the single canonical
// resolver those call sites now share, in the spirit of CLAUDE.md's rule for
// `DeviceFamily.forRegistryModel`: one resolver, never a scattered string compare.

/// Where a resolved weight value came from. Display-facing: the detail list labels each row with it.
enum WeightSource: String, Equatable, Sendable {
    /// Typed into NOOP (editable here).
    case manual
    /// Imported from Apple Health (read-only here — edit it in Health).
    case appleHealth

    /// The `bodyWeightEntry.source` token this corresponds to, for rows NOOP itself writes.
    var storageToken: String {
        switch self {
        case .manual:      return BodyWeightRow.Source.manual.rawValue
        case .appleHealth: return BodyWeightRow.Source.appleHealth.rawValue
        }
    }
}

/// One resolved day of the weight series.
struct WeightPoint: Equatable, Sendable {
    let day: String        // yyyy-MM-dd
    let value: Double      // kg
    let source: WeightSource
}

/// One row in the weigh-in history list. A `manual` entry carries the id and instant needed to edit
/// or delete it; an Apple-imported day carries neither, because NOOP does not own it.
struct WeightEntry: Equatable, Identifiable, Sendable {
    /// Stable row identity: the entry id for a NOOP weigh-in, the day key for an Apple import.
    let id: String
    let day: String
    let value: Double
    let source: WeightSource
    /// Precise instant, when the source records one. Apple's daily cell does not.
    let takenAt: Date?
    let note: String?

    /// Whether this row can be edited or deleted in NOOP. False for Apple-imported days: the
    /// measurement lives in Health, and pretending to delete it here would delete nothing.
    var isEditable: Bool { source == .manual }
}

/// The pure half — merging, so it can be unit-tested with no store, no HealthKit and no clock.
enum WeightSeries {

    /// A `yyyy-MM-dd` day key as a Date, anchored at NOON so a timezone shift can never move a
    /// weigh-in onto the neighbouring day. Same anchor `GoalTrackingEngine.parseDay` uses, because
    /// the two feed the same trend maths and must place a reading on the same day.
    static func date(forDay day: String) -> Date? {
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
    static func merge(manual: [(day: String, value: Double)],
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
    static func mergeEntries(manual: [BodyWeightRow],
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
enum WeightDisplayTier: Equatable, Sendable {
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
    static func displayWeight(summary: WeightTrendSummary?,
                              profileWeightKg: Double) -> (kg: Double, tier: WeightDisplayTier) {
        if let s = summary {
            if s.isTrendReliable, s.trendKg > 10 { return (s.trendKg, .trend) }
            if s.latestKg > 10 { return (s.latestKg, .measured) }
        }
        return (profileWeightKg, .profile)
    }
}

// MARK: - Repository access

extension Repository {

    /// The canonical daily weight series, oldest first — NOOP weigh-ins unioned over Apple Health.
    /// Every weight reader in the app goes through here.
    func weightSeries(days: Int = 4000) async -> [WeightPoint] {
        async let manual = series(key: WhoopStore.bodyWeightMetricKey,
                                  source: WhoopStore.noopWeightSourceId, days: days)
        async let apple = series(key: WhoopStore.bodyWeightMetricKey,
                                 source: Self.appleHealthSource, days: days)
        return WeightSeries.merge(manual: await manual, appleHealth: await apple)
    }

    /// The same resolution as plain `(day, value)` pairs, for the existing callers that want a series
    /// to feed into `GoalMeasure` / a chart and don't care which source a day came from.
    func weightDailyValues(days: Int = 4000) async -> [(day: String, value: Double)] {
        await weightSeries(days: days).map { ($0.day, $0.value) }
    }

    /// The smoothed weight summary the Today tiles and the Weight screen share. One accessor rather
    /// than each screen folding its own series: two screens smoothing the same weigh-ins with the same
    /// config would still be two places to change, and one of them would eventually be missed.
    func weightTrendSummary(days: Int = 91) async -> WeightTrendSummary? {
        let dated = await weightSeries(days: days).compactMap { point -> (date: Date, value: Double)? in
            WeightSeries.date(forDay: point.day).map { ($0, point.value) }
        }
        return WeightTrendSummary.summarize(dated)
    }

    /// The weigh-in history for the detail list, newest first.
    func weightEntries(days: Int = 4000) async -> [WeightEntry] {
        guard let store = await storeHandle() else { return [] }
        let from = Self.dayString(Date().addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(Date().addingTimeInterval(86_400))
        let manual = (try? await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId, from: from, to: to)) ?? []
        let apple = await series(key: WhoopStore.bodyWeightMetricKey,
                                 source: Self.appleHealthSource, days: days)
        return WeightSeries.mergeEntries(manual: manual, appleHealth: apple)
    }

    /// The most recent measurement from EITHER source, or nil when nothing has ever been recorded.
    /// This is what "current weight" means once a history exists — `ProfileStore.weightKg` remains a
    /// manually-set default for someone who has never weighed in.
    /// The window is `GoalMeasure.weightWindowDays` — the SAME 90 days goal tracking judges a weight
    /// goal over, so "current weight" here and "where am I now" there can never disagree.
    func latestWeightKg() async -> Double? {
        await weightSeries(days: GoalMeasure.weightWindowDays).last?.value
    }

    // MARK: - Writes

    /// Record a weigh-in. `at` is the instant it was taken, which may be in the past — someone
    /// entering yesterday's scale reading is the ordinary case, not an edge case.
    ///
    /// Returns the stored row, and posts `.noopWeightLogged` so the platform layer can mirror the
    /// measurement into Apple Health under ITS OWN day (see `HealthKitBridge.writeWeight(kg:day:)`)
    /// rather than assuming today. Posting rather than calling: this file is shared with macOS, where
    /// there is no HealthKit — and a per-call-site hook is the wiring the next write path forgets.
    @discardableResult
    func logWeight(kg: Double, at: Date = Date(), note: String? = nil,
                   source: WeightSource = .manual) async -> BodyWeightRow? {
        guard kg > 0, let store = await storeHandle() else { return nil }
        let row = BodyWeightRow(id: UUID().uuidString,
                                deviceId: WhoopStore.noopWeightSourceId,
                                day: Self.localDayKey(at),
                                takenAt: Int(at.timeIntervalSince1970),
                                weightKg: kg,
                                source: source.storageToken,
                                note: note?.isEmpty == true ? nil : note)
        guard (try? await store.upsertBodyWeights([row])) != nil else { return nil }
        await refresh()
        WeightLogNotification(kg: kg, day: row.day).post()
        return row
    }

    /// Edit an existing weigh-in in place, keeping its id. A changed instant may move it to another
    /// day, so BOTH the old and the new day are re-projected — otherwise the old day keeps a value
    /// no measurement backs any more.
    @discardableResult
    func updateWeight(id: String, kg: Double, at: Date, note: String?) async -> Bool {
        guard kg > 0, let store = await storeHandle() else { return false }
        let existing = (try? await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId))?
            .first { $0.id == id }
        guard let existing else { return false }
        // Delete-then-insert rather than an UPDATE: the natural key carries `takenAt`, so moving an
        // entry to a new instant is a new key, and the delete re-projects the day being left behind.
        _ = try? await store.deleteBodyWeight(id: id)
        let row = BodyWeightRow(id: id,
                                deviceId: WhoopStore.noopWeightSourceId,
                                day: Self.localDayKey(at),
                                takenAt: Int(at.timeIntervalSince1970),
                                weightKg: kg,
                                source: existing.source,
                                note: note?.isEmpty == true ? nil : note)
        guard (try? await store.upsertBodyWeights([row])) != nil else { return false }
        await refresh()
        WeightLogNotification(kg: kg, day: row.day).post()
        return true
    }

    /// Delete a weigh-in NOOP owns. Apple-imported days are not deletable here — `WeightEntry.isEditable`
    /// is what the UI gates on, and this returns false for an unknown id rather than pretending.
    @discardableResult
    func deleteWeight(id: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        let deleted = (try? await store.deleteBodyWeight(id: id)) ?? false
        if deleted { await refresh() }
        return deleted
    }
}

// MARK: - Cross-layer notification

extension Notification.Name {
    /// A weigh-in was recorded or edited. Carries `WeightLogNotification`'s payload.
    static let noopWeightLogged = Notification.Name("noop.weightLogged")
}

/// The payload of `.noopWeightLogged`, as a value with its own encode/decode rather than raw
/// `userInfo` key strings at both ends — a typo in one of them would fail silently at runtime.
///
/// Exists because the write path is shared and the mirror is not: `Repository` compiles on macOS,
/// `HealthKitBridge` is `#if os(iOS)`. The alternative — a closure hook every call site has to set —
/// is exactly the kind of wiring that gets forgotten when a new write path appears.
struct WeightLogNotification: Equatable {
    let kg: Double
    /// The day the measurement belongs to (yyyy-MM-dd), NOT today: a weigh-in entered for last
    /// Tuesday has to reach Health under last Tuesday.
    let day: String

    private static let kgKey = "kg"
    private static let dayKey = "day"

    init(kg: Double, day: String) {
        self.kg = kg
        self.day = day
    }

    /// Decode from a posted notification; nil when the payload isn't the expected shape.
    init?(_ notification: Notification) {
        guard let kg = notification.userInfo?[Self.kgKey] as? Double,
              let day = notification.userInfo?[Self.dayKey] as? String else { return nil }
        self.kg = kg
        self.day = day
    }

    func post() {
        NotificationCenter.default.post(name: .noopWeightLogged, object: nil,
                                        userInfo: [Self.kgKey: kg, Self.dayKey: day])
    }
}
