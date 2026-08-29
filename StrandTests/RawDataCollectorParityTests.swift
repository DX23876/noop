import XCTest
@testable import Strand

/// Feature-level parity guard for the Android and Apple raw-data collectors. The shared oracle lists
/// every user-visible/session-lifecycle capability and source markers on both implementations.
final class RawDataCollectorParityTests: XCTestCase {
    private struct Oracle: Decodable {
        let schemaVersion: Int
        let capabilities: [String: Capability]
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", capabilities }
    }
    private struct Capability: Decodable { let swift: [String]; let kotlin: [String] }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func oracleData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "raw_data_collector_parity",
                                                            withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testAppleSurfaceStillImplementsEveryDeclaredCapability() throws {
        let oracle = try JSONDecoder().decode(Oracle.self, from: oracleData())
        XCTAssertEqual(oracle.schemaVersion, 1)
        let paths = [
            "Strand/Collect/RawDataSessionStore.swift", "Strand/Collect/Collector.swift",
            "Strand/BLE/BLEManager.swift", "Strand/Screens/RawDataCollectorView.swift",
            "Strand/Collect/ImuSessionFileStore.swift",
            "Packages/WhoopStore/Sources/WhoopStore/Database.swift",
            "Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift",
            "Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift",
        ]
        let source = try paths.map { try String(contentsOf: repoRoot.appendingPathComponent($0)) }
            .joined(separator: "\n")
        for (name, capability) in oracle.capabilities {
            for marker in capability.swift {
                XCTAssertTrue(source.contains(marker), "Apple collector lost \(name) marker: \(marker)")
            }
        }
    }

    func testAndroidAndAppleOracleCopiesAreByteIdentical() throws {
        let android = repoRoot.appendingPathComponent("android/app/src/test/resources/raw_data_collector_parity.json")
        XCTAssertEqual(try oracleData(), try Data(contentsOf: android),
                       "Raw-data collector parity oracle copies must change together")
    }

    func testAppleKeepsTheOffSessionRealtimeImuFailSafe() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Strand/BLE/BLEManager.swift"))
        XCTAssertTrue(source.contains("stopUnexpectedRealtimeImu(frame, isOffload: isOffload)"))
        XCTAssertTrue(source.contains("frame[8] == 43 || frame[8] == 51"))
        XCTAssertTrue(source.contains("send(.stopRawData, payload: [0x01]"))
        XCTAssertTrue(source.contains("send(.toggleIMUMode, payload: [0x01, 0x00]"))
    }
}
