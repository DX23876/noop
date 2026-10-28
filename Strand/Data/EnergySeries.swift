import Foundation
import StrandAnalytics
import WhoopProtocol   // StepSample — the @57 counter + @63 activity class behind bucket movement
import WhoopStore
import StrandCore

/// One five-minute bucket's step movement, as `Repository.bucketStepMovement` derives it.

struct EnergyTimelinePoint: Identifiable, Equatable, Sendable {
    let timestamp: Date
    let basalKcal: Double
    let activeKcal: Double
    var totalKcal: Double { basalKcal + activeKcal }
    var id: Date { timestamp }
}

/// One logged session, clipped to the day it is drawn on, as the burn-rate chart shades it.
struct EnergyTrainingBand: Identifiable, Hashable, Sendable {
    let startTs: Int
    let endTs: Int
    let sport: String

    var id: Int { startTs }
    var start: Date { Date(timeIntervalSince1970: TimeInterval(startTs)) }
    var end: Date { Date(timeIntervalSince1970: TimeInterval(endTs)) }
}

/// A day's burn rate, the sessions inside it, and the split of its active energy between the two.
///
/// One value rather than three, because the three are one answer: `trainingKcal` is the energy
/// under `bands`, and `movementKcal` is what is left of active energy once they are accounted for.
struct EnergyDayRate: Equatable, Sendable {
    let day: String
    let points: [EnergyBurnRate.Point]
    let bands: [EnergyTrainingBand]
    /// The share of the day's active energy that happened inside a session — a FRACTION, not a kcal
    /// figure, and that is the whole point.
    ///
    /// The buckets know the SHAPE of the split; they do not own the day's magnitude. `EnergyEngine`
    /// does, and it arrives at active energy by subtracting a profile basal rate from the day's
    /// total, which is not the same arithmetic the bucket model used. Reporting the bucket sums
    /// directly put "Daily movement 148 + Training 444" on a card whose "Active" said 463 — two
    /// figures that must add up, visibly not adding up. Applying the fraction to the summary's own
    /// active energy makes them add up by construction, whatever either model does later.
    let trainingFraction: Double?

    /// True when the day has a rate curve at all. False for an Apple-only, steps-only or
    /// profile-only day: those have a total but no five-minute grid under it, and the card says so
    /// rather than drawing an empty chart that reads as a day of no activity.
    var hasBuckets: Bool { !points.isEmpty }

    static func empty(day: String) -> EnergyDayRate {
        .init(day: day, points: [], bands: [], trainingFraction: nil)
    }
}

struct EnergyCalibrationViewState: Equatable {
    let status: EnergyCalibrationStatus
    let factor: Double?
    let sampleDays: Int
    let sampleBuckets: Int
    let referenceDeviceId: String?

    static let off = EnergyCalibrationViewState(
        status: .off, factor: nil, sampleDays: 0, sampleBuckets: 0, referenceDeviceId: nil)
}

enum EnergyCalibrationPreferences {
    static let enabledKey = "energy.watchCalibration.enabled"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

// EnergySeries.swift — the single place the app asks "how much did I burn?".
//
// The same shape as `WeightSeries.swift`, for the same reason: energy arrives from several stores
// that disagree about what they measure, and every screen reading them directly would eventually
// read them differently. `EnergyEngine` (StrandAnalytics, pure) owns the arithmetic; this file only
// gathers the inputs it needs out of the repository and hands back the summaries.
//
// What is gathered, and from where:
//   • `AppleDaily.activeKcal` / `.basalKcal` — Apple's split, per day (`repo.appleDailyRows()`).
//   • `DailyMetric.activeKcalEst` — the strap's whole-day HR estimate, already on `repo.days`. A
//     TOTAL for worn time, NOT an "active" figure; `EnergyEngine`'s header explains the trap.
//   • `appleStepHour` (v42's neighbour, migration v41) — hours of the day that carry any steps, the
//     movement-coverage signal. Read once for the whole window rather than per day.
//
// The existing daily-metric row also persists the number of HR seconds behind the strap estimate;
// this lets the engine top up only the unobserved basal portion without double-counting worn time.

extension Repository {

    /// A retrospective energy-balance comparison from imported food logs and the canonical weight
    /// trend. It is deliberately separate from `energySummaries`: this estimate never calibrates or
    /// replaces WHOOP, and an incomplete current day is always excluded.
    func adaptiveExpenditureEstimate(asOf: Date = Date()) async -> AdaptiveExpenditureEstimate? {
        guard let store = await storeHandle() else { return nil }
        // Both intake sources, manual winning a day it shares with an import, priced in `NutritionReads`.
        return await NutritionReads.adaptiveEstimate(reader: storeReader(store), asOf: asOf,
                                                     healthSourceNames: NutritionSourcePreferences.healthSourceByDay)
    }

    /// Energy summaries for the trailing `days`, oldest first. One entry per day that has ANY input;
    /// a day nobody measured is simply absent rather than present with zeroes.
    ///
    /// `profile` is passed in rather than read here because `ProfileStore` is a `@MainActor`
    /// observable the caller already holds, and the BMR must come from the same profile the rest of
    /// the screen is showing.
    func energySummaries(days: Int = 30, profile: UserProfile) async -> [DailyEnergySummary] {
        energyProfile = profile
        let todayKey = Self.localDayKey(Date())
        let now = Date()

        let appleRows = await appleDailyRows(days: days)
        let appleByDay = Dictionary(appleRows.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        let stepHoursByDay = await hoursWithStepsByDay(days: days)
        // Sessions the wearer logged, for the days no device measured the energy of. `reconcileHrCap: 0`
        // is deliberate: the reconcile exists to fill Avg HR for a LIST, costs one indexed window read
        // per row, and this path runs behind Today, Trends, Overview, the Energy screens and the coach.
        // Whatever is already stored on the row is what prices it here; a row with no stored average
        // falls to the MET table, which is the precedence this path is supposed to have anyway.
        let sessionsByDay = await loggedSessionsByDay(days: days)
        // Resolve body mass separately for every day. Using today's profile weight for history leaks
        // future information backwards and can rewrite old calorie totals after a new weigh-in.
        let weightObservations = await weightSeries(days: max(days + 100, 100)).compactMap { point in
            WeightSeries.date(forDay: point.day).map {
                CausalWeightObservation(
                    timestamp: Int($0.timeIntervalSince1970), weightKg: point.value,
                    source: point.source == .manual ? .manual : .health)
            }
        }

        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        let cutoff = Self.dayString(cutoffDate)
        let strapDays = self.days.filter { $0.day >= cutoff }
        let strapByDay = Dictionary(strapDays.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        let store = await storeHandle()
        // Only rows from the CURRENT model generation. Without this the version stamp is decorative:
        // a 30-day chart would mix v1 kcal (heart-rate only, blind to walking) with v2 kcal in one
        // trend line, and the step the user would read as a behaviour change is a model change.
        // A superseded row falls back to the legacy whole-day estimate until the next refresh
        // overwrites it, which `EnergyDetailView.loadIfNeeded` triggers before it reads summaries.
        func derivedRows() async -> [String: WhoopDailyEnergyRow] {
            let rows = ((try? await store?.whoopDailyEnergy(
                deviceId: deviceId, from: cutoff, to: todayKey)) ?? [])
                .filter { $0.modelVersion == WhoopDailyEnergyEstimate.modelVersion }
            return Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        }
        var derivedByDay = await derivedRows()
        // Today's row is the only thing standing between a worn strap and the steps fallback, and it
        // exists only once this generation's model has run over today's buckets. Until then the card
        // reports a strap day as "no device recorded energy today" — which is what a user on a strap
        // was seeing. The Energy detail screen has always repaired this on open; doing it here means
        // Today, Trends, the widget and the coach get the same repair instead of each waiting for
        // somebody to visit that screen.
        //
        // Once per day per session, and cheap when there is nothing to do: the refresh reads today's
        // heart-rate buckets and returns immediately when the strap has not offloaded any.
        if derivedByDay[todayKey] == nil, repairedTodayEnergyOn != todayKey {
            repairedTodayEnergyOn = todayKey
            await refreshWhoopEnergyModel(days: 1, profile: profile)
            derivedByDay = await derivedRows()
        }
        // Older days follow in the background, once per model generation; their readers are keyed on
        // `energyPresentationRevision`, which the refresh bumps when it writes.
        if UserDefaults.standard.string(forKey: Self.energyHistoryModelKey)
            != WhoopDailyEnergyEstimate.modelVersion, !energyHistoryRefreshRunning {
            Task { @MainActor [weak self] in await self?.ensureEnergyHistoryCurrent(profile: profile) }
        }
        let calibration = await energyCalibrationState(store: store)
        let calibrationFactor = calibration.status == .active ? calibration.factor : nil
        // Katch–McArdle reads the body fat in force on each day; every other formula skips the read.
        let bodyFatOn = await bodyFatResolver(for: profile.basalFormula)
        // The model's own active energy per day, summed from the hourly rows it stored beside the
        // buckets. Handed to the engine so a day's active energy is what the buckets priced, not
        // "total minus a basal rate" — which drifts the moment the basal formula differs from the one
        // the buckets were priced with, as it does after a formula change on days past the recompute.
        var strapActiveByDay: [String: Double] = [:]
        for row in (try? await store?.whoopEnergyHours(deviceId: deviceId, from: cutoff, to: todayKey)) ?? [] {
            strapActiveByDay[row.day, default: 0] += row.activeKcal
        }
        // Both shape the FORECAST only, never what was actually burned. Resolved once for the whole
        // window rather than per day: they describe the person, not the day.
        let shape = await activityShape()
        let adaptivePrior = await adaptiveExpenditureEstimate()?.estimatedDailyKcal
        let appleReference = await appleEnergyReference(days: days)
        let appleCoverageByDay = appleReference.coverage

        return EnergySummaryPreparation.summaries(.init(
            appleByDay: appleByDay, strapByDay: strapByDay, derivedByDay: derivedByDay,
            strapActiveByDay: strapActiveByDay, stepHoursByDay: stepHoursByDay,
            sessionsByDay: sessionsByDay, weightObservations: weightObservations,
            calibrationStatus: calibration.status, calibrationFactor: calibrationFactor,
            shape: shape, adaptivePrior: adaptivePrior, appleCoverageByDay: appleCoverageByDay,
            stride: appleReference.stride), profile: profile, hrMax: strainProfile?.hrMax,
            now: now, calendar: calendar, bodyFatOn: bodyFatOn)
    }

    /// Today's summary, or nil when the day has produced nothing at all yet.
    func todayEnergy(profile: UserProfile) async -> DailyEnergySummary? {
        let todayKey = Self.localDayKey(Date())
        return await energySummaries(days: 2, profile: profile).last { $0.day == todayKey }
    }

    /// Cumulative v5 output for the current day. Basal accrues continuously from midnight while
    /// active energy comes only from the persisted, context-qualified five-minute buckets.
    func todayEnergyTimeline(profile: UserProfile, now: Date = Date()) async
        -> [EnergyTimelinePoint] {
        var profile = profile
        profile.bodyFatPercent = await bodyFatResolver(for: profile.basalFormula)(Self.localDayKey(now))
        guard let store = await storeHandle(),
              let bmr = Calories.bmrKcalPerDay(profile: profile) else { return [] }
        let calendar = Calendar.current
        let day = Self.localDayKey(now)
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let duration = end.timeIntervalSince(start)
        let rows = (try? await store.whoopEnergyBuckets(deviceId: deviceId, day: day)) ?? []
        guard !rows.isEmpty else { return [] }
        let calibration = await energyCalibrationState(store: store)
        let activeFactor = calibration.status == .active ? (calibration.factor ?? 1) : 1
        var active = 0.0
        var points = [EnergyTimelinePoint(timestamp: start, basalKcal: 0, activeKcal: 0)]
        for row in rows where row.bucketStart < Int(now.timeIntervalSince1970) {
            active += row.activeKcal * activeFactor
            let bucketEnd = min(now, Date(timeIntervalSince1970:
                TimeInterval(row.bucketStart + row.durationSeconds)))
            let elapsed = min(duration, max(0, bucketEnd.timeIntervalSince(start)))
            points.append(.init(timestamp: bucketEnd, basalKcal: bmr * elapsed / duration,
                                activeKcal: active))
        }
        let elapsed = min(duration, max(0, now.timeIntervalSince(start)))
        if points.last?.timestamp != now {
            points.append(.init(timestamp: now, basalKcal: bmr * elapsed / duration,
                                activeKcal: active))
        }
        return points
    }

    // MARK: - Burn rate

    /// Everything the burn-rate card needs for ONE day, read in one pass.
    ///
    /// Gathered together rather than offered as four calls because the four answers come from the
    /// same two reads, and because they have to agree: the training figure is the energy under the
    /// bands, so a view that fetched them separately could paint a total the bands do not account
    /// for (see `EnergyBurnRate.activeSplit`).
    func energyDayRate(day: String, profile: UserProfile) async -> EnergyDayRate {
        if let cached = energyDayRateCache[day] { return cached }
        guard let store = await storeHandle(),
              let noon = WeightSeries.date(forDay: day) else { return .empty(day: day) }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: noon)
        let startTs = Int(start.timeIntervalSince1970)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let endTs = Int(end.timeIntervalSince1970)

        let rows = (try? await store.whoopEnergyBuckets(deviceId: deviceId, day: day)) ?? []
        // The Watch reference multiplier scales ACTIVE energy only, exactly as the cumulative
        // timeline and the daily total apply it. A rate curve drawn from unscaled buckets under a
        // headline that was scaled would disagree with itself by the calibration factor.
        let calibration = await energyCalibrationState(store: store)
        let activeFactor = calibration.status == .active ? (calibration.factor ?? 1) : 1
        let slices = rows.map {
            EnergyBurnRate.Slice(startSeconds: Double($0.bucketStart - startTs),
                                 durationSeconds: Double($0.durationSeconds),
                                 basalKcal: $0.basalKcal,
                                 activeKcal: $0.activeKcal * activeFactor)
        }

        // Same window, same dedup rule as the Workouts screen (#687): a strap session and its
        // imported Health twin are one session, and counting both would draw two bands over one
        // workout and charge its energy twice.
        // Two days of lead-in, not one: the window has to start before any session that REACHES this
        // day, and a 24 h lead-in silently drops a session longer than a day — an ultra, a hike, or
        // a mis-entered end time. `rawWorkoutRows` is an indexed range read, so the extra day costs
        // nothing and the alternative is a band that is missing exactly when the day is unusual.
        let sessions = WorkoutSource.dedupCrossSource(
            await rawWorkoutRows(from: startTs - 2 * 86_400, to: endTs))
            .filter { $0.endTs > startTs && $0.startTs < endTs }
            .sorted { $0.startTs < $1.startTs }
        let bands = sessions.map { row in
            EnergyTrainingBand(startTs: max(row.startTs, startTs), endTs: min(row.endTs, endTs),
                               sport: row.sport)
        }
        let split = EnergyBurnRate.activeSplit(
            slices: slices,
            training: bands.map { .init(startSeconds: Double($0.startTs - startTs),
                                        endSeconds: Double($0.endTs - startTs)) })
        let splitTotal = split.training + split.movement
        let fraction = splitTotal > 0 ? split.training / splitTotal : nil

        let result = EnergyDayRate(day: day, points: EnergyBurnRate.measured(slices: slices),
                                   bands: bands, trainingFraction: fraction)
        // Only a finished day is memoized. Today is still accruing, and a cached morning would keep
        // being handed back all afternoon.
        if day != Self.localDayKey(Date()) { energyDayRateCache[day] = result }
        return result
    }

    /// What the strap energy model charged for each session that recorded no energy of its own,
    /// keyed by `WorkoutEnergyDisplay.key(_:)`. Sessions it cannot answer for are absent; the tile then
    /// falls back to the heart-rate and activity-table estimates as before.
    ///
    /// Only days whose stored model row is the CURRENT generation are read: a superseded day still
    /// holds buckets priced under the previous inclusion rules, which is the exact disagreement this
    /// exists to remove. `maxDays` bounds the bucket reads for a long list — rows arrive newest first,
    /// so it is the oldest sessions that keep their fallback.
    /// Records where a saved manual row's energy came from (`workoutEnergySource`).
    ///
    /// A figure the save left unchanged keeps the source it had, so editing a computed walk's notes does
    /// not turn its energy into a typed one; an unknown source stays unknown. A new or changed figure was
    /// typed. No figure, no entry. A re-keyed row moves its entry to the new key.
    func recordManualEnergySource(for row: WorkoutRow, replacing old: WorkoutRow?,
                                  store: WhoopStore) async {
        let key = WorkoutKey(deviceId: deviceId, startTs: row.startTs, sport: row.sport)
        let oldKey = old.map { WorkoutKey(deviceId: deviceId, startTs: $0.startTs, sport: $0.sport) }
        var carried: WorkoutEnergySource?
        if let old, let oldKey, old.energyKcal == row.energyKcal {
            carried = ((try? await store.workoutEnergySources(
                deviceId: deviceId, from: old.startTs, to: old.startTs)) ?? [:])[oldKey]
        }
        if let oldKey, oldKey != key { try? await store.clearWorkoutEnergySource(for: oldKey) }
        guard let kcal = row.energyKcal, kcal > 0 else {
            try? await store.clearWorkoutEnergySource(for: key)
            return
        }
        if old != nil, old?.energyKcal == row.energyKcal {
            if let carried { try? await store.setWorkoutEnergySource(carried, for: key) }
            return
        }
        try? await store.setWorkoutEnergySource(.entered, for: key)
    }

    /// The versioned correction of stored session figures NOOP computed with Keytel (AI-13 to AI-15).
    ///
    /// Every manual row with energy and no recorded source is re-priced when its figure reproduces an
    /// old formula on the strap's heart rate for its window (`LegacyWorkoutEnergy.looksComputed`), using
    /// that day's weight and resting rate. A reproduced figure is replaced by the model-v8 session price
    /// and recorded as computed. A row already recorded as computed is priced again as it stands (AI-15:
    /// AI-13 and AI-14 read the resting rate from imported rows only, so every day after the last WHOOP
    /// export was priced and recognised without one). Rows with known entered provenance or without
    /// enough strap heart rate stay unchanged. Each committed correction queues its Health rewrite and
    /// energy refresh immediately, so a later read failure does not strand an already-corrected row.
    /// Returns the earliest correction.
    func correctLegacyWorkoutEnergy(profile base: UserProfile) async throws -> Int? {
        guard let store = await storeHandle() else { return nil }
        // The correction itself is shared with Android (`EnergyCorrections`); the follow-ups stay here.
        return try await EnergyCorrections.correctLegacyWorkoutEnergy(reader: storeReader(store), profile: base) { earliest in
            HealthWorkoutRewrite.request(from: earliest)
            scheduleEnergyRefresh(coveringStart: earliest)
        }
    }

    /// Active energy per local day, from the energy model: the strap first, Apple only on a day the strap
    /// did not cover (`EnergyEngine`). What every surface that says "active energy" or shows a bare
    /// calorie figure reads, so none of them can disagree with the Energy screen or quote the retired
    /// whole-day estimate (`DailyMetric.activeKcalEst`, a Harris-Benedict plus Keytel TOTAL despite its
    /// name). A day nobody measured is absent, never zero.
    func activeEnergyByDay(days: Int) async -> [String: Double] {
        let profile = energyProfile ?? ProfileStore.persistedAnalyticsProfile
        return EnergySummaryPreparation.activeValues(await energySummaries(days: days, profile: profile))
    }

    /// The day's stored model row of this generation, or nil when none has been computed.
    /// The newest energy row of this model generation within the last `days` days, for surfaces that
    /// describe "the current" ceiling (the Profile's VO₂max hint) rather than one chosen day.
    func latestWhoopEnergyRow(days: Int = 7) async -> WhoopDailyEnergyRow? {
        guard let store = await storeHandle() else { return nil }
        let today = Self.localDayKey(Date())
        return ((try? await store.whoopDailyEnergy(
            deviceId: deviceId, from: WeeklyDigestEngine.addDays(today, -days), to: today)) ?? [])
            .filter { $0.modelVersion == WhoopDailyEnergyEstimate.modelVersion }
            .max { $0.day < $1.day }
    }

    func whoopEnergyRow(day: String) async -> WhoopDailyEnergyRow? {
        guard let store = await storeHandle() else { return nil }
        return ((try? await store.whoopDailyEnergy(deviceId: deviceId, from: day, to: day)) ?? [])
            .first { $0.modelVersion == WhoopDailyEnergyEstimate.modelVersion }
    }

    /// The aerobic ceiling (METs) each day's energy model used, for this model generation, keyed by
    /// local day. A session priced outside the bucket model (its tile without strap coverage, a
    /// rescore, a live save) reads it through `WorkoutEnergyDisplay.peakMET(on:in:)`, so it lands on the
    /// same scale as the day it belongs to.
    func energyPeakMETByDay(fromDay: String, toDay: String) async -> [String: Double] {
        guard let store = await storeHandle() else { return [:] }
        return await EnergyCorrections.peakMETByDay(store: store, deviceId: deviceId, fromDay: fromDay, toDay: toDay)
    }

    func strapSessionEnergy(for rows: [WorkoutRow], maxDays: Int = 120) async -> [String: Double] {
        let candidates = rows.filter { row in
            row.endTs > row.startTs && !(row.energyKcal.map { $0.isFinite && $0 > 0 } ?? false)
        }
        guard !candidates.isEmpty, let store = await storeHandle(),
              let earliest = candidates.map(\.startTs).min(),
              let latest = candidates.map({ $0.endTs - 1 }).max() else { return [:] }
        func dayKey(_ ts: Int) -> String { Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts))) }
        let current = Set(((try? await store.whoopDailyEnergy(
            deviceId: deviceId, from: dayKey(earliest), to: dayKey(latest))) ?? [])
            .filter { $0.modelVersion == WhoopDailyEnergyEstimate.modelVersion }
            .map(\.day))
        guard !current.isEmpty else { return [:] }
        let calibration = await energyCalibrationState(store: store)
        let activeFactor = calibration.status == .active ? (calibration.factor ?? 1) : 1

        var bucketsByDay: [String: [WorkoutEnergyEstimate.StrapBucket]] = [:]
        var result: [String: Double] = [:]
        for row in candidates {
            let days = Array(Set([dayKey(row.startTs), dayKey(row.endTs - 1)])).sorted()
            guard days.allSatisfy(current.contains) else { continue }
            var buckets: [WorkoutEnergyEstimate.StrapBucket] = []
            for day in days {
                if bucketsByDay[day] == nil {
                    guard bucketsByDay.count < maxDays else { break }
                    let stored = (try? await store.whoopEnergyBuckets(deviceId: deviceId, day: day)) ?? []
                    bucketsByDay[day] = stored.map {
                        WorkoutEnergyEstimate.StrapBucket(
                            start: $0.bucketStart, durationSeconds: $0.durationSeconds,
                            basalKcal: $0.basalKcal, activeKcal: $0.activeKcal,
                            context: EnergyContext(rawValue: $0.context))
                    }
                }
                buckets += bucketsByDay[day] ?? []
            }
            if let kcal = WorkoutEnergyEstimate.strapWindowKcal(
                buckets: buckets, startTs: row.startTs, endTs: row.endTs, activeFactor: activeFactor) {
                result[WorkoutEnergyDisplay.key(row)] = kcal
            }
        }
        return result
    }

    /// The median rate curve over the `windowDays` days BEFORE `day`, or nil when too few of them
    /// qualify.
    ///
    /// The window ends at the day before the selected one, never at today: a "30-day average" shown
    /// against a day in August must not contain the days that came after it.
    func energyReferenceRate(before day: String, windowDays: Int,
                             profile: UserProfile) async -> EnergyBurnRate.Reference? {
        guard let store = await storeHandle(), let noon = WeightSeries.date(forDay: day) else { return nil }
        let calendar = Calendar.current
        guard let previous = calendar.date(byAdding: .day, value: -1, to: noon),
              let first = calendar.date(byAdding: .day, value: -windowDays, to: noon) else { return nil }
        let from = Self.localDayKey(first), to = Self.localDayKey(previous)
        let bodyFatOn = await bodyFatResolver(for: profile.basalFormula)
        let hours = (try? await store.whoopEnergyHours(deviceId: deviceId, from: from, to: to)) ?? []
        let daily = (try? await store.whoopDailyEnergy(deviceId: deviceId, from: from, to: to)) ?? []
        let eligible = Set(daily.filter {
            EnergyBurnRate.dayQualifies(modelVersion: $0.modelVersion,
                                        representedSeconds: $0.representedSeconds)
        }.map(\.day))
        guard !eligible.isEmpty else { return nil }
        var byDay: [String: [Double]] = [:]
        for row in hours where eligible.contains(row.day) && (0...23).contains(row.hour) {
            byDay[row.day, default: [Double](repeating: 0, count: 24)][row.hour] += row.activeKcal
        }
        return EnergyBurnRate.reference(
            days: byDay.sorted { $0.key < $1.key }.map { .init(day: $0.key, activeKcalByHour: $0.value) },
            windowDays: windowDays,
            basalKcalPerDay: Calories.bmrKcalPerDay(profile: {
                var dayProfile = profile
                dayProfile.bodyFatPercent = bodyFatOn(day)
                return dayProfile
            }()))
    }

    func energyCalibrationState() async -> EnergyCalibrationViewState {
        await energyCalibrationState(store: await storeHandle())
    }

    private func energyCalibrationState(store: WhoopStore?) async -> EnergyCalibrationViewState {
        guard let store,
              let row = try? await store.energyCalibrationModel(deviceId: deviceId) else {
            return EnergyCalibrationPreferences.enabled
                ? .init(status: .learning, factor: nil, sampleDays: 0, sampleBuckets: 0,
                        referenceDeviceId: nil)
                : .off
        }
        let optedIn = EnergyCalibrationPreferences.enabled
        let active = optedIn && row.enabled && row.modelVersion == EnergyCalibrationFit.modelVersion
        return .init(status: active ? .active : (optedIn ? .learning : .paused),
                     factor: active ? row.factor : nil, sampleDays: row.sampleDays,
                     sampleBuckets: row.sampleBuckets, referenceDeviceId: row.referenceDeviceId)
    }

    @discardableResult
    func setEnergyCalibrationEnabled(_ enabled: Bool, profile: UserProfile) async
        -> EnergyCalibrationViewState {
        EnergyCalibrationPreferences.enabled = enabled
        if let store = await storeHandle() {
            _ = try? await store.setEnergyCalibrationEnabled(deviceId: deviceId, enabled: enabled)
        }
        if enabled { await refreshWhoopEnergyModel(days: 120, profile: profile) }
        return await energyCalibrationState()
    }

    @discardableResult
    func resetEnergyCalibration() async -> EnergyCalibrationViewState {
        EnergyCalibrationPreferences.enabled = false
        if let store = await storeHandle() {
            _ = try? await store.resetEnergyCalibration(deviceId: deviceId)
        }
        return .off
    }

    /// `cursors` row holding the `sensorWriteSeq` value the last post-offload energy refresh read up to.
    /// In the store rather than UserDefaults so it always describes the database it sits in: a restored
    /// backup or a copied store brings the cursor its own energy rows were priced under.
    static let energyInputCursorName = "energy:postOffloadInputSeq"
    /// `cursors` row holding the earliest day start a re-score re-derived since the last post-offload refresh.
    static let energyRederivedFromName = EnergyCorrections.rederivedFromCursor

    /// Record that a re-score re-derived the days from `dayStartTs` on. Its sleep sessions and workouts are
    /// energy inputs the write sequence does not see (computed-namespace writes are not stamped), so the
    /// next post-offload refresh covers them too, from the day before: a night re-derived for one day
    /// starts the evening before it. Persisted, so a process ended between the two keeps the debt.
    func noteEnergyInputsRederived(dayStartTs: Int) async {
        guard let store = await storeHandle() else { return }
        await EnergyCorrections.noteInputsRederived(store: store, dayStartTs: dayStartTs)
    }

    /// The energy refresh after a completed strap offload: re-prices from the first day whose scoring
    /// inputs changed since the previous one, instead of a fixed `energyRefreshMaxDays` window.
    ///
    /// Every offload used to re-price 120 days, although an offload almost always adds samples to
    /// today alone; measured on a real 3.6 GB store that was 24 to 34 s per offload against about 5 s for
    /// the whole re-score, on the main actor. A short window prices like the full one: days before it
    /// keep their stored rows, and the activity evidence a day needs from the weeks before is read from
    /// those stored rows (see `refreshWhoopEnergyModel`). The re-score's own sleep sessions and workouts are
    /// not stamped in the write sequence; it reports the days it re-derived through
    /// `noteEnergyInputsRederived`, and they join the window here. Apple Health inputs are not stamped
    /// either; a Health sync the hourly limit skipped is settled here (`refreshPendingHealthEnergy`). Other
    /// inputs the sequence does not cover (weight, saved workouts, profile) schedule their own refresh
    /// through `scheduleEnergyRefresh`.
    ///
    /// Without a usable cursor (first run, a device-wide invalidation, an unreadable store row) the full
    /// window runs as before. The cursor is the sequence read BEFORE the refresh and is stored only after
    /// it succeeds, so a write that lands meanwhile is picked up by the next one.
    func refreshWhoopEnergyModelAfterOffload(profile: UserProfile) async {
        await refreshEnergyForChangedInputs(profile: profile)
        await refreshPendingHealthEnergy(profile: profile)
    }

    private func refreshEnergyForChangedInputs(profile: UserProfile) async {
        guard let store = await storeHandle(),
              let sequence = try? await store.sensorWriteSeq() else { return }
        let recorded = try? await store.cursor(Self.energyInputCursorName)
        let rederivedFrom = try? await store.cursor(Self.energyRederivedFromName)
        // nil: the full window.
        var coveringStart: Int?
        if let recorded, recorded <= sequence,
           let change = try? await store.analysisInputChange(after: recorded) {
            switch change {
            case .none:
                guard let rederivedFrom else { return }
                coveringStart = rederivedFrom
            case .since(let utcDayStart):
                coveringStart = min(utcDayStart, rederivedFrom ?? utcDayStart)
            case .everything:
                coveringStart = nil
            }
        }
        let refreshed = if let coveringStart {
            await refreshWhoopEnergyModel(coveringStart: coveringStart, profile: profile)
        } else {
            await refreshWhoopEnergyModel(days: Self.energyRefreshMaxDays, profile: profile)
        }
        guard refreshed else { return }
        try? await store.setCursor(Self.energyInputCursorName, sequence)
        // Cleared only if no re-score moved it while this refresh ran.
        if let rederivedFrom {
            try? await store.removeCursor(Self.energyRederivedFromName, ifEqualTo: rederivedFrom)
        }
    }

    /// UserDefaults key for when the last Health-sync-driven energy refresh succeeded.
    static let energyHealthRefreshKey = "energy.lastHealthSyncRefresh.v1"
    /// UserDefaults key set when a Health sync's refresh was skipped (hourly limit, or one already running)
    /// and is still owed.
    static let energyHealthRefreshPendingKey = "energy.healthRefreshPending.v1"
    /// At most one Health-sync-driven refresh per hour.
    static let energyHealthRefreshInterval: TimeInterval = 3_600

    /// The 30-day refresh a completed Apple Health sync asks for, at most once an hour.
    ///
    /// It ran after every Health sync, and a history repair alone runs one sync per 31-day chunk: 110 of
    /// them in a morning on a field phone, each re-pricing 30 days on the main actor. What a Health sync
    /// feeds the model (step length, the Watch reference for the opt-in calibration) moves slowly, so an
    /// hour's delay changes nothing a reader can see; the window and the calibration rule are unchanged.
    /// A skipped sync is not dropped: it leaves `energyHealthRefreshPendingKey`, which the next post-offload
    /// refresh settles once the hour is up, so the last sync of a day is priced even if no other follows.
    func refreshWhoopEnergyModelAfterHealthSync(profile: UserProfile, now: Date = Date()) async {
        let defaults = UserDefaults.standard
        if energyHealthRefreshRunning
            || Self.energyHealthRefreshIsRecent(last: defaults.object(forKey: Self.energyHealthRefreshKey) as? Double,
                                                now: now.timeIntervalSince1970) {
            defaults.set(true, forKey: Self.energyHealthRefreshPendingKey)
            return
        }
        energyHealthRefreshRunning = true
        defer { energyHealthRefreshRunning = false }
        // Cleared before the refresh reads, so a sync landing while it runs owes a pass of its own.
        defaults.removeObject(forKey: Self.energyHealthRefreshPendingKey)
        if await refreshWhoopEnergyModel(days: 30, profile: profile) {
            defaults.set(now.timeIntervalSince1970, forKey: Self.energyHealthRefreshKey)
        } else {
            defaults.set(true, forKey: Self.energyHealthRefreshPendingKey)
        }
    }

    /// Settle a Health-sync refresh the hourly limit skipped, once the hour is up.
    func refreshPendingHealthEnergy(profile: UserProfile) async {
        guard UserDefaults.standard.bool(forKey: Self.energyHealthRefreshPendingKey) else { return }
        await refreshWhoopEnergyModelAfterHealthSync(profile: profile)
    }

    /// The shortest refresh window the opt-in Watch calibration refits from: the Health-sync window.
    static let energyCalibrationFitMinimumDays = EnergyModelRefresh.calibrationFitMinimumDays

    /// Whether a Health-sync refresh already ran within the interval. A clock moved backwards does not
    /// count as recent, so a wrong wall clock can never stop the refresh for good.
    nonisolated static func energyHealthRefreshIsRecent(last: Double?, now: Double) -> Bool {
        guard let last else { return false }
        let age = now - last
        return age >= 0 && age < energyHealthRefreshInterval
    }

    /// Whole local days from the one holding `startTs` through today, bounded to `energyRefreshMaxDays`.
    /// The day holding the instant starts at or before it, so every changed sample is inside the window.
    nonisolated static func energyRefreshDays(coveringStart startTs: Int, now: Date, calendar: Calendar) -> Int {
        let first = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(max(0, startTs))))
        let spanned = (calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day ?? 0) + 1
        return min(energyRefreshMaxDays, max(1, spanned))
    }

    /// Rebuilds the auditable WHOOP bucket output and, only after explicit opt-in, learns a bounded
    /// Apple Watch reference factor from time-aligned high-quality buckets. Sources remain separate:
    /// each point compares one WHOOP estimate with one selected Watch source and never adds devices.
    ///
    /// Refreshes run one at a time, in the order they were asked for. Each reads its inputs, then
    /// replaces its window wholesale, and the steps between are awaits on the main actor: two refreshes
    /// could interleave, and the one that read first would then write last, putting back the rows priced
    /// on the older inputs. The post-offload refresh trusts its stored cursor that its window is current,
    /// so such a rewrite would stay until the day's inputs moved again.
    @discardableResult
    func refreshWhoopEnergyModel(days: Int = 120, profile: UserProfile) async -> Bool {
        await serializedEnergyRefresh(profile: profile) { _ in days }
    }

    /// A refresh covering the local day holding `startTs` through today. The span is measured when the
    /// refresh starts, not when it was asked for: a queued refresh that starts after midnight still
    /// covers the day the change landed on.
    @discardableResult
    func refreshWhoopEnergyModel(coveringStart startTs: Int, profile: UserProfile) async -> Bool {
        await serializedEnergyRefresh(profile: profile) { now in
            Self.energyRefreshDays(coveringStart: startTs, now: now, calendar: .current)
        }
    }

    private func serializedEnergyRefresh(profile: UserProfile, days: @escaping (Date) -> Int) async -> Bool {
        // A refresh that reaches another through its own readers runs it inline; queueing it behind
        // itself would never finish.
        if EnergyRefreshContext.isInside {
            return await measuredEnergyRefresh(profile: profile, days: days)
        }
        let previous = energyRefreshTail
        let run = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await EnergyRefreshContext.$isInside.withValue(true) {
                await self.measuredEnergyRefresh(profile: profile, days: days)
            }
        }
        energyRefreshTail = run
        return await run.value
    }

    private func measuredEnergyRefresh(profile: UserProfile, days: (Date) -> Int) async -> Bool {
        let now = Date()
        let covered = days(now)
        let start = DispatchTime.now().uptimeNanoseconds
        let refreshed = await performWhoopEnergyRefresh(days: covered, profile: profile, now: now)
        EnergyRefreshStats.record(days: covered,
                                  millis: Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
        return refreshed
    }

    /// One energy refresh over `days` whole local days (`EnergyModelRefresh`).
    private func performWhoopEnergyRefresh(days: Int, profile: UserProfile, now: Date) async -> Bool {
        energyProfile = profile
        guard let store = await storeHandle() else { return false }
        let inputs = EnergyModelRefresh.Inputs(
            dailyRows: self.days, manualVO2: FitnessPreferences.manualEntry,
            activityLevelOverride: FitnessPreferences.activityLevelOverride,
            calibrationEnabled: EnergyCalibrationPreferences.enabled, refreshMaxDays: Self.energyRefreshMaxDays,
            dismissedDetectedSpans: dismissedDetectedWorkoutSpans, latestPeakMET: latestEnergyPeakMET)
        let outcome = await EnergyModelRefresh.perform(reader: storeReader(store), days: days, profile: profile,
                                                       now: now, inputs: inputs, stepCache: energyStepMovementCache)
        latestEnergyPeakMET = outcome.latestPeakMET
        if outcome.wroteWindow { noteEnergyPresentationChanged() }
        return outcome.ok
    }

    /// The model generation the stored energy history was last recomputed with.
    static let energyHistoryModelKey = "energy.historyModelVersion"

    /// Recomputes the stored energy history once per model generation.
    ///
    /// A model-version bump used to reach only today (the repair in `energySummaries`) and the days a
    /// later offload spanned. Every older day kept its superseded row, which the readers skip, and fell
    /// back to the retired whole-day estimate: after v8, the history the wearer scrolled back through was
    /// still priced by Keytel. This runs the full refresh window once and records the generation only
    /// when the pass completed, so an interrupted pass runs again on the next launch.
    ///
    /// `waitIfRunning` is for the workout-energy migration, which prices sessions against the stored
    /// daily ceilings and must not read them while a pass is still rewriting them.
    func ensureEnergyHistoryCurrent(profile: UserProfile, waitIfRunning: Bool = false) async {
        let current = WhoopDailyEnergyEstimate.modelVersion
        while waitIfRunning, energyHistoryRefreshRunning, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard UserDefaults.standard.string(forKey: Self.energyHistoryModelKey) != current,
              !energyHistoryRefreshRunning else { return }
        energyHistoryRefreshRunning = true
        defer { energyHistoryRefreshRunning = false }
        if await refreshWhoopEnergyModel(days: Self.energyRefreshMaxDays, profile: profile) {
            UserDefaults.standard.set(current, forKey: Self.energyHistoryModelKey)
        }
    }

    /// The user's personal time-of-day activity profile, or nil until enough history exists.
    /// Nil is the honest state, not a failure: `EnergyEngine` then keeps the linear projection.
    func activityShape() async -> ActivityShape? {
        guard let store = await storeHandle() else { return nil }
        return await EnergySummaryStoreReads.activityShape(reader: storeReader(store), now: Date())
    }

    /// Pure bucketing of a day's step samples (`EnergyModelRefresh`).
    nonisolated static func bucketStepMovement(
        _ samples: [StepSample], ticksPerStep: Double
    ) -> [Int: EnergyStepMovement] {
        EnergyModelRefresh.bucketStepMovement(samples, ticksPerStep: ticksPerStep)
    }



    /// How many distinct hours of each day carry a step count — the movement-coverage signal.
    ///
    /// One windowed read for the whole range rather than a query per day: this runs on a Today load,
    /// beside a dozen other reads, and 30 round-trips for a caption would be the wrong trade.
    /// Which local hours of each day carry any step count.
    ///
    /// It used to return only the COUNT, which answers "how much of the day moved" for the coverage
    /// figure but not "which part of it" — and the second question is what lets a logged session's
    /// hours be taken OUT of the step estimate instead of being guessed at. The count is still there,
    /// one `.count` away, so nothing had to read the table twice to get both.
    private func hoursWithStepsByDay(days: Int) async -> [String: [Int]] {
        guard let store = await storeHandle() else { return [:] }
        return await EnergySummaryStoreReads.stepHours(reader: storeReader(store), days: days, now: Date())
    }

    /// The sessions each local day carries, for the days no device measured the energy of.
    ///
    /// Reads through `workoutRows`, so this list is the SAME one the Workouts screen shows: dismissed
    /// rows removed, detected shadows dropped, and cross-source twins collapsed by
    /// `WorkoutSource.dedupCrossSource`. An Apple import and the strap session behind it are one
    /// session here for the same reason they are one row there — and a second, energy-only dedup rule
    /// would eventually disagree with the list about which session was real.
    ///
    /// A session that straddles midnight is filed under BOTH days; the engine splits its energy by time.
    private func loggedSessionsByDay(days: Int) async -> [String: [WorkoutRow]] {
        let rows = await workoutRows(days: max(1, days) + 1, reconcileHrCap: 0)
        var byDay: [String: [WorkoutRow]] = [:]
        for row in rows where row.endTs > row.startTs {
            let start = Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            let end = Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.endTs - 1)))
            byDay[start, default: []].append(row)
            if end != start { byDay[end, default: []].append(row) }
        }
        return byDay
    }

    /// One logged session, priced for the energy engine — or nil when it cannot be priced at all.
    ///
    /// The precedence is the point, and it runs strongest-evidence-first:
    ///
    ///   1. what the session itself recorded (`energyKcal`),
    ///   2. the Keytel rate at the session's stored AVERAGE heart rate — evidence about this person,
    ///      flattened to one number, so weaker than a sample series but far stronger than a table,
    ///   3. the Compendium MET value for the sport — a population average for an activity NAME.
    ///
    /// Anything NOOP modelled here is marked `isEstimated`, which both keeps it visibly an estimate on
    /// screen and tells the engine the figure is gross.
    nonisolated static func activityContribution(_ row: WorkoutRow, profile: UserProfile,
                                                 hrMax: Double?, restingHR: Double?,
                                                 peakMET: Double? = nil)
        -> ActivityContribution? {
        EnergySummaryPreparation.activityContribution(row, profile: profile, hrMax: hrMax, restingHR: restingHR, peakMET: peakMET)
    }

    /// The app's workout lane for a stored `source` string, as the engine's own mirror of it.
    ///
    /// Exhaustive over `WorkoutSource` with no `default`: the lane decides whether a figure still
    /// contains the bout's resting energy, and a lane added later must answer that question rather
    /// than inherit an answer from whichever case happened to be first.
    nonisolated static func contributionSource(_ source: String) -> ActivityContribution.Source {
        EnergySummaryPreparation.contributionSource(source)
    }

    /// Distinct seconds an Apple Health energy source (iPhone or Watch) actually reported for, per
    /// local day — the same `healthEnergyBucket` reference stream the Watch calibration fit reads,
    /// repurposed here as an honest coverage signal for an `appleSplit` day (`docs/ANALYTICS.md`
    /// §Daily energy). iOS only: the bridge that populates this table is `#if os(iOS)`, so this
    /// returns empty on macOS and every day there keeps its existing `.solid` confidence.
    ///
    /// **Max per bucket across sources, never summed.** An iPhone and a Watch can both report the
    /// same five-minute window; summing their `coverageSeconds` would push a bucket's coverage past
    /// 100% and overstate the day. This is the same anti-double-counting rule the calibration fit and
    /// `EnergyEngine`'s header both apply to energy itself, here applied to a coverage DENOMINATOR.
    ///
    /// The same rows carry `strideM`, the phone-measured walking step length, so the timeline the step
    /// fallback needs rides out of this ONE query rather than a second pass over the same table.
    private func appleEnergyReference(days: Int) async
        -> (coverage: [String: Int], stride: StepLengthTimeline) {
        guard let store = await storeHandle() else { return ([:], StepLengthTimeline(samplesByDay: [:])) }
        return await EnergySummaryStoreReads.appleReference(reader: storeReader(store), days: days, now: Date())
    }

    /// Real local-day bounds for the energy engine. Calendar arithmetic is essential here: daylight-
    /// saving transitions produce 23- and 25-hour days, for which a fixed 86,400 denominator makes both
    /// basal accrual and the active-energy projection wrong.
    nonisolated static func energyDayContext(day: String, now: Date = Date(),
                                             calendar: Calendar = .current) -> EnergyEngine.DayContext {
        EnergySummaryPreparation.dayContext(day: day, now: now, calendar: calendar)
    }

    /// The `UserProfile` the analytics package expects, from the app's `ProfileStore`. One conversion
    /// site, so the BMR behind the energy card and the BMR behind a workout's calories are the same
    /// person. Main-actor isolated because `ProfileStore` is — callers read it where they already
    /// hold the profile, which is on the main actor anyway.
    @MainActor
    static func analyticsProfile(_ profile: ProfileStore) -> UserProfile {
        // The basal formula the wearer chose on the Energy Plan (Mifflin–St Jeor until they choose),
        // applied to the whole history. Body fat is resolved per day by the energy paths that need it.
        UserProfile(weightKg: profile.weightKg,
                    heightCm: profile.heightCm,
                    age: Double(profile.age),
                    sex: profile.sex,
                    maxHR: Double(profile.hrMax),
                    basalFormula: EnergyPlanStore.formulaLog.current)
    }

    /// The body fat in force on a day, for Katch–McArdle; a resolver that answers nil without reading
    /// anything for every other formula.
    func bodyFatResolver(for formula: BasalFormula) async -> (String) -> Double? {
        guard formula.needsBodyFat else { return { _ in nil } }
        let metrics = await bodyMetrics()
        return { metrics.asOf("body_fat", day: $0)?.value }
    }
}

/// Marks the task running an energy refresh, so a refresh it reaches through its own readers runs inline
/// instead of queueing behind itself.
private enum EnergyRefreshContext {
    @TaskLocal static var isInside = false
}
