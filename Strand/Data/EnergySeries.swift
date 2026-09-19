import Foundation
import StrandAnalytics
import WhoopProtocol   // StepSample — the @57 counter + @63 activity class behind bucket movement
import WhoopStore

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
        let calendar = Calendar.current
        let cutoff = calendar.startOfDay(for: asOf)
        guard let firstDate = calendar.date(
            byAdding: .day, value: -(AdaptiveExpenditureEngine.maximumWindowDays + 1), to: cutoff),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: cutoff) else { return nil }
        let from = Self.localDayKey(firstDate)
        let to = Self.localDayKey(yesterday)
        // Both intake sources, manual winning a day it shares with an import — the same "one source
        // wins a day, never a sum" rule weight follows. Reading only the CSV source (as this did) made
        // a typed number invisible to the balance estimate, which for a strap-only setup is the ONLY
        // remaining way to check the level at all.
        let intake = await intakeByDay(from: from, to: to)
        guard !intake.isEmpty else { return nil }
        let nutrition = intake.map { MetricPoint(day: $0.key, key: "calories_in", value: $0.value) }
        let weights = await weightSeries(days: AdaptiveExpenditureEngine.maximumWindowDays + 2)

        var byDay: [String: (calories: Double?, weight: Double?)] = [:]
        for point in nutrition where point.day >= from && point.day <= to {
            byDay[point.day, default: (nil, nil)].calories = point.value
        }
        for point in weights where point.day >= from && point.day <= to {
            byDay[point.day, default: (nil, nil)].weight = point.value
        }
        let inputs = byDay.compactMap { day, values -> AdaptiveExpenditureDay? in
            guard let date = WeightSeries.date(forDay: day) else { return nil }
            return .init(date: date, caloriesIn: values.calories, weightKg: values.weight)
        }
        return AdaptiveExpenditureEngine.estimate(days: inputs, asOf: asOf, calendar: calendar)
    }

    /// Energy summaries for the trailing `days`, oldest first. One entry per day that has ANY input;
    /// a day nobody measured is simply absent rather than present with zeroes.
    ///
    /// `profile` is passed in rather than read here because `ProfileStore` is a `@MainActor`
    /// observable the caller already holds, and the BMR must come from the same profile the rest of
    /// the screen is showing.
    func energySummaries(days: Int = 30, profile: UserProfile) async -> [DailyEnergySummary] {
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
        let calibration = await energyCalibrationState(store: store)
        let calibrationFactor = calibration.status == .active ? calibration.factor : nil
        // Both shape the FORECAST only, never what was actually burned. Resolved once for the whole
        // window rather than per day: they describe the person, not the day.
        let shape = await activityShape()
        let adaptivePrior = await adaptiveExpenditureEstimate()?.estimatedDailyKcal
        let appleReference = await appleEnergyReference(days: days)
        let appleCoverageByDay = appleReference.coverage

        // TODAY is always included, even with no inputs at all. Without this the engine's
        // `.profileOnly` branch is unreachable in practice: a day with no Apple row and no strap row
        // produced no summary, so the card that exists to say "nothing recorded yet, here is your
        // estimated basal rate" simply never appeared. Past days stay data-driven — an empty card for
        // every unworn day last month would be noise, not honesty.
        let allDays = Set(appleByDay.keys).union(strapByDay.keys)
            .union(derivedByDay.keys).union([todayKey]).sorted()
        return allDays.map { day in
            let apple = appleByDay[day]
            let strap = strapByDay[day]
            let derived = derivedByDay[day]
            // A total and its coverage denominator MUST come from the same model. These two lines used
            // to disagree — the total preferred `derived`, the denominator preferred `strap` — so on
            // any day both existed the engine divided one model's kcal by the other's seconds. Where
            // the legacy denominator is the larger (low-confidence PPG stretches are dropped from the
            // bucket model but counted by `energyCoverageSeconds`), the basal top-up it implies is too
            // big and `max(0, total - basal)` silently eats the day's active energy.
            let legacyEnergy = day == todayKey
                ? nil
                : strap?.activeKcalEst.map { ($0, strap?.energyCoverageSeconds) }
            let strapEnergy: (kcal: Double, seconds: Int?)? = derived.map {
                ($0.rawTotalKcal, $0.representedSeconds)
            } ?? legacyEnergy
            var dayProfile = profile
            if let date = WeightSeries.date(forDay: day),
               let historicalWeight = CausalWeightResolver.weight(
                   at: Int(date.timeIntervalSince1970 + 43_200), observations: weightObservations,
                   calendar: calendar) {
                dayProfile.weightKg = historicalWeight
            }
            // Priced with THIS day's body mass and resting heart rate: both belong to the day rather
            // than to today, the same reason the weight above is resolved causally. The engine reads
            // them only on a day nothing measured, so the decision stays in one place.
            let sessions = (sessionsByDay[day] ?? []).compactMap {
                Self.activityContribution($0, profile: dayProfile, hrMax: strainProfile?.hrMax,
                                          restingHR: strap?.restingHr.map(Double.init))
            }
            let inputs = EnergyEngine.DayInputs(
                day: day,
                appleActiveKcal: apple?.activeKcal,
                appleBasalKcal: apple?.basalKcal,
                appleCoverageSeconds: appleCoverageByDay[day],
                strapTotalKcal: strapEnergy?.kcal,
                strapCoverageSeconds: strapEnergy?.seconds,
                strapCalibrationFactor: calibrationFactor,
                strapUncertaintyFraction: derived?.uncertaintyFraction,
                calibrationStatus: calibration.status,
                // Apple's own step total first (a phone counts all day), else the strap's.
                steps: apple?.steps ?? strap?.steps,
                hoursWithSteps: stepHoursByDay[day]?.count,
                stepHours: stepHoursByDay[day],
                strideM: appleReference.stride.estimate(onDay: day)?.metersPerStep,
                loggedActivity: sessions,
                unresolvedElevatedHRSeconds: derived.map {
                    Self.energyContextSeconds($0.contextJSON, context: .unresolvedElevatedHR)
                } ?? 0,
                modelWeightSource: derived?.weightSource.rawValue ?? "profile")
            return EnergyEngine.summarize(
                inputs,
                profile: dayProfile,
                context: Self.energyDayContext(day: day, now: now, calendar: calendar),
                shape: shape,
                adaptivePriorKcal: adaptivePrior)
        }
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
            basalKcalPerDay: Calories.bmrKcalPerDay(profile: profile))
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

    /// Rebuilds the auditable WHOOP bucket output and, only after explicit opt-in, learns a bounded
    /// Apple Watch reference factor from time-aligned high-quality buckets. Sources remain separate:
    /// each point compares one WHOOP estimate with one selected Watch source and never adds devices.
    func refreshWhoopEnergyModel(days: Int = 120, profile: UserProfile) async {
        guard let store = await storeHandle() else { return }
        let now = Date()
        let calendar = Calendar.current
        // Callers may request a current-day repair after a model-version upgrade. Calibration still
        // enforces its own seven-day minimum when fitting, so forcing every refresh to read at least
        // seven days only made the Energy detail screen unnecessarily block on raw movement history.
        let fromDate = days <= 1
            ? calendar.startOfDay(for: now)
            : (calendar.date(byAdding: .day, value: -days, to: now) ?? now)
        let from = Int(fromDate.timeIntervalSince1970)
        let to = Int(now.timeIntervalSince1970) + 1
        let hr = await hrBuckets(from: from, to: to, bucketSeconds: 300)
            .filter { $0.bpm.isFinite && $0.conf >= 0.5 }
        guard !hr.isEmpty else { return }

        let observations = await weightSeries(days: max(days + 100, 100)).compactMap { point in
            WeightSeries.date(forDay: point.day).map {
                CausalWeightObservation(timestamp: Int($0.timeIntervalSince1970),
                                        weightKg: point.value,
                                        source: point.source == .manual ? .manual : .health)
            }
        }
        let maximumHR = profile.maxHR
            ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        let sleepIntervals = await energySleepIntervals(store: store, from: from, to: to)
        let offWristIntervals = await energyOffWristIntervals(store: store, from: from, to: to)
        let workoutIntervals = await energyWorkoutIntervals(store: store, from: from, to: to)

        // The wearer's own step length, from Apple's iPhone-measured walking-step-length reading.
        // This is an INPUT to the model, not an energy figure: no Apple kcal is read here, the source
        // is the phone rather than a watch, and the Watch calibration path below is untouched. Any day
        // this cannot answer keeps `movementMET`'s documented population average, which is exactly the
        // behaviour every day had before v6.
        //
        // Read further back than the refresh window: a measurement carries forward, so the earliest
        // days of the window need the readings that precede them or they would fall back to the
        // average while every later day used a measurement.
        let strideFrom = from - StepLengthTimeline.carryForwardDays * 86_400
        let strideRows = (try? await store.healthEnergyBuckets(
            deviceId: Self.appleHealthSource, from: strideFrom, to: to)) ?? []
        var strideSamplesByDay: [String: [Double]] = [:]
        for row in strideRows {
            guard let stride = row.strideM else { continue }
            let day = Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.bucketStart)))
            strideSamplesByDay[day, default: []].append(stride)
        }
        let strideTimeline = StepLengthTimeline(samplesByDay: strideSamplesByDay)
        var bucketResults: [Int: WhoopEnergyBucketResult] = [:]
        var bucketInputs: [Int: WhoopEnergyBucket] = [:]
        var pendingWindow: [WhoopEnergyWindowDay] = []
        // Active-only kcal per bucket (bucket total minus that bucket's own basal share). Populated
        // once here and reused by the Watch-calibration fit below — the fit must compare like with
        // like (Apple's `activeKcal` is already basal-free), and computing it twice would risk the
        // two copies drifting apart on the exact basal-per-second arithmetic.
        var whoopActiveByBucket: [Int: Double] = [:]
        for (day, rows) in Dictionary(grouping: hr, by: { Self.localDayKey(
            Date(timeIntervalSince1970: TimeInterval($0.ts))) }) {
            var dayProfile = profile
            let noon = WeightSeries.date(forDay: day)
                .map { Int($0.timeIntervalSince1970 + 43_200) } ?? (rows.first.map(\.ts) ?? from)
            var weightSource = WhoopDailyEnergyRow.WeightSource.profile
            if let historical = CausalWeightResolver.weight(
                at: noon, observations: observations, calendar: calendar) {
                dayProfile.weightKg = historical
                weightSource = .history
            }
            // Movement for THIS day only. Heart rate alone cannot see a walk (see the header of
            // `WhoopEnergyModel.estimate`), and until now every bucket was built from `averageHR` and
            // nothing else — which left `hasMovement` unreachable, `inferredSeconds` permanently 0,
            // and a half-hour walk worth exactly zero active kcal.
            //
            // Read per day rather than once for the whole window: `stepSample` is a ~1 Hz stream, so
            // 30 days at once is millions of rows on a phone, while one day is bounded and released
            // before the next iteration.
            let dayStartDate = WeightSeries.date(forDay: day)
                ?? Date(timeIntervalSince1970: TimeInterval(rows.map(\.ts).min() ?? from))
            let dayFrom = Int(calendar.startOfDay(for: dayStartDate).timeIntervalSince1970)
            let nextDay = calendar.date(byAdding: .day, value: 1,
                                        to: calendar.startOfDay(for: dayStartDate)) ?? dayStartDate
            let dayTo = min(to, Int(nextDay.timeIntervalSince1970))
            let movement = await stepMovementByBucket(from: dayFrom, to: dayTo, profile: profile)
            // Resolved once per day, never per bucket: the readings are per walking bout, so most
            // buckets hold none and a per-bucket lookup would jitter between measured and assumed
            // depending on where a sample happened to fall.
            let dayStrideM = strideTimeline.estimate(onDay: day)?.metersPerStep
            let hrByStart = Dictionary(rows.map { ($0.ts, $0) }, uniquingKeysWith: { a, _ in a })
            let bucketStarts = Set(hrByStart.keys).union(movement.keys).sorted()
            let inputs = bucketStarts.compactMap { start -> WhoopEnergyBucket? in
                let wallSeconds = min(300, dayTo - start)
                guard wallSeconds > 0 else { return nil }
                let hrRow = hrByStart[start]
                let move = movement[start]
                let midpoint = start + wallSeconds / 2
                let workout = Self.energyInterval(at: midpoint, in: workoutIntervals)
                return WhoopEnergyBucket(
                    start: start, durationSeconds: wallSeconds,
                    hrCoverageSeconds: min(wallSeconds, max(0, hrRow?.sampleSeconds ?? 0)),
                    averageHR: hrRow?.bpm, steps: move?.steps,
                    strideM: dayStrideM,
                    activityClass: move?.activityClass,
                    isWorkout: workout != nil, workoutKind: workout?.kind ?? .other,
                    isSleep: Self.contains(midpoint, in: sleepIntervals),
                    isOffWrist: Self.contains(midpoint, in: offWristIntervals),
                    hasMovementCoverage: move?.covered == true,
                    movementSeconds: move?.movementSeconds ?? 0)
            }
            for input in inputs { bucketInputs[input.start] = input }
            let priorResting = self.days.filter { $0.day < day }.compactMap(\.restingHr)
                .suffix(14).map(Double.init).sorted()
            let restingHR = priorResting.isEmpty ? nil : priorResting[priorResting.count / 2]
            guard let estimate = WhoopEnergyModel.estimate(
                buckets: inputs, profile: dayProfile, restingHR: restingHR,
                maxHR: maximumHR, flexHR: restingHR.map { $0 + 20 }) else { continue }
            for bucket in estimate.buckets { bucketResults[bucket.start] = bucket }
            // The same pass, kept at hourly resolution so `ActivityShapeEngine` can fit a personal
            // time-of-day profile later without re-walking the raw ~1 Hz streams. ACTIVE energy only:
            // basal is flat by construction and would flatten the very shape this measures.
            var activeByHour: [Int: Double] = [:]
            for bucket in estimate.buckets {
                let active = bucket.activeKcal
                whoopActiveByBucket[bucket.start] = active
                guard active > 0 else { continue }
                let hour = calendar.component(
                    .hour, from: Date(timeIntervalSince1970: TimeInterval(bucket.start)))
                activeByHour[hour, default: 0] += active
            }
            let row = WhoopDailyEnergyRow(
                day: day, rawTotalKcal: estimate.totalKcal,
                modelVersion: WhoopDailyEnergyEstimate.modelVersion,
                observedSeconds: estimate.observedSeconds,
                inferredSeconds: estimate.inferredSeconds,
                modeledSeconds: estimate.modeledSeconds,
                representedSeconds: estimate.representedSeconds,
                physiologicalSeconds: estimate.physiologicalSeconds,
                contextJSON: Self.energyContextJSON(estimate.contextSeconds),
                uncertaintyFraction: estimate.uncertaintyFraction,
                weightKg: dayProfile.weightKg, weightSource: weightSource)
            let storedBuckets = estimate.buckets.compactMap { bucket -> WhoopEnergyBucketRow? in
                guard let input = bucketInputs[bucket.start] else { return nil }
                return .init(day: day, bucketStart: bucket.start,
                             durationSeconds: input.durationSeconds,
                             basalKcal: max(0, bucket.kcal - bucket.activeKcal),
                             activeKcal: bucket.activeKcal,
                             context: bucket.context.rawValue,
                             evidence: bucket.evidence.rawValue,
                             uncertaintyFraction: bucket.uncertaintyFraction)
            }
            pendingWindow.append(.init(daily: row, activeKcalByHour: activeByHour,
                                       buckets: storedBuckets))
        }

        // Daily totals and their hourly activity shape describe one model generation. Publish the
        // entire recomputed window in one SQLite transaction so a cancellation or write failure can
        // never expose half v3 / half v4 state.
        guard !pendingWindow.isEmpty else { return }
        do {
            _ = try await store.replaceWhoopEnergyWindow(pendingWindow, deviceId: deviceId)
        } catch {
            return
        }
        // Publish only after the atomic replacement succeeded, including every calibration exit below.
        defer { noteEnergyPresentationChanged() }

        guard EnergyCalibrationPreferences.enabled else { return }
        let referenceRows = (try? await store.healthEnergyBuckets(
            deviceId: Self.appleHealthSource, from: from, to: to, eligibleOnly: true)) ?? []
        // ACTIVE only, both sides. Apple already reports it separately from basal — nothing to derive
        // there — and `whoopActiveByBucket` (above) is WHOOP's bucket total minus that bucket's own
        // basal share. A fit fitted on totals would bake resting metabolism into the ratio, and
        // `EnergyEngine.burn` would then apply that diluted factor to active energy alone: two
        // different quantities calibrated against each other, understating the true correction.
        let candidates = referenceRows.filter { $0.coverageSeconds > 0 }
        // Keep this deliberately simple for Swift 5's type checker. The nested generic
        // Dictionary(grouping:) -> tuple map -> ternary sort expression timed out in the
        // universal macOS CI build even though newer local compilers accepted it.
        var sourceCounts: [String: Int] = [:]
        for row in candidates { sourceCounts[row.sourceId, default: 0] += 1 }
        let rankedSources = sourceCounts.keys.sorted { lhs, rhs in
            let lhsCount = sourceCounts[lhs] ?? 0
            let rhsCount = sourceCounts[rhs] ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs < rhs
        }
        let chosenSource = rankedSources.first
        guard let chosenSource else { return }
        let hrByStart = Dictionary(hr.map { ($0.ts, $0) }, uniquingKeysWith: { a, _ in a })
        let points = candidates.compactMap { row -> EnergyCalibrationPoint? in
            guard row.sourceId == chosenSource, let whoopActive = whoopActiveByBucket[row.bucketStart],
                  let context = bucketResults[row.bucketStart]?.context,
                  let input = bucketInputs[row.bucketStart] else { return nil }
            let apple = (row.activeKcal ?? 0) / Double(row.coverageSeconds) * 300
            // `activeKcal` covers the WHOLE wall bucket. Dividing it by HR seconds (the former code)
            // inflated a sparse optical bucket before fitting. Only wall duration belongs here.
            let normalizedWhoop = whoopActive / Double(max(1, input.durationSeconds)) * 300
            let coverage = Double(row.coverageSeconds) / Double(HealthEnergyBucketRow.durationSeconds)
            let hrBucket = hrByStart[row.bucketStart]
            let signalCoverage: Double
            let signalQuality: Double
            if context == .locomotion, input.hasMovementCoverage {
                signalCoverage = 1
                signalQuality = hrBucket?.conf ?? 1
            } else {
                signalCoverage = Double(input.hrCoverageSeconds) / Double(input.durationSeconds)
                signalQuality = hrBucket?.conf ?? 0
            }
            let quality = min(min(row.quality ?? coverage, coverage),
                              min(signalQuality, signalCoverage))
            return .init(timestamp: row.bucketStart, whoopKcal: normalizedWhoop,
                         appleWatchKcal: apple, overlapQuality: quality, context: context)
        }
        guard let fit = EnergyCalibrationEngine.fit(points: points, calendar: calendar) else { return }
        let model = EnergyCalibrationModelRow(
            deviceId: deviceId, referenceDeviceId: chosenSource, enabled: true,
            factor: fit.factor, sampleDays: fit.sampleDays, sampleBuckets: fit.sampleBuckets,
            coefficientOfVariation: fit.coefficientOfVariation,
            fittedAt: Int(now.timeIntervalSince1970), modelVersion: EnergyCalibrationFit.modelVersion)
        _ = try? await store.saveEnergyCalibrationModel(model)
    }

    /// The user's personal time-of-day activity profile, or nil until enough history exists.
    /// Nil is the honest state, not a failure: `EnergyEngine` then keeps the linear projection.
    func activityShape() async -> ActivityShape? {
        guard let store = await storeHandle() else { return nil }
        let calendar = Calendar.current
        let now = Date()
        guard let firstDate = calendar.date(byAdding: .day,
                                            value: -ActivityShapeEngine.maximumWindowDays,
                                            to: now) else { return nil }
        // Yesterday is the last COMPLETE day. Today is still accruing, and a half-finished day would
        // teach the curve that this person stops being active at whatever time it currently is.
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
        let rows = (try? await store.whoopEnergyHours(deviceId: deviceId,
                                                      from: Self.localDayKey(firstDate),
                                                      to: Self.localDayKey(yesterday))) ?? []
        let daily = (try? await store.whoopDailyEnergy(deviceId: deviceId,
                                                       from: Self.localDayKey(firstDate),
                                                       to: Self.localDayKey(yesterday))) ?? []
        let eligibleDays = Set(daily.filter {
            EnergyBurnRate.dayQualifies(modelVersion: $0.modelVersion,
                                        representedSeconds: $0.representedSeconds)
        }.map(\.day))
        guard !rows.isEmpty, !eligibleDays.isEmpty else { return nil }
        var byDay: [String: [Double]] = [:]
        for row in rows where eligibleDays.contains(row.day) && (0...23).contains(row.hour) {
            byDay[row.day, default: [Double](repeating: 0, count: 24)][row.hour] += row.activeKcal
        }
        return ActivityShapeEngine.fit(days: byDay.sorted { $0.key < $1.key }
            .map { .init(day: $0.key, activeByHour: $0.value) })
    }

    /// Per-5-minute-bucket strap movement for one day: real steps and the strap's own `activity_class`.
    ///
    /// Three existing rules are deliberately reused rather than re-derived:
    ///
    ///   • **One device id, never merged** (`strapStepTicks`, `Repository.swift`). `@57` is a CUMULATIVE
    ///     counter, so interleaving two straps' counters fabricates enormous deltas. The first id in
    ///     `importedReadIds` that yields a countable window wins the whole day.
    ///   • **The shared `StepsCounter` kernel** does the wrap-aware delta maths. A second copy of that
    ///     arithmetic here is exactly what `AnalyticsEngine`'s comment warns against, because then the
    ///     daily total and this per-bucket total could disagree.
    ///   • **`stepTicksPerStep`** (#139) converts motion TICKS to steps. Skipping it would feed the MET
    ///     model an inflated cadence on a 5/MG, which over-counts precisely where the counter is worst.
    ///
    /// Empty for a WHOOP 4.0, whose record layout carries no `@57` counter at all. Without a separate
    /// phone movement stream or trusted workout that device deliberately takes v4's conservative
    /// physiological path; HR alone is never promoted to activity.
    private func stepMovementByBucket(
        from: Int, to: Int, profile: UserProfile
    ) async -> [Int: (steps: Int?, activityClass: Int?, covered: Bool, movementSeconds: Int)] {
        guard let store = await storeHandle() else { return [:] }
        var samples: [StepSample] = []
        for id in importedReadIds {   // active strap FIRST, mirroring strapStepTicks
            let rows = (try? await store.stepSamples(deviceId: id, from: from - 300, to: to,
                                                     limit: Int.max)) ?? []
            if StepsCounter.stepsInWindow(rows) != nil { samples = rows; break }
        }
        guard samples.count >= 2 else { return [:] }
        return Self.bucketStepMovement(samples, ticksPerStep: profile.stepTicksPerStep)
    }

    /// Pure bucketing of a day's step samples, split out (like `latestActivityClass`) so the delta and
    /// gap rules are unit-testable without a store.
    nonisolated static func bucketStepMovement(
        _ samples: [StepSample], ticksPerStep: Double
    ) -> [Int: (steps: Int?, activityClass: Int?, covered: Bool, movementSeconds: Int)] {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return [:] }

        let bucketSeconds = WhoopEnergyModel.defaultBucketSeconds
        var byBucket: [Int: [StepSample]] = [:]
        var classCounts: [Int: [Int: Int]] = [:]
        var movementSecondsByBucket: [Int: Int] = [:]
        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            let bucket = (current.ts / bucketSeconds) * bucketSeconds
            let interval = min(30, max(0, current.ts - previous.ts))
            let counterMoved = current.counter != previous.counter
            let classMoved = (current.activityClass ?? 0) > 0
            if counterMoved || classMoved {
                movementSecondsByBucket[bucket, default: 0] += interval
            }
        }
        for (index, sample) in sorted.enumerated() {
            let start = (sample.ts / bucketSeconds) * bucketSeconds
            // Carry the PREVIOUS sample into each bucket as well. `stepsInWindow` needs a predecessor
            // to form a delta, so a slice starting cold silently drops the ticks that accrued across
            // every bucket boundary — 288 small losses a day, all in the same direction.
            //
            // But ONLY across a plausible boundary. `@57` is cumulative, so a predecessor from before
            // a data gap (a charge break, a not-yet-offloaded stretch) carries every tick that accrued
            // during that whole gap — `StepsCounter` accepts any delta below 512 — and crediting it to
            // the first bucket after the gap renders hours of absence as five minutes of brisk
            // walking, which then feeds `movementMET` a cadence that never happened.
            if byBucket[start] == nil, index > 0,
               sorted[index - 1].ts >= start - bucketSeconds {
                byBucket[start] = [sorted[index - 1]]
            }
            byBucket[start, default: []].append(sample)
            if let cls = sample.activityClass {
                classCounts[start, default: [:]][cls, default: 0] += 1
            }
        }

        let perStep = max(ticksPerStep, 0.5)
        return byBucket.reduce(into: [:]) { out, entry in
            let (start, slice) = entry
            let steps = StepsCounter.stepsInWindow(slice)
                .map { Int((Double($0) / perStep).rounded()) }
                .flatMap { $0 > 0 ? $0 : nil }
            // Modal class, ties resolved DOWN: one stray "run" tick in a bucket of walking must not
            // promote the whole five minutes to a 7-MET floor.
            let cls = classCounts[start]?.max {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            }?.key
            out[start] = (steps: steps, activityClass: cls, covered: true,
                          movementSeconds: min(bucketSeconds,
                                               movementSecondsByBucket[start] ?? 0))
        }
    }

    private typealias EnergyWorkoutInterval = (start: Int, end: Int, kind: EnergyWorkoutKind)

    private func energySleepIntervals(store: WhoopStore, from: Int, to: Int) async
        -> [(start: Int, end: Int)] {
        var rows: [CachedSleepSession] = []
        for id in computedReadIds + importedReadIds {
            rows += (try? await store.sleepSessions(deviceId: id, from: from - 43_200,
                                                     to: to, limit: 10_000)) ?? []
        }
        return rows.map { (start: $0.effectiveStartTs, end: $0.endTs) }
            .filter { $0.end > $0.start }
    }

    private func energyOffWristIntervals(store: WhoopStore, from: Int, to: Int) async
        -> [(start: Int, end: Int)] {
        for id in importedReadIds {
            let events = (try? await store.events(deviceId: id, from: from, to: to,
                                                  limit: 100_000)) ?? []
            let intervals = AnalyticsEngine.offWristIntervals(events: events, windowEnd: to)
            if !intervals.isEmpty { return intervals }
        }
        return []
    }

    private func energyWorkoutIntervals(store: WhoopStore, from: Int, to: Int) async
        -> [EnergyWorkoutInterval] {
        var rows: [WorkoutRow] = []
        let ids = importedReadIds + computedReadIds
            + [Self.appleHealthSource, "lifting", "activity-file"]
        for id in ids {
            rows += (try? await store.workouts(deviceId: id, from: from - 43_200,
                                               to: to, limit: 100_000)) ?? []
        }
        return rows.filter { $0.endTs > $0.startTs }.map {
            (start: $0.startTs, end: $0.endTs, kind: Self.energyWorkoutKind($0.sport))
        }
    }

    private nonisolated static func energyWorkoutKind(_ sport: String) -> EnergyWorkoutKind {
        let key = sport.lowercased().filter { $0.isLetter }
        if ["strength", "weight", "lifting", "crossfit", "functional", "yoga", "pilates"]
            .contains(where: key.contains) { return .resistance }
        if ["run", "walk", "cycle", "cycling", "bike", "swim", "row", "hike", "ski"]
            .contains(where: key.contains) { return .endurance }
        return .other
    }

    private nonisolated static func contains(_ timestamp: Int,
                                             in intervals: [(start: Int, end: Int)]) -> Bool {
        intervals.contains { $0.start <= timestamp && timestamp < $0.end }
    }

    private nonisolated static func energyInterval(at timestamp: Int,
                                                   in intervals: [EnergyWorkoutInterval])
        -> EnergyWorkoutInterval? {
        intervals.first { $0.start <= timestamp && timestamp < $0.end }
    }

    private nonisolated static func energyContextJSON(_ values: [EnergyContext: Int]) -> String {
        let object = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private nonisolated static func energyContextSeconds(_ raw: String,
                                                         context: EnergyContext) -> Int {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return 0 }
        return max(0, object[context.rawValue] ?? 0)
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
        let calendar = Calendar.current
        let now = Date()
        let fromDate = calendar.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        let toDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let from = Int(fromDate.timeIntervalSince1970)
        let to = Int(toDate.timeIntervalSince1970)
        guard let rows = try? await store.appleStepHours(deviceId: Self.appleHealthSource,
                                                         fromTs: from, toTs: to) else { return [:] }
        var byDay: [String: Set<Int>] = [:]
        for row in rows where row.steps > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(row.ts))
            let hour = Calendar.current.component(.hour, from: date)
            byDay[Self.localDayKey(date), default: []].insert(hour)
        }
        return byDay.mapValues { $0.sorted() }
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
                                                 hrMax: Double?, restingHR: Double?)
        -> ActivityContribution? {
        let source = contributionSource(row.source)
        let seconds = max(0, Double(row.endTs - row.startTs))
        func contribution(_ kcal: Double, estimated: Bool) -> ActivityContribution? {
            guard kcal.isFinite, kcal > 0 else { return nil }
            return ActivityContribution(startTs: row.startTs, endTs: row.endTs, kcal: kcal,
                                        source: source, isEstimated: estimated)
        }
        // The precedence itself lives in `WorkoutEnergyEstimate`, which the Workouts screen also
        // reads. Two copies of "recorded, else heart rate, else table" is two places for a day's
        // energy and the same session's own tile to come to different answers.
        return WorkoutEnergyEstimate.resolve(
            recordedKcal: row.energyKcal, sport: row.sport, durationSeconds: seconds,
            averageHR: row.avgHr, profile: profile, hrMax: hrMax, restingHR: restingHR)
            .flatMap { contribution($0.kcal, estimated: $0.isEstimated) }
    }

    /// The app's workout lane for a stored `source` string, as the engine's own mirror of it.
    ///
    /// Exhaustive over `WorkoutSource` with no `default`: the lane decides whether a figure still
    /// contains the bout's resting energy, and a lane added later must answer that question rather
    /// than inherit an answer from whichever case happened to be first.
    nonisolated static func contributionSource(_ source: String) -> ActivityContribution.Source {
        switch WorkoutSource.classify(source) {
        case .whoop:        return .whoop
        case .apple:        return .apple
        case .detected:     return .detected
        case .manual:       return .manual
        case .lifting:      return .lifting
        case .activityFile: return .activityFile
        case .hevy:         return .hevy
        }
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
        let calendar = Calendar.current
        let now = Date()
        let fromDate = calendar.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        let toDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        guard let rows = try? await store.healthEnergyBuckets(
            deviceId: Self.appleHealthSource,
            from: Int(fromDate.timeIntervalSince1970),
            to: Int(toDate.timeIntervalSince1970)) else {
            return ([:], StepLengthTimeline(samplesByDay: [:]))
        }
        var maxPerBucket: [Int: Int] = [:]
        var strideSamplesByDay: [String: [Double]] = [:]
        for row in rows {
            maxPerBucket[row.bucketStart] = max(maxPerBucket[row.bucketStart] ?? 0, row.coverageSeconds)
            if let stride = row.strideM {
                let day = Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.bucketStart)))
                strideSamplesByDay[day, default: []].append(stride)
            }
        }
        var byDay: [String: Int] = [:]
        for (bucketStart, seconds) in maxPerBucket where seconds > 0 {
            let day = Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(bucketStart)))
            byDay[day, default: 0] += seconds
        }
        return (byDay, StepLengthTimeline(samplesByDay: strideSamplesByDay))
    }

    /// Real local-day bounds for the energy engine. Calendar arithmetic is essential here: daylight-
    /// saving transitions produce 23- and 25-hour days, for which a fixed 86,400 denominator makes both
    /// basal accrual and the active-energy projection wrong.
    nonisolated static func energyDayContext(day: String, now: Date = Date(),
                                             calendar: Calendar = .current) -> EnergyEngine.DayContext {
        var parseCalendar = calendar
        parseCalendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = parseCalendar.date(from: DateComponents(
                calendar: parseCalendar, timeZone: parseCalendar.timeZone,
                year: parts[0], month: parts[1], day: parts[2])),
              let end = parseCalendar.date(byAdding: .day, value: 1, to: start) else {
            return .completePastDay
        }
        let duration = end.timeIntervalSince(start)
        let isToday = parseCalendar.isDate(now, inSameDayAs: start)
        return EnergyEngine.DayContext(isToday: isToday,
                                       dayDurationSeconds: duration,
                                       elapsedSeconds: isToday ? now.timeIntervalSince(start) : duration,
                                       startTs: Int(start.timeIntervalSince1970))
    }

    /// The `UserProfile` the analytics package expects, from the app's `ProfileStore`. One conversion
    /// site, so the BMR behind the energy card and the BMR behind a workout's calories are the same
    /// person. Main-actor isolated because `ProfileStore` is — callers read it where they already
    /// hold the profile, which is on the main actor anyway.
    @MainActor
    static func analyticsProfile(_ profile: ProfileStore) -> UserProfile {
        UserProfile(weightKg: profile.weightKg,
                    heightCm: profile.heightCm,
                    age: Double(profile.age),
                    sex: profile.sex,
                    maxHR: Double(profile.hrMax))
    }
}
