import Foundation
import StrandCore
import StrandTraining
import WhoopStore

/// Keeps the reviewed plan stable between preview and the wearer's explicit selection.
actor CoreHevyRoutines {
    static let shared = CoreHevyRoutines()
    struct Choice: Encodable { let id: String, title: String; let exercises: [String] }
    struct Preview: Encodable { let token: String; let routines: [Choice]; let skippedExercises: Int }
    private var token: String = ""
    private var prepared: TrainingRoutineImport?
    private var generation = 0
    private var owner: ObjectIdentifier?

    func preview(store: WhoopStore, restSeconds: Int = 120) async throws -> Preview {
        let version = generation
        _ = try await CoreTrainingLibrary.catalog(store: store)
        let exercises = try await store.trainingExercises()
        let imported = try await HevyRoutinePreparation.read(store: store, exercises: exercises,
            defaultRestSeconds: min(600, max(0, restSeconds)))
        let titles = Dictionary((exercises + imported.newExercises).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        guard version == generation else { throw HevyImportError.busy }
        token = UUID().uuidString; prepared = imported; owner = ObjectIdentifier(store)
        return Preview(token: token, routines: imported.routines.map {
            Choice(id: $0.id.uuidString, title: $0.title, exercises: $0.exercises.compactMap { titles[$0.exerciseId] })
        }, skippedExercises: imported.skippedExercises)
    }

    func invalidate() { generation += 1; prepared = nil; token = ""; owner = nil }

    func accept(store: WhoopStore, token requested: String, ids: [String]) async throws -> Bool {
        guard requested == token, owner == ObjectIdentifier(store), let imported = prepared else { return false }
        let selected = Set(ids.compactMap(UUID.init(uuidString:)))
        guard !selected.isEmpty, selected.count == Set(ids).count,
              selected.isSubset(of: Set(imported.routines.map(\.id))) else { return false }
        let archive = imported.keeping(selected).archive(includingSchedule: false, weekStartsOn: .monday)
        prepared = nil; token = ""; owner = nil
        try await store.mergeTrainingPlan(archive, nowTs: Int(Date().timeIntervalSince1970))
        return true
    }
}
