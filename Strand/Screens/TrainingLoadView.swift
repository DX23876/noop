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
        /// How evenly the last seven days were loaded (Foster 1998). Nil below seven known days, and when
        /// every known day carried exactly the same load — an undefined figure, not a flat week.
        let distribution: LoadDistribution?
        /// This week's total against the week before it, as a signed percentage. Nil without two weeks.
        let weekOverWeek: Double?
        /// What the lane's figure rests on over the last 28 days, in the lane's own unit: RPE-rated
        /// working sets for Strength, sessions with adequate HR for Cardio, rated sessions for Session.
        let measuredCount: Int
        let possibleCount: Int
        /// The lane's band and the runs behind it (`LaneEngine`) — the one reading every surface shows.
        /// Nil for the session lane, which has no band.
        let reading: LaneReading?
    }

    /// One day's ratio and band per lane, for the eight-week chart. Nil while that day had no comparison.
    struct RatioPoint: Sendable, Identifiable {
        let day: String
        let strength: Double?
        let cardio: Double?
        var strengthBand: RelativeLoadBand? = nil
        var cardioBand: RelativeLoadBand? = nil
        var id: String { day }
    }

    struct Prepared: Sendable {
        let strength: Lane
        let cardio: Lane
        let session: Lane
        let response: StrengthResponseReading
        let vo2display: VO2maxDisplay
        let cardioEvidence: CardioEvidenceReading
        let recovery: RecoveryReading
        let history: [TrainingStatusModel.WeeklyLoadBands]
        let ratios: [RatioPoint]
        let strengthVerdict: LaneVerdict?
        let cardioVerdict: LaneVerdict?
        let statement: TrainingStatusModel.TrainingStatement
        let sustained: SustainedOverreaching?
        let cardioMeasured: Bool
        let strengthAdaptation: TrainingAdaptationReading
        let cardiovascularAdaptation: TrainingAdaptationReading
        let provisionalStrengthRing: ProvisionalStrengthRingReading?
    }

    /// Days of history read: the oldest week-end of the eight-week strip, 49 days back, plus everything
    /// a reading on that day depends on (`TrainingLoadLanes.lookbackDays`).
    private static let historyDays = 7 * 7 + TrainingLoadLanes.lookbackDays

    @Published private(set) var strength: Lane?
    @Published private(set) var cardio: Lane?
    @Published private(set) var session: Lane?
    /// Which way the lifts of the last six weeks are moving — strength adaptation evidence.
    @Published private(set) var strengthResponse: StrengthResponseReading?
    /// The VO₂max the card shows: NOOP's estimate as the headline, Apple's latest reading beside it.
    @Published private(set) var vo2display: VO2maxDisplay?
    /// The cardio lane's performance evidence — fresh Apple VO₂max, else heart-rate efficiency, else none.
    @Published private(set) var cardioEvidence: CardioEvidenceReading?
    /// Overreaching that has lasted with performance falling and recovery strained, if present.
    @Published private(set) var sustainedOverreaching: SustainedOverreaching?
    /// How recovery has held over the last seven nights.
    @Published private(set) var recovery: RecoveryReading?
    /// Each lane's band at the end of each of the last eight weeks, oldest first.
    @Published private(set) var history: [TrainingStatusModel.WeeklyLoadBands] = []
    /// Each lane's verdict (`LaneEngine.verdict`): a judgement only where performance evidence allows one.
    @Published private(set) var strengthVerdict: LaneVerdict?
    @Published private(set) var cardioVerdict: LaneVerdict?
    /// What the two verdicts say together — the page's single statement.
    @Published private(set) var statement: TrainingStatusModel.TrainingStatement = .noHistory
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
                         dailyRows: dailyRows, vo2Estimates: vo2.estimates, vo2Apple: vo2.apple,
                         today: today, now: now, offset: offset)
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
        vo2display = prepared.vo2display
        cardioEvidence = prepared.cardioEvidence
        sustainedOverreaching = prepared.sustained
        recovery = prepared.recovery
        history = prepared.history
        ratios = prepared.ratios
        strengthVerdict = prepared.strengthVerdict
        cardioVerdict = prepared.cardioVerdict
        statement = prepared.statement
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
                                    vo2Estimates: [VO2maxReading], vo2Apple: [VO2maxReading] = [],
                                    today: String, now: Int,
                                    offset: Int) -> Prepared {
        let strengthWorkouts = strengthHistory.workouts
        let templates = strengthHistory.templates
        let strengthByDay = TrainingLoadLanes.strengthByDay(strengthWorkouts, tzOffsetSeconds: offset)
        let cardioSeries = TrainingLoadLanes.cardioSeries(sessions: unified, resolution: cardioResolution,
                                                          tzOffsetSeconds: offset)
        let cardioByDay = cardioSeries.byDay
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

        // Each lane is read through today only once something was logged today; before that, through
        // yesterday. A day that has not happened yet is not a rest day (`LaneEngine.readingDay`).
        let strengthActivity = TrainingLoadLanes.strengthActivity(strengthWorkouts, tzOffsetSeconds: offset)
        let strengthDay = LaneEngine.readingDay(today: today,
                                                hasActivityToday: (strengthActivity.sessionsByDay[today] ?? 0) > 0)
        let cardioDay = LaneEngine.readingDay(today: today,
                                              hasActivityToday: (cardioSeries.activity.sessionsByDay[today] ?? 0) > 0)
        let sessionDay = LaneEngine.readingDay(today: today,
                                               hasActivityToday: !(possibleSessionKeysByDay[today] ?? []).isEmpty)

        let cutoff = WeeklyDigestEngine.addDays(sessionDay, -6)
        let possible = possibleSessionKeysByDay.filter { $0.key >= cutoff && $0.key <= sessionDay }
            .values.reduce(0) { $0 + $1.count }
        let measured = ratedSessionKeysByDay.filter { $0.key >= cutoff && $0.key <= sessionDay }
            .values.reduce(0) { $0 + $1.count }

        // Load, adaptation and recovery stay separate. The latter two may provide context, but do
        // not turn a high load into a positive or medical verdict.
        let response = TrainingStatusModel.strengthResponse(workouts: strengthWorkouts,
                                                            templates: templates, through: today,
                                                            tzOffsetSeconds: offset)
        let recovery = TrainingStatusModel.recovery(days: dailyRows, through: today)
        let strengthLane = TrainingLoadLanes.strengthLane(workouts: strengthWorkouts, byDay: strengthByDay,
                                                          through: strengthDay, tzOffsetSeconds: offset)
        let cardioLane = TrainingLoadLanes.cardioLane(sessions: unified, resolution: cardioResolution,
                                                      series: cardioSeries, through: cardioDay,
                                                      tzOffsetSeconds: offset)
        let sessionRelative = TrainingLoad.relativeLoad(dailyByDay: sessionByDay, through: sessionDay,
                                                        unknownDays: sessionUnknown)
        let history = TrainingStatusModel.weeklyBands(
            strength: LaneEngine.readings(dailyByDay: strengthByDay, activity: strengthActivity, lane: .strength,
                                          days: TrainingStatusModel.weekEnds(weeks: 8, through: strengthDay)),
            cardio: LaneEngine.readings(dailyByDay: cardioByDay, unknownDays: cardioUnknown,
                                        activity: cardioSeries.activity, lane: .cardio,
                                        days: TrainingStatusModel.weekEnds(weeks: 8, through: cardioDay)))
        // The chart runs to the later of the two reading days; a lane read through yesterday leaves today
        // empty rather than drawing a point the hero does not show.
        let ratios = TrainingLoadLanes.ratios(strengthByDay: strengthByDay, strengthActivity: strengthActivity,
                                              cardio: cardioSeries, through: max(strengthDay, cardioDay))
            .map { point in
                TrainingLoadModel.RatioPoint(day: point.day,
                                             strength: point.day <= strengthDay ? point.strength : nil,
                                             cardio: point.day <= cardioDay ? point.cardio : nil,
                                             strengthBand: point.day <= strengthDay ? point.strengthBand : nil,
                                             cardioBand: point.day <= cardioDay ? point.cardioBand : nil)
            }
        // What the card shows and what counts as evidence are separate questions: NOOP's estimate is the
        // headline, but it is partly built from the load it would be judging, so the cardio verdict reads
        // fresh Apple VO₂max or the lane's own heart-rate efficiency instead (`CardioEvidence`).
        let vo2display = CardioEvidence.display(estimates: vo2Estimates, apple: vo2Apple, through: today)
        let cardioSessions = CardioSession.sessions(
            unified.filter { !cardioResolution.duplicateSessionIds.contains($0.id) }.map(\.row),
            tzOffsetSeconds: offset)
        let cardioEvidenceReading = CardioEvidence.reading(apple: vo2Apple, sessions: cardioSessions, through: today)
        let strengthAdaptation = TrainingStatusModel.strengthAdaptation(response)
        let cardiovascularAdaptation = TrainingStatusModel.cardiovascularAdaptation(cardioEvidenceReading)
        let strengthEvidence = LaneEvidence(response.direction)
        let cardioEvidence = cardioEvidenceReading.evidence
        let strengthVerdict = strengthLane.reading.flatMap {
            LaneEngine.verdict($0, evidence: strengthEvidence, recovery: recovery.state, lane: .strength)
        }
        let cardioVerdict = cardioLane.reading.flatMap {
            LaneEngine.verdict($0, evidence: cardioEvidence, recovery: recovery.state, lane: .cardio)
        }
        let sustained = TrainingStatusModel.sustainedOverreaching(history: history, strengthEvidence: strengthEvidence,
                                                                  cardioEvidence: cardioEvidence,
                                                                  recovery: recovery)
        let provisionalStrengthRing: ProvisionalStrengthRingReading?
        if strengthLane.trend == nil {
            let ringCutoff = WeeklyDigestEngine.addDays(strengthDay, -6)
            let recentResolved = strengthHistory.sessions.filter {
                let day = AnalyticsEngine.dayString($0.startTs, offsetSec: offset)
                return day >= ringCutoff && day <= strengthDay
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
            strength: strengthLane,
            cardio: cardioLane,
            session: Lane(sevenDayTotal: TrainingLoadLanes.lastSeven(sessionByDay, through: sessionDay),
                          sevenDayWorkingSets: 0,
                          trend: sessionRelative.trend,
                          relative: sessionRelative,
                          isLowerBound: TrainingLoadLanes.lastSevenContainsUnknown(sessionUnknown, through: sessionDay),
                          distribution: TrainingLoad.distribution(dailyByDay: sessionByDay, through: sessionDay,
                                                                  unknownDays: sessionUnknown),
                          weekOverWeek: TrainingLoad.weekOverWeek(dailyByDay: sessionByDay, through: sessionDay,
                                                                  unknownDays: sessionUnknown),
                          measuredCount: measured, possibleCount: possible, reading: nil),
            response: response,
            vo2display: vo2display,
            cardioEvidence: cardioEvidenceReading,
            recovery: recovery,
            history: history,
            ratios: ratios,
            strengthVerdict: strengthVerdict,
            cardioVerdict: cardioVerdict,
            statement: TrainingStatusModel.statement(strength: strengthVerdict, cardio: cardioVerdict,
                                                     recovery: recovery.state),
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
    /// Screenshot QA for the statement matrix. The seeded demo history cannot produce a split, so
    /// `--demo-status split-sharp|split-mild|both-high` overrides the two verdicts and bands after a
    /// normal load. Display only: nothing is stored, and every figure beneath the statement still comes
    /// from the seeded data.
    private func applyDemoStatusOverride() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--demo-status"), index + 1 < args.count else { return }
        let pair: (strength: (LaneVerdict, RelativeLoadBand), cardio: (LaneVerdict, RelativeLoadBand))
        switch args[index + 1] {
        case "split-sharp": pair = ((.status(.detraining), .below), (.status(.overreaching), .muchHigher))
        case "split-mild":  pair = ((.status(.productive), .higher), (.status(.detraining), .below))
        case "both-high":   pair = ((.status(.overreaching), .muchHigher), (.status(.overreaching), .muchHigher))
        default: return
        }
        func overridden(_ lane: Lane?, band: RelativeLoadBand) -> Lane? {
            guard let lane else { return nil }
            return Lane(sevenDayTotal: lane.sevenDayTotal, sevenDayWorkingSets: lane.sevenDayWorkingSets,
                        trend: lane.trend, relative: lane.relative, isLowerBound: lane.isLowerBound,
                        distribution: lane.distribution, weekOverWeek: lane.weekOverWeek,
                        measuredCount: lane.measuredCount, possibleCount: lane.possibleCount,
                        reading: lane.reading?.replacingBand(band))
        }
        strength = overridden(strength, band: pair.strength.1)
        cardio = overridden(cardio, band: pair.cardio.1)
        strengthVerdict = pair.strength.0
        cardioVerdict = pair.cardio.0
        statement = TrainingStatusModel.statement(strength: strengthVerdict, cardio: cardioVerdict,
                                                  recovery: recovery?.state ?? .unknown)
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

    /// Both VO₂max series, each reading tagged with where it came from: NOOP's weekly estimate (by its
    /// estimator, Nes 2011 or Uth 2004, so no line is drawn across a change of method) and Apple Watch's
    /// measured Cardio Fitness. `CardioEvidence` decides what each is used for.
    private static func vo2maxReadings(repo: Repository) async -> (estimates: [VO2maxReading], apple: [VO2maxReading]) {
        let appleSeries = await repo.exploreSeries(key: "vo2max", source: Repository.appleHealthSource, days: 90)
        let apple = appleSeries.map { VO2maxReading(day: $0.day, value: $0.value, segment: Repository.appleHealthSource) }
        let resolution = await repo.resolvedSeries(key: "vo2max_est", source: Repository.whoopSource, days: 90)
        var estimates: [VO2maxReading] = []
        for point in resolution.points {
            let tag = await repo.scoreProvenanceTag(resolvedSource: point.source, day: point.day,
                                                    metricKey: "vo2max_est")
            estimates.append(VO2maxReading(day: point.day, value: point.value, segment: tag ?? point.source))
        }
        return (estimates, apple)
    }
}

struct TrainingLoadView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = TrainingLoadModel()
    @State private var shownVO2: Double = 0
    @State private var openSummary: SummaryDetail?
    @State private var adviceBounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum SummaryDetail: String, Identifiable {
        case adaptation, recovery, history, session
        var id: String { rawValue }
    }

    var body: some View {
        ScreenScaffold(title: "Training Load",
                       subtitle: "Three views of training, each in the unit that fits it.",
                       onRefresh: { await model.load(repo: repo) }) {
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                // Named sections for `--demo-scroll-to` screenshot QA (DEBUG only; ids are inert otherwise).
                hero.id("hero")
                statementCard.trainingCardEntrance().id("advice")
                maturityLine
                duplicateReviewCard
                sustainedCard
                summaryGrid.trainingCardEntrance().id("statement")
                developmentCards.trainingCardEntrance().id("lifts")
                shapeCard.trainingCardEntrance().id("shape")
                explainers.trainingCardEntrance().id("method")
            }
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
        .sheet(item: $openSummary) { detail in summarySheet(detail) }
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

    // MARK: - The two lanes

    /// Strength and cardio side by side, each in its own unit and colour. Never one combined figure: the
    /// two lanes are measured differently, and a blended score would need an invented exchange rate.
    private var hero: some View {
        HStack(alignment: .top, spacing: NoopMetrics.gap) {
            laneLink(to: .strength) {
                LoadHeroCard(lane: .strength, percent: model.strength?.trend?.percentChange,
                             state: LoadPillState.of(model.strength,
                                                     provisional: model.provisionalStrengthRing != nil),
                             figure: strengthFigure, trend: model.ratios.compactMap(\.strength),
                             coverage: strengthEvidence, caveat: strengthCaveat,
                             note: provisionalNote ?? capNote(model.strength), compact: true)
            }
            laneLink(to: .cardio) {
                LoadHeroCard(lane: .cardio, percent: model.cardio?.trend?.percentChange,
                             state: LoadPillState.of(model.cardio), figure: cardioFigure,
                             trend: model.ratios.compactMap(\.cardio), coverage: cardioEvidence,
                             caveat: cardioCaveat, note: capNote(model.cardio), compact: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// On iOS a lane opens its own screen. The macOS detail column has no navigation stack to push onto,
    /// and both screens sit in its sidebar anyway.
    @ViewBuilder private func laneLink<Label: View>(to lane: TrainingLane,
                                                     @ViewBuilder label: () -> Label) -> some View {
        #if os(iOS)
        NavigationLink {
            if lane == .strength { StrengthView() } else { CardioView() }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .strandPressable()
        #else
        label()
        #endif
    }

    /// Before a personal comparison exists the strength lane can still say roughly how much the week was.
    private var provisionalNote: String? {
        guard model.strength?.reading?.band == nil, let reading = model.provisionalStrengthRing else { return nil }
        let amount: String
        switch reading.band {
        case .low: amount = String(localized: "Low")
        case .moderate: amount = String(localized: "Moderate")
        case .high: amount = String(localized: "High")
        case .veryHigh: amount = String(localized: "Very high")
        }
        return "\(amount) · \(String(localized: "provisional seven-day amount"))"
    }

    /// Said whenever the low-volume guard shaped the band, so "above usual" is never read as the most the
    /// scale can say about a real jump.
    private func capNote(_ lane: TrainingLoadModel.Lane?) -> String? {
        guard lane?.reading?.guardState == .lowVolumeCap else { return nil }
        return String(localized: "Your usual training is below the WHO weekly minimum, so this reads at most “above usual”.")
    }

    @ViewBuilder private var maturityLine: some View {
        if currentMaturity != .personalBaseline {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                Image(systemName: maturitySymbol)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.metricCyan)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(maturityTitle)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(maturityDetail)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, NoopMetrics.space1)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - At a glance

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.gap),
                            GridItem(.flexible(), spacing: NoopMetrics.gap)],
                  spacing: NoopMetrics.gap) {
            SummaryTile(symbol: "chart.line.uptrend.xyaxis", tint: StrandPalette.statusPositive,
                        title: String(localized: "Adaptation"), headline: nil,
                        action: { openSummary = .adaptation }) {
                VStack(alignment: .leading, spacing: 6) {
                    adaptationMini(.strength, model.strengthAdaptation)
                    adaptationMini(.cardio, model.cardiovascularAdaptation)
                }
            }
            SummaryTile(symbol: "moon.zzz.fill", tint: recoveryTint, title: String(localized: "Recovery"),
                        headline: nil, detail: recoverySummary, action: { openSummary = .recovery }) {
                recoveryDots
            }
            SummaryTile(symbol: "calendar", tint: StrandPalette.metricCyan,
                        title: String(localized: "Last 8 weeks"), headline: nil,
                        action: { openSummary = .history }) {
                VStack(alignment: .leading, spacing: 6) {
                    historyStrip(.strength)
                    historyStrip(.cardio)
                }
            }
            SummaryTile(symbol: "person.fill.checkmark", tint: StrandPalette.metricCyan,
                        title: String(localized: "Session load"), headline: sessionText(model.session),
                        detail: model.session?.trend.map {
                            "\(signedPercent($0.percentChange)) · \(comparisonText($0.percentChange))"
                        } ?? String(localized: "Needs two weeks of measured history"),
                        action: { openSummary = .session }) {
                EmptyView()
            }
        }
    }

    private func adaptationMini(_ lane: TrainingLane, _ reading: TrainingAdaptationReading?) -> some View {
        let presentation = adaptationPresentation(reading)
        return HStack(spacing: 6) {
            Image(systemName: lane.symbol)
                .font(StrandFont.caption)
                .foregroundStyle(lane.color)
                .frame(width: 14)
            Label(presentation.1, systemImage: presentation.0)
                .font(StrandFont.caption)
                .foregroundStyle(presentation.2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoveryTint: Color {
        switch model.recovery?.state {
        case .strained: return StrandPalette.statusWarning
        case .holding: return StrandPalette.statusPositive
        default: return StrandPalette.textTertiary
        }
    }

    private var recoveryDots: some View {
        HStack(spacing: NoopMetrics.space2) {
            recoveryDot("HRV", key: "hrv")
            recoveryDot("Resting HR", key: "rhr")
            recoveryDot("Breathing", key: "respRate")
        }
    }

    private func recoveryDot(_ title: LocalizedStringKey, key: String) -> some View {
        let read = model.recovery?.readOnLatestNight.contains(key) ?? false
        let flagging = model.recovery?.flaggingOnLatestNight.contains(key) ?? false
        let color = !read ? StrandPalette.textTertiary
            : (flagging ? StrandPalette.statusWarning : StrandPalette.statusPositive)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
        }
        .minimumScaleFactor(0.7)
    }

    /// Eight weeks for one lane, oldest first: stronger colour for a week further above that lane's usual.
    private func historyStrip(_ lane: TrainingLane) -> some View {
        let weeks = Array(model.history.suffix(8))
        return HStack(spacing: 3) {
            Image(systemName: lane.symbol)
                .font(StrandFont.caption)
                .foregroundStyle(lane.color)
                .frame(width: 14)
            ForEach(weeks.indices, id: \.self) { index in
                let band = lane == .strength ? weeks[index].strength : weeks[index].cardio
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(band.map { lane.color.opacity(historyOpacity($0)) } ?? StrandPalette.surfaceInset)
                    .frame(height: 14)
            }
        }
        .accessibilityHidden(true)
    }

    private func historyOpacity(_ band: RelativeLoadBand) -> Double {
        switch band {
        case .below: return 0.3
        case .usual: return 0.55
        case .higher: return 0.8
        case .muchHigher: return 1
        }
    }

    private func summarySheet(_ detail: SummaryDetail) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    switch detail {
                    case .adaptation: adaptationCard
                    case .recovery: recoveryCard
                    case .history: historyCard
                    case .session: sessionCard
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { openSummary = nil } }
            }
        }
    }

    private var developmentCards: some View {
        AdaptiveTwoColumn {
            strengthSummaryCard
        } trailing: {
            vo2maxCard
        }
    }

    private var explainers: some View {
        ExplainerRows(items: [
            ExplainerItem(id: "maturity", symbol: maturitySymbol, title: maturityTitle,
                          subtitle: maturityDetail, text: maturityDetail),
            ExplainerItem(id: "basis", symbol: "checkmark.seal", title: String(localized: "What it rests on"),
                          subtitle: String(localized: "Data coverage")) { basisRows },
            ExplainerItem(id: "method", symbol: "function", title: String(localized: "What each number means"),
                          subtitle: String(localized: "Transparent by design")) { methodRows },
        ])
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
        return "\(raw) · \(estimated)"
    }

    private var cardioFigure: String? {
        guard let lane = model.cardio else { return nil }
        return lane.isLowerBound ? String(localized: "at least \(effortText(lane))") : effortText(lane)
    }

    /// What the strength verdict rests on — a below-usual run, the lifts, or an honest "load only".
    private var strengthEvidence: String? {
        guard let lane = model.strength else { return nil }
        if lane.reading?.guardState == .tooFewSessions {
            return String(localized: "Fewer than 3 sessions in the comparison window yet")
        }
        guard let reading = lane.reading, reading.band != nil else {
            return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) working sets rated · comparison available after 21 complete days")
        }
        if reading.band == .below, reading.daysBelowUsual > 0 { return belowSinceText(reading.daysBelowUsual, through: reading.day) }
        return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) working sets rated · compared only with your strength history")
    }

    private var cardioEvidence: String? {
        guard let lane = model.cardio else { return nil }
        if lane.reading?.guardState == .tooFewSessions {
            return String(localized: "Fewer than 3 sessions in the comparison window yet")
        }
        guard let reading = lane.reading, reading.band != nil else {
            return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) sessions complete · comparison available after 21 complete days")
        }
        if reading.band == .below, reading.daysBelowUsual > 0 { return belowSinceText(reading.daysBelowUsual, through: reading.day) }
        return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) sessions complete · compared only with your cardiovascular history")
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

    /// Symbol, words and colour for one lane's adaptation reading.
    private func adaptationPresentation(_ reading: TrainingAdaptationReading?) -> (String, String, Color) {
        switch reading?.state ?? .notEnoughData {
        case .improving:
            return ("arrow.up.right", String(localized: "Productive development"), StrandPalette.statusPositive)
        case .declining:
            return ("arrow.down.right", String(localized: "Performance trending down"), StrandPalette.statusWarning)
        case .stable:
            return ("equal", String(localized: "Performance stable"), StrandPalette.metricCyan)
        case .unclear:
            return ("minus", String(localized: "No clear direction"), StrandPalette.textSecondary)
        case .notEnoughData:
            return ("hourglass", String(localized: "Adaptation not assessable yet"), StrandPalette.textTertiary)
        }
    }

    private func adaptationRow(symbol: String, title: LocalizedStringKey,
                               reading: TrainingAdaptationReading?) -> some View {
        let presentation = adaptationPresentation(reading)
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
    private func belowSinceText(_ days: Int, through day: String) -> String {
        let since = WeeklyDigestEngine.addDays(day, -(days - 1))
        return String(localized: "Below your usual since \(StatusHistoryStrip.shortDate(since))")
    }

    // MARK: - What the two lanes say together

    private struct Advice {
        let symbol: String
        let color: Color
        let text: String
        /// A second colour for a statement that speaks about BOTH lanes at once — the card then runs
        /// from the lane that is falling behind to the one that is ahead.
        var secondary: Color? = nil
        /// Whether the card may be painted in the colour itself rather than washed with it. Yellow is
        /// the exception: white text on it fails to read.
        var filled = true
    }

    /// The page's one statement, dressed. The DECISION is pure and lives in
    /// `TrainingStatusModel.statement(strength:cardio:recovery:)`, where every pair of verdicts is
    /// resolved and covered by tests; this only chooses the words, the glyph and the colours.
    private var advice: Advice {
        switch model.statement {
        case .noHistory:
            return Advice(symbol: "hourglass", color: StrandPalette.textTertiary,
                          text: String(localized: "After two weeks of training this shows whether it is building, holding or too much."),
                          filled: false)

        case let .laneOnly(lane, verdict):
            return Advice(symbol: verdict.symbol, color: verdict.color,
                          text: sentence(for: verdict, lane: lane) + " "
                              + String(localized: "The other lane needs two more weeks of measured history."),
                          filled: verdict != .status(.unproductive))

        case let .aligned(verdict):
            return Advice(symbol: verdict.symbol, color: verdict.color, text: sentence(for: verdict, lane: nil),
                          filled: verdict != .status(.unproductive))

        case let .oneBehind(lane):
            return Advice(symbol: TrainingStatus.detraining.symbol, color: laneColor(lane),
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
            return Advice(symbol: TrainingStatus.overreaching.symbol, color: TrainingStatus.overreaching.color,
                          text: text)

        case .bothExcessive:
            return Advice(symbol: TrainingStatus.overreaching.symbol, color: TrainingStatus.overreaching.color,
                          text: String(localized: "Both lanes are well above your usual. Fine for a short block, but not both at once for long."))

        case let .spinning(lane, otherAlsoHigh):
            // Both facts, side by side. That the other lane's block is what costs this one its progress is
            // plausible and unmeasured, so the card does not say it.
            let text: String
            switch (lane, otherAlsoHigh) {
            case (.strength, true):
                text = String(localized: "Plenty of strength work without the lifts improving, and your cardio is well above your usual too. Decide which of the two to ease first.")
            case (.strength, false):
                text = String(localized: "Plenty of strength work, but your lifts are not improving. More volume will not fix that: look at sleep, recovery or the programme.")
            case (.cardio, true):
                text = String(localized: "Plenty of cardio without your endurance improving, and your strength work is well above your usual too. Decide which of the two to ease first.")
            case (.cardio, false):
                text = String(localized: "Plenty of cardio, but your endurance is not improving. More volume will not fix that: look at sleep, recovery or how the sessions are built.")
            }
            return Advice(symbol: TrainingStatus.unproductive.symbol, color: TrainingStatus.unproductive.color,
                          text: text, filled: false)

        case .bothSpinning:
            return Advice(symbol: TrainingStatus.unproductive.symbol, color: TrainingStatus.unproductive.color,
                          text: String(localized: "Both lanes are trained at or above your usual while performance falls in each. Ease the load and look at sleep and recovery before adding more."),
                          filled: false)

        case .strainedRecovery:
            return Advice(symbol: "moon.zzz.fill", color: TrainingStatus.unproductive.color,
                          text: String(localized: "Your recovery signals flagged on several recent nights. Hold your load rather than raising it."),
                          filled: false)
        }
    }

    /// The lane's own colour — the same one its band carries.
    private func laneColor(_ lane: TrainingStatusModel.TrainingStatementLane) -> Color {
        let verdict = lane == .strength ? model.strengthVerdict : model.cardioVerdict
        return verdict?.color ?? StrandPalette.textTertiary
    }

    /// One verdict in a sentence, for the cases that speak about a single state. A description — no
    /// performance evidence — says what the load did and nothing about what it achieved.
    private func sentence(for verdict: LaneVerdict, lane: TrainingStatusModel.TrainingStatementLane?) -> String {
        switch verdict {
        case .status(.detraining):
            return String(localized: "You have been training well below your usual level. If this is not a planned break, restart with a few easy sessions.")
        case .status(.recovering):
            return String(localized: "A lighter stretch after a hard phase. Good timing to let strength and fitness settle.")
        case .status(.maintaining):
            return String(localized: "You are holding your level. To build, raise the load in small steps.")
        case .status(.productive):
            return model.recovery?.state == .holding
                ? String(localized: "Your build is working: load at or above your usual, and your recovery is keeping up.")
                : String(localized: "Your build is working: load at or above your usual, and it is paying off.")
        case .status(.unproductive):
            return lane == .cardio
                ? String(localized: "Plenty of cardio, but your endurance is not improving. More volume will not fix that: look at sleep, recovery or how the sessions are built.")
                : String(localized: "Plenty of strength work, but your lifts are not improving. More volume will not fix that: look at sleep, recovery or the programme.")
        case .status(.overreaching):
            return lane == .cardio
                ? String(localized: "Much more cardio than usual. Hold here until your usual level catches up.")
                : String(localized: "Much more strength work than usual. Hold here until your usual level catches up.")
        case .loadOnly(.below):
            return String(localized: "Less training than usual. Whether it costs fitness shows once there is performance data.")
        case .loadOnly(.usual):
            return String(localized: "Training at your usual level. Performance data will show whether it is building or holding.")
        case .loadOnly(.higher):
            return String(localized: "More training than usual. Whether it pays off shows once there is performance data.")
        case .loadOnly(.muchHigher):
            return String(localized: "Much more training than usual. Watch your recovery; whether it pays off shows once there is performance data.")
        }
    }

    private var statementCard: some View {
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
                    verdictTile("Strength", verdict: model.strengthVerdict, lane: model.strength, filled: advice.filled)
                    verdictTile("Cardio", verdict: model.cardioVerdict, lane: model.cardio, filled: advice.filled)
                }
            }
        }
        .task(id: advice.text) {
            guard !reduceMotion else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            adviceBounce += 1
        }
    }

    /// One lane's verdict and change inside the statement card, so the sentence above it is answerable
    /// without scrolling back to the hero.
    private func verdictTile(_ title: LocalizedStringKey, verdict: LaneVerdict?, lane: TrainingLoadModel.Lane?,
                             filled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(filled ? StrandPalette.onDarkSecondary : StrandPalette.textSecondary)
            Text(verdict?.label ?? "—")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(filled ? StrandPalette.onDarkPrimary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let trend = lane?.trend {
                Text(verbatim: LoadFormat.signedPercent(trend.percentChange))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(filled ? StrandPalette.onDarkSecondary : StrandPalette.textSecondary)
            }
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

    /// Cardio's "is it working". Two things, kept apart: the VO₂max headline — NOOP's weekly estimate, with
    /// Apple's latest reading and its date beneath it — and the performance EVIDENCE the cardio verdict
    /// reads, which is never the estimate (it is partly built from the load it would judge).
    private var vo2maxCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Cardio development", overline: "VO₂max, last eight weeks")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let display = model.vo2display, let latest = display.primary {
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
                        }
                        if display.line.readings.count >= 2 {
                            VO2maxSparkline(readings: display.line.readings, color: StrandPalette.effortColor)
                        }
                        Text(vo2SourceText(latest))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let apple = display.appleLatest {
                            Label(appleLatestText(apple), systemImage: "applewatch")
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
                    Divider().overlay(StrandPalette.hairline)
                    evidenceRow
                }
            }
        }
    }

    /// What the cardio verdict rests on, in one line: its direction and where it came from.
    private var evidenceRow: some View {
        let evidence = model.cardioEvidence
        let direction = evidence?.evidence ?? LaneEvidence.none
        let color: Color
        let symbol: String
        switch direction {
        case .rising: color = StrandPalette.statusPositive; symbol = "arrow.up.right"
        case .falling: color = StrandPalette.statusCritical; symbol = "arrow.down.right"
        case .unclear: color = StrandPalette.textSecondary; symbol = "minus"
        case .none: color = StrandPalette.textTertiary; symbol = "hourglass"
        }
        return HStack(alignment: .top, spacing: NoopMetrics.space3) {
            StatusBadge(symbol: symbol, color: color, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Performance evidence")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(evidenceText(evidence))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func evidenceText(_ evidence: CardioEvidenceReading?) -> String {
        let direction: String
        switch evidence?.evidence ?? LaneEvidence.none {
        case .rising: direction = String(localized: "improving")
        case .falling: direction = String(localized: "declining")
        case .unclear: direction = String(localized: "no clear direction")
        case .none: direction = ""
        }
        switch evidence?.source {
        case .appleVO2max:
            return String(localized: "Measured VO₂max from Apple Watch: \(direction).")
        case .heartRateEfficiency:
            let sport = evidence?.efficiency.map { WorkoutSource.localizedDisplaySport($0.sport) } ?? ""
            return String(localized: "Heart-rate efficiency in \(sport) — beats per kilometre over \(evidence?.efficiency?.sessions ?? 0) sessions: \(direction).")
        case .some(.none), nil:
            return String(localized: "No performance evidence yet: a fresh Apple Watch VO₂max, or at least four endurance sessions with distance and heart rate. Until then the statement only describes the load.")
        }
    }

    /// "Apple Watch last: 41.2 · 5 weeks ago" — the date is what keeps an old reading from passing as today's.
    private func appleLatestText(_ reading: VO2maxReading) -> String {
        let value = reading.value.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "Apple Watch last measured \(value) on \(StatusHistoryStrip.shortDate(reading.day))")
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
            StatusBadge(symbol: symbol, color: lane?.reading?.band?.color ?? StrandPalette.textTertiary,
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

    private var basisRows: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            basisRow(symbol: "figure.strengthtraining.traditional", share: coverageShare(model.strength),
                     text: strengthCoverage(model.strength))
            Divider().overlay(StrandPalette.hairline)
            basisRow(symbol: "heart.fill", share: coverageShare(model.cardio),
                     text: cardioCoverage(model.cardio))
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

    private var methodRows: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            // The lane titles, not bare "Strength/Cardio/Session": the method rows explain the three
            // cards above and have to name them the same way in every language.
            methodRow("Strength load", "Working sets weighted by proximity to failure. Tonnage remains a training statistic, not the load.")
            Divider().overlay(StrandPalette.hairline)
            methodRow("Cardiovascular load", "Classic Edwards TRIMP from time in percentages of your maximum heart rate. NOOP band data wins; workout-associated Health data fills only when the band trace is incomplete.")
            Divider().overlay(StrandPalette.hairline)
            methodRow("Session load", "Your whole-session RPE × duration. Add it from any workout detail; missing ratings are never guessed.")
            Divider().overlay(StrandPalette.hairline)
            methodRow("How comparison works", "NOOP compares the last 7 days with an earlier, non-overlapping baseline: through today once you have trained today, through yesterday before that. A day whose training could not be measured leaves both windows while at least 5 of the 7 days and three quarters of the baseline are known; otherwise there is no comparison. For the first eight weeks, below usual starts under −25 % and well above over +44 % — Polar's thresholds on these windows — with usual up to +15 %; after that your own robust weekly variation sets the range, with well above starting between +15 % and +44 % and below usual no earlier than −10 %. A band changes only once the change clears its edge by 5 points. With fewer than 3 sessions in the baseline there is no band, and a baseline under the WHO weekly minimum reads at most above usual.")
            Divider().overlay(StrandPalette.hairline)
            methodRow("Load and adaptation", "Relative load is descriptive. A verdict such as productive, maintaining or unproductive needs a clear performance trend: estimated one-rep max for strength or VO₂max within one consistent measurement method for cardiovascular training. Without one, the statement only describes the load.")
            Divider().overlay(StrandPalette.hairline)
            methodRow("Sources", "Edwards 1993 · Banister 1991 · Foster 2001 · Mujika & Padilla 2000 · Bosquet et al. 2013 · Meeusen et al. 2013 · WHO 2020 · Polar Training Load Pro 2025 · Pelland et al. 2024 · Robinson et al. 2024")
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
