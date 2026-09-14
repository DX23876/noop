import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The measured cardiovascular work attached to one canonical training session. TRIMP is additive;
/// Effort is its familiar 0–100 presentation and must never be summed across sessions.
struct TrainingCardioLoad: Equatable, Sendable {
    enum Source: String, Sendable { case noopBand = "noop_band", healthKitWorkout = "healthkit_workout" }

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
    /// Bump whenever the read-time Training Load recipe changes. It is part of the in-memory memo key,
    /// so a new build cannot reuse a result produced by different zone or gap semantics.
    nonisolated static let cardiovascularLoadRecipeVersion = 1
    /// Sessions shorter than this are not priced: a TRIMP over a couple of minutes is dominated by the
    /// ramp in and out, and the coverage rule below could not tell a real trace from two stray samples.
    nonisolated static let cardioLoadMinimumSeconds = 600
    /// How many sessions one pass will read raw heart rate for. Each priced session is its own indexed
    /// range read, so an unbounded pass over a decade of history would stall the screen it feeds. The
    /// newest sessions are priced first, which is what every surface reading this actually shows.
    nonisolated static let cardioLoadSessionBudget = 300

    /// Resolve exactly one HR source per session. A sufficiently complete NOOP-band trace wins; only
    /// when it is absent do workout-associated HealthKit samples fill the session. Sources are never
    /// stitched, because a seam can double-count time or hide a recording gap.
    ///
    /// Overlapping sessions are priced ONCE. Two components the wearer has not yet ruled on stay
    /// separate on purpose (that is the duplicate review), but they describe the same minutes of heart
    /// rate, so adding both would double that day's cardio load until the review is answered.
    func cardioLoads(for sessions: [UnifiedTrainingSession]) async -> TrainingCardioLoadResolution {
        // A missing strain profile must not blank the whole lane: the population default is what every
        // other unprofiled Effort path uses, and the figure is a comparison against the wearer's own
        // recent level rather than an absolute claim.
        let maxHR = strainProfile?.hrMax ?? Double(StrainScorer.defaultMaxHR())
        let store = await storeHandle()
        var resolution = TrainingCardioLoadResolution()

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

        var priced: [(start: Int, end: Int)] = []
        var budget = Self.cardioLoadSessionBudget
        for session in ordered {
            let start = session.row.startTs
            let end = session.row.endTs
            if priced.contains(where: { Self.describesSameMinutes($0, (start, end)) }) {
                resolution.duplicateSessionIds.insert(session.id)
                continue
            }
            guard budget > 0 else {
                resolution.deferredSessionIds.insert(session.id)
                continue
            }
            let memoKey = Self.cardioLoadMemoKey(session: session, maxHR: maxHR,
                                                 dataRevision: refreshSeq)
            if let memo = cardioLoadMemo[memoKey] {
                resolution.loads[session.id] = memo
                priced.append((start, end))
                continue
            }
            budget -= 1

            let band = await hrSamples(from: start, to: end, limit: 20_000)
            var load = Self.makeCardioLoad(sessionId: session.id, samples: band,
                                           start: start, end: end, source: .noopBand,
                                           maxHR: maxHR)
            if load == nil, let store {
                let samples = await Self.healthKitMinuteTrace(for: session, store: store)
                load = Self.makeCardioLoad(sessionId: session.id, samples: samples,
                                           start: start, end: end, source: .healthKitWorkout,
                                           maxHR: maxHR)
            }
            guard let load else { continue }
            resolution.loads[session.id] = load
            cardioLoadMemo[memoKey] = load
            priced.append((start, end))
        }
        return resolution
    }

    /// Every input that can change a session's Edwards result. Keeping the key builder testable makes
    /// stale reuse after an HR-max edit, source switch, fusion change or data refresh detectable.
    nonisolated static func cardioLoadMemoKey(session: UnifiedTrainingSession, maxHR: Double,
                                              dataRevision: Int,
                                              recipeVersion: Int = cardiovascularLoadRecipeVersion) -> String {
        let components = session.components.map {
            "\($0.id):\($0.row.source):\($0.row.startTs):\($0.row.endTs)"
        }.sorted().joined(separator: ",")
        return "v\(recipeVersion)|r\(dataRevision)|hr\(maxHR)|\(session.id)|"
            + "\(session.row.startTs)|\(session.row.endTs)|\(components)"
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

    nonisolated private static func makeCardioLoad(sessionId: String, samples: [HRSample],
                                                   start: Int, end: Int,
                                                   source: TrainingCardioLoad.Source,
                                                   maxHR: Double) -> TrainingCardioLoad? {
        let coverage = traceCoverage(samples, start: start, end: end)
        guard hasUsableCoverage(samples, start: start, end: end),
              let load = StrainScorer.edwardsTrainingLoad(samples, maxHR: maxHR) else { return nil }
        return TrainingCardioLoad(sessionId: sessionId, trimp: load.trimp, effort: load.effort,
                                  source: source, coveredMinutes: coverage.covered,
                                  possibleMinutes: coverage.possible)
    }
}
