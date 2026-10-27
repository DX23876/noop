import Foundation
import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

@MainActor
final class CoreGoalBackupTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goal-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func preferences() throws -> GoalPreferenceImage {
        let image = GoalPreferenceImage()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let goal = CoachGoal(kind: .consistency, title: "Regular training", createdAt: date)
        image.set(try JSONEncoder().encode([goal]), forKey: CoachGoalStore.goalsKey)
        var period = PeriodGoal(metric: .workouts, period: .week, target: 3, parentGoalId: goal.id,
            status: .paused, pauseIntervals: [.init(startedAt: date, endedAt: nil, reason: .travel)],
            targetHistory: [.init(fromDay: "2026-09-01", target: 2), .init(fromDay: "2026-10-01", target: 3)])
        period.unknownFields["futureField"] = .string("keep")
        image.set(try JSONEncoder().encode([period]), forKey: PeriodGoalStore.storageKey)
        image.set(try JSONEncoder().encode([PeriodGoalResult(goalId: period.id, periodStart: "2026-10-05",
            target: 3, value: 3, outcome: .achieved, frozenAt: date)]), forKey: PeriodGoalStore.resultsKey)
        image.set(["bytes": Data([0, 255]), "date": date], forKey: "goals.future")
        image.set([1, 7], forKey: "training.restWeekdays")
        image.set(9_000, forKey: "momentum.stepGoal")
        return image
    }

    func testAndroidExportCarriesAppleReadableGoalsFromTheSameDatabaseSnapshot() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("source.sqlite").path
        let store = try await WhoopStore(path: path)
        let image = try preferences()
        let committed = try await store.commitGoalPreferenceState(expected: nil, replacement: image.serialized())
        XCTAssertTrue(committed)
        let archive = dir.appendingPathComponent("test.noopbak")
        let exported = await CoreBackup.export(store: store, dbPath: path, to: archive.path,
            scratch: dir.path, appVersion: "test", appBuild: "1")
        XCTAssertEqual(exported, .done)
        let appleImage = GoalPreferenceImage()
        let target = dir.appendingPathComponent("apple.sqlite")
        let outcome = BackupArchive.restore(from: archive, toDatabaseAt: target.path, scratchRoot: dir,
            applySettings: { data in
                guard let goals = BackupSettings.decode(data)[GoalBackupBundle.settingsKey] as? String else {
                    return XCTFail("the export must carry the Apple goal settings entry")
                }
                GoalBackupBundle.apply(goals, to: appleImage)
            })
        guard case .imported = outcome else { return XCTFail("restore failed: \(outcome)") }
        XCTAssertEqual(GoalBackupBundle.encode(from: appleImage), GoalBackupBundle.encode(from: image))
        let restored = try await WhoopStore(path: target.path)
        let stored = try await restored.goalPreferenceState()
        let copied = try GoalPreferenceImage(serialized: stored)
        XCTAssertEqual(GoalBackupBundle.encode(from: copied), GoalBackupBundle.encode(from: appleImage))
    }

    func testAppleSettingsOverrideAnOlderDatabaseImageAndPreserveGoalHistory() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("apple-source.sqlite").path
        let source = try await WhoopStore(path: path)
        let stale = GoalPreferenceImage(["momentum.stepGoal": 1_000])
        _ = try await source.commitGoalPreferenceState(expected: nil, replacement: stale.serialized())
        try await source.checkpointWAL()
        let image = try preferences()
        let bundle = try XCTUnwrap(GoalBackupBundle.encode(from: image))
        let archive = dir.appendingPathComponent("apple.noopbak")
        try BackupArchive.writeVerified(dbURL: URL(fileURLWithPath: path), to: archive,
            settingsJSON: BackupSettings.encode([GoalBackupBundle.settingsKey: bundle]),
            manifestJSON: BackupArchive.manifestJSON(appVersion: "test", appBuild: "1", platform: "ios"), scratchRoot: dir)
        let originalArchive = try Data(contentsOf: archive)
        let target = dir.appendingPathComponent("android.sqlite").path
        XCTAssertEqual(CoreBackup.restore(from: archive.path, toDatabaseAt: target, scratch: dir.path), .imported)
        let restored = try await WhoopStore(path: target)
        let stored = try await restored.goalPreferenceState()
        let recovered = try GoalPreferenceImage(serialized: stored)
        XCTAssertEqual(GoalBackupBundle.encode(from: recovered), bundle)
        let periods = PeriodGoalStore(defaults: recovered)
        XCTAssertEqual(periods.goals.first?.status, .paused)
        XCTAssertEqual(periods.goals.first?.pauseIntervals.first?.reason, .travel)
        XCTAssertEqual(periods.goals.first?.targetHistory.count, 2)
        XCTAssertEqual(periods.goals.first?.unknownFields["futureField"], .string("keep"))
        XCTAssertEqual(periods.results.first?.outcome, .achieved)
        XCTAssertEqual(try Data(contentsOf: archive), originalArchive, "preparation must not mutate the picked archive")
    }

    func testPreparationFailureKeepsDestinationAndPickedBackupUntouched() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourcePath = dir.appendingPathComponent("bad-goals.sqlite").path
        let source = try await WhoopStore(path: sourcePath)
        _ = try await source.commitGoalPreferenceState(expected: nil, replacement: Data("invalid image".utf8))
        try await source.checkpointWAL()
        let archive = dir.appendingPathComponent("bad.noopbak")
        let bundle = try XCTUnwrap(GoalBackupBundle.encode(from: preferences()))
        try BackupArchive.writeVerified(dbURL: URL(fileURLWithPath: sourcePath), to: archive,
            settingsJSON: BackupSettings.encode([GoalBackupBundle.settingsKey: bundle]),
            manifestJSON: BackupArchive.manifestJSON(appVersion: "test", appBuild: "1", platform: "ios"), scratchRoot: dir)
        let target = dir.appendingPathComponent("live.sqlite").path
        let live = try await WhoopStore(path: target)
        _ = try await live.commitGoalPreferenceState(expected: nil, replacement: preferences().serialized())
        try await live.checkpointWAL()
        let originalLive = try Data(contentsOf: URL(fileURLWithPath: target))
        let originalArchive = try Data(contentsOf: archive)
        let result = CoreBackup.restore(from: archive.path, toDatabaseAt: target, scratch: dir.path)
        XCTAssertEqual(result, .failed("importFailed"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), originalLive)
        XCTAssertEqual(try Data(contentsOf: archive), originalArchive)
    }

    func testBackupSnapshotKeepsItsGoalImageWhenTheLiveStoreChanges() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await WhoopStore(path: dir.appendingPathComponent("live.sqlite").path)
        let first = try preferences().serialized()
        _ = try await store.commitGoalPreferenceState(expected: nil, replacement: first)
        let path = dir.appendingPathComponent("snapshot.sqlite").path
        let captured = try await store.writeBackupSnapshot(to: path)
        let changed = GoalPreferenceImage(["momentum.stepGoal": 20_000])
        _ = try await store.commitGoalPreferenceState(expected: first, replacement: changed.serialized())
        let snapshot = try WhoopStore.readOnly(path: path)
        let copied = try await snapshot.goalPreferenceState()
        XCTAssertEqual(copied, captured)
        XCTAssertEqual(copied, first)
        let live = try await store.goalPreferenceState()
        XCTAssertNotEqual(live, copied)
    }

    func testLegacySQLiteRestoreFoldsInWalWithoutChangingPickedMainFile() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourcePath = dir.appendingPathComponent("legacy.sqlite").path
        let source = try await WhoopStore(path: sourcePath)
        let image = try preferences()
        _ = try await source.commitGoalPreferenceState(expected: nil, replacement: image.serialized())
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePath + "-wal"))
        let original = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let target = dir.appendingPathComponent("restored.sqlite").path
        XCTAssertEqual(CoreBackup.restore(from: sourcePath, toDatabaseAt: target, scratch: dir.path), .imported)
        let restored = try await WhoopStore(path: target)
        let recovered = try GoalPreferenceImage(serialized: await restored.goalPreferenceState())
        XCTAssertEqual(GoalBackupBundle.encode(from: recovered), GoalBackupBundle.encode(from: image))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourcePath)), original)
    }
}
