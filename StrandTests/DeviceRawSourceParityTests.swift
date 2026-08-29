import Foundation
import XCTest
@testable import Strand
import WhoopStore
import WhoopProtocol

/// Apple half of the shared Android/Apple raw-source oracle. This tests the repository contract rather
/// than duplicating expected values in Swift, so source precedence and R-R identity cannot drift quietly.
final class DeviceRawSourceParityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct SourceCase: Decodable {
            let name: String
            let activeDeviceId: String
            let registeredWhoopIds: [String]
            let imported: [String]
            let computed: [String]
        }
        struct Beat: Decodable {
            let source: String?
            let ts: Int
            let rrMs: Int
            let seq: Int
            let ord: Int?
        }
        struct BeatSource: Decodable { let id: String; let beats: [Beat] }
        struct RRCase: Decodable { let name: String; let sources: [BeatSource]; let expected: [Beat] }
        let sourceCases: [SourceCase]
        let rrCases: [RRCase]
    }

    private func fixture() throws -> Fixture {
        let testFile = URL(fileURLWithPath: #filePath)
        let url = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/parity_cases/device_raw_sources.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Shared device-source parity fixture is missing; parity must fail closed")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func production(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Production source missing: \(path); consumer wiring guard must fail closed")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSourceResolutionMatchesSharedOracle() throws {
        for vector in try fixture().sourceCases {
            let actual = Repository.rawWhoopSourceIds(activeDeviceId: vector.activeDeviceId,
                                                       registeredWhoopIds: vector.registeredWhoopIds)
            XCTAssertEqual(actual, vector.imported, vector.name)
            XCTAssertEqual(actual.map { $0 + "-noop" }, vector.computed, vector.name)
        }
    }

    func testRRIdentityMergeMatchesSharedOracle() throws {
        for vector in try fixture().rrCases {
            let inputs = vector.sources.map { source in
                source.beats.map { RRInterval(ts: $0.ts, rrMs: $0.rrMs, ord: $0.ord, seq: $0.seq) }
            }
            let actual = Repository.mergeRRByIdentity(inputs)
            XCTAssertEqual(actual.map(\.ts), vector.expected.map(\.ts), vector.name)
            XCTAssertEqual(actual.map(\.rrMs), vector.expected.map(\.rrMs), vector.name)
            XCTAssertEqual(actual.map(\.seq), vector.expected.map(\.seq), vector.name)
            XCTAssertEqual(actual.map(\.ord), vector.expected.map(\.ord), vector.name)
        }
    }

    func testStressCannotPinRawReadsToCanonicalNamespace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/Screens/StressView.swift"),
                                encoding: .utf8)
        let withoutComments = source.replacingOccurrences(of: #"/\*.*?\*/"#, with: "",
                                                           options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1).first.map(String.init) ?? "" }
            .joined(separator: "\n")
        let directCanonicalRaw = #"(?s)(hrSamples|rrIntervals|gravitySamples)\s*\([^)]*(\"my-whoop\"|Repository\.whoopSource)"#
        XCTAssertNil(withoutComments.range(of: directCanonicalRaw, options: .regularExpression),
                     "Stress raw physiology must resolve via the device-aware repository API")
        for call in ["repo.hrSamples(from:", "repo.rrIntervals(from:", "repo.gravitySamplesUnion(from:"] {
            XCTAssertTrue(withoutComments.contains(call), "Stress must use device-aware \(call)")
        }
    }

    func testCoachTimelineAndRhythmUseDeviceAwareRawFacades() throws {
        let coach = try production("Strand/AI/AICoach.swift")
        XCTAssertTrue(coach.contains("repo.rrIntervals(from:"),
                      "AI Coach stress context must use Repository's all-source R-R facade")
        XCTAssertFalse(coach.contains("store.rrIntervals(\n            deviceId: repo.deviceId"),
                       "AI Coach must not pin R-R to the currently active device")

        let repository = try production("Strand/Data/Repository.swift")
        guard let timelineStart = repository.range(of: "func timelineSeries(")?.lowerBound else {
            return XCTFail("Repository.timelineSeries is missing")
        }
        let timeline = String(repository[timelineStart...].prefix(12_000))
        XCTAssertTrue(timeline.contains("rawPhysiologyReadIds(store: store)"),
                      "Default Full Day timelines must resolve every registered raw source")
        XCTAssertFalse(timeline.contains("source.map { [$0] } ?? importedReadIds"),
                       "Timeline must not fall back to active-plus-canonical only")
        XCTAssertTrue(repository.contains("hrBuckets(deviceIds: rawPhysiologyReadIds(store: store)"),
                      "Coarse HR reads must include every registered WHOOP strap")
        XCTAssertTrue(repository.contains("ids: rawPhysiologyReadIds(store: store)"),
                      "Primary sleep reads must include every registered WHOOP strap")
        XCTAssertTrue(repository.contains("ids: rawComputedReadIds(store: store)"),
                      "Computed sleep reads must include every registered WHOOP strap")

        let pillars = try production("Strand/Screens/V5PillarHosts.swift")
        XCTAssertTrue(pillars.contains("repo.rrIntervals(from:"),
                      "Rhythm must use Repository's all-source R-R facade")
        XCTAssertTrue(pillars.contains("repo.gravitySamplesUnion(from:"),
                      "Rhythm must use Repository's all-source gravity facade")
        XCTAssertFalse(pillars.contains("store.rrIntervals(deviceId: repo.deviceId"),
                       "Rhythm must not pin R-R to the currently active device")
    }
}
