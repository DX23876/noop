import Foundation
import StrandCore
import StrandTraining
import WhoopStore

/// Offline library and performance history through the core. The host only filters display metadata,
/// localizes labels and chooses an exercise; no records or anatomy are recalculated in Kotlin.
public enum CoreTrainingLibrary {
    public struct Row: Encodable {
        public var id: String, title: String, mode: String, source: String
        public var primaryMuscle: String?
        public var aliases: [String], region: String, primary: [String], secondary: [String], equipment: [String], matchingMuscles: [String]
        init(_ exercise: TrainingExercise) {
            let info = TrainingLibraryPreparation.Info(exercise)
            id = exercise.id; title = exercise.title; mode = exercise.mode.rawValue; source = exercise.source.rawValue
            primaryMuscle = info.primary.first; aliases = exercise.aliases
            region = info.region.rawValue; primary = info.primary; secondary = info.secondary; equipment = info.equipment; matchingMuscles = info.matchingMuscles
        }
    }

    public struct Catalog: Encodable {
        public var exercises: [Row], muscles: [String], equipment: [String], regions: [String], modes: [String]
        public var provider: String, licence: String, attribution: String?
    }

    public struct Records: Encodable {
        public var sessions: Int, heaviestKg: Double?, estimatedOneRepMaxKg: Double?, lastPerformedTs: Int?
        init(_ records: TrainingPerformanceHistory.Records) {
            sessions = records.sessionCount; heaviestKg = records.heaviestSetKg
            estimatedOneRepMaxKg = records.bestEstimatedOneRepMaxKg; lastPerformedTs = records.lastPerformedTs
        }
    }

    public struct Recent: Encodable {
        public var startTs: Int, isNative: Bool, workingSets: Int, heaviestKg: Double?
        init(_ entry: TrainingPerformanceHistory.Entry) {
            startTs = entry.startTs; isNative = entry.isNative; workingSets = entry.workingSets.count
            heaviestKg = entry.workingSets.compactMap(\.weightKg).filter { $0 > 0 }.max()
        }
    }

    public struct Detail: Encodable {
        public var exercise: Row, instructions: [String], attribution: String?
        public var unilateral: Bool, hasDraft: Bool, records: Records, recent: [Recent]
    }

    public static func catalog(store: WhoopStore) async throws -> Catalog {
        await CoreTraining.prepare(store: store)
        let exercises = try await store.trainingExercises()
        let rows = exercises.map(Row.init)
        let rights = BundledExerciseCatalog.rights
        return Catalog(exercises: rows, muscles: TrainingMuscleCatalog.all.map(\.id),
            equipment: Array(Set(rows.flatMap(\.equipment)).union(TrainingEquipmentCatalog.known)).sorted(),
            regions: TrainingBodyRegion.allCases.filter { $0 != .other }.map(\.rawValue),
            modes: TrainingMeasurementMode.allCases.map(\.rawValue),
            provider: rights.provider, licence: rights.licence, attribution: rights.attribution)
    }

    public static func detail(reader: StoreReader, id: String, dismissedWorkouts: [String],
                              now: Int = Int(Date().timeIntervalSince1970)) async -> Detail? {
        await CoreTraining.prepare(store: reader.store)
        guard let exercises = try? await reader.store.trainingExercises(),
              let exercise = exercises.first(where: { $0.id == id }) else { return nil }
        let from = now - TrainingHistoryWindow.allDays * 86_400
        async let native = StrengthHistoryReader.pagedNativeWorkouts(store: reader.store, from: from, to: now + 86_400)
        let history = await StrengthHistoryReader.read(store: reader.store, days: TrainingHistoryWindow.allDays, now: now) {
            await TrainingSessionResolver.read(reader: reader, from: from, to: now + 86_400,
                dismissedDetectedSpans: dismissedWorkouts)
        }
        let performance = await TrainingPerformanceHistory(native: native, resolved: history, exercises: exercises)
        let draft = try? await reader.store.workoutDraft()
        return Detail(exercise: Row(exercise), instructions: exercise.instructions, attribution: exercise.attribution,
            unilateral: exercise.isUnilateral, hasDraft: draft != nil,
            records: Records(performance.records(for: id, mode: exercise.mode)),
            recent: performance.entries(for: id).reversed().prefix(5).map(Recent.init))
    }

    public static func create(store: WhoopStore, title: String, mode: String, primary: String,
                              equipment: String, instruction: String, unilateral: Bool) async -> String? {
        guard let mode = TrainingMeasurementMode(rawValue: mode),
              let exercise = TrainingLibraryPreparation.customExercise(title: title, mode: mode,
                primary: primary, equipment: equipment, instruction: instruction, unilateral: unilateral) else { return nil }
        do {
            try await store.upsertTrainingExercises([exercise], nowTs: Int(Date().timeIntervalSince1970))
            return exercise.id
        } catch { return nil }
    }

    /// The same archive and explicit offline-storage right as the Apple file importer. Media ids are
    /// metadata; importing a catalogue never downloads an image or grants additional rights to it.
    public static func importCatalog(store: WhoopStore, json: String) async -> Int? {
        do {
            let exercises = try TrainingLibraryPreparation.importedExercises(Data(json.utf8))
            try await store.upsertTrainingExercises(exercises, nowTs: Int(Date().timeIntervalSince1970))
            return exercises.count
        } catch { return nil }
    }
}
