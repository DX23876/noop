import Foundation
import StrandImport
import WhoopStore

/// Full offline lifting history shared by the Apple and Android import hosts.
/// Only explicit imports write inputs; no physiological score or synthetic HR is created.
public enum LiftingHistoryImport {
    public static let maximumBytes = 64 * 1024 * 1024

    public enum ImportError: Error { case tooLarge, noWorkouts }

    public static func run(data: Data, store: WhoopStore, zone: TimeZone = .current) async throws -> LiftingImportResult {
        guard data.count <= maximumBytes else { throw ImportError.tooLarge }
        let result = LiftingImporter.parse(data: data, zone: zone)
        guard result.sessionCount > 0 else { throw ImportError.noWorkouts }
        try await save(result, store: store)
        return result
    }

    /// Persists the parser's complete transcript and its list projection using the same source identity.
    public static func save(_ result: LiftingImportResult, store: WhoopStore) async throws {
        let catalogue = (try? await store.hevyExerciseTemplates()) ?? [:]
        let catalogueByTitle = Dictionary(
            catalogue.values.map { (normalizedExerciseTitle($0.title), $0.id) },
            uniquingKeysWith: { first, _ in first })
        let detailed = result.sessions.map { session -> HevyWorkout in
            let start = Int(session.start.timeIntervalSince1970)
            let end = max(start, Int(session.end.timeIntervalSince1970))
            let sourcePrefix = session.source.rawValue
            let normalizedTitle = normalizedExerciseTitle(session.title ?? "workout")
            let exercises = session.exercises.map { exercise in
                HevyExercise(index: exercise.index, title: exercise.title,
                             templateId: catalogueByTitle[normalizedExerciseTitle(exercise.title)],
                             supersetId: exercise.supersetId, notes: exercise.notes,
                             sets: exercise.sets)
            }
            return HevyWorkout(id: "\(sourcePrefix):\(start):\(normalizedTitle)",
                               title: session.title?.isEmpty == false ? session.title! : LiftingImporter.sport,
                               routineId: nil, notes: session.volumeLoadNote(),
                               startTs: start, endTs: end, updatedAtTs: start,
                               createdAtTs: start, exercises: exercises, source: session.source)
        }
        try await store.upsertLiftingHistory(detailed, rows: workoutRows(result))
    }

    /// The compatibility projection used while classic Android screens still read Room.
    public static func workoutRows(_ result: LiftingImportResult) -> [WorkoutRow] {
        result.sessions.map { s in
            WorkoutRow(
                startTs: Int(s.start.timeIntervalSince1970),
                endTs: Int(s.end.timeIntervalSince1970),
                sport: LiftingImporter.sport,
                source: LiftingImporter.sourceId,
                durationS: s.durationS,
                energyKcal: nil,
                avgHr: nil,
                maxHr: nil,
                strain: nil,                 // never a fabricated cardiovascular strain
                distanceM: nil,
                zonesJSON: nil,
                notes: s.volumeLoadNote(), steps: nil
            )
        }
    }

    private static func normalizedExerciseTitle(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

}
