import Foundation
import StrandAnalytics
import WhoopProtocol   // StepSample — the @57 counter + @63 activity class behind bucket movement
import WhoopStore

/// One five-minute bucket's movement read off the strap's step counter.
public typealias EnergyStepMovement = (steps: Int?, activityClass: Int?, covered: Bool, movementSeconds: Int)

/// Memo for the step-movement read, keyed by the window start. Each entry carries the key it was computed under:
/// window, read ids in order, ticks per step and the step owners' input revisions over the window. Reading a
/// day's raw step counter is most of an energy refresh; a finished day's counter does not move, so a repeat
/// refresh in the same process reads its revisions instead. Process-lifetime only; the app owns it.
public actor EnergyStepMovementCache {
    private var entries: [Int: (key: String, buckets: [Int: EnergyStepMovement])] = [:]

    public init() {}

    func buckets(from: Int, key: String) -> [Int: EnergyStepMovement]? {
        guard let cached = entries[from], cached.key == key else { return nil }
        return cached.buckets
    }

    func store(_ buckets: [Int: EnergyStepMovement], from: Int, key: String, maxEntries: Int) {
        entries[from] = (key: key, buckets: buckets)
        if entries.count > maxEntries, let oldest = entries.keys.min() { entries.removeValue(forKey: oldest) }
    }
}

/// The energy model's refresh over a window of whole local days (moved from `Repository`, Android plan B3 step 4):
/// prices every five-minute bucket from heart rate, the step counter, sleep, wear and workouts, writes the window
/// atomically, and refits the Watch calibration when it is on. The app passes the wearer's profile, its fitness
/// settings and its merged daily rows, and publishes the result.
public enum EnergyModelRefresh {
    /// The widest window a refresh reads, in days.
    public static let refreshMaxDays = 120
    /// The shortest window the Watch calibration is refitted from.
    public static let calibrationFitMinimumDays = 30

    /// What a refresh reads from the app besides the store.
    public struct Inputs: Sendable {
        /// The merged daily rows the app shows (imported over computed); each day's resting rate is the
        /// median of the fourteen before it.
        public var dailyRows: [DailyMetric]
        public var manualVO2: PeakMETResolver.ManualEntry?
        public var activityLevelOverride: JurcaFitness.ActivityLevel?
        public var calibrationEnabled: Bool
        public var refreshMaxDays: Int
        public var dismissedDetectedSpans: [String]
        /// The newest day with a priced aerobic ceiling before this refresh.
        public var latestPeakMET: (day: String, peakMET: Double)?

        public init(dailyRows: [DailyMetric], manualVO2: PeakMETResolver.ManualEntry?,
                    activityLevelOverride: JurcaFitness.ActivityLevel?, calibrationEnabled: Bool,
                    refreshMaxDays: Int, dismissedDetectedSpans: [String],
                    latestPeakMET: (day: String, peakMET: Double)?) {
            self.dailyRows = dailyRows; self.manualVO2 = manualVO2
            self.activityLevelOverride = activityLevelOverride; self.calibrationEnabled = calibrationEnabled
            self.refreshMaxDays = refreshMaxDays; self.dismissedDetectedSpans = dismissedDetectedSpans
            self.latestPeakMET = latestPeakMET
        }
    }

    /// How a refresh ended.
    public struct Outcome: Sendable {
        /// False when the store could not take the window.
        public let ok: Bool
        public let latestPeakMET: (day: String, peakMET: Double)?
        /// The window was replaced, so the app should republish its energy screens.
        public let wroteWindow: Bool
    }

    typealias EnergyWorkoutInterval = (start: Int, end: Int, kind: EnergyWorkoutKind,
                                       onFoot: Bool, tableMET: Double)

    /// The body fat in force on a day, for Katch–McArdle; a resolver that answers nil without reading
    /// anything for every other formula.
    static func bodyFatResolver(reader: StoreReader, for formula: BasalFormula) async -> (String) -> Double? {
        guard formula.needsBodyFat else { return { _ in nil } }
        let metrics = await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: 4_000)
        return { metrics.asOf("body_fat", day: $0)?.value }
    }

    public static func perform(reader: StoreReader, days: Int, profile: UserProfile, now: Date,
                               inputs given: Inputs, stepCache: EnergyStepMovementCache) async -> Outcome {
        let store = reader.store
        let deviceId = reader.activeDeviceId
        var latestEnergyPeakMET = given.latestPeakMET
        let calendar = Calendar.current
        // Callers may request a current-day repair after a model-version upgrade. Calibration still
        // enforces its own seven-day minimum when fitting, so forcing every refresh to read at least
        // seven days only made the Energy detail screen unnecessarily block on raw movement history.
        //
        // Whole local days only: `days` calendar days ending today, from the first one's midnight.
        // The window used to start at `now - days`, mid-day, and `replaceWhoopEnergyWindow` replaces
        // each day it is handed WHOLESALE — so the oldest day was rewritten from its afternoon alone
        // on every refresh, losing its morning's buckets and part of its total.
        let fromDate = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: now) ?? now)
        let from = Int(fromDate.timeIntervalSince1970)
        let to = Int(now.timeIntervalSince1970) + 1
        let hr = await reader.hrBuckets(from: from, to: to, bucketSeconds: 300)
            .filter { $0.bpm.isFinite && $0.conf >= 0.5 }
        guard !hr.isEmpty else { return Outcome(ok: true, latestPeakMET: latestEnergyPeakMET, wroteWindow: false) }

        // The weight and VO2max histories are read over the FULL window's span whatever `days` is. Both feed
        // resolvers that look at every reading they are handed (the causal weight trend, the freshest Apple
        // VO2max), so a shorter read gave a short refresh a different weight and aerobic ceiling for the same
        // day than the full 120-day refresh: 210.8 against 211.2 kg on a real store. At the full window this
        // reads exactly what it always read.
        let historyDays = max(days, given.refreshMaxDays)
        let weightDays = max(historyDays + 100, 100)
        let observations = await WeightSeries.series(
            reader: reader, from: StoreReader.localDayKey(Date().addingTimeInterval(-Double(weightDays) * 86_400)),
            to: StoreReader.localDayKey(Date().addingTimeInterval(86_400))).compactMap { point in
            WeightSeries.date(forDay: point.day).map {
                CausalWeightObservation(timestamp: Int($0.timeIntervalSince1970),
                                        weightKg: point.value,
                                        source: point.source == .manual ? .manual : .health)
            }
        }
        let maximumHR = profile.maxHR
            ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        let sleepIntervals = await sleepIntervals(reader: reader, from: from, to: to)
        let offWristIntervals = await offWristIntervals(reader: reader, from: from, to: to)
        let workoutIntervals = await workoutIntervals(reader: reader, from: from, to: to,
                                                      dismissedDetectedSpans: given.dismissedDetectedSpans)
        let bodyFatOn = await bodyFatResolver(reader: reader, for: profile.basalFormula)

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
            deviceId: MetricResolver.appleHealthSource, from: strideFrom, to: to)) ?? []
        var strideSamplesByDay: [String: [Double]] = [:]
        for row in strideRows {
            guard let stride = row.strideM else { continue }
            let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.bucketStart)))
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
        // Pass 1 builds every day's inputs and reads off its activity evidence; pass 2 prices each
        // day with the aerobic ceiling that evidence implies. Two passes because a day's Jurca
        // category includes the day itself, and the evidence does not depend on the ceiling (a workout
        // qualifies by heart-rate reserve, movement by pace), so pricing without one is enough to read it.
        // Oldest first, so each day's category sees the days before it.
        struct PreparedDay {
            let day: String
            let profile: UserProfile
            let weightSource: WhoopDailyEnergyRow.WeightSource
            let inputs: [WhoopEnergyBucket]
            let restingHR: Double?
        }
        var prepared: [PreparedDay] = []
        var evidence: [DailyActivityEvidence] = []
        let hrByDay = Dictionary(grouping: hr, by: { StoreReader.localDayKey(
            Date(timeIntervalSince1970: TimeInterval($0.ts))) })
        for (day, rows) in hrByDay.sorted(by: { $0.key < $1.key }) {
            var dayProfile = profile
            dayProfile.bodyFatPercent = bodyFatOn(day)
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
            let movement = await stepMovementByBucket(reader: reader, from: dayFrom, to: dayTo, profile: profile,
                                                      cache: stepCache)
            // Resolved once per day, never per bucket: the readings are per walking bout, so most
            // buckets hold none and a per-bucket lookup would jitter between measured and assumed
            // depending on where a sample happened to fall.
            let dayStrideM = strideTimeline.estimate(onDay: day)?.metersPerStep
            let hrByStart = Dictionary(rows.map { ($0.ts, $0) }, uniquingKeysWith: { a, _ in a })
            // This day's own buckets only. The movement read starts one bucket early (a step delta needs
            // its predecessor), so it also returns the previous day's 23:55 bucket; kept, that bucket was
            // priced into both days and written under both, and the second write broke the window's
            // unique key, which rolled back every multi-day refresh.
            let bucketStarts = Set(hrByStart.keys).union(movement.keys)
                .filter { $0 >= dayFrom && $0 < dayTo }.sorted()
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
                    workoutOnFoot: workout?.onFoot ?? false, workoutTableMET: workout?.tableMET,
                    isSleep: Self.contains(midpoint, in: sleepIntervals),
                    isOffWrist: Self.contains(midpoint, in: offWristIntervals),
                    hasMovementCoverage: move?.covered == true,
                    movementSeconds: move?.movementSeconds ?? 0)
            }
            for input in inputs { bucketInputs[input.start] = input }
            let priorResting = given.dailyRows.filter { $0.day < day }.compactMap(\.restingHr)
                .suffix(14).map(Double.init).sorted()
            let restingHR = priorResting.isEmpty ? nil : priorResting[priorResting.count / 2]
            guard let unpriced = WhoopEnergyModel.estimate(
                buckets: inputs, profile: dayProfile, restingHR: restingHR,
                maxHR: maximumHR, flexHR: restingHR.map { $0 + 20 }) else { continue }
            evidence.append(DailyActivityEvidence(day: day, aerobicSeconds: unpriced.aerobicSeconds,
                                                  hadLightActivity: unpriced.hadLightActivity))
            prepared.append(PreparedDay(day: day, profile: dayProfile, weightSource: weightSource,
                                        inputs: inputs, restingHR: restingHR))
        }

        // Evidence for the four weeks before the window, from this generation's stored days; older
        // generations never recorded it and would read as inactive weeks.
        if let firstDay = prepared.first?.day {
            let lookback = WeeklyDigestEngine.addDays(firstDay, -PeakMETResolver.activityWindowDays)
            let stored = (try? await store.whoopDailyEnergy(
                deviceId: deviceId, from: lookback, to: WeeklyDigestEngine.addDays(firstDay, -1))) ?? []
            evidence += stored.filter { $0.modelVersion == WhoopDailyEnergyEstimate.modelVersion }.map {
                DailyActivityEvidence(day: $0.day, aerobicSeconds: $0.aerobicSeconds,
                                      hadLightActivity: $0.hadLightActivity)
            }
        }
        let vo2Days = historyDays + PeakMETResolver.appleFreshnessDays
        let appleVO2 = await reader.series(
            key: "vo2max", source: MetricResolver.appleHealthSource,
            from: StoreReader.localDayKey(Date().addingTimeInterval(-Double(vo2Days) * 86_400)),
            to: StoreReader.localDayKey(Date().addingTimeInterval(86_400)), suppressedSleepWakeDays: [])
            .map { VO2maxReading(day: $0.day, value: $0.value, segment: MetricResolver.appleHealthSource) }
        let manualVO2 = given.manualVO2
        let levelOverride = given.activityLevelOverride
        func weightOnDay(_ day: String) -> Double? {
            guard let date = WeightSeries.date(forDay: day) else { return nil }
            return CausalWeightResolver.weight(at: Int(date.timeIntervalSince1970 + 43_200),
                                               observations: observations, calendar: calendar)
        }

        for entry in prepared {
            let day = entry.day
            let dayProfile = entry.profile
            let restingHR = entry.restingHR
            let level = levelOverride ?? PeakMETResolver.activityLevel(for: day, evidence: evidence)
            let ceiling = PeakMETResolver.resolve(
                day: day, profile: dayProfile, restingHR: restingHR, manual: manualVO2,
                apple: appleVO2, weightOnDay: weightOnDay, activityLevel: level)
            guard let estimate = WhoopEnergyModel.estimate(
                buckets: entry.inputs, profile: dayProfile, restingHR: restingHR,
                maxHR: maximumHR, flexHR: restingHR.map { $0 + 20 },
                peakMET: ceiling?.peakMET) else { continue }
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
                weightKg: dayProfile.weightKg, weightSource: entry.weightSource,
                aerobicSeconds: estimate.aerobicSeconds, hadLightActivity: estimate.hadLightActivity,
                peakMET: ceiling?.peakMET, peakMETSource: ceiling?.source.rawValue,
                peakMETSourceDay: ceiling?.sourceDay, measuredVO2max: ceiling?.measuredVO2max,
                measuredWeightKg: ceiling?.measuredWeightKg, activityLevel: ceiling?.activityLevel?.rawValue)
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
            if let peak = ceiling?.peakMET, day >= (latestEnergyPeakMET?.day ?? "") {
                latestEnergyPeakMET = (day, peak)
            }
        }

        // Daily totals and their hourly activity shape describe one model generation. Publish the
        // entire recomputed window in one SQLite transaction so a cancellation or write failure can
        // never expose half v3 / half v4 state.
        guard !pendingWindow.isEmpty else { return Outcome(ok: true, latestPeakMET: latestEnergyPeakMET, wroteWindow: false) }
        do {
            _ = try await store.replaceWhoopEnergyWindow(pendingWindow, deviceId: deviceId)
        } catch {
            return Outcome(ok: false, latestPeakMET: latestEnergyPeakMET, wroteWindow: false)
        }
        // The app publishes only after the atomic replacement succeeded, including every calibration exit below.
        let done = Outcome(ok: true, latestPeakMET: latestEnergyPeakMET, wroteWindow: true)

        // The Watch fit learns from the window it is handed. A short post-offload window holds a week or
        // two at most, and fitting it would replace a month's factor with a noisier one; it keeps the
        // stored model, and the Health-sync and full refreshes refit it as before.
        guard given.calibrationEnabled, days >= calibrationFitMinimumDays else { return done }
        let referenceRows = (try? await store.healthEnergyBuckets(
            deviceId: MetricResolver.appleHealthSource, from: from, to: to, eligibleOnly: true)) ?? []
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
        guard let chosenSource else { return done }
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
        guard let fit = EnergyCalibrationEngine.fit(points: points, calendar: calendar) else { return done }
        let model = EnergyCalibrationModelRow(
            deviceId: deviceId, referenceDeviceId: chosenSource, enabled: true,
            factor: fit.factor, sampleDays: fit.sampleDays, sampleBuckets: fit.sampleBuckets,
            coefficientOfVariation: fit.coefficientOfVariation,
            fittedAt: Int(now.timeIntervalSince1970), modelVersion: EnergyCalibrationFit.modelVersion)
        _ = try? await store.saveEnergyCalibrationModel(model)
        return done
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
    static func stepMovementByBucket(
        reader: StoreReader, from: Int, to: Int, profile: UserProfile, cache: EnergyStepMovementCache
    ) async -> [Int: EnergyStepMovement] {
        let store = reader.store
        // The memo key: everything the result depends on. Revisions are per UTC day over the read window,
        // so any step write that could move this window's buckets (or a device-wide invalidation) changes
        // it; a probe that fails leaves no key and the window is read as before.
        let ids = reader.importedReadIds
        var revisions: [String] = []
        for id in ids {
            guard let revision = try? await store.analysisInputRevision(deviceId: id, from: from - 300, to: to) else {
                revisions.removeAll(); break
            }
            revisions.append("\(id):\(revision.inputRevision):\(revision.deviceRevision)")
        }
        let key = revisions.count == ids.count
            ? "\(from)|\(to)|\(profile.stepTicksPerStep)|" + revisions.joined(separator: ",") : nil
        if let key, let cached = await cache.buckets(from: from, key: key) { return cached }

        var samples: [StepSample] = []
        for id in ids {   // active strap FIRST, mirroring strapStepTicks
            let rows = (try? await store.stepSamples(deviceId: id, from: from - 300, to: to,
                                                     limit: Int.max)) ?? []
            if StepsCounter.stepsInWindow(rows) != nil { samples = rows; break }
        }
        let buckets = samples.count >= 2
            ? Self.bucketStepMovement(samples, ticksPerStep: profile.stepTicksPerStep) : [:]
        if let key {
            // One entry per day start; the oldest has left every window. Bounded for a process that runs
            // for weeks, and for day starts a time-zone change orphaned.
            await cache.store(buckets, from: from, key: key, maxEntries: refreshMaxDays + 2)
        }
        return buckets
    }

    /// Pure bucketing of a day's step samples, split out (like `latestActivityClass`) so the delta and
    /// gap rules are unit-testable without a store.
    public static func bucketStepMovement(
        _ samples: [StepSample], ticksPerStep: Double
    ) -> [Int: EnergyStepMovement] {
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

    static func sleepIntervals(reader: StoreReader, from: Int, to: Int) async
        -> [(start: Int, end: Int)] {
        var rows: [CachedSleepSession] = []
        for id in reader.computedReadIds + reader.importedReadIds {
            rows += (try? await reader.store.sleepSessions(deviceId: id, from: from - 43_200,
                                                     to: to, limit: 10_000)) ?? []
        }
        return rows.map { (start: $0.effectiveStartTs, end: $0.endTs) }
            .filter { $0.end > $0.start }
    }

    static func offWristIntervals(reader: StoreReader, from: Int, to: Int) async
        -> [(start: Int, end: Int)] {
        // Two days of lead-in, as the workout intervals use: a strap taken off before the window opens is
        // otherwise seen only by its WRIST_ON, which closes nothing, so a short refresh priced the first
        // hours of its window as worn while the full refresh, whose window held the WRIST_OFF, did not.
        for id in reader.importedReadIds {
            let events = (try? await reader.store.events(deviceId: id, from: from - 2 * 86_400, to: to,
                                                  limit: 100_000)) ?? []
            let intervals = AnalyticsEngine.offWristIntervals(events: events, windowEnd: to)
            if !intervals.isEmpty { return intervals }
        }
        return []
    }

    /// The sessions whose five-minute buckets the model prices as a confirmed workout.
    ///
    /// Read through `rawWorkoutRows`, the same union the Workouts list, the burn-rate bands and the
    /// day's logged activity read, rather than a list of storage namespaces of its own. The private
    /// list this replaced had drifted: it lacked the native training tables (every session the
    /// in-app strength logger or the FitNotes/Strong import produced), the Hevy API namespace and any
    /// retained strap other than the active and canonical ones, and it still counted detector bouts
    /// the wearer had dismissed. A native lifting session was therefore priced as elevated heart
    /// rate with no activity — zero active kcal — under a band the chart labelled as training.
    ///
    /// Two days of lead-in, as `energyDayRate` uses, so a session that started before the window
    /// still marks the buckets it reaches.
    static func workoutIntervals(reader: StoreReader, from: Int, to: Int,
                                 dismissedDetectedSpans: [String]) async -> [EnergyWorkoutInterval] {
        let rows = WorkoutSource.dedupCrossSource(
            await reader.rawWorkoutRows(from: from - 2 * 86_400, to: to, dismissedDetectedSpans: dismissedDetectedSpans))
        return rows.filter { $0.endTs > $0.startTs && $0.endTs > from && $0.startTs < to }.map {
            (start: $0.startTs, end: $0.endTs, kind: EnergyWorkoutKind.forSport($0.sport),
             onFoot: EnergyWorkoutKind.isOnFoot(sport: $0.sport),
             tableMET: ActivityMETCatalog.met(forSport: $0.sport))
        }
    }

    static func contains(_ timestamp: Int,
                    in intervals: [(start: Int, end: Int)]) -> Bool {
        intervals.contains { $0.start <= timestamp && timestamp < $0.end }
    }

    static func energyInterval(at timestamp: Int,
                                                   in intervals: [EnergyWorkoutInterval])
        -> EnergyWorkoutInterval? {
        intervals.first { $0.start <= timestamp && timestamp < $0.end }
    }

    static func energyContextJSON(_ values: [EnergyContext: Int]) -> String {
        let object = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
