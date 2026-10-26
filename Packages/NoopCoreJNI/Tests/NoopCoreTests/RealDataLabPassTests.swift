import XCTest
import NoopCore
import StrandAnalytics
import StrandCore
import WhoopStore

/// Opt-in real-data parity check (Android parity plan 1.1): runs the Android analysis path (`CoreAnalysis`) over a
/// clone of an iPhone store and compares what it writes with a fresh Apple re-analysis of the same source, for
/// every derived daily series and computed daily row in the rescored window. `NOOP_REALDATA_DB` names the source,
/// `NOOP_REALDATA_APPLE_DB` the Apple snapshot (`RealDataAnalysisSnapshotTests`), and `NOOP_REALDATA_PREFS` the
/// same iPhone preferences plist that test used. No user values are printed. The full 78-table comparison is
/// `Tools/compare_analysis_snapshots.py` over the two output copies; this test checks the analysis values directly.
final class RealDataLabPassTests: XCTestCase {
    @MainActor func testTheAndroidPathWritesWhatTheAppleAppStored() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["NOOP_REALDATA_DB"], let applePath = env["NOOP_REALDATA_APPLE_DB"],
              let prefsPath = env["NOOP_REALDATA_PREFS"],
              let prefs = NSDictionary(contentsOfFile: prefsPath) as? [String: Any] else {
            throw XCTSkip("NOOP_REALDATA_DB, NOOP_REALDATA_APPLE_DB and NOOP_REALDATA_PREFS not set")
        }
        func number(_ key: String, fallback: Double = 0) -> Double { (prefs[key] as? NSNumber)?.doubleValue ?? fallback }
        func flag(_ key: String, fallback: Bool = false) -> Bool { (prefs[key] as? NSNumber)?.boolValue ?? fallback }
        let age = (prefs["profile.dateOfBirth"] as? Date).flatMap {
            Calendar.current.dateComponents([.year], from: $0, to: Date()).year
        } ?? Int(number("profile.age", fallback: 30))
        let profile = CoreAnalysis.Profile(
            age: age, sex: prefs["profile.sex"] as? String ?? "male",
            weightKg: number("profile.weightKg", fallback: 75), heightCm: number("profile.heightCm", fallback: 178),
            hrMaxOverride: Int(number("profile.hrMaxOverride")), waistCm: number("profile.waistCm"),
            stepTicksPerStep: number("profile.stepTicksPerStep", fallback: 1),
            stepsManualCoefficient: number("profile.stepsManualCoefficient"),
            stepsCalibrationCoefficient: number("profile.stepsCalibrationCoefficient"),
            stepsCalibrationSampleDays: Int(number("profile.stepsCalibrationSampleDays")),
            stepsCalibrationConfidence: number("profile.stepsCalibrationConfidence"),
            stepsCalibrationManual: flag("profile.stepsCalibrationManual"),
            stepsHasBankedMotion: flag("profile.stepsHasBankedMotion"))
        var settings = CoreAnalysis.Settings.standard
        settings.effortBanister = flag("noopBanisterEffort")
        settings.sleepStagerV2 = flag("noopExperimentalSleepV2", fallback: true)
        settings.motionAwareWake = flag("noopMotionAwareWake")
        settings.deepHrvWindow = prefs["hrv.window"] as? String == "deep"
        settings.dayCycleMode = prefs["noop.dayCycleMode"] as? String
        settings.healthspan = flag("noopHealthspanAge")
        settings.rhythmAge = flag("noopRhythmAge")
        settings.dismissedSleepSpans = prefs["sleep.dismissedSessions"] as? [String] ?? []
        settings.dismissedWorkoutSpans = prefs["workouts.dismissedDetected"] as? [String] ?? []
        settings.energyCalibration = flag("energy.watchCalibration.enabled")
        settings.spo2CandidateDisplay = flag("noopSpo2CandidateDisplay")
        settings.hrvBaselineEpoch = number("noop.hrvBaselineEpoch")
        settings.recoveryBaselineEpoch = number("noop.recoveryBaselineEpoch")
        settings.manualVO2max = number("profile.vo2maxManual")
        settings.manualVO2maxDay = prefs["profile.vo2maxManualDay"] as? String ?? ""
        settings.manualVO2maxWeightKg = number("profile.vo2maxManualWeightKg")
        settings.activityLevelOverride = Int(number("profile.activityLevelOverride"))

        // `NOOP_REALDATA_OUT` keeps the analysed copy for `Tools/compare_analysis_snapshots.py` against the Apple
        // pass's copy (`RealDataAnalysisSnapshotTests` with the same preferences); otherwise it is removed.
        let dir = URL(fileURLWithPath: env["NOOP_REALDATA_WORK"] ?? NSTemporaryDirectory())
            .appendingPathComponent("parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clone = env["NOOP_REALDATA_OUT"].map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent("whoop.sqlite")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: clone.path + suffix) }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source + suffix),
                                             to: URL(fileURLWithPath: clone.path + suffix))
        }
        let store = try await WhoopStore(path: clone.path)
        let apple = try await WhoopStore(path: applePath)
        let computed = "my-whoop-noop"
        let windowDays = 21
        let from = StoreReader.localDayKey(Date().addingTimeInterval(-Double(windowDays + 120) * 86_400))
        let to = "9999-12-31"

        func series(in sourceStore: WhoopStore) async throws -> [String: Double] {
            var out: [String: Double] = [:]
            for key in try await sourceStore.metricKeys(deviceId: computed) {
                for row in try await sourceStore.metricSeries(deviceId: computed, key: key, from: from, to: to) {
                    out["\(key) \(row.day)"] = row.value
                }
            }
            return out
        }
        func rows(in sourceStore: WhoopStore) async throws -> [String: [String: String]] {
            var out: [String: [String: String]] = [:]
            for row in try await sourceStore.dailyMetrics(deviceId: computed, from: from, to: to) {
                var fields: [String: String] = [:]
                for child in Mirror(reflecting: row).children {
                    if let label = child.label { fields[label] = String(describing: child.value) }
                }
                out[row.day] = fields
            }
            return out
        }
        let appleSeries = try await series(in: apple), appleRows = try await rows(in: apple)
        _ = await CoreAnalysis.run(store: store, deviceId: "my-whoop", profile: profile, settings: settings,
                                   days: windowDays)
        let androidSeries = try await series(in: store), androidRows = try await rows(in: store)

        var differing: [String] = []
        var compared = 0
        for key in Set(appleSeries.keys).union(androidSeries.keys) {
            guard let before = appleSeries[key], let after = androidSeries[key] else {
                differing.append("series \(key): missing on one side")
                continue
            }
            compared += 1
            if abs(after - before) > 1e-9 { differing.append("series \(key): Apple \(before), Android \(after)") }
        }
        for day in Set(appleRows.keys).union(androidRows.keys) {
            guard let before = appleRows[day], let after = androidRows[day] else {
                differing.append("row \(day): missing on one side")
                continue
            }
            for field in Set(before.keys).union(after.keys) {
                let value = before[field]
                compared += 1
                if after[field] != value {
                    differing.append("row \(field) \(day): Apple \(value ?? "-"), Android \(after[field] ?? "-")")
                }
            }
        }
        print("PARITY compared \(compared) values (\(appleSeries.count) series points, \(appleRows.count) rows), " +
              "differing \(differing.count)")
        // One line per differing field or series key, with its count, then the first examples.
        var byKind: [String: Int] = [:]
        for line in differing { byKind[line.split(separator: " ").prefix(2).joined(separator: " "), default: 0] += 1 }
        byKind.sorted { $0.key < $1.key }.forEach { print("PARITY  kind \($0.key): \($0.value)") }
        differing.sorted().prefix(60).forEach { print("PARITY  \($0)") }
        XCTAssertGreaterThan(compared, 0)
        XCTAssertEqual(differing.count, 0)
    }
}
