import Foundation
import StrandAnalytics
import WhoopStore

/// Shared store reads used by the energy summary and by goals that count active energy. Source ids,
/// coverage deduplication and step-length history remain the same on every platform.
public enum EnergySummaryStoreReads {
    public static func stepHours(reader: StoreReader, days: Int, now: Date) async -> [String: [Int]] {
        let store = reader.store
        let calendar = Calendar.current
        let fromDate = calendar.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        let toDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let from = Int(fromDate.timeIntervalSince1970)
        let to = Int(toDate.timeIntervalSince1970)
        guard let rows = try? await store.appleStepHours(deviceId: MetricResolver.appleHealthSource,
                                                         fromTs: from, toTs: to) else { return [:] }
        var byDay: [String: Set<Int>] = [:]
        for row in rows where row.steps > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(row.ts))
            let hour = Calendar.current.component(.hour, from: date)
            byDay[StoreReader.localDayKey(date), default: []].insert(hour)
        }
        return byDay.mapValues { $0.sorted() }
    }

    public static func appleReference(reader: StoreReader, days: Int, now: Date) async
        -> (coverage: [String: Int], stride: StepLengthTimeline) {
        let store = reader.store
        let calendar = Calendar.current
        let fromDate = calendar.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        let toDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        guard let rows = try? await store.healthEnergyBuckets(
            deviceId: MetricResolver.appleHealthSource,
            from: Int(fromDate.timeIntervalSince1970),
            to: Int(toDate.timeIntervalSince1970)) else {
            return ([:], StepLengthTimeline(samplesByDay: [:]))
        }
        var maxPerBucket: [Int: Int] = [:]
        var strideSamplesByDay: [String: [Double]] = [:]
        for row in rows {
            maxPerBucket[row.bucketStart] = max(maxPerBucket[row.bucketStart] ?? 0, row.coverageSeconds)
            if let stride = row.strideM {
                let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.bucketStart)))
                strideSamplesByDay[day, default: []].append(stride)
            }
        }
        var byDay: [String: Int] = [:]
        for (bucketStart, seconds) in maxPerBucket where seconds > 0 {
            let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(bucketStart)))
            byDay[day, default: 0] += seconds
        }
        return (byDay, StepLengthTimeline(samplesByDay: strideSamplesByDay))
    }

    public static func activityShape(reader: StoreReader, now: Date) async -> ActivityShape? {
        let store = reader.store
        let calendar = Calendar.current
        guard let firstDate = calendar.date(byAdding: .day,
                                            value: -ActivityShapeEngine.maximumWindowDays,
                                            to: now) else { return nil }
        // Yesterday is the last COMPLETE day. Today is still accruing, and a half-finished day would
        // teach the curve that this person stops being active at whatever time it currently is.
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
        let rows = (try? await store.whoopEnergyHours(deviceId: reader.activeDeviceId,
                                                      from: StoreReader.localDayKey(firstDate),
                                                      to: StoreReader.localDayKey(yesterday))) ?? []
        let daily = (try? await store.whoopDailyEnergy(deviceId: reader.activeDeviceId,
                                                       from: StoreReader.localDayKey(firstDate),
                                                       to: StoreReader.localDayKey(yesterday))) ?? []
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

    /// Complete active-energy inputs for a goal window. Activity shape and adaptive expenditure affect
    /// forecasts only, so they are not read for an accessor that returns measured/modelled active kcal.
    /// The host supplies today's normal repair gate, preserving its once-per-day/session policy.
    @MainActor
    public static func activeEnergyByDay(reader: StoreReader, days: Int, dailyRows: [DailyMetric],
        workouts: [WorkoutRow], profile: UserProfile, hrMax: Double?, calibrationEnabled: Bool,
        now: Date, refreshToday: () async -> Void) async -> [String: Double] {
        EnergySummaryPreparation.activeValues(await summaries(reader: reader, days: days, dailyRows: dailyRows,
            workouts: workouts, profile: profile, hrMax: hrMax, calibrationEnabled: calibrationEnabled, now: now,
            shape: nil, adaptivePrior: nil, refreshToday: refreshToday))
    }

    /// The day summaries over the stored inputs, as `Repository.energySummaries` assembles them on Apple. The
    /// activity shape and the balance prior shape the forecast only; a measured-only reader passes nil.
    @MainActor
    public static func summaries(reader: StoreReader, days: Int, dailyRows: [DailyMetric],
        workouts: [WorkoutRow], profile: UserProfile, hrMax: Double?, calibrationEnabled: Bool,
        now: Date, shape: ActivityShape?, adaptivePrior: Double?,
        refreshToday: () async -> Void) async -> [DailyEnergySummary] {
        let calendar = Calendar.current
        let today = StoreReader.localDayKey(now)
        let cutoffDate = calendar.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        let cutoff = StoreReader.localDayKey(cutoffDate)
        let to = StoreReader.localDayKey(now.addingTimeInterval(86_400))
        let store = reader.store
        let appleRows = (try? await store.appleDaily(deviceId: MetricResolver.appleHealthSource,
            from: StoreReader.localDayKey(now.addingTimeInterval(-Double(days) * 86_400)), to: to)) ?? []
        let appleByDay = Dictionary(appleRows.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        let strapByDay = Dictionary(dailyRows.filter { $0.day >= cutoff }.map { ($0.day, $0) },
                                     uniquingKeysWith: { _, b in b })
        func derivedRows() async -> [String: WhoopDailyEnergyRow] {
            let rows = ((try? await store.whoopDailyEnergy(deviceId: reader.activeDeviceId, from: cutoff, to: today)) ?? [])
                .filter { $0.modelVersion == WhoopDailyEnergyEstimate.modelVersion }
            return Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        }
        var derived = await derivedRows()
        if derived[today] == nil {
            await refreshToday()
            derived = await derivedRows()
        }
        let weights = await WeightSeries.series(reader: reader,
            from: StoreReader.localDayKey(now.addingTimeInterval(-Double(max(days + 100, 100)) * 86_400)), to: to)
        let observations = weights.compactMap { point in
            WeightSeries.date(forDay: point.day).map {
                CausalWeightObservation(timestamp: Int($0.timeIntervalSince1970), weightKg: point.value,
                                       source: point.source == .manual ? .manual : .health)
            }
        }
        let body = profile.basalFormula.needsBodyFat
            ? await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: 4000)
            : BodyMetrics(readings: [:])
        let calibration = try? await store.energyCalibrationModel(deviceId: reader.activeDeviceId)
        let status: EnergyCalibrationStatus
        let factor: Double?
        if let calibration {
            let active = calibrationEnabled && calibration.enabled && calibration.modelVersion == EnergyCalibrationFit.modelVersion
            status = active ? .active : (calibrationEnabled ? .learning : .paused)
            factor = active ? calibration.factor : nil
        } else {
            status = calibrationEnabled ? .learning : .off
            factor = nil
        }
        var active: [String: Double] = [:]
        for row in (try? await store.whoopEnergyHours(deviceId: reader.activeDeviceId, from: cutoff, to: today)) ?? [] {
            active[row.day, default: 0] += row.activeKcal
        }
        var sessions: [String: [WorkoutRow]] = [:]
        for row in workouts where row.endTs > row.startTs {
            let start = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            let end = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.endTs - 1)))
            sessions[start, default: []].append(row)
            if end != start { sessions[end, default: []].append(row) }
        }
        let hours = await stepHours(reader: reader, days: days, now: now)
        let apple = await appleReference(reader: reader, days: days, now: now)
        let source = EnergySummaryPreparation.Inputs(appleByDay: appleByDay, strapByDay: strapByDay,
            derivedByDay: derived, strapActiveByDay: active, stepHoursByDay: hours, sessionsByDay: sessions,
            weightObservations: observations, calibrationStatus: status, calibrationFactor: factor,
            shape: shape, adaptivePrior: adaptivePrior, appleCoverageByDay: apple.coverage, stride: apple.stride)
        return EnergySummaryPreparation.summaries(source, profile: profile, hrMax: hrMax, now: now,
            calendar: calendar, bodyFatOn: { body.asOf("body_fat", day: $0)?.value })
    }

}
