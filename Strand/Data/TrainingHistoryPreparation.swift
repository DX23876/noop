import Foundation
import StrandAnalytics
import WhoopStore
import StrandCore

/// Shared history preparation; Apple and Android read the same lane units, coverage and adaptations.
enum TrainingHistoryPreparation {
    /// Everything read from the repository, once per visit.
    struct Source: Sendable {
        let workouts: [HevyWorkout]
        let templates: [String: HevyExerciseTemplate]
        let strengthByDay: [String: Double]
        let strengthActivity: LaneActivity
        let strengthStart: String?
        let cardio: TrainingLoadLanes.CardioSeries
        /// Days the cardio lane could not measure but a workout's average heart rate estimates (P4).
        let cardioEstimatedByDay: [String: Double]
        let cardioStart: String?
        let session: TrainingLoadPreparation.SessionSeries
        let sessionStart: String?
        let vo2Estimates: [(day: String, value: Double)]
        let vo2Apple: [(day: String, value: Double)]
        let today: String
        let strengthDay: String
        let cardioDay: String
        let sessionDay: String
        let offset: Int

        var earliest: String? { [strengthStart, cardioStart, sessionStart].compactMap { $0 }.min() }
    }

    struct Lift: Sendable, Identifiable {
        let id: String
        let title: String
        let values: [TrainingHistoryValue]
    }

    struct LiftChoice: Sendable, Identifiable, Hashable {
        let id: String
        let title: String
        let sessions: Int
    }

    /// One span, built.
    struct Built: Sendable {
        let span: TrainingHistorySpan
        let range: TrainingHistoryRange
        let periods: [TrainingHistoryPeriod]
        let strength: [TrainingHistoryLanePeriod]
        let cardio: [TrainingHistoryLanePeriod]
        let session: [TrainingHistoryLanePeriod]
        let lifts: [Lift]
        let vo2: [TrainingHistoryValue]
        let vo2Apple: [TrainingHistoryValue]
    }

    static func source(workouts: [HevyWorkout], templates: [String: HevyExerciseTemplate],
                                   sessions: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                                   ratings: [SessionRPEEntry], vo2Estimates: [(day: String, value: Double)],
                                   vo2Apple: [(day: String, value: Double)], today: String,
                                   offset: Int) -> (Source, [LiftChoice]) {
        let strengthByDay = TrainingLoadLanes.strengthByDay(workouts, tzOffsetSeconds: offset)
        let strengthActivity = TrainingLoadLanes.strengthActivity(workouts, tzOffsetSeconds: offset)
        let cardio = TrainingLoadLanes.cardioSeries(sessions: sessions, resolution: resolution,
                                                    tzOffsetSeconds: offset)
        let session = TrainingLoadPreparation.sessionSeries(unified: sessions, strengthWorkouts: workouts,
                                                      rpeEntries: ratings, offset: offset)
        // The same daily series with the estimates admitted: whatever it knows that the measured series
        // does not is an estimated day.
        let withEstimates = TrainingLoadPreparation.cardioDailyLoad(
            sessions: sessions, loads: resolution.loads.merging(resolution.estimates) { measured, _ in measured },
            duplicates: resolution.duplicateSessionIds, tzOffsetSeconds: offset)
        var estimatedByDay: [String: Double] = [:]
        for day in cardio.unknownDays where !withEstimates.unknownDays.contains(day) {
            estimatedByDay[day] = withEstimates.byDay[day] ?? 0
        }
        let source = Source(
            workouts: workouts, templates: templates,
            strengthByDay: strengthByDay, strengthActivity: strengthActivity,
            strengthStart: strengthActivity.sessionsByDay.keys.min(),
            cardio: cardio,
            cardioEstimatedByDay: estimatedByDay,
            cardioStart: cardio.activity.sessionsByDay.keys.min(),
            session: session,
            sessionStart: session.possibleKeysByDay.keys.min(),
            vo2Estimates: vo2Estimates, vo2Apple: vo2Apple, today: today,
            strengthDay: LaneEngine.readingDay(today: today,
                                               hasActivityToday: (strengthActivity.sessionsByDay[today] ?? 0) > 0),
            cardioDay: LaneEngine.readingDay(today: today,
                                             hasActivityToday: (cardio.activity.sessionsByDay[today] ?? 0) > 0),
            sessionDay: LaneEngine.readingDay(today: today,
                                              hasActivityToday: !(session.possibleKeysByDay[today] ?? []).isEmpty),
            offset: offset)
        return (source, liftChoices(source))
    }

    /// Every lift with an e1RM, the most trained over the whole history first.
    static func liftChoices(_ source: Source) -> [LiftChoice] {
        let first = source.strengthStart ?? source.today
        let ids = TrainingHistory.mostTrainedTemplates(workouts: source.workouts, templates: source.templates,
                                                       from: first, through: source.today,
                                                       tzOffsetSeconds: source.offset, limit: .max)
        var sessions: [String: Int] = [:]
        var titles: [String: String] = [:]
        for workout in source.workouts {
            for id in Set(workout.exercises.compactMap(\.templateId)) { sessions[id, default: 0] += 1 }
            for exercise in workout.exercises {
                if let id = exercise.templateId, titles[id] == nil { titles[id] = exercise.title }
            }
        }
        return ids.map { LiftChoice(id: $0, title: source.templates[$0]?.title ?? titles[$0] ?? $0,
                                    sessions: sessions[$0] ?? 0) }
    }

    static func build(source: Source, span: TrainingHistorySpan, end: String,
                                  chosenLifts: [String]) -> Built {
        let range = TrainingHistory.range(span: span, end: end, earliest: source.earliest)
        let periods = TrainingHistory.periods(range)
        let strength = TrainingHistory.lane(dailyByDay: source.strengthByDay, historyStart: source.strengthStart,
                                            through: min(source.strengthDay, end), periods: periods,
                                            bandLane: (.strength, source.strengthActivity))
        let cardio = TrainingHistory.lane(dailyByDay: source.cardio.byDay, unknownDays: source.cardio.unknownDays,
                                          estimatedByDay: source.cardioEstimatedByDay, historyStart: source.cardioStart, through: min(source.cardioDay, end),
                                          periods: periods, bandLane: (.cardio, source.cardio.activity))
        let session = TrainingHistory.lane(dailyByDay: source.session.byDay, unknownDays: source.session.unknownDays,
                                           historyStart: source.sessionStart, through: min(source.sessionDay, end),
                                           periods: periods, measuredByDay: source.session.ratedByDay,
                                           possibleByDay: source.session.possibleByDay)
        let choices = liftChoices(source)
        let known = Set(choices.map(\.id))
        var ids = chosenLifts.filter { known.contains($0) }
        if ids.isEmpty {
            ids = TrainingHistory.mostTrainedTemplates(workouts: source.workouts, templates: source.templates,
                                                       from: range.first, through: range.last,
                                                       tzOffsetSeconds: source.offset)
        }
        let titles = Dictionary(choices.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let lifts = ids.map { id in
            Lift(id: id, title: titles[id] ?? id,
                 values: TrainingHistory.liftSeries(templateId: id, workouts: source.workouts,
                                                    templates: source.templates, periods: periods,
                                                    tzOffsetSeconds: source.offset))
        }
        return Built(span: span, range: range, periods: periods, strength: strength, cardio: cardio,
                     session: session, lifts: lifts,
                     vo2: TrainingHistory.meanPerPeriod(source.vo2Estimates, periods: periods),
                     vo2Apple: TrainingHistory.meanPerPeriod(source.vo2Apple, periods: periods))
    }

    /// Where a span ends when the wearer jumps to `day`: the day centred where the span allows, never past
    /// today. The whole history always ends today.
    static func end(for span: TrainingHistorySpan, jumpedTo day: String?, today: String) -> String {
        guard let day, let days = span.days else { return today }
        return min(today, WeeklyDigestEngine.addDays(day, days / 2))
    }
}
