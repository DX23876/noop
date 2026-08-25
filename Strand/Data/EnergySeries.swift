import Foundation
import StrandAnalytics
import WhoopProtocol   // StepSample — the @57 counter + @63 activity class behind bucket movement
import WhoopStore

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
        let nutrition = (try? await store.metricSeries(
            deviceId: "nutrition-csv", key: "calories_in", from: from, to: to)) ?? []
        guard !nutrition.isEmpty else { return nil }
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
        let derivedRows = ((try? await store?.whoopDailyEnergy(
            deviceId: deviceId, from: cutoff, to: todayKey)) ?? [])
            .filter { $0.modelVersion == WhoopDailyEnergyEstimate.modelVersion }
        let derivedByDay = Dictionary(derivedRows.map { ($0.day, $0) },
                                      uniquingKeysWith: { _, b in b })
        let calibration = await energyCalibrationState(store: store)
        let calibrationFactor = calibration.status == .active ? calibration.factor : nil
        // Both shape the FORECAST only, never what was actually burned. Resolved once for the whole
        // window rather than per day: they describe the person, not the day.
        let shape = await activityShape()
        let adaptivePrior = await adaptiveExpenditureEstimate()?.estimatedDailyKcal
        let appleCoverageByDay = await appleEnergyCoverageByDay(days: days)

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
            let strapEnergy: (kcal: Double, seconds: Int?)? = derived.map {
                ($0.rawTotalKcal, $0.observedSeconds)
            } ?? strap?.activeKcalEst.map { ($0, strap?.energyCoverageSeconds) }
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
                hoursWithSteps: stepHoursByDay[day])
            var dayProfile = profile
            if let date = WeightSeries.date(forDay: day),
               let historicalWeight = CausalWeightResolver.weight(
                   at: Int(date.timeIntervalSince1970 + 43_200), observations: weightObservations,
                   calendar: calendar) {
                dayProfile.weightKg = historicalWeight
            }
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
        if enabled { await refreshWhoopEnergyModel(days: 30, profile: profile) }
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
    func refreshWhoopEnergyModel(days: Int = 30, profile: UserProfile) async {
        guard let store = await storeHandle() else { return }
        let now = Date()
        let calendar = Calendar.current
        let fromDate = calendar.date(byAdding: .day, value: -max(7, days), to: now) ?? now
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
        let resting = self.days.compactMap(\.restingHr).suffix(14).map(Double.init).sorted()
        let restingHR = resting.isEmpty ? nil : resting[resting.count / 2]
        let maximumHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil
        var bucketResults: [Int: WhoopEnergyBucketResult] = [:]
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
            let dayFrom = rows.map(\.ts).min() ?? from
            let dayTo = (rows.map(\.ts).max() ?? to) + WhoopEnergyModel.defaultBucketSeconds
            let movement = await stepMovementByBucket(from: dayFrom, to: dayTo, profile: profile)
            let inputs = rows.map {
                let move = movement[$0.ts]
                return WhoopEnergyBucket(start: $0.ts,
                                         durationSeconds: min(300, max(1, $0.sampleSeconds)),
                                         averageHR: $0.bpm,
                                         steps: move?.steps,
                                         activityClass: move?.activityClass)
            }
            guard let estimate = WhoopEnergyModel.estimate(
                buckets: inputs, profile: dayProfile, restingHR: restingHR,
                maxHR: maximumHR) else { continue }
            for bucket in estimate.buckets { bucketResults[bucket.start] = bucket }
            // The same pass, kept at hourly resolution so `ActivityShapeEngine` can fit a personal
            // time-of-day profile later without re-walking the raw ~1 Hz streams. ACTIVE energy only:
            // basal is flat by construction and would flatten the very shape this measures.
            let basalPerSecond = (Calories.bmrKcalPerDay(profile: dayProfile) ?? 0) / 86_400
            var activeByHour: [Int: Double] = [:]
            for bucket in estimate.buckets {
                let seconds = Double(min(300, max(1, bucketSeconds(for: bucket.start, in: rows))))
                let active = max(0, bucket.kcal - basalPerSecond * seconds)
                whoopActiveByBucket[bucket.start] = active
                guard active > 0 else { continue }
                let hour = calendar.component(
                    .hour, from: Date(timeIntervalSince1970: TimeInterval(bucket.start)))
                activeByHour[hour, default: 0] += active
            }
            _ = try? await store.replaceWhoopEnergyHours(
                day: day, deviceId: deviceId, activeKcalByHour: activeByHour)
            let row = WhoopDailyEnergyRow(
                day: day, rawTotalKcal: estimate.totalKcal,
                modelVersion: WhoopDailyEnergyEstimate.modelVersion,
                observedSeconds: estimate.observedSeconds,
                inferredSeconds: estimate.inferredSeconds,
                modeledSeconds: estimate.modeledSeconds,
                uncertaintyFraction: estimate.uncertaintyFraction,
                weightKg: dayProfile.weightKg, weightSource: weightSource)
            _ = try? await store.upsertWhoopDailyEnergy([row], deviceId: deviceId)
        }

        guard EnergyCalibrationPreferences.enabled else { return }
        let referenceRows = (try? await store.healthEnergyBuckets(
            deviceId: Self.appleHealthSource, from: from, to: to, eligibleOnly: true)) ?? []
        // ACTIVE only, both sides. Apple already reports it separately from basal — nothing to derive
        // there — and `whoopActiveByBucket` (above) is WHOOP's bucket total minus that bucket's own
        // basal share. A fit fitted on totals would bake resting metabolism into the ratio, and
        // `EnergyEngine.burn` would then apply that diluted factor to active energy alone: two
        // different quantities calibrated against each other, understating the true correction.
        let candidates = referenceRows.filter {
            ($0.activeKcal ?? 0) > 0 && $0.coverageSeconds > 0
        }
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
                  let hrBucket = hrByStart[row.bucketStart] else { return nil }
            let apple = (row.activeKcal ?? 0) / Double(row.coverageSeconds) * 300
            let normalizedWhoop = whoopActive / Double(max(1, hrBucket.sampleSeconds)) * 300
            let coverage = Double(row.coverageSeconds) / Double(HealthEnergyBucketRow.durationSeconds)
            let whoopCoverage = Double(hrBucket.sampleSeconds) / 300
            let quality = min(min(row.quality ?? coverage, coverage), min(hrBucket.conf, whoopCoverage))
            return .init(timestamp: row.bucketStart, whoopKcal: normalizedWhoop,
                         appleWatchKcal: apple, overlapQuality: quality)
        }
        guard let fit = EnergyCalibrationEngine.fit(points: points, calendar: calendar) else { return }
        let model = EnergyCalibrationModelRow(
            deviceId: deviceId, referenceDeviceId: chosenSource, enabled: true,
            factor: fit.factor, sampleDays: fit.sampleDays, sampleBuckets: fit.sampleBuckets,
            coefficientOfVariation: fit.coefficientOfVariation,
            fittedAt: Int(now.timeIntervalSince1970), modelVersion: EnergyCalibrationFit.modelVersion)
        _ = try? await store.saveEnergyCalibrationModel(model)
    }

    /// How many seconds the bucket starting at `start` actually observed, from the HR rows it was
    /// built from. Mirrors the `durationSeconds` handed to `WhoopEnergyModel`, so the basal share
    /// subtracted per hour matches the basal share the model added.
    private nonisolated func bucketSeconds(for start: Int, in rows: [HRBucket]) -> Int {
        rows.first { $0.ts == start }.map { min(300, max(1, $0.sampleSeconds)) } ?? 300
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
        guard !rows.isEmpty else { return nil }
        var byDay: [String: [Double]] = [:]
        for row in rows where (0...23).contains(row.hour) {
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
    /// Empty for a WHOOP 4.0, whose record layout carries no `@57` counter at all — that strap keeps
    /// exactly today's HR-only behaviour rather than degrading.
    private func stepMovementByBucket(
        from: Int, to: Int, profile: UserProfile
    ) async -> [Int: (steps: Int?, activityClass: Int?)] {
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
    ) -> [Int: (steps: Int?, activityClass: Int?)] {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return [:] }

        let bucketSeconds = WhoopEnergyModel.defaultBucketSeconds
        var byBucket: [Int: [StepSample]] = [:]
        var classCounts: [Int: [Int: Int]] = [:]
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
            out[start] = (steps: steps, activityClass: cls)
        }
    }

    /// How many distinct hours of each day carry a step count — the movement-coverage signal.
    ///
    /// One windowed read for the whole range rather than a query per day: this runs on a Today load,
    /// beside a dozen other reads, and 30 round-trips for a caption would be the wrong trade.
    private func hoursWithStepsByDay(days: Int) async -> [String: Int] {
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
        return byDay.mapValues(\.count)
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
    private func appleEnergyCoverageByDay(days: Int) async -> [String: Int] {
        guard let store = await storeHandle() else { return [:] }
        let calendar = Calendar.current
        let now = Date()
        let fromDate = calendar.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        let toDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        guard let rows = try? await store.healthEnergyBuckets(
            deviceId: Self.appleHealthSource,
            from: Int(fromDate.timeIntervalSince1970),
            to: Int(toDate.timeIntervalSince1970)) else { return [:] }
        var maxPerBucket: [Int: Int] = [:]
        for row in rows {
            maxPerBucket[row.bucketStart] = max(maxPerBucket[row.bucketStart] ?? 0, row.coverageSeconds)
        }
        var byDay: [String: Int] = [:]
        for (bucketStart, seconds) in maxPerBucket where seconds > 0 {
            let day = Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(bucketStart)))
            byDay[day, default: 0] += seconds
        }
        return byDay
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
                                       elapsedSeconds: isToday ? now.timeIntervalSince(start) : duration)
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
                    sex: profile.sex)
    }
}
