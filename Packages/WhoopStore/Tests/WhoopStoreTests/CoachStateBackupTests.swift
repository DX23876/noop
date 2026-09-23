import XCTest
@testable import WhoopStore

/// The `coach-state.json` codec and its file/UserDefaults round trip. Every test uses a throwaway
/// directory and a suite-scoped UserDefaults, never the runner's real domain. The ZIP-container round trip
/// through `DataBackup` lives in the app target's `BackupSyncRoundTripTests`.
final class CoachStateBackupTests: XCTestCase {

    private var tmp: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coach-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "coach-state-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        suites.append(name)
        return defaults
    }

    private func dir(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Round trip

    func testSnapshotEncodeDecodeApplyReproducesTheCoachState() throws {
        let source = try freshDefaults()
        let sourceDir = try dir("source")
        let facts = Data(#"[{"text":"Knee injury 2024"}]"#.utf8)
        source.set(facts, forKey: "ai.memory.facts")
        source.set("guardian", forKey: "ai.persona")
        source.set(true, forKey: "ai.allowEmoji")
        let conversations = Data(#"[{"id":"a","messages":[]}]"#.utf8)
        let avatar = Data([0xFF, 0xD8, 0xFF, 0x00, 0x42])
        try conversations.write(to: sourceDir.appendingPathComponent("coach-conversations.json"))
        try avatar.write(to: sourceDir.appendingPathComponent("coach-avatar-1234-ABCD.img"))

        let encoded = try XCTUnwrap(CoachStateBackup.encode(
            CoachStateBackup.snapshot(defaults: source, directory: sourceDir)))
        let decoded = try XCTUnwrap(CoachStateBackup.decode(encoded))

        let target = try freshDefaults()
        let targetDir = try dir("target")
        try CoachStateBackup.apply(decoded, to: target, directory: targetDir)

        XCTAssertEqual(target.data(forKey: "ai.memory.facts"), facts)
        XCTAssertEqual(target.string(forKey: "ai.persona"), "guardian")
        XCTAssertEqual(target.object(forKey: "ai.allowEmoji") as? Bool, true, "types survive the plist hop")
        XCTAssertEqual(try Data(contentsOf: targetDir.appendingPathComponent("coach-conversations.json")),
                       conversations)
        XCTAssertEqual(try Data(contentsOf: targetDir.appendingPathComponent("coach-avatar-1234-ABCD.img")),
                       avatar)
    }

    func testRestoreReplacesRatherThanBlends() throws {
        let target = try freshDefaults()
        let targetDir = try dir("target")
        target.set(Data("old facts".utf8), forKey: "ai.memory.facts")
        target.set("commander", forKey: "ai.persona")
        try Data("old plans".utf8).write(to: targetDir.appendingPathComponent("coach-plans.json"))

        // The backup knew the persona but had no memory and no plans.
        let payload = CoachStateBackup.Payload(defaults: ["ai.persona": "friend"])
        try CoachStateBackup.apply(payload, to: target, directory: targetDir)

        XCTAssertEqual(target.string(forKey: "ai.persona"), "friend")
        XCTAssertNil(target.object(forKey: "ai.memory.facts"), "a key the backup lacks is removed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: targetDir.appendingPathComponent("coach-plans.json").path),
            "a store file the backup lacks is removed")
    }

    // MARK: - What never travels

    func testConsentProviderAndStampsAreNeverCarried() throws {
        let source = try freshDefaults()
        source.set(true, forKey: "ai.dataConsent")
        source.set("gemini", forKey: "ai.provider")
        source.set("Bearer secret", forKey: "ai.customAuthHeader")
        source.set("2026-09-23", forKey: "ai.lastBriefDay")
        source.set("friend", forKey: "ai.persona")

        let payload = CoachStateBackup.snapshot(defaults: source, directory: try dir("empty"))
        XCTAssertEqual(Set(payload.defaults.keys), ["ai.persona"])

        // Even a hand-edited backup that smuggles them in is filtered on decode.
        var smuggled = payload
        smuggled.defaults["ai.dataConsent"] = true
        let encoded = try XCTUnwrap(CoachStateBackup.encode(smuggled))
        XCTAssertNil(CoachStateBackup.decode(encoded)?.defaults["ai.dataConsent"])
    }

    func testFileNamesOutsideTheCoachDirectoryAreRefused() {
        XCTAssertTrue(CoachStateBackup.isAllowedFileName("coach-plans.json"))
        XCTAssertTrue(CoachStateBackup.isAllowedFileName("coach-avatar-9F2C-11AA.img"))
        XCTAssertFalse(CoachStateBackup.isAllowedFileName("../whoop.sqlite"))
        XCTAssertFalse(CoachStateBackup.isAllowedFileName("coach-avatar-../../x.img"))
        XCTAssertFalse(CoachStateBackup.isAllowedFileName("coach-avatar-.img"))
        XCTAssertFalse(CoachStateBackup.isAllowedFileName("coach-state-pending.json"))
    }

    func testCraftedPayloadCannotWriteOutsideTheDirectory() throws {
        let object: [String: Any] = [
            "format": 1,
            "files": ["../escape.json": Data("x".utf8).base64EncodedString()],
            "defaults": try PropertyListSerialization.data(fromPropertyList: [String: Any](),
                                                           format: .binary, options: 0).base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try XCTUnwrap(CoachStateBackup.decode(data))
        XCTAssertTrue(decoded.files.isEmpty)
    }

    // MARK: - Refusals

    func testNewerFormatAndMalformedPayloadsAreRefused() throws {
        XCTAssertNil(CoachStateBackup.decode(Data("not json".utf8)))
        XCTAssertNil(CoachStateBackup.decode(Data(#"{"format":2,"files":{},"defaults":""}"#.utf8)))
        XCTAssertNil(CoachStateBackup.decode(Data(#"{"format":1,"files":{}}"#.utf8)))
    }

    func testAnEmptyCoachWritesNoEntry() throws {
        let payload = CoachStateBackup.snapshot(defaults: try freshDefaults(), directory: try dir("empty"))
        XCTAssertNil(CoachStateBackup.encode(payload))
    }

    // MARK: - Pending restore

    func testPendingRestoreKeepsThePreviousStateAndIsConsumedOnce() throws {
        let defaults = try freshDefaults()
        let coachDir = try dir("coach")
        defaults.set("commander", forKey: "ai.persona")

        let restored = try XCTUnwrap(CoachStateBackup.encode(.init(defaults: ["ai.persona": "friend"])))
        try restored.write(to: coachDir.appendingPathComponent(CoachStateBackup.pendingFileName))

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(CoachStateBackup.applyPending(defaults: defaults, directory: coachDir, now: now))
        XCTAssertEqual(defaults.string(forKey: "ai.persona"), "friend")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: coachDir.appendingPathComponent(CoachStateBackup.pendingFileName).path))

        let kept = try Data(contentsOf: coachDir.appendingPathComponent("coach-state-replaced-1790000000.json"))
        XCTAssertEqual(CoachStateBackup.decode(kept)?.defaults["ai.persona"] as? String, "commander")

        XCTAssertFalse(CoachStateBackup.applyPending(defaults: defaults, directory: coachDir, now: now),
                       "nothing pending the second time")
    }

    func testUnreadablePendingFileLeavesTheCoachAlone() throws {
        let defaults = try freshDefaults()
        let coachDir = try dir("coach")
        defaults.set("commander", forKey: "ai.persona")
        try Data("garbage".utf8).write(to: coachDir.appendingPathComponent(CoachStateBackup.pendingFileName))

        XCTAssertFalse(CoachStateBackup.applyPending(defaults: defaults, directory: coachDir))
        XCTAssertEqual(defaults.string(forKey: "ai.persona"), "commander")
    }
}
