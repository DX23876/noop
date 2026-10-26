import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Pure Strength screen preparation, shared by the Apple model and Android core. Store reads,
/// observation and week caches stay with the host; all finished readings come from this implementation.
enum StrengthPreparation {
    struct ExerciseChoice: Identifiable, Equatable, Sendable {
        let templateId: String
        let sessions: Int
        var id: String { templateId }
    }

    struct WeekBundle: Sendable {
        let week: StrengthSession.WeekSummary
        let bands: [HevyMuscleGroup: ClosedRange<Double>]
        let lane: TrainingLoadPreparation.Lane
        let laneRatios: [TrainingLoadPreparation.RatioPoint]
        let laneDay: String
        let stimulus: [HevyMuscleGroup: Double]
        let typical: [HevyMuscleGroup: Double]
        let balance: [StrengthBalance.Reading]
        let ratios: [StrengthBalance.Axis: ClosedRange<Double>]
        let bodyweightKg: Double
        let bodyweightSets: Int
        let unpricedBodyweightSets: Int
        let groupBands: [HevyMuscleGroup: RelativeLoadBand]
    }

    struct Prepared: Sendable {
        let index: MuscleStimulus.SessionStimulusIndex
        let overview: StrengthOverview
        let summaries: [StrengthSessionSummary]
        let recentSets: [HevyMuscleGroup: Int]
        let lastWorked: [HevyMuscleGroup: (day: String, startTs: Int, exercise: String)]
        let typicalSession: [HevyMuscleGroup: Double]
        let tau: [HevyMuscleGroup: Double]
        let fatigue: [HevyMuscleGroup: Double]
        let ratedShare: Double
        let choices: [ExerciseChoice]
        let unmapped: [String]
        let laneByDay: [String: Double]
    }

    /// The most-trained movement with something to draw, searched over the busiest candidates only —
    /// the list is frequency-ordered, so the answer is almost always the first or second entry, and a
    /// history with hundreds of movements should not cost a scan of all of them to pick a default.
    static func firstPlottable(in choices: [ExerciseChoice],
                                       workouts: [HevyWorkout],
                                       templates: [String: HevyExerciseTemplate],
                                       tzOffsetSeconds: Int) -> String? {
        for choice in choices.prefix(12) {
            let points = StrengthSession.exerciseHistory(templateId: choice.templateId,
                                                         workouts: workouts, templates: templates,
                                                         tzOffsetSeconds: tzOffsetSeconds)
            let plottable = points.filter { $0.bestE1RMKg != nil || $0.volumeLoadKg > 0 }
            if plottable.count >= 2 { return choice.templateId }
        }
        return nil
    }

    static func prepare(history: ResolvedStrengthHistory, laneWorkouts: [HevyWorkout],
                        observations: [MuscleRecovery.Observation], now: Int, historyDays: Int,
                        offset: Int, firstWeekday: Int) -> Prepared {
        let sessions = history.workouts
        let catalogue = history.templates
        let index = MuscleStimulus.SessionStimulusIndex(workouts: sessions, templates: catalogue,
                                                        tzOffsetSeconds: offset)
        let typical = MuscleRecovery.typicalSessionStimulus(index: index)
        var fitted: [HevyMuscleGroup: Double] = [:]
        for group in HevyMuscleGroup.allCases {
            fitted[group] = MuscleRecovery.fittedTauSeconds(for: group, observations: observations,
                                                            index: index, typicalSession: typical)
        }
        return Prepared(
            index: index,
            overview: StrengthOverview.calculate(
                workouts: sessions, templates: catalogue,
                from: now - historyDays * 86_400, to: now,
                tzOffsetSeconds: offset, firstWeekday: firstWeekday),
            summaries: sessions.map { StrengthSession.summarize($0, templates: catalogue) },
            recentSets: StrengthSession.recentSetsByMuscle(sessions, templates: catalogue,
                                                           days: 7, now: now),
            lastWorked: StrengthSession.lastWorkedByMuscle(sessions, templates: catalogue,
                                                            tzOffsetSeconds: offset),
            typicalSession: typical,
            tau: fitted,
            fatigue: MuscleRecovery.fatigue(index: index, now: now,
                                            tau: { fitted[$0] ?? MuscleRecovery.defaultTauSeconds(for: $0) }),
            ratedShare: index.total().ratedShare,
            choices: StrengthSession.exerciseFrequency(sessions)
                .map { ExerciseChoice(templateId: $0.templateId, sessions: $0.sessions) },
            unmapped: history.unmappedExerciseTitles,
            laneByDay: TrainingLoadLanes.strengthByDay(laneWorkouts, tzOffsetSeconds: offset))
    }

    static func week(anchor: String, sessions: [HevyWorkout], catalogue: [String: HevyExerciseTemplate],
                     laneWorkouts: [HevyWorkout], laneByDay: [String: Double], laneDay: String,
                     laneActivity: LaneActivity, index: MuscleStimulus.SessionStimulusIndex,
                     bodyweight: BodyweightTimeline, offset: Int) -> WeekBundle {
        let week = StrengthSession.week(containing: anchor, workouts: sessions,
                                        templates: catalogue, tzOffsetSeconds: offset)
        let inWeekWorkouts = sessions.filter { workout in
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: offset)
            return day >= week.mondayKey
                && day <= WeeklyDigestEngine.addDays(week.mondayKey, 6)
        }
        let bodyweightVolume = StrengthDetail.bodyweightVolume(
            inWeekWorkouts, templates: catalogue,
            bodyweightKgAt: { bodyweight.kg(at: $0, tzOffsetSeconds: offset) })
        // Sets that carry the body but could not be priced — the coverage figure beside the volume.
        var unpriced = 0
        for workout in inWeekWorkouts where bodyweight.kg(at: workout.startTs, tzOffsetSeconds: offset) == nil {
            for exercise in workout.exercises {
                let kind = StrengthMovementKind.of(exercise.templateId.flatMap { catalogue[$0] })
                guard kind.carriesBodyweight else { continue }
                unpriced += exercise.workingSets.filter { ($0.reps ?? 0) > 0 }.count
            }
        }
        return WeekBundle(
            week: week,
            bands: StrengthSession.typicalWeeklySets(sessions, templates: catalogue,
                                                      endingBefore: anchor, tzOffsetSeconds: offset),
            lane: TrainingLoadLanes.strengthLane(workouts: laneWorkouts, byDay: laneByDay, through: laneDay,
                                                 tzOffsetSeconds: offset),
            laneRatios: TrainingLoadLanes.ratios(strengthByDay: laneByDay, strengthActivity: laneActivity,
                                                 cardio: nil, through: laneDay),
            laneDay: laneDay,
            stimulus: index.week(containing: anchor).byMuscle,
            typical: MuscleStimulus.typicalWeeklyStimulus(index: index, endingBefore: anchor),
            balance: StrengthBalance.readings(setsByMuscle: week.setsByMuscle),
            ratios: StrengthBalance.typicalRatios(sessions, templates: catalogue,
                                                  endingBefore: anchor, tzOffsetSeconds: offset),
            bodyweightKg: bodyweightVolume.kg,
            bodyweightSets: bodyweightVolume.sets,
            unpricedBodyweightSets: unpriced,
            groupBands: MuscleGroupLoad.bands(laneWorkouts, templates: catalogue, through: laneDay,
                                              tzOffsetSeconds: offset))
    }

    static func exercise(id: String, sessions: [HevyWorkout], catalogue: [String: HevyExerciseTemplate],
                         offset: Int) -> (points: [ExercisePerformancePoint], records: ExerciseRecords,
                                          line: StrengthTrendLine?, isVolume: Bool) {
        let points = StrengthSession.exerciseHistory(templateId: id, workouts: sessions,
                                                     templates: catalogue, tzOffsetSeconds: offset)
        let records = StrengthProgress.records(templateId: id, workouts: sessions,
                                               templates: catalogue, tzOffsetSeconds: offset)
        // The e1RM line where the movement defines one; otherwise volume, which is the only
        // progression question a plank or a bodyweight row can answer.
        if let line = StrengthProgress.e1rmTrend(points) {
            return (points, records, line, false)
        }
        return (points, records, StrengthProgress.volumeTrend(points), true)
    }
}
