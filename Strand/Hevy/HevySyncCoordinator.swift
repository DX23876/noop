import Foundation
import WhoopStore
import StrandCore
import StrandAnalytics

typealias HevySyncProgress = HevyImportProgress
typealias HevySyncSummary = HevyImportSummary

/// Platform adapter: the shared engine owns paging, replay and persistence.
actor HevySyncCoordinator {
    private let engine: HevySyncEngine
    init(fetcher: HevyFetching, store: WhoopStore, pageSize: Int = HevyAPIClient.listPageSize,
         templatePageSize: Int = HevyAPIClient.templatePageSize) {
        engine = HevySyncEngine(fetcher: fetcher, store: store, pageSize: pageSize,
            templatePageSize: templatePageSize, note: HevySource.note)
    }
    func run(onProgress: @Sendable (HevySyncProgress) -> Void = { _ in }) async throws -> HevySyncSummary {
        do {
            return try await engine.run(onProgress: onProgress)
        } catch let error as HevyImportError {
            switch error {
            case .busy: throw HevyError.syncInProgress
            case .notConnected: throw HevyError.notConnected
            case .unauthorized: throw HevyError.unauthorized
            case .notPro: throw HevyError.notPro
            case .rateLimited: throw HevyError.rateLimited
            case .network: throw HevyError.network("")
            case .decode, .limitExceeded: throw HevyError.decode
            }
        }
    }
    func refreshRoutines() async throws -> Set<String> { try await engine.refreshRoutines() }
}

/// The source identity of the Hevy lane, in one place.
///
/// A source of its OWN (`"hevy"`), not the existing `"lifting"` used by the CSV importer: the two can
/// hold the same session — someone who imported a CSV export before connecting the API — and keeping
/// them apart is what lets `WorkoutSource.dedupCrossSource` collapse that pair instead of the app
/// silently overwriting one lane's history with the other's.
enum HevySource {
    static let id = WorkoutSource.hevySource
    /// The same sport label the CSV lane uses, so the two fold to one `sportKey` and the cross-source
    /// dedup recognises them as the same activity.
    static let sport = "Strength Training"

    /// The one-line note carried on the mirrored `WorkoutRow` — what the Workouts list shows before
    /// anyone opens the session. Same shape as the CSV lane's `volumeLoadNote`, so a Hevy row and an
    /// imported one read alike, plus the working-set count that is the figure strength training is
    /// actually prescribed in.
    ///
    /// Every part is omitted when it has nothing to say: a calisthenics session states its sets and no
    /// volume, rather than claiming "0 kg".
    static func note(for workout: HevyWorkout,
                     templates: [String: HevyExerciseTemplate]) -> String {
        let s = StrengthSession.summarize(workout, templates: templates)
        var parts: [String] = []
        if s.volumeLoadKg > 0 {
            parts.append(String(localized: "volume load \(groupedKg(s.volumeLoadKg)) kg"))
        }
        parts.append(s.workingSetCount == 1
                     ? String(localized: "1 working set")
                     : String(localized: "\(s.workingSetCount) working sets"))
        if s.exerciseCount > 0 {
            parts.append(s.exerciseCount == 1
                         ? String(localized: "1 exercise")
                         : String(localized: "\(s.exerciseCount) exercises"))
        }
        var note = String(localized: "Strength") + " · " + parts.joined(separator: " · ")
        if !workout.title.isEmpty { note = "\(workout.title): " + note }
        return note
    }

    /// A kilogram total with thousands separators (`HevyFormat.groupedKg`).
    static func groupedKg(_ kg: Double) -> String { HevyFormat.groupedKg(kg) }
}
