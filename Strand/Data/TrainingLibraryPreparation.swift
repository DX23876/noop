import Foundation
import StrandTraining

/// Library metadata and custom exercise creation shared by Apple and Android. Anatomy and equipment
/// use the same reviewed identities as training analytics; localized labels remain in the host UI.
enum TrainingLibraryPreparation {
    struct Info: Encodable, Sendable {
        var region: TrainingBodyRegion
        var primary: [String]
        var secondary: [String]
        var equipment: [String]
        var matchingMuscles: [String]

        init(_ exercise: TrainingExercise) {
            let anatomy = TrainingMuscleProjection.anatomy(for: exercise)
            let own = [exercise.primaryMuscleId].compactMap { $0 }
            primary = Array(Set(anatomy?.primaryMuscleIds ?? own)).sorted()
            secondary = Array(Set(anatomy?.secondaryMuscleIds ?? exercise.secondaryMuscleIds).subtracting(primary)).sorted()
            matchingMuscles = Array(Set(own + exercise.secondaryMuscleIds + primary + secondary)).sorted()
            region = anatomy?.bodyRegion ?? TrainingBodyRegion.forMuscles(own)
            equipment = Array(Set(exercise.equipmentIds.map(TrainingEquipmentCatalog.canonical))).sorted()
        }

        func matchesMuscle(_ id: String) -> Bool { matchingMuscles.contains(id) }
    }

    static func customExercise(title: String, mode: TrainingMeasurementMode, primary: String,
                               equipment: String, instruction: String, unilateral: Bool,
                               id: UUID = UUID()) -> TrainingExercise? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, TrainingMuscleCatalog.all.contains(where: { $0.id == primary }) else { return nil }
        let equipment = equipment.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return TrainingExercise(id: "user:\(id.uuidString.lowercased())", title: title, mode: mode,
            primaryMuscleId: primary,
            equipmentIds: equipment.isEmpty ? [] : [equipment.lowercased().replacingOccurrences(of: " ", with: "-")],
            instructions: instruction.isEmpty ? [] : [instruction], isUnilateral: unilateral, source: .user)
    }
    enum ImportError: Error { case offlineStorageNotAllowed, tooLarge, invalidDefinitions }

    /// A file import carries its provider credit into each stored definition when it has no more
    /// specific attribution. Only metadata is imported; media rights and downloads remain separate.
    static func importedExercises(_ data: Data) throws -> [TrainingExercise] {
        guard data.count <= ExerciseContentLimits.providerCacheBytes else { throw ImportError.tooLarge }
        let archive = try ExerciseCatalogArchive.decode(data)
        guard archive.rights.allowsOfflineCache else { throw ImportError.offlineStorageNotAllowed }
        guard Set(archive.exercises.map(\.id)).count == archive.exercises.count,
              archive.exercises.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ImportError.invalidDefinitions
        }
        let credit = [archive.provider, archive.rights.licence, archive.rights.attribution ?? ""]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " · ")
        return archive.exercises.map { exercise in
            var value = exercise
            if value.attribution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                value.attribution = credit
            }
            return value
        }
    }

}
