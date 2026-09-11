import Foundation
import SwiftUI
import WhoopStore
import StrandAnalytics

// MARK: - What the Cardio screen knows
//
// The counterpart to `StrengthModel`, and it exists for the same reason: the derivations are pure and
// testable in `Packages/StrandAnalytics`, and the orchestration — which window, which sport, what is
// cached — belongs somewhere that is not a SwiftUI body.
//
// One difference worth stating. Strength reads a lane of its own (`hevyWorkout`); cardio reads the SAME
// `WorkoutRow`s the Workouts list shows, through `Repository.workoutRows`, so the two screens can never
// disagree about which sessions exist. What this screen adds is not different data — it is the units
// that data was never shown in: pace, speed, beats per kilometre, and a week that adds up.

@MainActor
final class CardioModel: ObservableObject {

    enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
        case quarter, year, all
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .quarter: return 120
            case .year:    return 365
            case .all:     return 4000
            }
        }
        var label: String {
            switch self {
            case .quarter: return String(localized: "3 months")
            case .year:    return String(localized: "1 year")
            case .all:     return String(localized: "All")
            }
        }
    }

    @Published var range: HistoryRange = .quarter
    @Published private(set) var loaded = false

    /// Every cardio session in the window, newest first. Strength rows are already dropped.
    @Published private(set) var sessions: [CardioSessionMetrics] = []
    @Published private(set) var sportChoices: [SportChoice] = []
    @Published var selectedSport: String?

    // The selected week
    @Published private(set) var weekOffset = 0
    @Published private(set) var week = CardioWeekSummary(mondayKey: "", sessionCount: 0, minutes: 0,
                                                          distanceM: 0, energyKcal: 0, effort: nil,
                                                          sessionsWithDistance: 0, bySport: [])
    @Published private(set) var typicalMinutes: ClosedRange<Double>?
    @Published private(set) var load: LoadTrend?
    @Published private(set) var weekCharge: Double?

    // The selected sport
    @Published private(set) var sportHistory: [CardioSessionMetrics] = []
    @Published private(set) var bests = CardioBests(farthest: nil, longest: nil, fastestPaceByBand: [:])
    /// Beats per kilometre over time, and the robust line through it. The line is reused from the
    /// strength lane deliberately: "is this series going anywhere, and do the points agree" is the same
    /// question, and answering it twice would mean two answers to compare.
    @Published private(set) var efficiencySeries: [(startTs: Int, day: String, value: Double)] = []
    @Published private(set) var efficiencyTrend: StrengthTrendLine?
    @Published private(set) var paceTrend: StrengthTrendLine?

    struct SportChoice: Identifiable, Equatable, Sendable {
        let sport: String
        let sessions: Int
        let modality: CardioModality
        var id: String { sport }
    }

    private var weekCache: [String: WeekBundle] = [:]
    private var tzOffset: Int { TimeZone.current.secondsFromGMT() }

    private struct WeekBundle: Sendable {
        let week: CardioWeekSummary
        let typical: ClosedRange<Double>?
        let load: LoadTrend?
    }

    // MARK: - Load

    func load(repo: Repository) async {
        let offset = tzOffset
        // The same rows the Workouts list shows. The HR reconcile is capped at what this screen can
        // actually display — see `Repository.workoutRows` for why an uncapped reconcile is expensive.
        let rows = await repo.workoutRows(days: range.days, reconcileHrCap: 60)

        let prepared = await Task.detached(priority: .userInitiated) { () -> ([CardioSessionMetrics], [SportChoice]) in
            let sessions = CardioSession.sessions(rows, tzOffsetSeconds: offset)
            let choices = CardioSession.sportFrequency(sessions).map {
                SportChoice(sport: $0.sport, sessions: $0.sessions,
                            modality: CardioModality.of(sport: $0.sport))
            }
            return (sessions, choices)
        }.value

        sessions = prepared.0
        sportChoices = prepared.1
        weekCache.removeAll()

        // Re-clamp the week stepper: shortening the history window can leave the offset pointing at a
        // week that is no longer loaded, and the stepper would then sit on an empty week with its
        // "older" arrow disabled.
        weekOffset = max(minWeekOffset, min(0, weekOffset))

        if selectedSport == nil || !prepared.1.contains(where: { $0.sport == selectedSport }) {
            selectedSport = prepared.1.first?.sport
        }
        await refreshSport()
        await refreshWeek(repo: repo)
        loaded = true
    }

    // MARK: - The week

    func stepWeek(_ delta: Int, repo: Repository) async {
        let next = max(minWeekOffset, min(0, weekOffset + delta))
        guard next != weekOffset else { return }
        weekOffset = next
        await refreshWeek(repo: repo)
    }

    func refreshWeek(repo: Repository) async {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay) else { return }
        let sunday = WeeklyDigestEngine.addDays(monday, 6)
        let inWeek = repo.days.filter { $0.day >= monday && $0.day <= sunday }
        let charges = inWeek.compactMap(\.recovery)
        weekCharge = charges.isEmpty ? nil : charges.reduce(0, +) / Double(charges.count)

        if let cached = weekCache[monday] {
            apply(cached)
            return
        }

        let anchor = weekAnchorDay
        let endDate = weekEndDate
        let all = sessions
        let offset = tzOffset

        let bundle = await Task.detached(priority: .userInitiated) { () -> WeekBundle in
            return WeekBundle(week: CardioSession.week(containing: anchor, sessions: all),
                              typical: CardioSession.typicalWeeklyMinutes(all, endingBefore: anchor),
                              load: CardioSession.cardioLoadTrend(all, asOf: endDate,
                                                                  tzOffsetSeconds: offset))
        }.value

        guard !Task.isCancelled else { return }
        weekCache[monday] = bundle
        apply(bundle)
    }

    private func apply(_ bundle: WeekBundle) {
        week = bundle.week
        typicalMinutes = bundle.typical
        load = bundle.load
    }

    // MARK: - The sport

    func select(_ sport: String) async {
        selectedSport = sport
        await refreshSport()
    }

    func refreshSport() async {
        guard let sport = selectedSport else {
            sportHistory = []; efficiencySeries = []; efficiencyTrend = nil; paceTrend = nil
            bests = CardioBests(farthest: nil, longest: nil, fastestPaceByBand: [:])
            return
        }
        let all = sessions

        let result = await Task.detached(priority: .userInitiated) { () -> (history: [CardioSessionMetrics], bests: CardioBests, series: [(startTs: Int, day: String, value: Double)], efficiency: StrengthTrendLine?, pace: StrengthTrendLine?) in
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
        }.value

        guard !Task.isCancelled else { return }
        sportHistory = result.history
        bests = result.bests
        efficiencySeries = result.series
        efficiencyTrend = result.efficiency
        paceTrend = result.pace
    }

    var selectedModality: CardioModality {
        CardioModality.of(sport: selectedSport ?? "")
    }

    // MARK: - Week navigation

    var weekAnchorDay: String {
        WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), weekOffset * 7)
    }

    var weekEndDate: Date {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay),
              let sunday = WeightSeries.date(forDay: WeeklyDigestEngine.addDays(monday, 6)) else {
            return Date()
        }
        return min(sunday, Date())
    }

    var minWeekOffset: Int {
        guard let earliest = sessions.map(\.day).min(),
              let earliestMon = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
              let thisMon = WeeklyDigestEngine.mondayOfWeek(containing: Repository.localDayKey(Date()))
        else { return 0 }
        var offset = 0
        var monday = thisMon
        while monday > earliestMon && offset > -520 {
            monday = WeeklyDigestEngine.addDays(monday, -7)
            offset -= 1
        }
        return offset
    }
}
