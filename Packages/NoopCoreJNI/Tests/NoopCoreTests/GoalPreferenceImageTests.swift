import Foundation
import XCTest
@testable import NoopCore

final class GoalPreferenceImageTests: XCTestCase {
    func testTypedReadsMatchFoundationDefaults() throws {
        let name = "GoalPreferenceImageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let image = GoalPreferenceImage()
        let values: [Any] = [true, false, 0, -42, 1.75, "true", "YES", "false", "0", "42",
                             " -17.5 ", "nonsense", "TRUE", "yes", "y", "2", "-1", "01", "1.0", " true ", " 1 ", "1e2", "nan", Data([0, 255]), ["one", "two"], [1, 2]]
        for (index, value) in values.enumerated() {
            let key = "case\(index)"
            defaults.set(value, forKey: key)
            image.set(value, forKey: key)
            XCTAssertEqual(image.string(forKey: key), defaults.string(forKey: key), key)
            XCTAssertEqual(image.bool(forKey: key), defaults.bool(forKey: key), key)
            XCTAssertEqual(image.integer(forKey: key), defaults.integer(forKey: key), key)
            XCTAssertEqual(image.double(forKey: key), defaults.double(forKey: key), key)
            XCTAssertEqual(image.data(forKey: key), defaults.data(forKey: key), key)
            XCTAssertEqual(image.stringArray(forKey: key), defaults.stringArray(forKey: key), key)
        }
        XCTAssertEqual(image.integer(forKey: "absent"), defaults.integer(forKey: "absent"))
        XCTAssertEqual(image.bool(forKey: "absent"), defaults.bool(forKey: "absent"))
    }

    func testBackupPreservesUnknownPropertyListValuesAcrossBothStorageHosts() throws {
        let name = "GoalPreferenceImageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let values: [String: Any] = [
            "ai.goals": Data(#"[{"kind":"future","payload":{"x":1}}]"#.utf8),
            "goals.future": ["date": Date(timeIntervalSince1970: 123456), "bytes": Data([0, 255])],
            "goals.frozen": ["2026-10-01", "2026-10-08"],
            "training.restWeekdays": [1, 7], "momentum.stepGoal": 10000,
            "unrelated.secret": "excluded"
        ]
        for (key, value) in values { defaults.set(value, forKey: key) }
        let original = try XCTUnwrap(GoalBackupBundle.encode(from: defaults))
        let image = GoalPreferenceImage()
        XCTAssertEqual(GoalBackupBundle.apply(original, to: image), 5)
        XCTAssertNil(image.object(forKey: "unrelated.secret"))
        XCTAssertEqual(GoalBackupBundle.encode(from: image), original)
        defaults.removePersistentDomain(forName: name)
        XCTAssertEqual(GoalBackupBundle.apply(try XCTUnwrap(GoalBackupBundle.encode(from: image)), to: defaults), 5)
        XCTAssertEqual(GoalBackupBundle.encode(from: defaults), original)
    }

    func testSnapshotDoesNotPublishLaterMutations() {
        let original = GoalPreferenceImage(["goals.limit": 3])
        let snapshot = GoalPreferenceImage(original.dictionaryRepresentation())
        original.set(5, forKey: "goals.limit")
        XCTAssertEqual(snapshot.integer(forKey: "goals.limit"), 3)
        snapshot.removeObject(forKey: "goals.limit")
        XCTAssertEqual(original.integer(forKey: "goals.limit"), 5)
    }
}
