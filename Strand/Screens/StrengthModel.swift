import Foundation
import SwiftUI
import WhoopStore
import StrandAnalytics
import StrandTraining

// MARK: - Everything the Strength screen knows, and where it is worked out
//
// The screen used to hold twenty pieces of `@State` and four loading functions in the middle of its own
// layout code, which had two consequences worth stating:
//
//   • None of it could be tested. The derivations are pure and live in `Packages/StrandAnalytics`, but
//     the ORCHESTRATION — which of them runs, against which window, with what cached — only existed
//     inside a SwiftUI view and was validated by looking at the screen.
//   • The week stepper recomputed everything on every tap, including the eight-week bands, which do not
//     depend on anything the tap changed except the anchor.
//
// So the data lives here. The view renders it. Two rules keep that boundary useful:
//
//   1. NOTHING HEAVY RUNS ON THE MAIN ACTOR. Every derivation happens in a detached task over value
//      types, and only the finished result is assigned. The one thing that must not happen on this
//      screen is a body evaluation that walks the session history.
//   2. ONE PRICED INDEX PER LOAD. `MuscleStimulus.SessionStimulusIndex` is built once and every muscle
//      question is asked of it — see that type's own header for what this replaced.

@MainActor
final class StrengthModel: ObservableObject {

    // MARK: - How far back to look

    /// The window the screen reads. A quarter is the default because it covers a training block and the
    /// eight-week bands; the longer options exist because records and a strength trend are exactly the
    /// questions a 120-day window cannot answer — a year of progress simply was not visible.
    enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
        case quarter, year, all
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .quarter: return 120
            case .year:    return 365
            case .all:     return ResolvedStrengthHistory.allHistoryDays
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

    // MARK: - The sessions

    @Published private(set) var loaded = false
    /// Every session in the window, newest first.
    @Published private(set) var workouts: [HevyWorkout] = []
    @Published private(set) var templates: [String: HevyExerciseTemplate] = [:]
    /// Consistency heatmap days, computed with the history instead of in the view body.
    @Published private(set) var activityDays: [TrainingActivityDay] = []
    @Published private(set) var resolvedHistory = ResolvedStrengthHistory(
        sessions: [], workouts: [], templates: [:])
    @Published private(set) var summaries: [StrengthSessionSummary] = []
    @Published private(set) var overview = StrengthOverview.calculate(
        workouts: [], templates: [:], from: 0, to: 1)
    /// One row per canonical strength session — the envelope the strap's heart rate lands on, filled
    /// read-side by the repository from the trace. The "Hevy says what, WHOOP says how the body
    /// answered" half, now also covering a session whose envelope came from Apple Health.
    @Published private(set) var rows: [WorkoutRow] = []
    /// Imported exercises the catalogue could not match, offered for a one-time manual mapping.
    @Published private(set) var unmappedExercises: [String] = []
    /// A strength session known only as a workout envelope, together with the manual entry the wearer
    /// has already added to it. Keeping the entry here is what makes the editor re-openable: the card
    /// stays after a save, and the sheet starts from what was stored instead of a blank form.
    struct GenericStrengthSession: Identifiable, Equatable {
        let session: UnifiedTrainingSession
        let manual: HevyWorkout?
        var id: String { session.id }
    }
    /// Strength sessions known only as a workout envelope. They count as sessions and can receive
    /// compact exercise/set details without pretending HealthKit supplied them.
    @Published private(set) var genericSessions: [GenericStrengthSession] = []

    // MARK: - The muscle map

    @Published private(set) var recentSets: [HevyMuscleGroup: Int] = [:]
    @Published private(set) var lastWorked: [HevyMuscleGroup: (day: String, startTs: Int, exercise: String)] = [:]
    @Published private(set) var fatigueNow: [HevyMuscleGroup: Double] = [:]
    @Published private(set) var typicalSession: [HevyMuscleGroup: Double] = [:]
    @Published private(set) var ratedShare: Double = 0
    @Published private(set) var feedback: [MuscleRecovery.Observation] = []
    @Published private(set) var tauByGroup: [HevyMuscleGroup: Double] = [:]

    // MARK: - The selected week

    /// 0 = the week containing today; each step back is one Monday–Sunday week earlier.
    @Published private(set) var weekOffset = 0
    @Published private(set) var week = StrengthSession.WeekSummary(
        mondayKey: "", sessionCount: 0, workingSetCount: 0, volumeLoadKg: 0,
        setsByMuscle: [:], secondarySetsByMuscle: [:], unattributedSetCount: 0)
    @Published private(set) var typicalBands: [HevyMuscleGroup: ClosedRange<Double>] = [:]
    @Published private(set) var strengthLoad: LoadTrend?
    @Published private(set) var weekStimulus: [HevyMuscleGroup: Double] = [:]
    @Published private(set) var typicalWeek: [HevyMuscleGroup: Double] = [:]
    @Published private(set) var weekCharge: Double?
    @Published private(set) var weekEffort: Double?
    @Published private(set) var balance: [StrengthBalance.Reading] = []
    @Published private(set) var typicalRatios: [StrengthBalance.Axis: ClosedRange<Double>] = [:]
    /// Bodyweight volume for the selected week, and how many sets it rests on. Kept apart from
    /// `week.volumeLoadKg` everywhere, including here.
    @Published private(set) var weekBodyweightKg: Double = 0
    @Published private(set) var weekBodyweightSets: Int = 0
    /// Working sets that carried the body but had no weigh-in near enough to price them.
    @Published private(set) var weekUnpricedBodyweightSets: Int = 0

    // MARK: - One exercise

    @Published var selectedTemplateId: String?
    @Published private(set) var exerciseChoices: [ExerciseChoice] = []
    @Published private(set) var trend: [ExercisePerformancePoint] = []
    @Published private(set) var records: ExerciseRecords?
    @Published private(set) var trendLine: StrengthTrendLine?
    /// True when the trend line is drawn from VOLUME rather than an estimated 1RM — the honest fallback
    /// for a movement no e1RM is defined for. The caption changes with it.
    @Published private(set) var trendIsVolume = false

    struct ExerciseChoice: Identifiable, Equatable, Sendable {
        let templateId: String
        let sessions: Int
        var id: String { templateId }
    }

    // MARK: - Internals

    /// Priced once per load; every muscle question is asked of it.
    private var index = MuscleStimulus.SessionStimulusIndex(workouts: [], templates: [:])
    /// The wearer's weigh-ins, for pricing bodyweight work at the body that performed it.
    private var bodyweight = BodyweightTimeline(points: [])
    /// Week-scoped results, keyed by the week's Monday. The bands and the usual week depend on nothing
    /// the stepper changes except this key, so stepping back and forward again is free.
    private var weekCache: [String: WeekBundle] = [:]

    private var tzOffset: Int { TimeZone.current.secondsFromGMT() }

    private struct WeekBundle: Sendable {
        let week: StrengthSession.WeekSummary
        let bands: [HevyMuscleGroup: ClosedRange<Double>]
        let load: LoadTrend?
        let stimulus: [HevyMuscleGroup: Double]
        let typical: [HevyMuscleGroup: Double]
        let balance: [StrengthBalance.Reading]
        let ratios: [StrengthBalance.Axis: ClosedRange<Double>]
        let bodyweightKg: Double
        let bodyweightSets: Int
        let unpricedBodyweightSets: Int
    }

    // MARK: - Load

    func load(repo: Repository) async {
        guard let store = await repo.storeHandle() else { loaded = true; return }
        let now = Int(Date().timeIntervalSince1970)
        let offset = tzOffset
        let historyDays = range.days
        let firstWeekday = TrainingPreferences.firstWeekday

        async let historyRead = repo.resolvedStrengthHistory(days: historyDays)
        async let fusedRead = repo.trainingSessions(days: historyDays)
        let history = await historyRead
        let sessions = history.workouts
        let catalogue = history.templates
        let fused = await fusedRead
        let observations = ((try? await store.muscleRecoveryFeedback()) ?? []).compactMap { row in
            MuscleRecovery.Feeling(rawValue: row.feeling).map {
                MuscleRecovery.Observation(group: row.muscleGroup, ts: row.ts, feeling: $0)
            }
        }
        // Weigh-ins over the same window plus the gap the timeline is allowed to bridge, so a session at
        // the very start of the window can still be priced by a measurement just before it.
        let weighInDays = historyDays + BodyweightTimeline.maximumGapDays
        let weighIns = await repo.weightDailyValues(days: weighInDays)
            .map { (day: $0.day, kg: $0.value) }

        let prepared = await Task.detached(priority: .userInitiated) { () -> Prepared in
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
                unmapped: history.unmappedExerciseTitles)
        }.value

        index = prepared.index
        bodyweight = BodyweightTimeline(points: weighIns)
        weekCache.removeAll()

        workouts = sessions
        resolvedHistory = history
        activityDays = TrainingActivityDay.pastYear(
            sessions: history.sessions,
            weekStart: TrainingWeekStart(rawValue: UserDefaults.standard.string(
                forKey: TrainingPreferences.weekStartKey) ?? "") ?? .monday)
        genericSessions = fused.sessions.compactMap { session -> GenericStrengthSession? in
            guard session.kind == .strength else { return nil }
            let overlapping = sessions.filter { detail in
                let overlap = max(0, min(detail.endTs, session.row.endTs) - max(detail.startTs, session.row.startTs))
                let shorter = max(1, min(detail.endTs - detail.startTs, session.row.endTs - session.row.startTs))
                return Double(overlap) / Double(shorter) > 0.8
            }
            // A session logged in Hevy or imported from a file already carries its exercises. Only an
            // envelope with nothing at all, or one the wearer completed by hand, belongs here — and the
            // completed one stays listed so its entry can be corrected later.
            guard overlapping.allSatisfy({ $0.source == .manual }) else { return nil }
            return GenericStrengthSession(session: session, manual: overlapping.first)
        }
        templates = catalogue
        summaries = prepared.summaries
        overview = prepared.overview
        unmappedExercises = prepared.unmapped
        recentSets = prepared.recentSets
        lastWorked = prepared.lastWorked
        feedback = observations
        typicalSession = prepared.typicalSession
        tauByGroup = prepared.tau
        fatigueNow = prepared.fatigue
        ratedShare = prepared.ratedShare
        exerciseChoices = prepared.choices

        // Keep the canonical envelope beside the detailed set log. This is what lets a manual detail
        // entry retain the Apple Health duration (and a Hevy + Health twin retain whichever source had
        // the richer envelope) instead of falling back to a synthetic one-hour matching window.
        rows = fused.sessions.filter { $0.kind == .strength }.map(\.row)

        // Re-clamp the week stepper: shortening the history window can leave the offset pointing at a
        // week that is no longer loaded, and the stepper would then sit on an empty week with its
        // "older" arrow disabled.
        weekOffset = max(minWeekOffset, min(0, weekOffset))

        // Keep the user's pick across a refresh when it is still in the window; otherwise choose one.
        //
        // The most-trained movement is NOT automatically the right default: in a push/pull/legs split
        // the plank is performed twice a week and carries nothing to plot — no one-rep-max estimate and
        // no volume load — so the card opened on an empty chart. Prefer the most-trained movement that
        // actually has a series, and fall back to the most-trained one when none does (a purely
        // bodyweight lifter), where the card then explains itself.
        if selectedTemplateId == nil || !prepared.choices.contains(where: { $0.templateId == selectedTemplateId }) {
            selectedTemplateId = Self.firstPlottable(in: prepared.choices, workouts: sessions,
                                                     templates: catalogue, tzOffsetSeconds: offset)
                ?? prepared.choices.first?.templateId
        }
        await refreshExercise()
        await refreshWeek(repo: repo)
        loaded = true
    }

    func refreshAfterManualDetails(repo: Repository) async { await load(repo: repo) }

    /// The most-trained movement with something to draw, searched over the busiest candidates only —
    /// the list is frequency-ordered, so the answer is almost always the first or second entry, and a
    /// history with hundreds of movements should not cost a scan of all of them to pick a default.
    private static func firstPlottable(in choices: [ExerciseChoice],
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

    private struct Prepared: Sendable {
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
        let efforts = inWeek.compactMap(\.strain)
        weekEffort = efforts.isEmpty ? nil : efforts.reduce(0, +)

        if let cached = weekCache[monday] {
            apply(cached)
            return
        }

        let anchor = weekAnchorDay
        let endDate = weekEndDate
        let sessions = workouts
        let catalogue = templates
        let offset = tzOffset
        let index = self.index
        let bodyweight = self.bodyweight

        let bundle = await Task.detached(priority: .userInitiated) { () -> WeekBundle in
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
                load: StrengthSession.strengthLoadTrend(sessions, asOf: endDate, tzOffsetSeconds: offset),
                stimulus: index.week(containing: anchor).byMuscle,
                typical: MuscleStimulus.typicalWeeklyStimulus(index: index, endingBefore: anchor),
                balance: StrengthBalance.readings(setsByMuscle: week.setsByMuscle),
                ratios: StrengthBalance.typicalRatios(sessions, templates: catalogue,
                                                      endingBefore: anchor, tzOffsetSeconds: offset),
                bodyweightKg: bodyweightVolume.kg,
                bodyweightSets: bodyweightVolume.sets,
                unpricedBodyweightSets: unpriced)
        }.value

        guard !Task.isCancelled else { return }
        weekCache[monday] = bundle
        apply(bundle)
    }

    private func apply(_ bundle: WeekBundle) {
        week = bundle.week
        typicalBands = bundle.bands
        strengthLoad = bundle.load
        weekStimulus = bundle.stimulus
        typicalWeek = bundle.typical
        balance = bundle.balance
        typicalRatios = bundle.ratios
        weekBodyweightKg = bundle.bodyweightKg
        weekBodyweightSets = bundle.bodyweightSets
        weekUnpricedBodyweightSets = bundle.unpricedBodyweightSets
    }

    // MARK: - The exercise card

    func select(_ templateId: String) async {
        selectedTemplateId = templateId
        await refreshExercise()
    }

    func refreshExercise() async {
        guard let id = selectedTemplateId else {
            trend = []; records = nil; trendLine = nil; return
        }
        let sessions = workouts
        let catalogue = templates
        let offset = tzOffset

        let result = await Task.detached(priority: .userInitiated) { () -> (points: [ExercisePerformancePoint], records: ExerciseRecords, line: StrengthTrendLine?, isVolume: Bool) in
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
        }.value

        guard !Task.isCancelled else { return }
        trend = result.points
        records = result.records
        trendLine = result.line
        trendIsVolume = result.isVolume
    }

    // MARK: - Feedback

    /// Record how a muscle feels, refit its time constant, and persist the answer.
    func record(_ feeling: MuscleRecovery.Feeling, for group: HevyMuscleGroup, repo: Repository) async {
        let ts = Int(Date().timeIntervalSince1970)
        feedback.append(MuscleRecovery.Observation(group: group, ts: ts, feeling: feeling))
        await refitTau()
        guard let store = await repo.storeHandle() else { return }
        try? await store.saveMuscleRecoveryFeedback(
            MuscleRecoveryFeedback(muscleGroup: group, ts: ts, feeling: feeling.rawValue))
    }

    /// Refit every muscle's time constant from the answers on hand, then recompute what is outstanding.
    ///
    /// Twenty groups against one priced index — which is the whole reason this is cheap enough to run
    /// on every answer rather than only on a reload.
    private func refitTau() async {
        let observations = feedback
        let index = self.index
        let typical = typicalSession
        let now = Int(Date().timeIntervalSince1970)

        let result = await Task.detached(priority: .userInitiated) { () -> (tau: [HevyMuscleGroup: Double], fatigue: [HevyMuscleGroup: Double]) in
            var fitted: [HevyMuscleGroup: Double] = [:]
            for group in HevyMuscleGroup.allCases {
                fitted[group] = MuscleRecovery.fittedTauSeconds(for: group, observations: observations,
                                                                index: index, typicalSession: typical)
            }
            let fatigue = MuscleRecovery.fatigue(index: index, now: now,
                                                 tau: { fitted[$0] ?? MuscleRecovery.defaultTauSeconds(for: $0) })
            return (fitted, fatigue)
        }.value

        guard !Task.isCancelled else { return }
        tauByGroup = result.tau
        fatigueNow = result.fatigue
    }

    // MARK: - One session, opened up

    /// The full breakdown for one session, priced at the body weight of the day it happened.
    ///
    /// Computed on demand rather than for every session at load: one session is a handful of sets, and
    /// the detail sheet is opened for one at a time.
    /// Where a session in this screen's list came from. Unknown ids fall back to the Hevy lane, which is
    /// the only way a summary can exist without its workout still being loaded.
    func source(for workoutId: String) -> StrengthDataSource {
        workouts.first { $0.id == workoutId }?.source ?? .hevyAPI
    }

    func breakdown(for workoutId: String) -> StrengthSessionBreakdown? {
        guard let workout = workouts.first(where: { $0.id == workoutId }) else { return nil }
        let offset = tzOffset
        return StrengthDetail.breakdown(workout, templates: templates,
                                        bodyweightKgAt: { bodyweight.kg(at: $0, tzOffsetSeconds: offset) })
    }

    /// The mirrored row for a session — where the strap's heart rate is.
    ///
    /// Matched by OVERLAP, not by start time. A ±1 hour window on the start alone matched whichever row
    /// happened to be first in the list when two sessions sat close together, and the badge then claimed
    /// a heart rate that belonged to a different workout.
    func matchedRow(for summary: StrengthSessionSummary) -> WorkoutRow? {
        let start = summary.startTs
        let end = summary.durationS.map { start + Int($0) } ?? (start + 3600)
        var best: (row: WorkoutRow, overlap: Int)?
        for row in rows {
            let overlap = min(end, row.endTs) - max(start, row.startTs)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap { best = (row, overlap) }
        }
        return best?.row
    }

    // MARK: - Week navigation

    var weekAnchorDay: String {
        WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), weekOffset * 7)
    }

    /// The instant the selected week is read "as of": noon on its Sunday, or now for the current week.
    /// See the note this moved from — noon, not midnight, so a timezone offset cannot push the acute
    /// window across a day boundary.
    var weekEndDate: Date {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay),
              let sunday = WeightSeries.date(forDay: WeeklyDigestEngine.addDays(monday, 6)) else {
            return Date()
        }
        return min(sunday, Date())
    }

    var earliestDay: String? {
        workouts.map { AnalyticsEngine.dayString($0.startTs, offsetSec: tzOffset) }.min()
    }

    var minWeekOffset: Int {
        guard let earliest = earliestDay,
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
