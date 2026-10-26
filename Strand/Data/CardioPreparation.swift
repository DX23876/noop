import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Pure Cardio screen preparation, shared by the Apple model and Android core. The host supplies
/// fused sessions, priced heart-rate load and the selected week's zone read without duplicating math.
enum CardioPreparation {
    struct SportChoice: Identifiable, Equatable, Sendable {
        let sport: String
        let sessions: Int
        let modality: CardioModality
        var id: String { sport }
    }

    struct WeekBundle: Sendable {
        let week: CardioWeekSummary
        let typical: ClosedRange<Double>?
        let lane: TrainingLoadPreparation.Lane?
        let laneRatios: [TrainingLoadPreparation.RatioPoint]
        let laneDay: String
        let shares: [CardioSportLoadShare]
        let topSportPace: Double?
        let averageHr: Double?
        let typicalAverageHr: Double?
        let zones: CardioZoneSplit?
    }

    static func sessions(rows: [WorkoutRow], loadByStart: [Int: Double], offset: Int)
        -> ([CardioSessionMetrics], [SportChoice]) {
        let sessions = CardioSession.sessions(rows, tzOffsetSeconds: offset,
                                               cardioLoadByStart: loadByStart)
        let choices = CardioSession.sportFrequency(sessions).map {
            SportChoice(sport: $0.sport, sessions: $0.sessions,
                        modality: CardioModality.of(sport: $0.sport))
        }
        return (sessions, choices)
    }

    static func week(anchor: String, all: [CardioSessionMetrics], laneSessions: [UnifiedTrainingSession],
                     laneResolution: TrainingCardioLoadResolution, laneSeries: TrainingLoadLanes.CardioSeries?,
                     laneDay: String, offset: Int, zones: CardioZoneSplit?) -> WeekBundle {
        let shares = CardioSession.loadShareBySport(inWeekContaining: anchor, sessions: all)
        let lane = laneSeries.map {
            TrainingLoadLanes.cardioLane(sessions: laneSessions, resolution: laneResolution, series: $0,
                                         through: laneDay, tzOffsetSeconds: offset)
        }
        return WeekBundle(week: CardioSession.week(containing: anchor, sessions: all),
                          typical: CardioSession.typicalWeeklyMinutes(all, endingBefore: anchor),
                          lane: lane,
                          laneRatios: TrainingLoadLanes.ratios(strengthByDay: nil, cardio: laneSeries,
                                                               through: laneDay),
                          laneDay: laneDay,
                          shares: shares,
                          topSportPace: shares.first.flatMap {
                              CardioSession.weeklyPaceSecPerKm(sport: $0.sport, inWeekContaining: anchor,
                                                               sessions: all)
                          },
                          averageHr: CardioSession.weeklyAverageHr(inWeekContaining: anchor, sessions: all),
                          typicalAverageHr: CardioSession.typicalWeeklyAverageHr(all, endingBefore: anchor),
                          zones: zones)
    }

    static func sport(_ sport: String, all: [CardioSessionMetrics])
        -> (history: [CardioSessionMetrics], bests: CardioBests,
            series: [(startTs: Int, day: String, value: Double)],
            efficiency: StrengthTrendLine?, pace: StrengthTrendLine?) {
        let history = CardioSession.history(sport: sport, sessions: all)
        let series = CardioSession.beatsPerKmSeries(sport: sport, sessions: all)
        // `StrengthProgress.trend` takes performance points, so the cardio series is expressed in
        // that shape. Reusing the estimator rather than writing a second one is the point: one
        // definition of "do these points agree on a direction", used by both lanes.
        let efficiencyPoints = series.map {
            ExercisePerformancePoint(day: $0.day, startTs: $0.startTs, workoutId: "",
                                     bestE1RMKg: $0.value, heaviestSetKg: nil,
                                     workingSetCount: 0, totalReps: 0, volumeLoadKg: 0,
                                     meanRpe: nil, rpeSetCount: 0)
        }
        let pacePoints = history.compactMap { session -> ExercisePerformancePoint? in
            guard let pace = session.paceSecPerKm else { return nil }
            return ExercisePerformancePoint(day: session.day, startTs: session.startTs,
                                            workoutId: "", bestE1RMKg: pace, heaviestSetKg: nil,
                                            workingSetCount: 0, totalReps: 0, volumeLoadKg: 0,
                                            meanRpe: nil, rpeSetCount: 0)
        }
        return (history,
                CardioSession.bests(sport: sport, sessions: all),
                series,
                StrengthProgress.e1rmTrend(efficiencyPoints),
                StrengthProgress.e1rmTrend(pacePoints))
    }
}
