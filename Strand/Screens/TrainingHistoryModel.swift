import Foundation
import StrandAnalytics
import WhoopStore
import StrandCore

/// Which lanes the history view shows — every entry point opens it on its own lane.
enum TrainingHistoryFocus: String, CaseIterable, Identifiable, Sendable {
    case all, strength, cardio, session
    var id: String { rawValue }

    var shows: (strength: Bool, cardio: Bool, session: Bool) {
        switch self {
        case .all: return (true, true, true)
        case .strength: return (true, false, false)
        case .cardio: return (false, true, false)
        case .session: return (false, false, true)
        }
    }
}

/// The history view's data: the whole training history read once, and each span built from it in memory.
///
/// The daily series are the Training Load screen's own (`TrainingLoadLanes`, `TrainingLoadModel
/// .sessionSeries`), and the bands come from the same `LaneEngine`, so a week in the history reads exactly
/// as the screen read it at the time. Cardio sessions the ledger has not priced yet are unknown days, not
/// rest; the ledger backfill fills them in, and a later visit shows them.
@MainActor
final class TrainingHistoryModel: ObservableObject {

    typealias Source = TrainingHistoryPreparation.Source
    typealias Lift = TrainingHistoryPreparation.Lift
    typealias LiftChoice = TrainingHistoryPreparation.LiftChoice
    typealias Built = TrainingHistoryPreparation.Built

    /// The lifts drawn above the strength lane, stored so a chosen set survives the next visit.
    static let liftsKey = "trainingHistory.lifts"

    @Published private(set) var source: Source?
    @Published private(set) var built: Built?
    @Published private(set) var liftChoices: [LiftChoice] = []
    @Published private(set) var loading = false

    func load(repo: Repository) async {
        loading = true
        defer { loading = false }
        let offset = TimeZone.current.secondsFromGMT()
        let days = TrainingHistoryWindow.allDays
        async let fusedRead = repo.trainingSessions(days: days)
        async let strengthRead = repo.resolvedStrengthHistory(days: days)
        async let ratingsRead = repo.sessionRPEEntries(from: 0, to: Int(Date().timeIntervalSince1970) + 86_400)
        async let appleRead = repo.exploreSeries(key: "vo2max", source: Repository.appleHealthSource, days: days)
        async let estimateRead = repo.resolvedSeries(key: "vo2max_est", source: Repository.whoopSource, days: days)
        let sessions = await fusedRead.sessions
        let resolution = await repo.cardioLoads(for: sessions)
        let strength = await strengthRead
        let ratings = await ratingsRead
        let apple = await appleRead.map { (day: $0.day, value: $0.value) }
        let estimates = await estimateRead.points.map { (day: $0.day, value: $0.value) }
        let today = Repository.localDayKey(Date())

        let built = await Task.detached(priority: .userInitiated) { () -> (Source, [LiftChoice]) in
            Self.source(workouts: strength.workouts, templates: strength.templates, sessions: sessions,
                        resolution: resolution, ratings: ratings, vo2Estimates: estimates, vo2Apple: apple,
                        today: today, offset: offset)
        }.value
        guard !Task.isCancelled else { return }
        source = built.0
        liftChoices = built.1
        // Prices the sessions this read could not, in portions, for the next visit.
        repo.scheduleCardioLoadBackfill()
    }

    /// Builds one span ending on `end`. `lifts` are the chosen template ids; empty picks the most trained.
    func build(span: TrainingHistorySpan, end: String, lifts: [String]) async {
        guard let source else { return }
        let result = await Task.detached(priority: .userInitiated) {
            Self.build(source: source, span: span, end: end, chosenLifts: lifts)
        }.value
        guard !Task.isCancelled else { return }
        built = result
    }

    // Shared preparation keeps the Apple model as an observable host.
    nonisolated static func source(workouts: [HevyWorkout], templates: [String: HevyExerciseTemplate],
                                   sessions: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                                   ratings: [SessionRPEEntry], vo2Estimates: [(day: String, value: Double)],
                                   vo2Apple: [(day: String, value: Double)], today: String,
                                   offset: Int) -> (Source, [LiftChoice]) {
        TrainingHistoryPreparation.source(workouts: workouts, templates: templates, sessions: sessions,
            resolution: resolution, ratings: ratings, vo2Estimates: vo2Estimates, vo2Apple: vo2Apple,
            today: today, offset: offset)
    }

    nonisolated static func liftChoices(_ source: Source) -> [LiftChoice] {
        TrainingHistoryPreparation.liftChoices(source)
    }

    nonisolated static func build(source: Source, span: TrainingHistorySpan, end: String,
                                  chosenLifts: [String]) -> Built {
        TrainingHistoryPreparation.build(source: source, span: span, end: end, chosenLifts: chosenLifts)
    }

    nonisolated static func end(for span: TrainingHistorySpan, jumpedTo day: String?, today: String) -> String {
        TrainingHistoryPreparation.end(for: span, jumpedTo: day, today: today)
    }
}
