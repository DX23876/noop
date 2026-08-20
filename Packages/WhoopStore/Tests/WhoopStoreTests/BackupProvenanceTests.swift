import XCTest
@testable import WhoopStore

/// Pins the #1410 build-provenance JSON. The expected strings are byte-identical to the Kotlin twin
/// (`BackupProvenanceTest.kt`) for the same inputs — `.sortedKeys` compact JSON, numbers unquoted — so an
/// analyst reads one shape across platforms.
final class BackupProvenanceTests: XCTestCase {

    func test_manifest_json_is_sorted_and_parity_with_kotlin() {
        // Same inputs the Kotlin test uses (platform "android") → must produce the identical string.
        XCTAssertEqual(
            BackupManifest.json(appVersion: "10.1.1", appBuild: "221", platform: "android",
                                schemaVersion: 30, exportedAtMs: 1_723_900_000_000),
            #"{"appBuild":"221","appVersion":"10.1.1","exportedAt":1723900000000,"platform":"android","schemaVersion":30}"#
        )
    }

    func test_versionEvent_payload_is_sorted() {
        XCTAssertEqual(
            AppVersionEvent.payloadJson(from: "10.1.0", to: "10.1.1", schemaVersion: 30),
            #"{"from":"10.1.0","schemaVersion":30,"to":"10.1.1"}"#
        )
    }

    func test_versionEvent_payload_escapes_named_controls_like_kotlin() throws {
        let from = "10.1\n0"
        let to = "10.1\t1\u{1}"
        let json = AppVersionEvent.payloadJson(from: from, to: to, schemaVersion: 30)

        XCTAssertEqual(
            json,
            #"{"from":"10.1\n0","schemaVersion":30,"to":"10.1\t1\u0001"}"#
        )
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["from"] as? String, from)
        XCTAssertEqual(decoded["to"] as? String, to)
    }

    func test_versionEvent_payload_round_trips_every_json_control_character() throws {
        var controls = ""
        for value in 0x00...0x1F {
            controls.unicodeScalars.append(UnicodeScalar(value)!)
        }
        let json = AppVersionEvent.payloadJson(from: controls, to: "ordinary", schemaVersion: 30)

        XCTAssertEqual(
            json,
            #"{"from":"\u0000\u0001\u0002\u0003\u0004\u0005\u0006\u0007\b\t\n\u000b\f\r\u000e\u000f\u0010\u0011\u0012\u0013\u0014\u0015\u0016\u0017\u0018\u0019\u001a\u001b\u001c\u001d\u001e\u001f","schemaVersion":30,"to":"ordinary"}"#
        )
        XCTAssertFalse(json.unicodeScalars.contains { $0.value <= 0x1F })
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["from"] as? String, controls)
    }

    func test_shouldRecord_only_on_a_real_transition() {
        XCTAssertFalse(AppVersionEvent.shouldRecord(lastSeen: nil, current: "10.1.1"))   // first launch
        XCTAssertFalse(AppVersionEvent.shouldRecord(lastSeen: "", current: "10.1.1"))
        XCTAssertFalse(AppVersionEvent.shouldRecord(lastSeen: "10.1.1", current: "10.1.1")) // unchanged
        XCTAssertTrue(AppVersionEvent.shouldRecord(lastSeen: "10.1.0", current: "10.1.1"))  // transition
    }
}
