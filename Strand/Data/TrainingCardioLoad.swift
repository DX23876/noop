import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The measured cardiovascular work attached to one canonical training session. TRIMP is additive;
/// Effort is its familiar 0–100 presentation and must never be summed across sessions.
struct TrainingCardioLoad: Equatable, Sendable {
    enum Source: String, Sendable {
        case noopBand = "noop_band", healthKitWorkout = "healthkit_workout"
        /// Estimated from the session's average heart rate (Banister's original form). Never a measured
        /// load: the history shows it marked as estimated, and no band or comparison reads it.
        case averageHeartRate = "avg_hr"
    }

    let sessionId: String
    let trimp: Double
    let effort: Double
    let source: Source
    let coveredMinutes: Int
    let possibleMinutes: Int

    var coverage: Double { possibleMinutes > 0 ? Double(coveredMinutes) / Double(possibleMinutes) : 0 }
}

/// What one pricing pass produced: the load per session, plus the sessions it deliberately did not
/// price because another session already described the same minutes of heart rate.
///
/// The distinction matters for the coverage line: a session skipped as a duplicate is not a session
/// with missing data, and counting it as one would report a gap the wearer cannot close.
struct TrainingCardioLoadResolution: Sendable {
    var loads: [String: TrainingCardioLoad] = [:]
    /// Sessions whose window was already priced by another session (an unresolved duplicate pair).
    var duplicateSessionIds: Set<String> = []
    /// Sessions left unpriced because the pass ran out of its heart-rate budget.
    var deferredSessionIds: Set<String> = []
    /// Sessions without a usable trace, estimated from their average heart rate. Kept apart from `loads`
    /// so nothing that compares or classifies load can read an estimate by accident.
    var estimates: [String: TrainingCardioLoad] = [:]

    /// Files a load where it belongs: a measured one in `loads`, an estimate in `estimates`.
    mutating func record(_ load: TrainingCardioLoad) {
        if load.source == .averageHeartRate { estimates[load.sessionId] = load } else { loads[load.sessionId] = load }
    }
}

/// How a period's training time was distributed across the heart-rate zones, and what that rests on.
///
/// The distribution is the question a weekly total cannot answer: 300 minutes of cardio is a different
/// week depending on whether it was all in zone 2 or half of it in zone 4. It is reported as measured
/// time, never as a verdict — the polarised and threshold models disagree about the ideal shape, and
/// which one applies depends on the sport, the season and the athlete.
struct CardioZoneSplit: Equatable, Sendable {
    /// Minutes in zones 1 through 5.
    let minutes: [Double]
    /// Sessions whose trace covered them well enough to bin.
    let sessionsRead: Int
    /// Sessions that could have contributed — the denominator the card must show beside the split.
    let sessionsPossible: Int
    /// True when any part of the split came from once-a-minute averages rather than a dense trace.
    let usedMinuteBuckets: Bool

    var total: Double { minutes.reduce(0, +) }
}

extension Repository {
    /// The version of `cardioLoadMethod`; bump it when that method's arithmetic changes. It is part of the
    /// ledger key and the in-memory memo key, so a new build cannot reuse a result produced by other
    /// semantics. Counted per method: a new method starts again at 1.
    nonisolated static let cardiovascularLoadRecipeVersion = 1
    /// Sessions shorter than this are not priced: a TRIMP over a couple of minutes is dominated by the
    /// ramp in and out, and the coverage rule below could not tell a real trace from two stray samples.
    nonisolated static let cardioLoadMinimumSeconds = 600
    /// How many sessions one pass will COMPUTE from raw heart rate. Each computation is its own indexed
    /// range read, so an unbounded pass over a decade of history would stall the screen it feeds. Loads
    /// already in the ledger cost no computation and do not count; the newest missing sessions are
    /// computed first, and `backfillCardioLoadLedger` fills the rest in the background.
    nonisolated static let cardioLoadSessionBudget = 300

    /// The method name stored with every ledger row. The version is `cardiovascularLoadRecipeVersion`.
    ///
    /// Banister's TRIMP over heart-rate reserve (P4, analysis recipe AI-9). Rows of the former
    /// `edwards-hrmax` method stay in the table untouched — history is never deleted — but are no longer
    /// read: the two methods have different scales, and one lane may not mix them.
    nonisolated static let cardioLoadMethod = "banister-hrr"
    /// Days either side of a session whose resting heart rates price it: the median of that week.
    nonisolated static let cardioLoadRestingWindowDays = 3
    /// How long after a session ends its heart rate may still change. A strap banks history and offloads
    /// it later, and a watch syncs its workout HR on its own schedule, so a load computed sooner is kept
    /// only as a provisional row and computed again; one computed after this is final.
    nonisolated static let cardioLoadFinalAfterSeconds = 7 * 86_400

    /// Resolve exactly one HR source per session. A sufficiently complete NOOP-band trace wins; only
    /// when it is absent do workout-associated HealthKit samples fill the session. Sources are never
    /// stitched, because a seam can double-count time or hide a recording gap.
    ///
    /// Overlapping sessions are priced ONCE. Two components the wearer has not yet ruled on stay
    /// separate on purpose (that is the duplicate review), but they describe the same minutes of heart
    /// rate, so adding both would double that day's cardio load until the review is answered.
    ///
    /// A final ledger row (`trainingSessionLoad`) answers without reading heart rate. Everything else is
    /// computed within the budget and written back, so the next read — and the long-term history — find it.
    func cardioLoads(for sessions: [UnifiedTrainingSession]) async -> TrainingCardioLoadResolution {
        await priceCardioSessions(sessions, budget: Self.cardioLoadSessionBudget, recompute: false).resolution
    }

    /// Computes up to `limit` sessions of the whole history that the ledger does not yet hold, newest
    /// first, and returns how many it computed. Resumable by construction: the rows it writes are what
    /// the next call skips, so calling it until it returns 0 fills the ledger.
    @discardableResult
    func backfillCardioLoadLedger(limit: Int = 200) async -> Int {
        let sessions = await trainingSessions(days: TrainingHistoryWindow.allDays).sessions
        return await priceCardioSessions(sessions, budget: limit, recompute: false).computed
    }

    /// Fills the ledger in portions at low priority, once at a time. Safe to call from every screen that
    /// reads cardio load; a call while a run is in flight joins nothing and returns.
    func scheduleCardioLoadBackfill() {
        guard cardioLoadBackfillTask == nil else { return }
        cardioLoadBackfillTask = Task(priority: .background) { [weak self] in
            while let self, !Task.isCancelled, await self.backfillCardioLoadLedger(limit: 200) > 0 {
                await Task.yield()
            }
            self?.cardioLoadBackfillTask = nil
        }
    }

    /// Re-reads the lanes behind `readinessLoadContext`, at most one read at a time: a request while one
    /// runs is remembered and served once it ends, so a burst of refreshes costs two reads, not many.
    func scheduleReadinessLoadContextRefresh() {
        guard readinessLoadContextTask == nil else {
            readinessLoadContextStale = true
            return
        }
        readinessLoadContextTask = Task(priority: .utility) { [weak self] in
            repeat {
                self?.readinessLoadContextStale = false
                await self?.refreshReadinessLoadContext()
            } while self?.readinessLoadContextStale == true && !Task.isCancelled
            self?.readinessLoadContextTask = nil
        }
    }

    /// Reads the lanes over exactly the history a reading depends on (`TrainingLoadLanes.lookbackDays`),
    /// and publishes only a changed context, so Today does not re-derive on an identical answer.
    func refreshReadinessLoadContext() async {
        let days = TrainingLoadLanes.lookbackDays
        async let fusedRead = trainingSessions(days: days)
        async let strengthRead = resolvedStrengthHistory(days: days)
        let sessions = await fusedRead.sessions
        let resolution = await cardioLoads(for: sessions)
        let workouts = await strengthRead.workouts
        let today = Repository.localDayKey(Date())
        let offset = TimeZone.current.secondsFromGMT()
        let context = await Task.detached(priority: .utility) {
            TrainingLoadLanes.readinessContext(
                strengthWorkouts: workouts,
                cardio: TrainingLoadLanes.cardioSeries(sessions: sessions, resolution: resolution,
                                                       tzOffsetSeconds: offset),
                today: today, tzOffsetSeconds: offset)
        }.value
        guard !Task.isCancelled, context != readinessLoadContext else { return }
        readinessLoadContext = context
    }

    /// Ledger rows priced with a different HR maximum than the current one — what the "recalculate
    /// history" action would change. A changed HR max never rewrites history on its own.
    func cardioLoadRowsWithOtherHRmax() async -> Int {
        guard let store = await storeHandle() else { return 0 }
        let current = Self.cardioLoadMaxHR(strainProfile)
        let rows = (try? await store.trainingSessionLoads(from: 0, to: Int.max, method: Self.cardioLoadMethod,
                                                           methodVersion: Self.cardiovascularLoadRecipeVersion)) ?? []
        return rows.filter { $0.trimp != nil && abs($0.hrmaxUsed - current) >= 0.5 }.count
    }

    /// Recomputes every stored load with the current HR maximum, wherever the heart rate is still
    /// there. A session whose raw heart rate is gone keeps its row as it was: history that cannot be
    /// recomputed is never thrown away.
    func recomputeCardioLoadHistory() async {
        let sessions = await trainingSessions(days: TrainingHistoryWindow.allDays).sessions
        _ = await priceCardioSessions(sessions, budget: Int.max, recompute: true)
        cardioLoadMemo.removeAll()
        cardioLoadUnpriceable.removeAll()
    }

    /// Fills the whole ledger with the current method, newest first — the migration for analysis recipe
    /// AI-9. Resumable by construction: an interrupted run leaves the rows it wrote, and the next run
    /// computes only what is still missing. Rows of the former method are left in place, unread.
    func fillCardioLoadLedger() async {
        while !Task.isCancelled, await backfillCardioLoadLedger(limit: 200) > 0 {
            await Task.yield()
        }
        scheduleReadinessLoadContextRefresh()
    }

    nonisolated static func cardioLoadMaxHR(_ profile: StrainProfile?) -> Double {
        // A missing strain profile must not blank the whole lane: the population default is what every
        // other unprofiled Effort path uses, and the figure is a comparison against the wearer's own
        // recent level rather than an absolute claim.
        profile?.hrMax ?? Double(StrainScorer.defaultMaxHR())
    }

    /// The shared pricing pass. `recompute` ignores the ledger's answers (while keeping any row whose raw
    /// heart rate can no longer be read); otherwise final rows answer and only the rest is computed.
    private func priceCardioSessions(_ sessions: [UnifiedTrainingSession], budget initialBudget: Int,
                                     recompute: Bool) async -> (resolution: TrainingCardioLoadResolution, computed: Int) {
        let maxHR = Self.cardioLoadMaxHR(strainProfile)
        let sex = strainProfile?.sex ?? ""
        let store = await storeHandle()
        let now = Int(Date().timeIntervalSince1970)
        var resolution = TrainingCardioLoadResolution()
        // Resting heart rate is read once, and only if something is actually computed: a pass the ledger
        // answers entirely should cost no daily-row read.
        var restingByDay: [String: Double]?

        // Newest first, and where two sessions describe the same window the better-evidenced one claims
        // it: more components first, then the longer window, then the id so the choice is deterministic.
        let ordered = sessions
            .filter { $0.row.endTs - $0.row.startTs >= Self.cardioLoadMinimumSeconds }
            .sorted { lhs, rhs in
                if lhs.row.startTs != rhs.row.startTs { return lhs.row.startTs > rhs.row.startTs }
                if lhs.components.count != rhs.components.count {
                    return lhs.components.count > rhs.components.count
                }
                let lhsSpan = lhs.row.endTs - lhs.row.startTs, rhsSpan = rhs.row.endTs - rhs.row.startTs
                if lhsSpan != rhsSpan { return lhsSpan > rhsSpan }
                return lhs.id < rhs.id
            }
        let ledger = (try? await store?.trainingSessionLoads(
            sessionIds: ordered.map(\.id), method: Self.cardioLoadMethod,
            methodVersion: Self.cardiovascularLoadRecipeVersion)) ?? [:]

        var priced: [(start: Int, end: Int)] = []
        var budget = initialBudget
        var computed = 0
        var written: [TrainingSessionLoadRow] = []
        for session in ordered {
            let start = session.row.startTs
            let end = session.row.endTs
            if priced.contains(where: { Self.describesSameMinutes($0, (start, end)) }) {
                resolution.duplicateSessionIds.insert(session.id)
                continue
            }
            let fingerprint = Self.cardioLoadFingerprint(session: session)
            let stored = ledger[session.id]
            if !recompute, let stored, Self.ledgerRowIsFinal(stored, fingerprint: fingerprint, sessionEnd: end) {
                if let load = Self.cardioLoad(from: stored) {
                    resolution.record(load)
                    priced.append((start, end))
                }
                continue
            }
            let memoKey = Self.cardioLoadMemoKey(session: session, maxHR: maxHR, sex: sex, dataRevision: refreshSeq)
            if !recompute, let memo = cardioLoadMemo[memoKey] {
                resolution.record(memo)
                priced.append((start, end))
                continue
            }
            if !recompute, cardioLoadUnpriceable.contains(memoKey) { continue }
            guard budget > 0 else {
                resolution.deferredSessionIds.insert(session.id)
                continue
            }
            budget -= 1
            computed += 1

            if restingByDay == nil {
                restingByDay = await restingHrByDay(
                    fromDay: Self.dayKey(ordered.last?.row.startTs ?? start, offsetDays: -30),
                    toDay: Self.dayKey(ordered.first?.row.endTs ?? end, offsetDays: 30))
            }
            let resting = Self.cardioLoadRestingHR(day: Self.dayKey(start, offsetDays: 0),
                                                   restingByDay: restingByDay ?? [:])
            let band = await hrSamples(from: start, to: end, limit: 20_000)
            var load = Self.makeCardioLoad(sessionId: session.id, samples: band,
                                           start: start, end: end, source: .noopBand,
                                           maxHR: maxHR, restingHR: resting, sex: sex)
            if load == nil, let store {
                let samples = await Self.healthKitMinuteTrace(for: session, store: store)
                load = Self.makeCardioLoad(sessionId: session.id, samples: samples,
                                           start: start, end: end, source: .healthKitWorkout,
                                           maxHR: maxHR, restingHR: resting, sex: sex)
            }
            if load == nil, recompute, let stored, let kept = Self.cardioLoad(from: stored),
               kept.source != .averageHeartRate {
                // The raw heart rate is gone; the stored answer is the only one left. Keep it untouched.
                resolution.record(kept)
                priced.append((start, end))
                continue
            }
            if load == nil {
                load = Self.averageHeartRateLoad(for: session, maxHR: maxHR, restingHR: resting, sex: sex)
            }
            written.append(Self.ledgerRow(for: session, load: load, fingerprint: fingerprint,
                                          maxHR: maxHR, restingHR: resting, computedAt: now))
            guard let load else {
                cardioLoadUnpriceable.insert(memoKey)
                continue
            }
            resolution.record(load)
            cardioLoadMemo[memoKey] = load
            priced.append((start, end))
        }
        if !written.isEmpty { try? await store?.upsertTrainingSessionLoads(written) }
        return (resolution, computed)
    }

    // MARK: - Ledger rows

    /// What a stored load was computed from. Deliberately NOT the HR maximum: a changed profile does not
    /// rewrite history on its own (it is recorded in `hrmaxUsed` and recomputed only on request), and not
    /// the data revision, which moves on every refresh. The window and the components are what make a
    /// different session out of the same id.
    nonisolated static func cardioLoadFingerprint(session: UnifiedTrainingSession) -> String {
        let components = session.components.map {
            "\($0.id):\($0.row.source):\($0.row.startTs):\($0.row.endTs)"
        }.sorted().joined(separator: ",")
        return "\(session.row.startTs)|\(session.row.endTs)|\(components)"
    }

    /// A row answers only for the same inputs, and only once it was computed late enough that the
    /// session's heart rate can no longer arrive (`cardioLoadFinalAfterSeconds`).
    nonisolated static func ledgerRowIsFinal(_ row: TrainingSessionLoadRow, fingerprint: String,
                                             sessionEnd: Int) -> Bool {
        row.inputFingerprint == fingerprint && row.computedAtTs >= sessionEnd + cardioLoadFinalAfterSeconds
    }

    nonisolated static func ledgerRow(for session: UnifiedTrainingSession, load: TrainingCardioLoad?,
                                      fingerprint: String, maxHR: Double, restingHR: Double?,
                                      computedAt: Int) -> TrainingSessionLoadRow {
        TrainingSessionLoadRow(sessionId: session.id, method: cardioLoadMethod,
                               methodVersion: cardiovascularLoadRecipeVersion,
                               startTs: session.row.startTs, endTs: session.row.endTs,
                               trimp: load?.trimp, effort: load?.effort,
                               hrSource: load?.source.rawValue ?? "none",
                               coveredMinutes: load?.coveredMinutes ?? 0,
                               possibleMinutes: load?.possibleMinutes ?? 0,
                               hrmaxUsed: maxHR, restingHrUsed: restingHR,
                               inputFingerprint: fingerprint, computedAtTs: computedAt)
    }

    /// The load a row stores, or nil for a row that records an unpriceable session.
    nonisolated static func cardioLoad(from row: TrainingSessionLoadRow) -> TrainingCardioLoad? {
        guard let trimp = row.trimp, let effort = row.effort,
              let source = TrainingCardioLoad.Source(rawValue: row.hrSource) else { return nil }
        return TrainingCardioLoad(sessionId: row.sessionId, trimp: trimp, effort: effort, source: source,
                                  coveredMinutes: row.coveredMinutes, possibleMinutes: row.possibleMinutes)
    }

    /// Every input that can change a session's result. Keeping the key builder testable makes stale
    /// reuse after an HR-max or profile edit, source switch, fusion change or data refresh detectable.
    /// Resting heart rate is covered by the data revision: it only changes when daily rows do.
    nonisolated static func cardioLoadMemoKey(session: UnifiedTrainingSession, maxHR: Double, sex: String = "",
                                              dataRevision: Int,
                                              recipeVersion: Int = cardiovascularLoadRecipeVersion) -> String {
        let components = session.components.map {
            "\($0.id):\($0.row.source):\($0.row.startTs):\($0.row.endTs)"
        }.sorted().joined(separator: ",")
        return "\(cardioLoadMethod)v\(recipeVersion)|r\(dataRevision)|hr\(maxHR)|\(sex)|\(session.id)|"
            + "\(session.row.startTs)|\(session.row.endTs)|\(components)"
    }

    /// The resting heart rate a session is priced with: the median of the recorded days within
    /// `cardioLoadRestingWindowDays` of it — the body that did the session, not today's. Widens to a month
    /// and then to every day read before falling back to the population default, so a session is never
    /// left unpriced for want of one night's reading. The value used is stored in the ledger row.
    nonisolated static func cardioLoadRestingHR(day: String, restingByDay: [String: Double]) -> Double {
        for radius in [cardioLoadRestingWindowDays, 30] {
            let values = (-radius...radius).compactMap { restingByDay[WeeklyDigestEngine.addDays(day, $0)] }
            if let median = median(values) { return median }
        }
        return median(Array(restingByDay.values)) ?? StrainScorer.defaultRestingHR
    }

    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Local day key `offsetDays` from a timestamp's day.
    nonisolated static func dayKey(_ ts: Int, offsetDays: Int) -> String {
        WeeklyDigestEngine.addDays(AnalyticsEngine.dayString(ts, offsetSec: TimeZone.current.secondsFromGMT()),
                                   offsetDays)
    }

    /// An estimate from the session's average heart rate, for a session whose trace could not be read.
    nonisolated static func averageHeartRateLoad(for session: UnifiedTrainingSession, maxHR: Double,
                                                 restingHR: Double, sex: String) -> TrainingCardioLoad? {
        guard let average = session.row.avgHr, average > 0 else { return nil }
        let seconds = session.row.durationS ?? Double(session.row.endTs - session.row.startTs)
        guard let trimp = StrainScorer.banisterAverageTRIMP(minutes: seconds / 60, averageHR: Double(average),
                                                            maxHR: maxHR, restingHR: restingHR, sex: sex)
        else { return nil }
        return TrainingCardioLoad(sessionId: session.id, trimp: trimp,
                                  effort: StrainScorer.banisterLaneEffort(trimp, sex: sex), source: .averageHeartRate,
                                  coveredMinutes: 0, possibleMinutes: max(1, Int(ceil(seconds / 60))))
    }

    /// True when two windows are the same bout: they overlap by more than half of the shorter one —
    /// the same test cross-source dedup uses, so the two layers cannot disagree about what a twin is.
    nonisolated static func describesSameMinutes(_ a: (start: Int, end: Int),
                                                 _ b: (start: Int, end: Int)) -> Bool {
        let overlap = min(a.end, b.end) - max(a.start, b.start)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(a.end - a.start, b.end - b.start))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    /// The minute-averaged trace HealthKit stored for a session, as heart-rate samples.
    ///
    /// HealthKit keeps one averaged value per minute for a workout, so each bucket is emitted twice
    /// thirty seconds apart — enough to give the minute its width for both TRIMP and time-in-zone, and
    /// not enough to resolve anything shorter, which is why every surface built on it says so.
    ///
    /// Both Apple Health spellings are read: early rows were stored as `apple_health`, and skipping them
    /// would silently drop this fallback for every workout imported back then.
    nonisolated static func healthKitMinuteTrace(for session: UnifiedTrainingSession,
                                                 store: WhoopStore) async -> [HRSample] {
        var byMinute: [Int: WorkoutHeartRateBucketRow] = [:]
        for component in session.components where WorkoutSource.isAppleHealth(component.row.source) {
            let rows = (try? await store.workoutHeartRateBuckets(componentKey: component.id)) ?? []
            for row in rows where byMinute[row.bucketStart] == nil { byMinute[row.bucketStart] = row }
        }
        return byMinute.values.sorted { $0.bucketStart < $1.bucketStart }.flatMap { bucket in
            [HRSample(ts: bucket.bucketStart, bpm: Int(bucket.bpm.rounded())),
             HRSample(ts: bucket.bucketStart + 30, bpm: Int(bucket.bpm.rounded()))]
        }
    }

    /// Minutes of the window a trace actually carries a reading for, and how many it could.
    nonisolated static func traceCoverage(_ samples: [HRSample], start: Int, end: Int)
    -> (covered: Int, possible: Int) {
        let possible = max(1, Int(ceil(Double(end - start) / 60.0)))
        let covered = Set(samples.filter { $0.ts >= start && $0.ts <= end }.map { ($0.ts - start) / 60 }).count
        return (covered, possible)
    }

    /// Whether a trace describes enough of a window to stand as that session's heart rate.
    ///
    /// One rule, shared by pricing and the zone split, so the two can never disagree about which
    /// sessions they were able to read.
    nonisolated static func hasUsableCoverage(_ samples: [HRSample], start: Int, end: Int) -> Bool {
        let coverage = traceCoverage(samples, start: start, end: end)
        return coverage.covered >= 10 && Double(coverage.covered) / Double(coverage.possible) >= 0.70
    }

    /// Time in each heart-rate zone across a set of sessions, in minutes.
    ///
    /// The SAME source rule as pricing: the band's own samples describe a session wherever they cover
    /// it, and only otherwise do HealthKit's minute buckets stand in. Sources are never stitched — here
    /// a seam would not merely blur a total, it would move minutes from one zone into another.
    ///
    /// Zones come from the CALLER's zone set and are never derived here. The app has one zone resolver
    /// (`ProfileStore.hrZoneSet`, which carries the wearer's own bands and any HR-max override); a
    /// second one would let the same heart rate read Zone 2 on one screen and Zone 3 on the next.
    ///
    /// Nil when nothing in the window carried a usable trace, so a screen shows nothing rather than five
    /// empty bars.
    func sessionZoneMinutes(for sessions: [UnifiedTrainingSession], zoneSet: HRZoneSet,
                            duplicates: Set<String> = []) async -> CardioZoneSplit? {
        let store = await storeHandle()
        var seconds = [Double](repeating: 0, count: 5)
        var read = 0
        var possible = 0
        var usedBuckets = false
        var budget = Self.cardioLoadSessionBudget
        var binned: [(start: Int, end: Int)] = []

        for session in sessions.sorted(by: { $0.row.startTs > $1.row.startTs }) {
            let start = session.row.startTs
            let end = session.row.endTs
            guard !duplicates.contains(session.id),
                  end - start >= Self.cardioLoadMinimumSeconds,
                  !binned.contains(where: { Self.describesSameMinutes($0, (start, end)) }) else { continue }
            possible += 1
            guard budget > 0 else { continue }
            budget -= 1

            var samples = await hrSamples(from: start, to: end, limit: 20_000)
            var fromBuckets = false
            if !Self.hasUsableCoverage(samples, start: start, end: end), let store {
                samples = await Self.healthKitMinuteTrace(for: session, store: store)
                fromBuckets = true
            }
            guard Self.hasUsableCoverage(samples, start: start, end: end) else { continue }

            let split = HRZones.timeInZone(samples, zoneSet: zoneSet)
            for index in 0..<min(seconds.count, split.seconds.count) { seconds[index] += split.seconds[index] }
            read += 1
            if fromBuckets { usedBuckets = true }
            binned.append((start, end))
        }

        guard read > 0, seconds.reduce(0, +) > 0 else { return nil }
        return CardioZoneSplit(minutes: seconds.map { $0 / 60 }, sessionsRead: read,
                               sessionsPossible: possible, usedMinuteBuckets: usedBuckets)
    }

    nonisolated static func makeCardioLoad(sessionId: String, samples: [HRSample],
                                           start: Int, end: Int,
                                           source: TrainingCardioLoad.Source,
                                           maxHR: Double, restingHR: Double, sex: String) -> TrainingCardioLoad? {
        let coverage = traceCoverage(samples, start: start, end: end)
        guard hasUsableCoverage(samples, start: start, end: end),
              let load = StrainScorer.banisterTrainingLoad(samples, maxHR: maxHR, restingHR: restingHR, sex: sex)
        else { return nil }
        return TrainingCardioLoad(sessionId: sessionId, trimp: load.trimp, effort: load.effort,
                                  source: source, coveredMinutes: coverage.covered,
                                  possibleMinutes: coverage.possible)
    }
}
