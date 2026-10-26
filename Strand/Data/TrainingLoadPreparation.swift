import Foundation
import StrandAnalytics
import WhoopStore
import StrandCore

/// The Training Load readings as one pure computation (`prepare`): the Strength, Cardio and Session lanes, their
/// eight weeks of bands and ratios, the verdicts and the page's statement, from the strength history, the fused
/// training sessions with their cardio loads, the session ratings, the daily rows and the VO2max readings. Moved
/// out of `TrainingLoadModel` (Android parity plan 1.2) so the Apple screen and the Android core read one
/// implementation; the model keeps the reads and the side effects.
enum TrainingLoadPreparation {
    /// Days of history read: the oldest week-end of the eight-week strip, 49 days back, plus everything
    /// a reading on that day depends on (`TrainingLoadLanes.lookbackDays`).
    static let historyDays = 7 * 7 + TrainingLoadLanes.lookbackDays

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

    /// What each lane can still take today, and when a high lane settles with rest (P6).
    struct Outlook: Sendable, Equatable {
        var strengthRoom: LaneHeadroom?
        var cardioRoom: LaneHeadroom?
        /// The first day the lane reads about usual again if every day from its reading day is rest.
        var strengthSettles: String?
        var cardioSettles: String?

        var isEmpty: Bool {
            strengthRoom == nil && cardioRoom == nil && strengthSettles == nil && cardioSettles == nil
        }
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
        var outlook = Outlook()
    }

    /// Session Load's daily series: the athlete's session RPE × minutes per day, the days holding a session
    /// that was not rated (unknown, never rest), and which sessions were possible and rated each day — the
    /// rating quota. Shared by the screen and the history view so both read one series.
    struct SessionSeries: Sendable {
        let byDay: [String: Double]
        let unknownDays: Set<String>
        let possibleKeysByDay: [String: Set<String>]
        let ratedKeysByDay: [String: Set<String>]
        let canonicalIdByStart: [Int: String]
        let ratingBySession: [String: SessionRPEEntry]

        var possibleByDay: [String: Int] { possibleKeysByDay.mapValues(\.count) }
        var ratedByDay: [String: Int] { ratedKeysByDay.mapValues(\.count) }
    }

    static func sessionSeries(unified: [UnifiedTrainingSession], strengthWorkouts: [HevyWorkout],
                                          rpeEntries: [SessionRPEEntry], offset: Int) -> SessionSeries {
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
        return SessionSeries(byDay: sessionByDay, unknownDays: sessionUnknown,
                             possibleKeysByDay: possibleSessionKeysByDay, ratedKeysByDay: ratedSessionKeysByDay,
                             canonicalIdByStart: canonicalIdByStart, ratingBySession: ratingBySession)
    }

    static func prepare(strengthHistory: ResolvedStrengthHistory,
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

        let sessionSeries = Self.sessionSeries(unified: unified, strengthWorkouts: strengthWorkouts,
                                               rpeEntries: rpeEntries, offset: offset)
        let canonicalIdByStart = sessionSeries.canonicalIdByStart
        let ratingBySession = sessionSeries.ratingBySession
        let sessionByDay = sessionSeries.byDay
        let sessionUnknown = sessionSeries.unknownDays
        let possibleSessionKeysByDay = sessionSeries.possibleKeysByDay
        let ratedSessionKeysByDay = sessionSeries.ratedKeysByDay

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
                RatioPoint(day: point.day,
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

        let outlook = Outlook(
            strengthRoom: LaneOutlook.headroom(dailyByDay: strengthByDay, activity: strengthActivity,
                                               lane: .strength, today: today),
            cardioRoom: LaneOutlook.headroom(dailyByDay: cardioByDay, unknownDays: cardioUnknown,
                                             activity: cardioSeries.activity, lane: .cardio, today: today),
            strengthSettles: LaneOutlook.backToUsual(dailyByDay: strengthByDay, activity: strengthActivity,
                                                     lane: .strength, from: strengthDay),
            cardioSettles: LaneOutlook.backToUsual(dailyByDay: cardioByDay, unknownDays: cardioUnknown,
                                                   activity: cardioSeries.activity, lane: .cardio,
                                                   from: cardioDay))

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
            provisionalStrengthRing: provisionalStrengthRing,
            outlook: outlook)
    }

    /// The cardio lane's daily series, on ONE axis.
    ///
    /// Measured Banister TRIMP wherever the window has it. Stored Effort is a different recipe and never
    /// substitutes for a missing trace, and neither does an estimate from average heart rate
    /// (`TrainingCardioLoadResolution.estimates`); an unpriced training day remains unknown.
    static func cardioDailyLoad(sessions: [UnifiedTrainingSession],
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
            guard session.row.endTs - session.row.startTs >= CardioLoadPricing.cardioLoadMinimumSeconds else {
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
    static func canonicalRatings(entries: [SessionRPEEntry],
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
}
