import Foundation
import StrandCore
import StrandTraining
import WhoopStore

/// One immutable metadata review. The receipt contains no credential, response body or media file.
actor CoreExerciseProvider {
    static let shared = CoreExerciseProvider()
    struct Defaults: Encodable {
        var endpoint = ExerciseDBProviderClient.defaultEndpoint
        var header = ExerciseDBProviderClient.defaultHeader
        var attribution = ExerciseDBProviderClient.defaultAttribution
        var documentation = ExerciseDBProviderClient.defaultDocumentation
    }
    struct Choice: Encodable { let id: String, title: String, mode: String; let primary: String? }
    struct Preview: Encodable { let token: String; let exercises: [Choice]; let attribution: [String] }
    private var token = ""
    private var definitions: [TrainingExercise] = []
    private var owner: ObjectIdentifier?
    private var generation = UUID()

    func preview(store: WhoopStore, endpoint: String, key: String?, header: String?) async throws -> Preview {
        invalidate()
        let ticket = generation
        let exercises = try await ExerciseDBProviderClient.fetch(endpoint: endpoint, key: key, headerName: header)
        let existing = try await store.trainingExercises()
        guard generation == ticket else { throw ExerciseDBProviderError.invalidResponse }
        return prepare(store: store, exercises: try ExerciseDBProviderClient.keepingMeasurementIdentity(exercises, existing: existing))
    }
    func prepare(store: WhoopStore, exercises: [TrainingExercise]) -> Preview {
        token = UUID().uuidString; definitions = exercises; owner = ObjectIdentifier(store)
        return Preview(token: token, exercises: exercises.map {
            Choice(id: $0.id, title: $0.title, mode: $0.mode.rawValue, primary: $0.primaryMuscleId)
        }, attribution: Array(Set(exercises.compactMap(\.attribution))).sorted())
    }
    func invalidate() { generation = UUID(); token = ""; definitions = []; owner = nil }

    func accept(store: WhoopStore, requested: String, ids: [String]) async throws -> Bool {
        let selected = Set(ids)
        guard !requested.isEmpty, requested == token, owner == ObjectIdentifier(store), !selected.isEmpty,
              selected.count == ids.count, selected.isSubset(of: Set(definitions.map(\.id))) else { return false }
        let picked = definitions.filter { selected.contains($0.id) }
        invalidate()
        try await store.upsertTrainingExercises(picked, nowTs: Int(Date().timeIntervalSince1970))
        return true
    }
}
