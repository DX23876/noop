import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import StrandCore

/// The measured cardiovascular work attached to one canonical training session. TRIMP is additive;
/// Effort is its familiar 0–100 presentation and must never be summed across sessions.
extension Repository {

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
        await priceCardioSessions(sessions, budget: CardioLoadPricing.cardioLoadSessionBudget, recompute: false).resolution
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

    /// The cardio lane's room today (`LaneOutlook.headroom`), read over exactly the history a reading
    /// depends on — what the Coach checks a planned session against.
    func cardioRoomToday() async -> LaneHeadroom? {
        let sessions = await trainingSessions(days: TrainingLoadLanes.lookbackDays).sessions
        let resolution = await cardioLoads(for: sessions)
        let offset = TimeZone.current.secondsFromGMT()
        let series = TrainingLoadLanes.cardioSeries(sessions: sessions, resolution: resolution, tzOffsetSeconds: offset)
        return LaneOutlook.headroom(dailyByDay: series.byDay, unknownDays: series.unknownDays,
                                    activity: series.activity, lane: .cardio, today: Repository.localDayKey(Date()))
    }

    /// Ledger rows priced with a different HR maximum than the current one — what the "recalculate
    /// history" action would change. A changed HR max never rewrites history on its own.
    func cardioLoadRowsWithOtherHRmax() async -> Int {
        guard let store = await storeHandle() else { return 0 }
        let current = Self.cardioLoadMaxHR(strainProfile)
        let rows = (try? await store.trainingSessionLoads(
            from: 0, to: Int.max, method: CardioLoadPricing.cardioLoadMethod,
            methodVersion: CardioLoadPricing.cardiovascularLoadRecipeVersion)) ?? []
        return rows.filter { $0.trimp != nil && abs($0.hrmaxUsed - current) >= 0.5 }.count
    }

    /// Recomputes every stored load with the current HR maximum, wherever the heart rate is still
    /// there. A session whose raw heart rate is gone keeps its row as it was: history that cannot be
    /// recomputed is never thrown away.
    func recomputeCardioLoadHistory() async {
        let sessions = await trainingSessions(days: TrainingHistoryWindow.allDays).sessions
        _ = await priceCardioSessions(sessions, budget: Int.max, recompute: true)
        await cardioLoadCache.removeAll()
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

    /// The shared pricing pass (`CardioLoadPricing.price`). `recompute` ignores the ledger's answers (while
    /// keeping any row whose raw heart rate can no longer be read); otherwise final rows answer and only the
    /// rest is computed.
    private func priceCardioSessions(_ sessions: [UnifiedTrainingSession], budget initialBudget: Int,
                                     recompute: Bool) async -> (resolution: TrainingCardioLoadResolution, computed: Int) {
        let maxHR = Self.cardioLoadMaxHR(strainProfile)
        let sex = strainProfile?.sex ?? ""
        let reader = await storeHandle().map(storeReader)
        return await CardioLoadPricing.price(sessions, reader: reader, maxHR: maxHR, sex: sex,
                                             dataRevision: refreshSeq, cache: cardioLoadCache,
                                             budget: initialBudget, recompute: recompute)
    }

    // MARK: - Ledger rows

    /// Time in each heart-rate zone across a set of sessions, in minutes (`CardioLoadPricing`). Zones come from
    /// the CALLER's zone set (`ProfileStore.hrZoneSet`); nil when nothing in the window carried a usable trace.
    func sessionZoneMinutes(for sessions: [UnifiedTrainingSession], zoneSet: HRZoneSet,
                            duplicates: Set<String> = []) async -> CardioZoneSplit? {
        let reader = await storeHandle().map(storeReader)
        return await CardioLoadPricing.sessionZoneMinutes(for: sessions, reader: reader, zoneSet: zoneSet,
                                                          duplicates: duplicates)
    }

}
