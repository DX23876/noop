import XCTest
@testable import Strand

/// The coach's own entry in a `.noopbak`.
///
/// A device migration used to restore every health row and lose most of the coach: who it is, how it
/// speaks, the facts it had remembered, the plan book, the digests of past conversations and every
/// consent. These run against a suite-scoped `UserDefaults` and a throwaway folder, never the
/// runner's own domain or files.
final class CoachBackupTests: XCTestCase {

    private var tmp: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coachbackup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "coachbackup-test-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else {
            throw NSError(domain: "CoachBackupTests", code: 1)
        }
        suites.append(name)
        return d
    }

    // MARK: - The round trip

    func testWhoTheCoachIsAndWhatItLearnedSurviveTheTrip() throws {
        let source = try freshDefaults()
        source.set("Smith", forKey: "coach.identity")
        source.set("dry", forKey: "ai.persona")
        source.set(true, forKey: "ai.dataConsent")
        source.set(false, forKey: "ai.allowEmoji")
        source.set(3, forKey: "ai.proactiveLevel")
        source.set(Data("two remembered facts".utf8), forKey: "ai.memory.facts")

        let plans = tmp.appendingPathComponent("coach-plans.json")
        try Data(#"[{"title":"Base block"}]"#.utf8).write(to: plans)

        let payload = try XCTUnwrap(CoachBackup.snapshot(defaults: source, supportDirectory: tmp))

        let target = try freshDefaults()
        let targetDir = tmp.appendingPathComponent("restored", isDirectory: true)
        CoachBackup.apply(payload, defaults: target, supportDirectory: targetDir)

        XCTAssertEqual(target.string(forKey: "coach.identity"), "Smith")
        XCTAssertEqual(target.string(forKey: "ai.persona"), "dry")
        XCTAssertEqual(target.object(forKey: "ai.dataConsent") as? Bool, true)
        XCTAssertEqual(target.object(forKey: "ai.allowEmoji") as? Bool, false,
                       "a stored false must come back false, not as 0")
        XCTAssertEqual(target.object(forKey: "ai.proactiveLevel") as? Int, 3)
        XCTAssertEqual(target.data(forKey: "ai.memory.facts"), Data("two remembered facts".utf8))
        XCTAssertEqual(try Data(contentsOf: targetDir.appendingPathComponent("coach-plans.json")),
                       try Data(contentsOf: plans))
    }

    /// Nothing to carry means no entry, which is the same right degrade `settings.json` makes: a fresh
    /// install writes a backup without one rather than an empty object.
    func testAFreshInstallCarriesNoEntryAtAll() throws {
        let empty = try freshDefaults()
        XCTAssertNil(CoachBackup.snapshot(defaults: empty,
                                          supportDirectory: tmp.appendingPathComponent("nothing-here")))
    }

    /// The master switch stays with the device. A restore must never switch on a coach the wearer has
    /// not switched on, which is also what makes carrying the consents safe.
    func testTheMasterSwitchIsNotCarried() {
        XCTAssertFalse(CoachBackup.carriedKeys.contains(CoachFeaturePrefs.enabledKey))
    }

    /// A value that travelled in both the coach entry and the goals bundle could come back differently
    /// depending on which was applied last. One key, one place.
    func testNoKeyTravelsInTheGoalsBundleAsWell() {
        for key in CoachBackup.carriedKeys {
            XCTAssertFalse(GoalBackupBundle.fixedKeys.contains(key),
                           "\(key) already travels in the goals bundle")
            XCTAssertFalse(key.hasPrefix("goals."),
                           "\(key) is swept into the goals bundle by its prefix")
        }
    }

    /// Neither the API keys nor anything that names this install's clock, screen or server may travel.
    func testNothingThatBelongsToThisDeviceTravels() {
        let forbidden = ["ai.customBaseURL", "ai.customAuthHeader", "ai.customConnected",
                         "ai.keyProvider", "ai.model", "ai.provider", "ai.memoryModel", "ai.cardModel",
                         "ai.deepModel", "ai.lastBriefDay", "ai.lastCheckInDay", "ai.usage.dayTotal",
                         "ai.openRouterModelPrices", "coach.settings.entry"]
        for key in forbidden {
            XCTAssertFalse(CoachBackup.carriedKeys.contains(key), "\(key) must not travel")
        }
    }

    func testAnUnknownVersionAppliesNothing() throws {
        let target = try freshDefaults()
        let alien = try JSONSerialization.data(withJSONObject: [
            "v": CoachBackup.version + 7,
            "defaults": ["coach.identity": ["kind": "string", "value": "Nope"]]
        ])
        CoachBackup.apply(alien, defaults: target, supportDirectory: tmp)
        XCTAssertNil(target.string(forKey: "coach.identity"))
        XCTAssertFalse(CoachBackup.isApplicable(alien))
    }

    /// A hand-edited file must not be able to write a key the allowlist does not name.
    func testAPayloadCannotWriteAKeyTheAllowlistDoesNotName() throws {
        let target = try freshDefaults()
        let hostile = try JSONSerialization.data(withJSONObject: [
            "v": CoachBackup.version,
            "defaults": ["ai.customBaseURL": ["kind": "string", "value": "http://10.0.0.5:1234"]]
        ])
        CoachBackup.apply(hostile, defaults: target, supportDirectory: tmp)
        XCTAssertNil(target.string(forKey: "ai.customBaseURL"))
    }

    // MARK: - Staged, and applied on the next launch

    func testAStagedPayloadIsAppliedOnceAndThenGone() throws {
        let source = try freshDefaults()
        source.set("Smith", forKey: "coach.identity")
        let payload = try XCTUnwrap(CoachBackup.snapshot(defaults: source, supportDirectory: tmp))

        CoachBackup.stage(payload, supportDirectory: tmp)
        let target = try freshDefaults()

        XCTAssertTrue(CoachBackup.applyStagedRestoreIfPresent(defaults: target, supportDirectory: tmp))
        XCTAssertEqual(target.string(forKey: "coach.identity"), "Smith")
        XCTAssertFalse(CoachBackup.applyStagedRestoreIfPresent(defaults: target, supportDirectory: tmp),
                       "the staged payload is removed once applied")
    }

    /// Restoring a backup without a coach entry clears a payload that had not been applied yet, so it
    /// cannot land on top of the database the newer restore just put in place. The coach's own state is
    /// not touched by that.
    func testABackupWithoutACoachEntryClearsAPendingPayload() throws {
        let source = try freshDefaults()
        source.set("Smith", forKey: "coach.identity")
        CoachBackup.stage(try XCTUnwrap(CoachBackup.snapshot(defaults: source, supportDirectory: tmp)),
                          supportDirectory: tmp)

        CoachBackup.stage(nil, supportDirectory: tmp)

        let target = try freshDefaults()
        XCTAssertFalse(CoachBackup.applyStagedRestoreIfPresent(defaults: target, supportDirectory: tmp))
        XCTAssertNil(target.string(forKey: "coach.identity"))
    }

    // MARK: - Thread digests

    func testOnlySummarisedThreadsTravelAndTheirMessagesDoNot() throws {
        var summarised = CoachConversation(title: "Knee and cycling")
        summarised.summary = "Prefers easy cycling when the knee hurts."
        summarised.messages = [ChatMessage(role: .user, text: "my knee hurts")]
        let unsummarised = CoachConversation(title: "Nothing distilled yet")
        let file = tmp.appendingPathComponent("coach-conversations.json")
        try JSONEncoder().encode([summarised, unsummarised]).write(to: file)

        let digests = CoachBackup.conversationDigests(supportDirectory: tmp)
        XCTAssertEqual(digests.count, 1)
        XCTAssertEqual(digests[0]["summary"] as? String, "Prefers easy cycling when the knee hurts.")
        XCTAssertEqual(digests[0]["title"] as? String, "Knee and cycling")
        XCTAssertNil(digests[0]["messages"], "a digest carries what was learned, never the chat")

        // Restored into a device that has none, and restoring the same backup twice must not double it.
        let targetDir = tmp.appendingPathComponent("digest-target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        CoachBackup.restoreDigests(digests, supportDirectory: targetDir)
        CoachBackup.restoreDigests(digests, supportDirectory: targetDir)

        let restored = try JSONDecoder().decode(
            [CoachConversation].self,
            from: try Data(contentsOf: targetDir.appendingPathComponent("coach-conversations.json")))
        XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(restored[0].messages.isEmpty)
        XCTAssertTrue(restored[0].archived, "a digest belongs in the archived section, not in the list")
        XCTAssertEqual(restored[0].summary, "Prefers easy cycling when the knee hurts.")
    }
}
