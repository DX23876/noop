import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopStore

// The Repository side of `StrengthHistoryReader`, which the Android core compiles too.
extension Repository {
    /// One read model for Strength, Training, Training Load and the Coach (`StrengthHistoryReader`).
    func resolvedStrengthHistory(days: Int = 4_000) async -> ResolvedStrengthHistory {
        guard let store = await storeHandle() else {
            let from = Int(Date().timeIntervalSince1970) - days * 86_400
            return .init(sessions: [], workouts: [], templates: [:], historyAvailableFrom: from)
        }
        return await StrengthHistoryReader.read(store: store, days: days) { [weak self] in
            await self?.trainingSessions(days: days)
                ?? TrainingSessionResolver.resolve(rows: [], metadata: [], links: [], preferences: [])
        }
    }

    nonisolated static func measurementMode(_ raw: String?) -> TrainingMeasurementMode? {
        StrengthHistoryReader.measurementMode(raw)
    }

    nonisolated static func equipmentIds(_ equipment: HevyEquipment?) -> [String] {
        StrengthHistoryReader.equipmentIds(equipment)
    }
}
