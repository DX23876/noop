import XCTest
import WhoopStore

/// Exercises the Corelibs Foundation NSNumber distinction used by BackupSettings on Linux.
final class BackupSettingsLinuxTests: XCTestCase {
    func testBooleanAndNumericJSONValuesKeepDistinctContracts() throws {
        let payload = Data(#"{"profile.age":true,"profile.hrMax":1,"profile.weightKg":false,"profile.heightCm":1}"#.utf8)

        let decoded = BackupSettings.decode(payload)

        XCTAssertNil(decoded["profile.age"], "A JSON boolean must not be accepted as numeric 1")
        XCTAssertNil(decoded["profile.weightKg"], "A JSON boolean must not be accepted as numeric 0")
        XCTAssertEqual(decoded["profile.hrMax"] as? Int, 1)
        XCTAssertEqual(decoded["profile.heightCm"] as? Double, 1.0)

        let roundTrip = try XCTUnwrap(BackupSettings.encode(decoded))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: roundTrip) as? [String: Any])
        XCTAssertEqual((json["profile.hrMax"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((json["profile.heightCm"] as? NSNumber)?.doubleValue, 1.0)
        XCTAssertNil(json["profile.age"])
        XCTAssertNil(json["profile.weightKg"])
    }
}
