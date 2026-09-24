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
            case .all:     return TrainingHistoryWindow.allDays
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
    /// Endurance and multisport: the sessions a pace or a speed actually describes.
    @Published private(set) var enduranceSessions: [CardioSessionMetrics] = []
    /// Intermittent/team sessions stay visible beside endurance, but in their own section because pace
    /// and distance trends do not describe them well.
    @Published private(set) var conditioningSessions: [CardioSessionMetrics] = []
    /// Mobility, recreation and anything still unclassified. Listed rather than dropped: the wearer
    /// recorded the session, and the totals above already counted it.
    @Published private(set) var otherSessions: [CardioSessionMetrics] = []
    @Published private(set) var sportChoices: [SportChoice] = []
    @Published var selectedSport: String?

    // The selected week
    @Published private(set) var weekOffset = 0
    @Published private(set) var week = CardioWeekSummary(mondayKey: "", sessionCount: 0, minutes: 0,
                                                          distanceM: 0, energyKcal: 0, effort: nil,
                                                          sessionsWithDistance: 0, bySport: [])
    @Published private(set) var typicalMinutes: ClosedRange<Double>?
    /// The selected week's cardio lane, read exactly as Training Load reads it.
    @Published private(set) var lane: TrainingLoadModel.Lane?
    @Published private(set) var laneRatios: [TrainingLoadModel.RatioPoint] = []
    /// The day the selected week is read through, for the load chart.
    @Published private(set) var laneReadingDay = Repository.localDayKey(Date())
    /// Each sport's share of the week's measured load, largest first.
    @Published private(set) var loadShares: [CardioSportLoadShare] = []
    /// Moving time over distance for the week's biggest sport, in seconds per kilometre.
    @Published private(set) var topSportPace: Double?
    @Published private(set) var weekAverageHr: Double?
    @Published private(set) var typicalAverageHr: Double?
    @Published private(set) var weekCharge: Double?
    /// The displayed week's time in each heart-rate zone. Nil when no zone set is known yet, or when
    /// nothing that week carried a trace complete enough to bin.
    @Published private(set) var zoneSplit: CardioZoneSplit?

    /// The zone definitions to bin against, set by the view from `ProfileStore.hrZoneSet`.
    ///
    /// Passed in rather than derived here: the app has ONE zone resolver, which carries the wearer's own
    /// bands and any HR-max override. Deriving a second set here would let the same heart rate read Zone
    /// 2 on this screen and Zone 3 in a session's detail.
    var zoneSet: HRZoneSet?

    /// The fused sessions behind `sessions`, kept because only they carry the COMPONENTS a HealthKit
    /// minute trace is looked up by — `CardioSessionMetrics` is a flattened view with no component keys.
    private var fusedVisible: [UnifiedTrainingSession] = []
    /// Sessions another record already described, so the zone split counts those minutes once.
    private var duplicateSessionIds: Set<String> = []
    /// The lane reads every training session, strength included, over the history window plus the
    /// lookback a reading needs, so the oldest selectable week still compares like Training Load does.
    private var laneSessions: [UnifiedTrainingSession] = []
    private var laneResolution = TrainingCardioLoadResolution()
    @Published private(set) var laneSeries: TrainingLoadLanes.CardioSeries?

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
        let lane: TrainingLoadModel.Lane?
        let laneRatios: [TrainingLoadModel.RatioPoint]
        let laneDay: String
        let shares: [CardioSportLoadShare]
        let topSportPace: Double?
        let averageHr: Double?
        let typicalAverageHr: Double?
        let zones: CardioZoneSplit?
    }

    // MARK: - Load

    func load(repo: Repository) async {
        let offset = tzOffset
        let fusion = await repo.trainingSessions(days: range.days)
        // Every family except strength. A recorded session must not vanish from Cardio because it is a
        // triathlon, a round of golf or a yoga class: `CardioSession.sessions` still drops what has no
        // cardiovascular reading to show, and the sections below keep the families that are READ
        // differently apart instead of hiding them.
        let visible = fusion.sessions.filter { $0.kind != .strength }
        let cardio = await repo.cardioLoads(for: visible)
        let laneFusion = await repo.trainingSessions(days: range.days + TrainingLoadLanes.lookbackDays)
        let laneResolution = await repo.cardioLoads(for: laneFusion.sessions)
        fusedVisible = visible
        duplicateSessionIds = cardio.duplicateSessionIds
        let rows = visible.map(\.row)
        var loadByStart: [Int: Double] = [:]
        for session in visible {
            if let value = cardio.loads[session.id]?.trimp { loadByStart[session.row.startTs] = value }
        }
        let conditioningStarts = Set(visible.filter { $0.kind == .conditioning }.map { $0.row.startTs })
        let enduranceStarts = Set(visible.filter { $0.kind == .endurance || $0.kind == .multisport }
            .map { $0.row.startTs })

        let laneSeries = await Task.detached(priority: .userInitiated) {
            TrainingLoadLanes.cardioSeries(sessions: laneFusion.sessions, resolution: laneResolution,
                                           tzOffsetSeconds: offset)
        }.value
        self.laneSessions = laneFusion.sessions
        self.laneResolution = laneResolution
        self.laneSeries = laneSeries

        let prepared = await Task.detached(priority: .userInitiated) { () -> ([CardioSessionMetrics], [SportChoice]) in
            let sessions = CardioSession.sessions(rows, tzOffsetSeconds: offset,
                                                   cardioLoadByStart: loadByStart)
            let choices = CardioSession.sportFrequency(sessions).map {
                SportChoice(sport: $0.sport, sessions: $0.sessions,
                            modality: CardioModality.of(sport: $0.sport))
            }
            return (sessions, choices)
        }.value

        sessions = prepared.0
        enduranceSessions = prepared.0.filter { enduranceStarts.contains($0.startTs) }
        conditioningSessions = prepared.0.filter { conditioningStarts.contains($0.startTs) }
        otherSessions = prepared.0.filter {
            !enduranceStarts.contains($0.startTs) && !conditioningStarts.contains($0.startTs)
        }
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
        // Fill the long-term cardio load history in the background, a portion at a time.
        repo.scheduleCardioLoadBackfill()
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
        let all = sessions
        let offset = tzOffset
        let laneSessions = self.laneSessions
        let laneResolution = self.laneResolution
        let laneSeries = self.laneSeries
        let today = Repository.localDayKey(Date())
        let laneDay = TrainingLoadLanes.readingDay(
            monday: monday, today: today,
            hasActivityToday: (laneSeries?.activity.sessionsByDay[today] ?? 0) > 0)

        // Outside the detached task: binning zones is an async read on the repository, and its result
        // travels into the bundle as a finished value so the week's cache holds it too.
        let zones = await weekZoneSplit(repo: repo, monday: monday, sunday: sunday)
        let bundle = await Task.detached(priority: .userInitiated) { () -> WeekBundle in
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
        }.value

        guard !Task.isCancelled else { return }
        weekCache[monday] = bundle
        apply(bundle)
    }

    /// The displayed week's time in zone, from the fused sessions of that week only.
    ///
    /// The week rather than the whole history window, so the split describes the same seven days as
    /// every other figure in the week grid above it.
    private func weekZoneSplit(repo: Repository, monday: String, sunday: String) async -> CardioZoneSplit? {
        guard let zoneSet else { return nil }
        let offset = tzOffset
        let inWeek = fusedVisible.filter { session in
            let day = AnalyticsEngine.dayString(session.row.startTs, offsetSec: offset)
            return day >= monday && day <= sunday
        }
        guard !inWeek.isEmpty else { return nil }
        return await repo.sessionZoneMinutes(for: inWeek, zoneSet: zoneSet,
                                             duplicates: duplicateSessionIds)
    }

    private func apply(_ bundle: WeekBundle) {
        week = bundle.week
        typicalMinutes = bundle.typical
        lane = bundle.lane
        laneRatios = bundle.laneRatios
        laneReadingDay = bundle.laneDay
        loadShares = bundle.shares
        topSportPace = bundle.topSportPace
        weekAverageHr = bundle.averageHr
        typicalAverageHr = bundle.typicalAverageHr
        zoneSplit = bundle.zones
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
