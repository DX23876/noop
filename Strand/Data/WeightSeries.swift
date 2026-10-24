import Foundation
import StrandAnalytics
import WhoopStore
import StrandCore

// MARK: - Repository access

extension Repository {

    /// The canonical daily weight series, oldest first — NOOP weigh-ins unioned over Apple Health.
    /// Every weight reader in the app goes through here.
    func weightSeries(days: Int = 4000) async -> [WeightPoint] {
        guard let store = await storeHandle() else { return [] }
        let now = Date()
        return await WeightSeries.series(reader: storeReader(store),
                                         from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
                                         to: Self.dayString(now.addingTimeInterval(86_400)))
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

    /// Pull `ProfileStore.weightKg` onto the newest measurement the app knows about.
    ///
    /// The profile scalar is read by HR zones, the calorie model and the coach, so it has to agree
    /// with the weight screen — and it did not. Two reasons, both fixed by having ONE place do this:
    ///
    ///   • It ran only from `WeightDetailView`, so the profile caught up only when that screen was
    ///     opened. Reported as "Apple Health's new weight shows in the detail view, the profile keeps
    ///     the old one".
    ///   • The iOS sync path fed the profile from `latestImportedWeightKg`, the newest reading INSIDE
    ///     the window just synced. A weigh-in older than that window is nil there, so a fortnight-old
    ///     reading never reached the profile at all. This asks the canonical series instead, which has
    ///     no window.
    ///
    /// Safe in both directions: the value always came either from Health (suppressed by the
    /// `lastImported` echo arm) or from a NOOP weigh-in that already wrote itself to Health under its
    /// own day (suppressed by `lastSelfWritten`) — see `HealthKitBridge.shouldWriteProfileWeight`.
    /// Assigns only on a real difference so the publisher does not fire for a no-op.
    ///
    /// - Returns: true when the profile was actually moved.
    @discardableResult
    func reconcileProfileWeight(_ profile: ProfileStore) async -> Bool {
        guard let latest = await latestWeightKg(), latest > 10 else { return false }
        guard abs(profile.weightKg - latest) > 0.005 else { return false }
        profile.weightKg = latest
        return true
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
        // The energy model resolves body mass per day from this series, so the stored days from this
        // weigh-in on were priced with the previous weight.
        scheduleEnergyRefresh(coveringStart: row.takenAt)
        WeightLogNotification(kg: kg, day: row.day).post()
        return row
    }

    /// Set TODAY's weight from a place that edits ONE value rather than logging an event — the
    /// profile field in Settings, and the onboarding wizard.
    ///
    /// Replaces today's own NOOP entry instead of appending, which is the difference that makes the
    /// profile field usable at all: it is a stepper, so "209 → 212" is six taps, and `logWeight`
    /// would bank six weigh-ins and six Health writes for one correction.
    ///
    /// No-ops when the stored value already agrees. That is what keeps the loop shut: the reconciler
    /// sets the profile scalar FROM this series, which fires the same observer that calls this, and
    /// without the guard the two would write to each other forever.
    ///
    /// - Returns: true when something was actually written.
    @discardableResult
    func setTodayWeight(kg: Double, source: WeightSource = .manual) async -> Bool {
        guard kg > 10, let store = await storeHandle() else { return false }
        let today = Self.localDayKey(Date())
        let mine = (try? await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId,
                                                 from: today, to: today)) ?? []
        if let existing = mine.max(by: { $0.takenAt < $1.takenAt }),
           abs(existing.weightKg - kg) <= 0.005 {
            return false
        }
        for row in mine { _ = try? await store.deleteBodyWeight(id: row.id) }
        return await logWeight(kg: kg, source: source) != nil
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
        scheduleEnergyRefresh(coveringStart: min(existing.takenAt, row.takenAt))
        WeightLogNotification(kg: kg, day: row.day).post()
        return true
    }

    /// Delete a weigh-in NOOP owns. Apple-imported days are not deletable here — `WeightEntry.isEditable`
    /// is what the UI gates on, and this returns false for an unknown id rather than pretending.
    @discardableResult
    func deleteWeight(id: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        let takenAt = (try? await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId))?
            .first { $0.id == id }?.takenAt
        let deleted = (try? await store.deleteBodyWeight(id: id)) ?? false
        if deleted {
            await refresh()
            scheduleEnergyRefresh(coveringStart: takenAt ?? 0)
        }
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
