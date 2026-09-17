import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Three loads, three units — and whether the training is doing anything
//
// A single combined score would need an invented exchange rate between a hard set, a heart-rate load
// and the athlete's own perception. This screen keeps all three visible in their real units and gives
// each the same useful comparison: the rolling seven days against the person's preceding level. That
// baseline grows with the history available and tops out at 28 days, without containing the week it
// is being used to judge.
//
// Relative load remains descriptive. Adaptation is a separate reading and needs performance evidence:
// e1RM for strength, VO₂max for cardiovascular training. Session Load remains the athlete's own view.

@MainActor
final class TrainingLoadModel: ObservableObject {
    struct Lane: Sendable {
        let sevenDayTotal: Double
        let sevenDayWorkingSets: Int
        let trend: LoadTrend?
        let relative: RelativeLoadReading
        /// The visible total is only the measured part of at least one incomplete day.
        let isLowerBound: Bool
        /// How evenly the last seven days were loaded (Foster 1998). Nil below five known days, and when
        /// every known day carried exactly the same load — an undefined figure, not a flat week.
        let distribution: LoadDistribution?
        /// This week's total against the week before it, as a signed percentage. Nil without two weeks.
        let weekOverWeek: Double?
        /// What the lane's figure rests on over the last 28 days, in the lane's own unit: RPE-rated
        /// working sets for Strength, sessions with adequate HR for Cardio, rated sessions for Session.
        let measuredCount: Int
        let possibleCount: Int
        /// The lane's status (`TrainingStatusModel`). Nil for the session lane, which has none, and
        /// while the comparison itself is withheld.
        let status: LaneStatus?
    }

    /// One day's ratio per lane, for the eight-week chart. Nil while that day had no comparison.
    struct RatioPoint: Sendable, Identifiable {
        let day: String
        let strength: Double?
        let cardio: Double?
        var id: String { day }
    }

    struct Prepared: Sendable {
        let strength: Lane
        let cardio: Lane
        let session: Lane
        let response: StrengthResponseReading
        let vo2max: VO2maxResponse
        let recovery: RecoveryReading
        let history: [TrainingStatusModel.WeeklyStatus]
        let ratios: [RatioPoint]
        let sustained: SustainedOverreaching?
        let cardioMeasured: Bool
        let strengthAdaptation: TrainingAdaptationReading
        let cardiovascularAdaptation: TrainingAdaptationReading
        let provisionalStrengthRing: ProvisionalStrengthRingReading?
    }

    /// Days of history read. The oldest week of the eight-week strip is judged as of 56 days ago, and
    /// that verdict looks back a further 28 days for its baseline and up to 60 for a below-usual run.
    private static let historyDays = 150

    @Published private(set) var strength: Lane?
    @Published private(set) var cardio: Lane?
    @Published private(set) var session: Lane?
    /// Which way the lifts of the last six weeks are moving — strength adaptation evidence.
    @Published private(set) var strengthResponse: StrengthResponseReading?
    /// VO₂max over the last eight weeks — cardiovascular adaptation evidence and one input to the
    /// sustained-overload pattern.
    @Published private(set) var vo2max: VO2maxResponse?
    /// Overreaching that has lasted with performance falling and recovery strained, if present.
    @Published private(set) var sustainedOverreaching: SustainedOverreaching?
    /// How recovery has held over the last seven nights.
    @Published private(set) var recovery: RecoveryReading?
    /// The status at the end of each of the last eight weeks, oldest first.
    @Published private(set) var history: [TrainingStatusModel.WeeklyStatus] = []
    /// Each of the last 56 days' ratio per lane — the same comparison the dials show, day by day.
    @Published private(set) var ratios: [RatioPoint] = []
    @Published private(set) var loaded = false
    @Published private(set) var ambiguousSessions: [[TrainingSessionComponent]] = []
    /// True when the cardiovascular lane has at least one session priced from measured heart rate.
    @Published private(set) var cardioMeasured = false
    @Published private(set) var strengthAdaptation: TrainingAdaptationReading?
    @Published private(set) var cardiovascularAdaptation: TrainingAdaptationReading?
    /// Ring-only estimate used before a personal comparison exists. It never becomes a lane status.
    @Published private(set) var provisionalStrengthRing: ProvisionalStrengthRingReading?

    func load(repo: Repository) async {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - Self.historyDays * 86_400
        let offset = TimeZone.current.secondsFromGMT()

        async let fusedSessions = repo.trainingSessions(days: Self.historyDays)
        async let ratings = repo.sessionRPEEntries(from: from, to: now + 86_400)
        async let strengthHistoryRead = repo.resolvedStrengthHistory(days: Self.historyDays)
        let strengthHistory = await strengthHistoryRead
        let fusion = await fusedSessions
        let unified = fusion.sessions
        let cardioResolution = await repo.cardioLoads(for: unified)
        let rpeEntries = await ratings
        let dailyRows = repo.days
        let vo2 = await Self.vo2maxReadings(repo: repo)

        let today = Repository.localDayKey(Date())
        let prepared = await Task.detached(priority: .userInitiated) { () -> Prepared in
            Self.prepare(strengthHistory: strengthHistory, unified: unified,
                         cardioResolution: cardioResolution, rpeEntries: rpeEntries,
                         dailyRows: dailyRows, vo2: vo2, today: today, now: now, offset: offset)
        }.value

        guard !Task.isCancelled else { return }
        // Imported workouts do not pass through `finishNativeWorkout`. If one has just ended and has
        // no rating on any of its canonical components, schedule the same single delayed prompt. The
        // stable request id makes repeated refreshes idempotent.
        let ratedIds = Set(rpeEntries.compactMap(\.sessionId))
        let ratedStarts = Set(rpeEntries.map(\.startTs))
        for workout in unified {
            let end = workout.row.endTs
            let componentStarts = Set(workout.components.map { $0.row.startTs })
            let alreadyRated = ratedIds.contains(workout.id)
                || ratedStarts.contains(workout.row.startTs)
                || !ratedStarts.isDisjoint(with: componentStarts)
            guard !alreadyRated, end <= now, end + 30 * 60 > now else { continue }
            await SessionRPEReminder.schedule(
                startTs: workout.row.startTs,
                durationS: Double(max(0, end - workout.row.startTs)),
                sport: workout.row.sport)
        }
        strength = prepared.strength
        cardio = prepared.cardio
        session = prepared.session
        strengthResponse = prepared.response
        vo2max = prepared.vo2max
        sustainedOverreaching = prepared.sustained
        recovery = prepared.recovery
        history = prepared.history
        ratios = prepared.ratios
        ambiguousSessions = fusion.ambiguous
        cardioMeasured = prepared.cardioMeasured
        strengthAdaptation = prepared.strengthAdaptation
        cardiovascularAdaptation = prepared.cardiovascularAdaptation
        provisionalStrengthRing = prepared.provisionalStrengthRing
        #if DEBUG
        applyDemoStatusOverride()
        #endif
        loaded = true
    }

    nonisolated static func prepare(strengthHistory: ResolvedStrengthHistory,
                                    unified: [UnifiedTrainingSession],
                                    cardioResolution: TrainingCardioLoadResolution,
                                    rpeEntries: [SessionRPEEntry], dailyRows: [DailyMetric],
                                    vo2: [VO2maxReading], today: String, now: Int,
                                    offset: Int) -> Prepared {
        let strengthWorkouts = strengthHistory.workouts
        let templates = strengthHistory.templates
        let cardioLoads = cardioResolution.loads
        let strengthByDay = StrengthSession.weightedSetsByDay(strengthWorkouts,
                                                              tzOffsetSeconds: offset)
        let cardioSeries = Self.cardioDailyLoad(sessions: unified, loads: cardioLoads,
                                                duplicates: cardioResolution.duplicateSessionIds,
                                                tzOffsetSeconds: offset)
        let cardioByDay = cardioSeries.byDay
        // Days that held real training the data could not price. They leave BOTH comparison
        // windows rather than counting as rest, so a gap in our measurement is never reported as
        // a drop in the wearer's training.
        let cardioUnknown = cardioSeries.unknownDays

        var durationByStart: [Int: Double] = [:]
        var canonicalIdByStart: [Int: String] = [:]
        for session in unified {
            let seconds = session.row.durationS ?? Double(session.row.endTs - session.row.startTs)
            if seconds > 0 {
                durationByStart[session.row.startTs] = seconds
                for component in session.components { durationByStart[component.row.startTs] = seconds }
            }
            canonicalIdByStart[session.row.startTs] = session.id
            for component in session.components { canonicalIdByStart[component.row.startTs] = session.id }
        }
        for workout in strengthWorkouts where durationByStart[workout.startTs] == nil {
            if let seconds = workout.durationS { durationByStart[workout.startTs] = seconds }
        }

        let ratings = Self.canonicalRatings(entries: rpeEntries, canonicalIdByStart: canonicalIdByStart)
        let ratingBySession = Dictionary(ratings.map { entry in
            let key = entry.sessionId ?? canonicalIdByStart[entry.startTs] ?? "start|\(entry.startTs)"
            return (key, entry)
        }, uniquingKeysWith: { _, newest in newest })
        var sessionByDay: [String: Double] = [:]
        var possibleSessionKeysByDay: [String: Set<String>] = [:]
        for session in unified {
            let day = AnalyticsEngine.dayString(session.row.startTs, offsetSec: offset)
            possibleSessionKeysByDay[day, default: []].insert(session.id)
        }
        for workout in strengthWorkouts {
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: offset)
            let key = canonicalIdByStart[workout.startTs] ?? "start|\(workout.startTs)"
            possibleSessionKeysByDay[day, default: []].insert(key)
        }
        var ratedSessionKeysByDay: [String: Set<String>] = [:]
        for entry in ratings {
            guard let seconds = durationByStart[entry.startTs], seconds > 0 else { continue }
            let day = AnalyticsEngine.dayString(entry.startTs, offsetSec: offset)
            sessionByDay[day, default: 0] += entry.rpe * seconds / 60
            let key = entry.sessionId ?? canonicalIdByStart[entry.startTs] ?? "start|\(entry.startTs)"
            ratedSessionKeysByDay[day, default: []].insert(key)
        }
        let sessionUnknown = Set(possibleSessionKeysByDay.compactMap { day, possibleKeys in
            let ratedKeys = ratedSessionKeysByDay[day] ?? []
            return possibleKeys.isSubset(of: ratedKeys) ? nil : day
        })

        let cutoff = WeeklyDigestEngine.addDays(today, -6)
        let recentStrength = strengthWorkouts.filter {
            let day = AnalyticsEngine.dayString($0.startTs, offsetSec: offset)
            return day >= cutoff && day <= today
        }
        let pooledStrength = StrengthSession.strengthLoad(recentStrength)
        // A session skipped because another one already priced the same minutes is NOT a session
        // with missing heart rate, so it must not widen the coverage denominator.
        let recentCardio = unified.filter {
            let day = AnalyticsEngine.dayString($0.row.startTs, offsetSec: offset)
            return day >= cutoff && day <= today
                && ($0.row.endTs - $0.row.startTs) >= Repository.cardioLoadMinimumSeconds
                && !cardioResolution.duplicateSessionIds.contains($0.id)
        }
        let possible = possibleSessionKeysByDay.filter { $0.key >= cutoff && $0.key <= today }
            .values.reduce(0) { $0 + $1.count }
        let measured = ratedSessionKeysByDay.filter { $0.key >= cutoff && $0.key <= today }
            .values.reduce(0) { $0 + $1.count }

        // Load, adaptation and recovery stay separate. The latter two may provide context, but do
        // not turn a high load into a positive or medical verdict.
        let response = TrainingStatusModel.strengthResponse(workouts: strengthWorkouts,
                                                            templates: templates, through: today,
                                                            tzOffsetSeconds: offset)
        let recovery = TrainingStatusModel.recovery(days: dailyRows, through: today)
        let strengthRelative = TrainingLoad.relativeLoad(dailyByDay: strengthByDay, through: today)
        let cardioRelative = TrainingLoad.relativeLoad(dailyByDay: cardioByDay, through: today,
                                                       unknownDays: cardioUnknown)
        let sessionRelative = TrainingLoad.relativeLoad(dailyByDay: sessionByDay, through: today,
                                                        unknownDays: sessionUnknown)
        let history = TrainingStatusModel.weeklyHistory(weeks: 8, through: today,
                                                        strengthDaily: strengthByDay,
                                                        cardioDaily: cardioByDay,
                                                        cardioUnknownDays: cardioUnknown,
                                                        workouts: strengthWorkouts, templates: templates,
                                                        days: dailyRows, tzOffsetSeconds: offset)
        var ratios: [RatioPoint] = []
        var ratioDay = WeeklyDigestEngine.addDays(today, -55)
        for _ in 0..<56 {
            ratios.append(RatioPoint(day: ratioDay,
                                     strength: TrainingLoad.trend(dailyByDay: strengthByDay, through: ratioDay)?.ratio,
                                     cardio: TrainingLoad.trend(dailyByDay: cardioByDay, through: ratioDay,
                                                                unknownDays: cardioUnknown)?.ratio))
            ratioDay = WeeklyDigestEngine.addDays(ratioDay, 1)
        }
        let vo2max = TrainingStatusModel.vo2maxResponse(readings: vo2, through: today)
        let strengthAdaptation = TrainingStatusModel.strengthAdaptation(response)
        let cardiovascularAdaptation = TrainingStatusModel.cardiovascularAdaptation(vo2max)
        let sustained = TrainingStatusModel.sustainedOverreaching(history: history, strengthResponse: response,
                                                                  cardioDirection: vo2max.direction,
                                                                  recovery: recovery)
        let provisionalStrengthRing: ProvisionalStrengthRingReading?
        if strengthRelative.trend == nil {
            let recentResolved = strengthHistory.sessions.filter {
                let day = AnalyticsEngine.dayString($0.startTs, offsetSec: offset)
                return day >= cutoff && day <= today
            }
            let loads: [Double?] = recentResolved.map { session in
                let canonicalKey = canonicalIdByStart[session.startTs]
                let rating = ratingBySession[session.id]
                    ?? canonicalKey.flatMap { ratingBySession[$0] }
                    ?? ratingBySession["start|\(session.startTs)"]
                guard let rpe = rating?.rpe, session.durationS > 0 else { return nil }
                return rpe * session.durationS / 60
            }
            let start = Int(Calendar(identifier: .gregorian).date(
                byAdding: .day, value: -6,
                to: Calendar(identifier: .gregorian).startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now))))?
                .timeIntervalSince1970 ?? Double(now - 6 * 86_400))
            let muscle = DetailedMuscleLoadSnapshot.volume(history: strengthHistory,
                                                           from: start, to: now)
            provisionalStrengthRing = TrainingLoad.provisionalStrengthRing(
                sessionLoads: loads, weightedMuscleSets: muscle.byMuscle,
                hasUnmappedSets: muscle.hasUnmappedSets)
        } else {
            provisionalStrengthRing = nil
        }

        return Prepared(
            strength: Lane(sevenDayTotal: Self.lastSeven(strengthByDay, through: today),
                           sevenDayWorkingSets: recentStrength.flatMap {
                               $0.exercises.flatMap(\.workingSets)
                           }.count,
                           trend: strengthRelative.trend,
                           relative: strengthRelative,
                           isLowerBound: false,
                           distribution: TrainingLoad.distribution(dailyByDay: strengthByDay, through: today),
                           weekOverWeek: TrainingLoad.weekOverWeek(dailyByDay: strengthByDay, through: today),
                           measuredCount: pooledStrength.ratedSets,
                           possibleCount: pooledStrength.workingSets,
                           status: Self.relativeStatus(strengthRelative)),
            cardio: Lane(sevenDayTotal: Self.lastSeven(cardioByDay, through: today),
                         sevenDayWorkingSets: 0,
                         trend: cardioRelative.trend,
                         relative: cardioRelative,
                         isLowerBound: Self.lastSevenContainsUnknown(cardioUnknown, through: today),
                         distribution: TrainingLoad.distribution(dailyByDay: cardioByDay, through: today,
                                                                 unknownDays: cardioUnknown),
                         weekOverWeek: TrainingLoad.weekOverWeek(dailyByDay: cardioByDay, through: today,
                                                                 unknownDays: cardioUnknown),
                         measuredCount: recentCardio.filter {
                             cardioLoads[$0.id] != nil
                         }.count,
                         possibleCount: recentCardio.count,
                         status: Self.relativeStatus(cardioRelative)),
            session: Lane(sevenDayTotal: Self.lastSeven(sessionByDay, through: today),
                          sevenDayWorkingSets: 0,
                          trend: sessionRelative.trend,
                          relative: sessionRelative,
                          isLowerBound: Self.lastSevenContainsUnknown(sessionUnknown, through: today),
                          distribution: TrainingLoad.distribution(dailyByDay: sessionByDay, through: today,
                                                                  unknownDays: sessionUnknown),
                          weekOverWeek: TrainingLoad.weekOverWeek(dailyByDay: sessionByDay, through: today,
                                                                  unknownDays: sessionUnknown),
                          measuredCount: measured, possibleCount: possible, status: nil),
            response: response,
            vo2max: vo2max,
            recovery: recovery,
            history: history,
            ratios: ratios,
            sustained: sustained,
            cardioMeasured: cardioSeries.measured,
            strengthAdaptation: strengthAdaptation,
            cardiovascularAdaptation: cardiovascularAdaptation,
            provisionalStrengthRing: provisionalStrengthRing)
    }

    func resolve(_ components: [TrainingSessionComponent], merge: Bool, repo: Repository) async {
        await repo.decideTrainingSessionPair(components, merge: merge)
        await load(repo: repo)
    }

    #if DEBUG
    /// Screenshot QA for the statement matrix. The seeded demo history cannot produce a split — both
    /// lanes sit near 0.8 — so `--demo-status split-sharp|split-mild|both-high` overrides the two
    /// verdicts after a normal load. Display only: nothing is stored, and every figure beneath the
    /// statement still comes from the seeded data.
    private func applyDemoStatusOverride() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--demo-status"), index + 1 < args.count else { return }
        func laneStatus(_ status: TrainingStatus, _ ratio: Double) -> LaneStatus {
            LaneStatus(status: status, ratio: ratio, band: TrainingStatusModel.band(ratio: ratio),
                       followsRecentHighPhase: false,
                       daysBelowUsual: status == .detraining ? 24 : 0,
                       usedStrengthResponse: true, usedRecovery: false)
        }
        let pair: (strength: LaneStatus, cardio: LaneStatus)
        switch args[index + 1] {
        case "split-sharp": pair = (laneStatus(.detraining, 0.58), laneStatus(.overreaching, 1.52))
        case "split-mild":  pair = (laneStatus(.productive, 1.14), laneStatus(.detraining, 0.62))
        case "both-high":   pair = (laneStatus(.overreaching, 1.44), laneStatus(.overreaching, 1.51))
        default: return
        }
        if let lane = strength {
            strength = Lane(sevenDayTotal: lane.sevenDayTotal,
                            sevenDayWorkingSets: lane.sevenDayWorkingSets, trend: lane.trend,
                            relative: lane.relative, isLowerBound: lane.isLowerBound,
                            distribution: lane.distribution, weekOverWeek: lane.weekOverWeek,
                            measuredCount: lane.measuredCount, possibleCount: lane.possibleCount,
                            status: pair.strength)
        }
        if let lane = cardio {
            cardio = Lane(sevenDayTotal: lane.sevenDayTotal,
                          sevenDayWorkingSets: lane.sevenDayWorkingSets, trend: lane.trend,
                          relative: lane.relative, isLowerBound: lane.isLowerBound,
                          distribution: lane.distribution, weekOverWeek: lane.weekOverWeek,
                          measuredCount: lane.measuredCount, possibleCount: lane.possibleCount,
                          status: pair.cardio)
        }
    }
    #endif

    /// The cardio lane's daily series, on ONE axis.
    ///
    /// Measured Edwards TRIMP wherever the window has it. Stored Effort is a different recipe and never
    /// substitutes for a missing trace; an unpriced training day remains unknown.
    nonisolated static func cardioDailyLoad(sessions: [UnifiedTrainingSession],
                                            loads: [String: TrainingCardioLoad],
                                            duplicates: Set<String>,
                                            tzOffsetSeconds: Int)
    -> (byDay: [String: Double], measured: Bool, unknownDays: Set<String>,
        measuredByDay: [String: Int], possibleByDay: [String: Int]) {
        let measured = !loads.isEmpty
        var byDay: [String: Double] = [:]
        var unpriceable: Set<String> = []
        var measuredByDay: [String: Int] = [:]
        var possibleByDay: [String: Int] = [:]
        for session in sessions {
            // On the fallback axis a duplicate still awaiting review has to be skipped for the same
            // reason it is skipped when priced: both records describe the same minutes, and its twin
            // has already spoken for them. It is not a gap in the data.
            if duplicates.contains(session.id) { continue }
            let day = AnalyticsEngine.dayString(session.row.startTs, offsetSec: tzOffsetSeconds)
            guard session.row.endTs - session.row.startTs >= Repository.cardioLoadMinimumSeconds else {
                continue
            }
            possibleByDay[day, default: 0] += 1
            let value = loads[session.id]?.trimp
            guard let value, value.isFinite, value >= 0 else {
                // A session long enough to have been priced, that carries no usable figure, is a day
                // the data cannot speak for — not a rest day. Only sessions past the pricing threshold
                // count: a five-minute walk was never going to be priced, and calling its day
                // unmeasurable would drop an ordinary day out of the comparison.
                unpriceable.insert(day)
                continue
            }
            byDay[day, default: 0] += value
            measuredByDay[day, default: 0] += 1
        }
        return (byDay, measured, unpriceable, measuredByDay, possibleByDay)
    }

    /// One rating per canonical session, so Session Load counts a workout once.
    ///
    /// A rating is stored against the component the wearer opened, so the same physical session can be
    /// rated twice — once from its Hevy detail, once from its Apple Health row — under two different
    /// start seconds. Summing both would report training nobody did. A rating that names its canonical
    /// session is grouped by that name; an older entry falls back to the session its start belongs to,
    /// which is how ratings written before fusion keep working. Where one session has several ratings,
    /// the latest answer wins. Legacy answers without a separate answer timestamp fall back to their
    /// workout start; the id breaks a tie so the choice never depends on read order.
    nonisolated static func canonicalRatings(entries: [SessionRPEEntry],
                                             canonicalIdByStart: [Int: String]) -> [SessionRPEEntry] {
        var chosen: [String: SessionRPEEntry] = [:]
        for entry in entries {
            let key = entry.sessionId ?? canonicalIdByStart[entry.startTs] ?? "start|\(entry.startTs)"
            let candidateOrder = (entry.ratedAtTs ?? entry.startTs, entry.id)
            if let existing = chosen[key],
               (existing.ratedAtTs ?? existing.startTs, existing.id) >= candidateOrder {
                continue
            }
            chosen[key] = entry
        }
        return chosen.values.sorted { ($0.startTs, $0.id) < ($1.startTs, $1.id) }
    }

    nonisolated private static func lastSeven(_ values: [String: Double], through day: String) -> Double {
        var total = 0.0
        var cursor = day
        for _ in 0..<7 {
            total += values[cursor] ?? 0
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        return total
    }

    nonisolated private static func lastSevenContainsUnknown(_ unknownDays: Set<String>,
                                                             through day: String) -> Bool {
        var cursor = day
        for _ in 0..<7 {
            if unknownDays.contains(cursor) { return true }
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        return false
    }

    /// Adapts the new neutral relative-load reading to the existing ring renderer. The legacy case names
    /// are not presented to the wearer; `TrainingStatusVisuals` labels these as relative-load bands.
    nonisolated private static func relativeStatus(_ reading: RelativeLoadReading) -> LaneStatus? {
        guard let trend = reading.trend else { return nil }
        let relativeBand: RelativeLoadBand = reading.band ?? {
            if trend.percentChange < -15 { return .below }
            if trend.percentChange <= 15 { return .usual }
            if trend.percentChange <= 30 { return .higher }
            return .muchHigher
        }()
        let legacyStatus: TrainingStatus
        let legacyBand: TrainingLoadBand
        switch relativeBand {
        case .below: legacyStatus = .detraining; legacyBand = .below
        case .usual: legacyStatus = .maintaining; legacyBand = .maintaining
        case .higher: legacyStatus = .productive; legacyBand = .productive
        case .muchHigher: legacyStatus = .overreaching; legacyBand = .above
        }
        return LaneStatus(status: legacyStatus, ratio: trend.ratio, band: legacyBand,
                          followsRecentHighPhase: false, usedStrengthResponse: false,
                          usedRecovery: false)
    }

    /// The VO₂max readings the cardio lane reads.
    ///
    /// Apple Watch's measured Cardio Fitness when it has at least four readings in the window — it comes
    /// from real outdoor effort. Otherwise NOOP's weekly estimate, each reading tagged with the estimator
    /// that produced it (Nes 2011 or Uth 2004), so `TrainingStatusModel.vo2maxResponse` never draws a
    /// line across a change of method. The same series and provenance the Metric Explorer shows.
    private static func vo2maxReadings(repo: Repository) async -> [VO2maxReading] {
        let cutoff = WeeklyDigestEngine.addDays(Repository.localDayKey(Date()),
                                                -(TrainingStatusModel.vo2maxWindowDays - 1))
        let apple = await repo.exploreSeries(key: "vo2max", source: Repository.appleHealthSource, days: 90)
        if apple.filter({ $0.day >= cutoff }).count >= StrengthProgress.minimumTrendPoints {
            return apple.map { VO2maxReading(day: $0.day, value: $0.value, segment: Repository.appleHealthSource) }
        }
        let resolution = await repo.resolvedSeries(key: "vo2max_est", source: Repository.whoopSource, days: 90)
        var readings: [VO2maxReading] = []
        for point in resolution.points {
            let tag = await repo.scoreProvenanceTag(resolvedSource: point.source, day: point.day,
                                                    metricKey: "vo2max_est")
            readings.append(VO2maxReading(day: point.day, value: point.value, segment: tag ?? point.source))
        }
        return readings
    }
}

struct TrainingLoadView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = TrainingLoadModel()
    @State private var shownVO2: Double = 0
    @State private var adviceBounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScreenScaffold(title: "Training Load",
                       subtitle: "Three views of training, each in the unit that fits it.",
                       onRefresh: { await model.load(repo: repo) }) {
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                hero
                precisionCard.trainingCardEntrance()
                duplicateReviewCard
                sustainedCard
                adaptationCard.trainingCardEntrance().id("statement")
                recoveryCard.trainingCardEntrance()
                // Named sections for `--demo-scroll-to` screenshot QA (DEBUG only; ids are inert otherwise).
                historyCard.trainingCardEntrance().id("history")
                strengthSummaryCard.trainingCardEntrance().id("lifts")
                vo2maxCard.trainingCardEntrance().id("cardio")
                sessionCard.trainingCardEntrance()
                shapeCard.trainingCardEntrance().id("shape")
                basisCard.trainingCardEntrance()
                methodCard.trainingCardEntrance()
            }
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
    }

    @ViewBuilder private var duplicateReviewCard: some View {
        if let candidates = model.ambiguousSessions.first, candidates.count >= 2 {
            TrainingWashCard(color: StrandPalette.statusWarning, watermark: "rectangle.on.rectangle") {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text("Are these the same session?")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(candidates) { component in
                            HStack(spacing: 8) {
                                Circle().fill(StrandPalette.statusWarning.opacity(0.75))
                                    .frame(width: 6, height: 6)
                                Text(WorkoutSource.localizedDisplaySport(component.row.sport))
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                // The start time is what makes this answerable: two records of one ride
                                // begin minutes apart, two genuine rides do not. Without it the card asks
                                // the wearer to choose between two identical lines.
                                Text(Date(timeIntervalSince1970: TimeInterval(component.row.startTs)),
                                     format: .dateTime.hour().minute())
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                Spacer(minLength: 8)
                                Text(sourceName(component.row.source))
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                    HStack {
                        Button("Keep separate") {
                            Task { await model.resolve(candidates, merge: false, repo: repo) }
                        }.buttonStyle(.bordered)
                        Button("Merge") {
                            Task { await model.resolve(candidates, merge: true, repo: repo) }
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func sourceName(_ source: String) -> String {
        switch WorkoutSource.classify(source) {
        case .apple: return String(localized: "Apple Health")
        case .hevy: return "Hevy"
        case .lifting: return String(localized: "Imported file")
        case .activityFile: return String(localized: "Activity file")
        case .manual: return "NOOP"
        case .detected, .whoop: return String(localized: "NOOP band")
        }
    }

    // MARK: - The instrument

    /// One instrument for both lanes: strength on the outer arc, cardio on the inner one, each with its
    /// own knob and its own verdict underneath.
    ///
    /// Deliberately NOT one combined ring with one word in the middle. The two lanes are measured in
    /// different units and the fork's decision log is explicit that they are never blended into a single
    /// score — so the ring shares a scale, and everything that could be mistaken for a joint verdict
    /// stays split in two.
    private var hero: some View {
        VStack(spacing: NoopMetrics.space3) {
            LoadDualRing(strength: strengthRingReading, cardio: cardioRingReading)
            laneSummary(symbol: "figure.strengthtraining.traditional", title: "Strength",
                        lane: model.strength?.status, figure: strengthFigure, evidence: strengthEvidence,
                        caveat: strengthCaveat)
            Divider().overlay(StrandPalette.hairline)
            laneSummary(symbol: "heart.fill", title: "Cardiovascular",
                        lane: model.cardio?.status, figure: cardioFigure, evidence: cardioEvidence,
                        caveat: cardioCaveat)
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity)
        .background(TrainingHeroSurface(leading: model.strength?.status?.status.color ?? StrandPalette.textTertiary,
                                        trailing: model.cardio?.status?.status.color ?? StrandPalette.textTertiary))
    }

    private var strengthRingReading: LoadRingReading? {
        if let status = model.strength?.status { return LoadRingReading(status) }
        return model.provisionalStrengthRing.map(LoadRingReading.init)
    }

    private var cardioRingReading: LoadRingReading? {
        model.cardio?.status.map(LoadRingReading.init)
    }

    /// One lane under the ring: the same symbol its knob carries, its verdict, its figure and what the
    /// verdict rests on. The symbol is what maps a row to an arc, so it is never dropped.
    private func laneSummary(symbol: String, title: LocalizedStringKey, lane: LaneStatus?,
                             figure: String?, evidence: String?, caveat: String? = nil) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            StatusBadge(symbol: symbol, color: lane?.status.color ?? StrandPalette.textTertiary, size: 30)
            // The ratio rides on the TITLE line, not in a column of its own: as a third column it
            // squeezed the figure so hard that "43,6 gewichtete Sätze · −21 %" broke after the minus.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let lane {
                        Text(lane.status.label)
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(lane.status.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 6)
                    Text(lane.map { LoadScale.ratioText($0.ratio, band: $0.band) } ?? "—")
                        .font(StrandFont.number(15, weight: .semibold))
                        .foregroundStyle(lane?.status.color ?? StrandPalette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                if let figure {
                    Text(figure)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let evidence {
                    Text(evidence)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caveat {
                    Label(caveat, systemImage: "exclamationmark.triangle.fill")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// How thin the measurement under a verdict is — carried WITH the verdict rather than in a card
    /// below the fold.
    ///
    /// Shown only when coverage is poor. A well-measured lane says nothing extra, so the warning keeps
    /// its meaning instead of becoming furniture the reader learns to skip; and it is a sentence, not a
    /// percentage the reader has to turn into doubt themselves.
    private var strengthCaveat: String? {
        guard let lane = model.strength, let share = coverageShare(lane),
              share < TrainingLoad.trustedRatedShare else { return nil }
        return String(localized: "Only \(lane.measuredCount) of \(lane.possibleCount) sets carry an RPE, so most of this rests on the default weighting")
    }

    private var cardioCaveat: String? {
        guard let lane = model.cardio, lane.possibleCount > 0 else { return nil }
        if !model.cardioMeasured {
            return String(localized: "No usable heart-rate trace in this window, so cardiovascular load is not estimated")
        }
        guard let share = coverageShare(lane), share < TrainingLoad.trustedRatedShare else { return nil }
        return String(localized: "Only \(lane.measuredCount) of \(lane.possibleCount) sessions are complete; the measured total is a lower bound")
    }

    private var strengthFigure: String? {
        guard let lane = model.strength else { return nil }
        let raw = String(localized: "\(lane.sevenDayWorkingSets) working sets")
        let estimated = weightedSetText(lane)
        guard let trend = lane.trend else { return "\(raw) · \(estimated)" }
        return "\(raw) · \(estimated) · \(signedPercent(trend.percentChange))"
    }

    private var cardioFigure: String? {
        guard let lane = model.cardio else { return nil }
        let total = lane.isLowerBound ? String(localized: "at least \(effortText(lane))") : effortText(lane)
        guard let trend = lane.trend else { return total }
        return "\(total) · \(signedPercent(trend.percentChange))"
    }

    /// What the strength verdict rests on — a below-usual run, the lifts, or an honest "load only".
    private var strengthEvidence: String? {
        guard let lane = model.strength else { return nil }
        guard let status = lane.status else {
            return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) working sets rated · comparison available after 21 complete days")
        }
        if status.band == .below, status.daysBelowUsual > 0 { return belowSinceText(status.daysBelowUsual) }
        return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) working sets rated · compared only with your strength history")
    }

    private var cardioEvidence: String? {
        guard let lane = model.cardio else { return nil }
        guard let status = lane.status else {
            return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) sessions complete · comparison available after 21 complete days")
        }
        if status.band == .below, status.daysBelowUsual > 0 { return belowSinceText(status.daysBelowUsual) }
        return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) sessions complete · compared only with your cardiovascular history")
    }

    private var precisionCard: some View {
        NoopCard(tint: StrandPalette.metricCyan) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                StatusBadge(symbol: maturitySymbol, color: StrandPalette.metricCyan, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(maturityTitle)
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(maturityDetail)
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var currentMaturity: TrainingLoadMaturity {
        let values = [model.strength?.relative.maturity, model.cardio?.relative.maturity].compactMap { $0 }
        if values.contains(.immediate) { return .immediate }
        if values.contains(.earlyEstimate) { return .earlyEstimate }
        if values.contains(.baselineGrowing) { return .baselineGrowing }
        return values.isEmpty ? .immediate : .personalBaseline
    }

    private var maturitySymbol: String {
        switch currentMaturity {
        case .immediate: return "chart.bar.fill"
        case .earlyEstimate: return "sparkles"
        case .baselineGrowing: return "chart.line.uptrend.xyaxis"
        case .personalBaseline: return "person.crop.circle.badge.checkmark"
        }
    }

    private var maturityTitle: String {
        switch currentMaturity {
        case .immediate: return String(localized: "Current load")
        case .earlyEstimate: return String(localized: "Early estimate")
        case .baselineGrowing: return String(localized: "Baseline growing")
        case .personalBaseline: return String(localized: "Personal baseline")
        }
    }

    private var maturityDetail: String {
        switch currentMaturity {
        case .immediate:
            return String(localized: "Your measured load is available now. A first personal comparison appears after 21 complete days.")
        case .earlyEstimate:
            return String(localized: "The last 7 days are compared with the preceding 14. Treat this as an early estimate while your baseline grows.")
        case .baselineGrowing:
            return String(localized: "The last 7 days are compared with the preceding 28. Personal variation bands need eight complete weeks.")
        case .personalBaseline:
            return String(localized: "Your usual range is based on the robust variation in your own complete training weeks.")
        }
    }

    private var adaptationCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Adaptation", overline: "Performance evidence")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    adaptationRow(symbol: "figure.strengthtraining.traditional", title: "Strength",
                                  reading: model.strengthAdaptation)
                    Divider().overlay(StrandPalette.hairline)
                    adaptationRow(symbol: "heart.fill", title: "Cardiovascular",
                                  reading: model.cardiovascularAdaptation)
                    Text("Load describes how much you trained. Adaptation is shown only when performance data supports a direction.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func adaptationRow(symbol: String, title: LocalizedStringKey,
                               reading: TrainingAdaptationReading?) -> some View {
        let state = reading?.state ?? .notEnoughData
        let presentation: (String, String, Color)
        switch state {
        case .improving:
            presentation = ("arrow.up.right", String(localized: "Productive development"), StrandPalette.statusPositive)
        case .declining:
            presentation = ("arrow.down.right", String(localized: "Performance trending down"), StrandPalette.statusWarning)
        case .stable:
            presentation = ("equal", String(localized: "Performance stable"), StrandPalette.metricCyan)
        case .unclear:
            presentation = ("minus", String(localized: "No clear direction"), StrandPalette.textSecondary)
        case .notEnoughData:
            presentation = ("hourglass", String(localized: "Adaptation not assessable yet"), StrandPalette.textTertiary)
        }
        return HStack(spacing: NoopMetrics.space3) {
            StatusBadge(symbol: symbol, color: presentation.2, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Label(presentation.1, systemImage: presentation.0)
                    .font(StrandFont.caption).foregroundStyle(presentation.2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Below your usual since 3 Sep" — a date rather than "N days", which needs no plural forms and
    /// says when the dip started, the thing the 21-day strength rule counts from.
    private func belowSinceText(_ days: Int) -> String {
        let since = WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), -(days - 1))
        return String(localized: "Below your usual since \(StatusHistoryStrip.shortDate(since))")
    }

    // MARK: - What to do

    private struct Advice {
        let symbol: String
        let color: Color
        let text: String
        /// A second colour for a statement that speaks about BOTH lanes at once — the card then runs
        /// from the lane that is falling behind to the one that is ahead.
        var secondary: Color? = nil
        /// Whether the card may be painted in the colour itself rather than washed with it. Yellow is
        /// the exception: white text on it fails to read, and darkening the fill would turn a warning
        /// into a different colour, so that state keeps the lighter treatment.
        var filled = true
    }

    /// The page's one statement, dressed. The DECISION is pure and lives in
    /// `TrainingStatusModel.statement(strength:cardio:recovery:)`, where every pair of verdicts is
    /// resolved and covered by tests; this only chooses the words, the glyph and the colours.
    ///
    /// It replaced a read-time ladder that stopped at its first hit and therefore named one lane: a
    /// wearer whose lifting was falling away while their cardio ran well above usual was told only
    /// about the cardio.
    private var advice: Advice {
        switch TrainingStatusModel.statement(strength: model.strength?.status?.status,
                                             cardio: model.cardio?.status?.status,
                                             recovery: model.recovery?.state ?? .unknown) {
        case .noHistory:
            return Advice(symbol: "hourglass", color: StrandPalette.textTertiary,
                          text: String(localized: "After two weeks of training this shows whether it is building, holding or too much."),
                          filled: false)

        case let .laneOnly(lane, status):
            return Advice(symbol: status.symbol, color: status.color,
                          text: sentence(for: status, lane: lane) + " "
                              + String(localized: "The other lane needs two more weeks of measured history."),
                          filled: status != .unproductive)

        case let .aligned(status):
            return Advice(symbol: status.symbol, color: status.color,
                          text: sentence(for: status, lane: nil),
                          filled: status != .unproductive)

        case let .oneBehind(lane):
            let color = laneColor(lane)
            return Advice(symbol: TrainingStatus.detraining.symbol, color: color,
                          text: lane == .strength
                            ? String(localized: "Your strength work is below your usual while your cardio holds steady.")
                            : String(localized: "Your cardio is below your usual while your strength work holds steady."))

        case let .split(low, high, severity):
            let text: String
            switch (low, severity) {
            case (.strength, .mild):
                text = String(localized: "Plenty of cardio, little strength: your endurance is carrying this block while your lifting loses ground.")
            case (.strength, .sharp):
                text = String(localized: "Much more cardio than usual while your strength work has fallen away. Bring the lifting back before the cardio goes higher.")
            case (.cardio, .mild):
                text = String(localized: "Plenty of strength work, little cardio: your lifting is carrying this block while your endurance loses ground.")
            case (.cardio, .sharp):
                text = String(localized: "Much more strength work than usual while your cardio has fallen away. Bring the cardio back before the lifting goes higher.")
            }
            // The surface itself splits: it runs from the lane that is behind to the one that is ahead.
            return Advice(symbol: "arrow.left.arrow.right", color: laneColor(high), text: text,
                          secondary: laneColor(low))

        case let .excessive(lane, strained):
            let text: String
            if lane == .strength {
                text = strained
                    ? String(localized: "Much more strength work than usual, and your recovery is dropping. Take a few easier days before adding more.")
                    : String(localized: "Much more strength work than usual. Hold here until your usual level catches up.")
            } else {
                text = String(localized: "Much more cardio than usual. Hold here until your usual level catches up.")
            }
            return Advice(symbol: TrainingStatus.overreaching.symbol,
                          color: TrainingStatus.overreaching.color, text: text)

        case .bothExcessive:
            return Advice(symbol: TrainingStatus.overreaching.symbol,
                          color: TrainingStatus.overreaching.color,
                          text: String(localized: "Both lanes are well above your usual. Fine for a short block, but not both at once for long."))

        case let .spinning(cardioAlsoHigh):
            // Both facts, side by side. That the cardio block is what costs the lifts their progress is
            // plausible and unmeasured, so the card does not say it.
            return Advice(symbol: TrainingStatus.unproductive.symbol,
                          color: TrainingStatus.unproductive.color,
                          text: cardioAlsoHigh
                            ? String(localized: "Plenty of strength work without the lifts improving, and your cardio is well above your usual too. Decide which of the two to ease first.")
                            : String(localized: "Plenty of strength work, but your lifts are not improving. More volume will not fix that: look at sleep, recovery or the programme."),
                          filled: false)

        case .strainedRecovery:
            return Advice(symbol: "moon.zzz.fill", color: TrainingStatus.unproductive.color,
                          text: String(localized: "Your recovery signals flagged on several recent nights. Hold your load rather than raising it."),
                          filled: false)
        }
    }

    /// The lane's own colour — the same one its arc and its row carry.
    private func laneColor(_ lane: TrainingStatusModel.TrainingStatementLane) -> Color {
        let status = lane == .strength ? model.strength?.status?.status : model.cardio?.status?.status
        return status?.color ?? StrandPalette.textTertiary
    }

    /// One verdict in a sentence, for the cases that speak about a single state.
    private func sentence(for status: TrainingStatus,
                          lane: TrainingStatusModel.TrainingStatementLane?) -> String {
        switch status {
        case .detraining:
            return String(localized: "You have been training well below your usual level. If this is not a planned break, restart with a few easy sessions.")
        case .recovering:
            return String(localized: "A lighter stretch after a hard phase. Good timing to let strength and fitness settle.")
        case .maintaining:
            return String(localized: "You are holding your level. To build, raise the load in small steps.")
        case .productive:
            return model.recovery?.state == .holding
                ? String(localized: "Your build is working: load at or above your usual, and your recovery is keeping up.")
                : String(localized: "Your build is working: load at or above your usual, and it is paying off.")
        case .unproductive:
            return String(localized: "Plenty of strength work, but your lifts are not improving. More volume will not fix that: look at sleep, recovery or the programme.")
        case .overreaching:
            return lane == .cardio
                ? String(localized: "Much more cardio than usual. Hold here until your usual level catches up.")
                : String(localized: "Much more strength work than usual. Hold here until your usual level catches up.")
        }
    }

    private var adviceCard: some View {
        let advice = advice
        let ink = advice.filled ? StrandPalette.onDarkPrimary : StrandPalette.textPrimary
        return TrainingWashCard(color: advice.color, watermark: advice.symbol, filled: advice.filled,
                                secondary: advice.secondary) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    // On a filled card the glyph stands on its own: a coloured badge on the same colour
                    // would disappear into it.
                    if advice.filled {
                        Image(systemName: advice.symbol)
                            .font(StrandFont.rounded(30, weight: .bold))
                            .foregroundStyle(ink)
                            .trainingSymbolBounce(trigger: adviceBounce)
                            .accessibilityHidden(true)
                    } else {
                        StatusBadge(symbol: advice.symbol, color: advice.color, size: 44,
                                    bounceTrigger: adviceBounce)
                    }
                    Text(advice.text)
                        .font(StrandFont.headline)
                        .foregroundStyle(ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: NoopMetrics.space2) {
                    stageTile("Strength", lane: model.strength?.status, filled: advice.filled)
                    stageTile("Cardio", lane: model.cardio?.status, filled: advice.filled)
                }
            }
        }
        .task(id: advice.text) {
            guard !reduceMotion else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            adviceBounce += 1
        }
    }

    /// One lane's ratio inside the statement card, so the sentence above it is answerable without
    /// scrolling back to the ring.
    private func stageTile(_ title: LocalizedStringKey, lane: LaneStatus?, filled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(filled ? StrandPalette.onDarkSecondary : StrandPalette.textSecondary)
            Text(lane.map { LoadScale.ratioText($0.ratio, band: $0.band) } ?? "—")
                .font(StrandFont.number(17, weight: .semibold))
                .foregroundStyle(filled ? StrandPalette.onDarkPrimary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(filled ? StrandPalette.onDarkPrimary.opacity(0.18) : StrandPalette.surfaceInset))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Lasting overreaching

    /// Shown only when overreaching has lasted three week-ends with that lane's performance falling and
    /// recovery strained — the pattern of non-functional overreaching (Meeusen et al. 2013). It says in
    /// so many words that it is not a diagnosis of overtraining.
    @ViewBuilder private var sustainedCard: some View {
        if let warning = model.sustainedOverreaching {
            TrainingWashCard(color: TrainingStatus.overreaching.color, watermark: "exclamationmark.octagon.fill") {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(spacing: NoopMetrics.space2) {
                        StatusBadge(symbol: "exclamationmark.octagon.fill", color: TrainingStatus.overreaching.color,
                                    size: 34, pulses: !reduceMotion)
                        Text("Persistent overload pattern")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text(sustainedText(warning))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This is not a diagnosis of overtraining. That can only be made by a doctor, over months and after ruling out other causes. If your performance and how you feel stay down for weeks, get checked.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sustainedText(_ warning: SustainedOverreaching) -> String {
        let lanes: String
        switch (warning.lanes.contains(.strength), warning.lanes.contains(.cardio)) {
        case (true, true): lanes = String(localized: "Strength and cardio")
        case (true, false): lanes = String(localized: "Strength")
        default: lanes = String(localized: "Cardio")
        }
        return String(localized: "Load was repeatedly well above usual for \(warning.weeks) weeks (\(lanes)), while performance fell and recovery signals were strained. Plan several easy or rest days now.")
    }

    // MARK: - Recovery

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recovery", overline: "Last seven nights")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(spacing: NoopMetrics.space2) {
                        recoveryTile("HRV", symbol: "waveform.path.ecg", key: "hrv")
                        recoveryTile("Resting HR", symbol: "heart.fill", key: "rhr")
                        recoveryTile("Breathing", symbol: "lungs.fill", key: "respRate")
                    }
                    if let reading = model.recovery, reading.nightsRead > 0 {
                        NightsMeter(strained: reading.strainedNights, read: reading.nightsRead,
                                    total: TrainingStatusModel.recoveryNights)
                    }
                    Text(recoverySummary)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func recoveryTile(_ title: LocalizedStringKey, symbol: String, key: String) -> some View {
        let read = model.recovery?.readOnLatestNight.contains(key) ?? false
        let flagging = model.recovery?.flaggingOnLatestNight.contains(key) ?? false
        let color = !read ? StrandPalette.textTertiary
            : (flagging ? StrandPalette.statusWarning : StrandPalette.statusPositive)
        let state = !read ? String(localized: "No data")
            : (flagging ? String(localized: "Flagging") : String(localized: "Normal"))
        return VStack(spacing: 6) {
            // A filled badge when there is a reading — pulsing while it flags; a missing reading stays
            // neutral so it never looks like a verdict.
            if read {
                StatusBadge(symbol: symbol, color: color, size: 44, pulses: flagging && !reduceMotion)
            } else {
                ZStack {
                    Circle().fill(StrandPalette.surfaceInset)
                    Image(systemName: symbol)
                        .font(StrandFont.rounded(18, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(width: 44, height: 44)
            }
            Text(title)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(state)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(color.opacity(read ? 0.13 : 0.05)))
        .accessibilityElement(children: .combine)
    }

    private var recoverySummary: String {
        guard let reading = model.recovery, reading.state != .unknown else {
            return String(localized: "Too few nights with recovery data to judge yet.")
        }
        return reading.state == .strained
            ? String(localized: "Recovery signals were strained on \(reading.strainedNights) of \(reading.nightsRead) measured nights.")
            : String(localized: "Holding: a signal flagged on \(reading.strainedNights) of \(reading.nightsRead) nights.")
    }

    // MARK: - History

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Last 8 weeks", overline: "Status history")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    LoadRatioChart(points: model.ratios)
                    Divider().overlay(StrandPalette.hairline)
                    StatusHistoryStrip(history: model.history)
                    Text("Each week is judged with that week's own data, as the screen would have shown it then.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Strength and cardio development

    /// The lifts' verdict in one bar: how many of the evaluated lifts rise, stay unclear or fall. This is
    /// the evidence behind the strength status; each lift's own line lives on the Strength screen.
    private var strengthSummaryCard: some View {
        let response = model.strengthResponse
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Strength development", overline: "Last six weeks")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let response, response.evaluated > 0 {
                        liftDirections(response)
                        Text("Each lift's estimated one-rep max over the last six weeks. A direction counts only when the sessions agree on it; the line for every lift is on the Strength screen.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Log a lift at least four times within six weeks to see which way it is moving.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// A donut with the counts beside it; a bar with the counts under it before macOS 14.
    @ViewBuilder private func liftDirections(_ response: StrengthResponseReading) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            HStack(spacing: NoopMetrics.space4) {
                LiftDirectionDonut(rising: response.rising, unclear: response.unclear, falling: response.falling)
                    .frame(width: 116, height: 116)
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    directionCounts(response)
                }
                Spacer(minLength: 0)
            }
        } else {
            DirectionBar(rising: response.rising, unclear: response.unclear, falling: response.falling)
            HStack(spacing: NoopMetrics.space4) {
                directionCounts(response)
            }
        }
    }

    @ViewBuilder private func directionCounts(_ response: StrengthResponseReading) -> some View {
        countLabel(response.rising, symbol: "arrow.up.right", color: StrandPalette.statusPositive, title: "Rising")
        countLabel(response.unclear, symbol: "minus", color: StrandPalette.textTertiary, title: "Unclear")
        countLabel(response.falling, symbol: "arrow.down.right", color: StrandPalette.statusCritical, title: "Falling")
    }

    private func countLabel(_ count: Int, symbol: String, color: Color, title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            StatusBadge(symbol: symbol, color: color, size: 26)
            Text(verbatim: "\(count)")
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Cardio's "is it working": VO₂max over eight weeks — the marker Garmin requires for a productive
    /// load. Shown beside Polar's load status, never changing it.
    private var vo2maxCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Cardio development", overline: "VO₂max, last eight weeks")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let vo2 = model.vo2max, let latest = vo2.latest {
                        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                            TrainingCountUp(value: shownVO2, decimals: 1)
                                .font(StrandFont.number(40, weight: .bold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .accessibilityLabel(Text(latest.value, format: .number.precision(.fractionLength(1))))
                                .task(id: latest.value) {
                                    if reduceMotion {
                                        shownVO2 = latest.value
                                    } else {
                                        withAnimation(StrandMotion.drawIn) { shownVO2 = latest.value }
                                    }
                                }
                            Text(verbatim: "ml/kg/min")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer(minLength: NoopMetrics.space2)
                            vo2Chip(vo2)
                        }
                        VO2maxSparkline(readings: vo2.readings, color: vo2Color(vo2.direction))
                        Text(vo2SourceText(latest))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if vo2.segmentBreak {
                            Text("Earlier readings in this window came from a different estimate and are left out, so a change of method is not shown as fitness.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("No VO₂max readings in the last eight weeks yet. They come from Apple Health, or from NOOP's weekly estimate once your profile and resting heart rate allow it.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func vo2Color(_ direction: FitnessDirection) -> Color {
        switch direction {
        case .improving: return StrandPalette.statusPositive
        case .worsening: return StrandPalette.statusCritical
        default:         return StrandPalette.effortColor
        }
    }

    /// The direction and the change the line implies, e.g. "↗ +1.2 in 7 weeks".
    private func vo2Chip(_ vo2: VO2maxResponse) -> some View {
        let color = vo2Color(vo2.direction)
        let symbol: String
        let text: String
        switch vo2.direction {
        case .improving, .worsening:
            symbol = vo2.direction == .improving ? "arrow.up.right" : "arrow.down.right"
            let change = (vo2.changeOverSpan ?? 0).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))
            let weeks = max(1, Int((Double(vo2.spanDays) / 7).rounded()))
            text = String(localized: "\(change) in \(weeks) weeks")
        case .unclear:
            symbol = "minus"
            text = String(localized: "No clear direction")
        case .unknown:
            symbol = "hourglass"
            text = String(localized: "Needs four readings")
        }
        let muted = vo2.direction == .unknown || vo2.direction == .unclear
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(StrandFont.rounded(11, weight: .bold))
            Text(text).font(StrandFont.captionNumber)
        }
        .foregroundStyle(muted ? StrandPalette.textSecondary : StrandPalette.onDarkPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if muted {
                Capsule().fill(StrandPalette.surfaceInset)
            } else {
                Capsule().fill(color.gradient).shadow(color: color.opacity(0.4), radius: 4, y: 2)
            }
        }
    }

    private func vo2SourceText(_ latest: VO2maxReading) -> String {
        if latest.segment == Repository.appleHealthSource {
            return String(localized: "Measured by Apple Watch during outdoor walks and runs.")
        }
        // Name the estimator when the reading carries its provenance; never print "Unknown" in its place.
        guard let estimator = Vo2MaxEstimator(rawValue: latest.segment) else {
            return String(localized: "Estimated by NOOP from your resting heart rate and activity. An estimate, not a lab test.")
        }
        let name = vo2MaxEstimatorDisplayName(estimator)
        return String(localized: "Estimated by NOOP (\(name)) from your resting heart rate and activity. An estimate, not a lab test.")
    }

    // MARK: - Session lane and coverage

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Session load", overline: "Your own rating")
            laneCard(icon: "person.fill.checkmark", title: "Session load", lane: model.session,
                     value: sessionText, tint: StrandPalette.metricCyan, coverage: sessionCoverage)
        }
    }

    /// Two things the seven-day mean throws away on purpose: how the week was DISTRIBUTED, and how it
    /// compares with the week before rather than with a 28-day baseline.
    ///
    /// Neither is a verdict, and the card says so in as many words. Monotony and strain (Foster 1998)
    /// describe a week's shape — 600 units in one session is not 100 units on six days — and week over
    /// week is the comparison a training plan is actually written in: no threshold to look up, and no
    /// overlap between the two windows it compares, which the load ratio cannot say of itself.
    @ViewBuilder private var shapeCard: some View {
        if hasShapeData {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Shape of the week", overline: "Spread and ramp")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        shapeRow(symbol: "figure.strengthtraining.traditional", title: "Strength",
                                 lane: model.strength)
                        Divider().overlay(StrandPalette.hairline)
                        shapeRow(symbol: "heart.fill", title: "Cardiovascular", lane: model.cardio)
                        Text("Monotony is how evenly the week was spread — higher means flatter, much the same load every day. Strain is the week's total multiplied by it. Both describe the shape of a week; neither judges it.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var hasShapeData: Bool {
        [model.strength, model.cardio].contains { $0?.distribution != nil || $0?.weekOverWeek != nil }
    }

    private func shapeRow(symbol: String, title: LocalizedStringKey,
                          lane: TrainingLoadModel.Lane?) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            StatusBadge(symbol: symbol, color: lane?.status?.status.color ?? StrandPalette.textTertiary,
                        size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(shapeText(lane))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func shapeText(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane else { return String(localized: "Nothing recorded yet") }
        var parts: [String] = []
        if let ramp = lane.weekOverWeek {
            parts.append(String(localized: "\(signedPercent(ramp)) against last week"))
        }
        if let shape = lane.distribution {
            let monotony = String(format: "%.1f", shape.monotony)
            let strain = String(format: "%.0f", shape.strain)
            parts.append(String(localized: "Monotony \(monotony) · Strain \(strain)"))
        }
        return parts.isEmpty
            ? String(localized: "Not enough known days yet to describe this week's shape")
            : parts.joined(separator: " · ")
    }

    private var basisCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What it rests on", overline: "Data coverage")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    basisRow(symbol: "figure.strengthtraining.traditional", share: coverageShare(model.strength),
                             text: strengthCoverage(model.strength))
                    Divider().overlay(StrandPalette.hairline)
                    basisRow(symbol: "heart.fill", share: coverageShare(model.cardio),
                             text: cardioCoverage(model.cardio))
                }
            }
        }
    }

    /// The measured share of a lane's figure, nil when there is nothing to measure.
    private func coverageShare(_ lane: TrainingLoadModel.Lane?) -> Double? {
        guard let lane, lane.possibleCount > 0 else { return nil }
        return Double(lane.measuredCount) / Double(lane.possibleCount)
    }

    private func basisRow(symbol: String, share: Double?, text: String) -> some View {
        let color = share.map { $0 >= TrainingLoad.trustedRatedShare ? StrandPalette.statusPositive
                                                                      : StrandPalette.statusWarning }
            ?? StrandPalette.textTertiary
        return HStack(alignment: .center, spacing: NoopMetrics.space3) {
            CoverageRing(fraction: share ?? 0, color: color, symbol: symbol)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func laneCard(icon: String, title: LocalizedStringKey, lane: TrainingLoadModel.Lane?,
                          value: @escaping (TrainingLoadModel.Lane?) -> String, tint: Color,
                          coverage: @escaping (TrainingLoadModel.Lane?) -> String) -> some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
                    Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if let trend = lane?.trend {
                        Text(signedPercent(trend.percentChange))
                            .font(StrandFont.number(18))
                            .foregroundStyle(abs(trend.percentChange) < 15
                                             ? StrandPalette.textSecondary : StrandPalette.metricCyan)
                    }
                }
                Text(value(lane))
                    .font(StrandFont.number(28))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(lane?.trend.map { comparisonText($0.percentChange) }
                     ?? String(localized: "Needs two weeks of measured history"))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(coverage(lane))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Legend and method

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("The six states", overline: "Legend")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(TrainingStatus.allCases, id: \.self) { status in
                        HStack(alignment: .top, spacing: NoopMetrics.space3) {
                            StatusBadge(symbol: status.symbol, color: status.color, size: 34, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.label)
                                    .font(StrandFont.subhead.weight(.semibold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(status.meaning)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What each number means", overline: "Transparent by design")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    // The lane titles, not bare "Strength/Cardio/Session": the method rows explain the three
                    // cards above and have to name them the same way in every language.
                    methodRow("Strength load", "Working sets weighted by proximity to failure. Tonnage remains a training statistic, not the load.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("Cardiovascular load", "Classic Edwards TRIMP from time in percentages of your maximum heart rate. NOOP band data wins; workout-associated Health data fills only when the band trace is incomplete.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("Session load", "Your whole-session RPE × duration. Add it from any workout detail; missing ratings are never guessed.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("How comparison works", "NOOP compares the last 7 days with an earlier, non-overlapping baseline. A partial training day stays visible as a lower bound but leaves the comparison. After eight complete weeks, robust personal variation replaces fixed population-style bands.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("Load and adaptation", "Relative load is descriptive. Productive development requires a clear performance trend: estimated one-rep max for strength or VO₂max within one consistent measurement method for cardiovascular training.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("Sources", "Edwards 1993 · Banister 1991 · Foster 2001 · Bosquet et al. 2013 · Meeusen et al. 2013 · Pelland et al. 2024 · Robinson et al. 2024")
                }
            }
        }
    }

    private func methodRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatting

    private func signedPercent(_ value: Double) -> String {
        let magnitude = Int(abs(value).rounded())
        // A change that rounds to zero has no direction; "+0 %" or "−0 %" would imply one.
        guard magnitude > 0 else { return "0 %" }
        return "\(value > 0 ? "+" : "−")\(magnitude) %"
    }

    private func comparisonText(_ value: Double) -> String {
        if value >= 15 { return String(localized: "Above your usual") }
        if value <= -15 { return String(localized: "Below your usual") }
        return String(localized: "About your usual")
    }

    private func weightedSetText(_ lane: TrainingLoadModel.Lane) -> String {
        let number = lane.sevenDayTotal.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(number) weighted sets")
    }

    private func effortText(_ lane: TrainingLoadModel.Lane) -> String {
        let total = Int(lane.sevenDayTotal.rounded())
        return String(localized: "\(total) TRIMP")
    }

    private func sessionText(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane, lane.measuredCount > 0 else { return "—" }
        return String(localized: "\(Int(lane.sevenDayTotal.rounded())) AU")
    }

    /// How much of the effort weighting is measured rather than the unrated default. Counted, not a
    /// percentage, so a share that rests on a handful of sets reads as a handful of sets.
    private func strengthCoverage(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane, lane.possibleCount > 0 else {
            return String(localized: "No working sets in the last 7 days")
        }
        let rated = lane.measuredCount
        let total = lane.possibleCount
        if rated == total {
            return String(localized: "All \(total) working sets in the last 7 days carry an RPE")
        }
        if Double(rated) / Double(total) < TrainingLoad.trustedRatedShare {
            return String(localized: "Only \(rated) of \(total) working sets in the last 7 days carry an RPE, so most of the weighting is estimated")
        }
        return String(localized: "\(rated) of \(total) working sets in the last 7 days carry an RPE; the rest use your recent median when available")
    }

    private func cardioCoverage(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane, lane.possibleCount > 0 else { return String(localized: "No cardiovascular sessions yet") }
        if lane.measuredCount < lane.possibleCount {
            return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) sessions fully measured; partial days do not enter your comparison")
        }
        return String(localized: "All \(lane.possibleCount) sessions have enough heart-rate data")
    }

    private func sessionCoverage(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane, lane.possibleCount > 0 else { return String(localized: "Open a workout to add your first session rating") }
        return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) sessions rated in the last 7 days")
    }
}
