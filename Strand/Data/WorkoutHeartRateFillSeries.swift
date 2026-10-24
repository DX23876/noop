import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import StrandCore

// The Repository side of `WorkoutHeartRateFills` (StrandCore): the wearer's profile in, a screen refresh out.
extension Repository {

    /// Whether a Health workout was written by the WHOOP app (`WorkoutHeartRateFills`).
    nonisolated static func isWhoopAuthored(bundleId: String?) -> Bool {
        WorkoutHeartRateFills.isWhoopAuthored(bundleId: bundleId)
    }

    /// Computes and stores the heart rate of every Apple Health workout starting in `[from, to]` that came
    /// without one (`WorkoutHeartRateFills.fillApple`). Returns the number of workouts filled.
    @discardableResult
    func fillAppleWorkoutHeartRate(from: Int, to: Int) async throws -> Int {
        guard let store = await storeHandle() else { return 0 }
        let outcome = try await WorkoutHeartRateFills.fillApple(
            reader: storeReader(store), from: from, to: to, maxHR: Self.cardioLoadMaxHR(strainProfile),
            sex: strainProfile?.sex ?? "", method: PuffinExperiment.effortMethod)
        if outcome.wrote { noteWorkoutAnnotationsChanged() }
        return outcome.filled
    }

    /// Fill namespace of recorded or entered workouts (`WorkoutHeartRateFills`).
    nonisolated static let recordedWorkoutFillNamespace = WorkoutHeartRateFills.recordedWorkoutFillNamespace

    /// Computes and stores the heart rate of every recorded or entered workout starting in `[from, to]` that
    /// was saved without one (`WorkoutHeartRateFills.fillRecorded`). Returns the number of workouts filled.
    @discardableResult
    func fillRecordedWorkoutHeartRate(from: Int, to: Int) async throws -> Int {
        guard let store = await storeHandle() else { return 0 }
        let outcome = try await WorkoutHeartRateFills.fillRecorded(
            reader: storeReader(store), from: from, to: to, maxHR: Self.cardioLoadMaxHR(strainProfile),
            sex: strainProfile?.sex ?? "", method: PuffinExperiment.effortMethod)
        if outcome.wrote { noteWorkoutAnnotationsChanged() }
        return outcome.filled
    }

    /// The fill namespace a row's stored fill lives in (`WorkoutHeartRateFills`).
    nonisolated static func fillNamespace(for row: WorkoutRow) -> String? {
        WorkoutHeartRateFills.fillNamespace(for: row)
    }

    /// Lays stored fills and Health step counts over the rows that lack them (`WorkoutHeartRateFills`).
    func overlayWorkoutFills(_ rows: [WorkoutRow], store: WhoopStore) async -> [WorkoutRow] {
        await WorkoutHeartRateFills.overlay(rows, store: store)
    }

    /// The stored fill of one Apple Health, recorded or entered row, for the detail screen's heart-rate
    /// source line.
    func workoutHeartRateFill(for row: WorkoutRow) async -> WorkoutHeartRateFillRow? {
        guard let namespace = Self.fillNamespace(for: row), let store = await storeHandle() else { return nil }
        let key = WorkoutKey(deviceId: namespace, startTs: row.startTs, sport: row.sport)
        return (try? await store.workoutHeartRateFills(deviceId: namespace,
                                                       from: row.startTs, to: row.startTs))?[key]
    }

    /// Every stored elevation for workouts starting in `[from, to]` (v78), for a batch reader that resolves
    /// each row through `WorkoutElevationRow.resolve`.
    func workoutElevations(from: Int, to: Int) async -> [WorkoutKey: WorkoutElevationRow] {
        guard let store = await storeHandle() else { return [:] }
        return (try? await store.workoutElevations(from: from, to: to)) ?? [:]
    }

    /// The resolved elevation of one workout, for its detail screen.
    func workoutElevation(for row: WorkoutRow) async -> WorkoutElevationRow? {
        WorkoutElevationRow.resolve(startTs: row.startTs, sport: row.sport, rowSource: row.source,
                                    in: await workoutElevations(from: row.startTs, to: row.startTs))
    }

    func noteWorkoutAnnotationsChanged() { workoutAnnotationRevision &+= 1 }
}
