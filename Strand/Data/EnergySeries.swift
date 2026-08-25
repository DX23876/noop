import Foundation
import StrandAnalytics
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
        let derivedRows = (try? await store?.whoopDailyEnergy(
            deviceId: deviceId, from: cutoff, to: todayKey)) ?? []
        let derivedByDay = Dictionary(derivedRows.map { ($0.day, $0) },
                                      uniquingKeysWith: { _, b in b })
        let calibration = await energyCalibrationState(store: store)
        let calibrationFactor = calibration.status == .active ? calibration.factor : nil

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
            let inputs = EnergyEngine.DayInputs(
                day: day,
                appleActiveKcal: apple?.activeKcal,
                appleBasalKcal: apple?.basalKcal,
                strapTotalKcal: derived?.rawTotalKcal ?? strap?.activeKcalEst,
                strapCoverageSeconds: strap?.energyCoverageSeconds ?? derived?.observedSeconds,
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
                context: Self.energyDayContext(day: day, now: now, calendar: calendar))
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
            let inputs = rows.map {
                WhoopEnergyBucket(start: $0.ts,
                                  durationSeconds: min(300, max(1, $0.sampleSeconds)),
                                  averageHR: $0.bpm)
            }
            guard let estimate = WhoopEnergyModel.estimate(
                buckets: inputs, profile: dayProfile, restingHR: restingHR,
                maxHR: maximumHR) else { continue }
            for bucket in estimate.buckets { bucketResults[bucket.start] = bucket }
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
        let candidates = referenceRows.filter {
            (($0.activeKcal ?? 0) + ($0.basalKcal ?? 0)) > 0 && $0.coverageSeconds > 0
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
            guard row.sourceId == chosenSource, let whoop = bucketResults[row.bucketStart],
                  let hrBucket = hrByStart[row.bucketStart] else { return nil }
            let apple = ((row.activeKcal ?? 0) + (row.basalKcal ?? 0))
                / Double(row.coverageSeconds) * 300
            let normalizedWhoop = whoop.kcal / Double(max(1, hrBucket.sampleSeconds)) * 300
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
