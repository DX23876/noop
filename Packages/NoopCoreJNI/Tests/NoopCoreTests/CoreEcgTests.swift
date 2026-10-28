import XCTest
import WhoopStore
@testable import NoopCore

/// Saved ECGs on Android (parity plan 2.3): a reading lists with its words, its strip keeps a lost second as a
/// gap, and deleting removes it.
final class CoreEcgTests: XCTestCase {
    func testAReadingListsReadsBackWithItsGapAndDeletes() async throws {
        let store = try await WhoopStore.inMemory()
        let row = EcgReadingRow(id: "r1", deviceId: "mg", wrist: "left", startTs: 1_761_650_000, endTs: 1_761_650_030,
                                strapTerminalTs: nil, resultCode: 1, category: "sinusRhythm", averageHr: 62,
                                variabilityRaw: 48, quality: 3, unreadableMask: 0, interruptions: 0, sampleCount: 300,
                                missingSegments: 1, status: "complete")
        let second = Array(repeating: Int16(0), count: CoreEcg.sampleRate)
        try await store.saveEcgReading(row, packets: [
            .init(sequence: 0, strapSeconds: nil, strapSubseconds: nil, isPlaceholder: false, samples: second),
            .init(sequence: 1, strapSeconds: nil, strapSubseconds: nil, isPlaceholder: true, samples: []),
            .init(sequence: 2, strapSeconds: nil, strapSubseconds: nil, isPlaceholder: false, samples: second)])

        let list = await CoreEcg.run("ecg.readings", args: [:], store: store)
        XCTAssertTrue(list.contains(#""title":"Sinus rhythm""#))
        XCTAssertTrue(list.contains(#""tone":"positive""#))
        let detail = await CoreEcg.run("ecg.reading", args: ["id": "r1"], store: store)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any])
        let samples = try XCTUnwrap(json["samples"] as? [Any])
        XCTAssertEqual(samples.count, 3 * CoreEcg.sampleRate)
        XCTAssertTrue(samples[CoreEcg.sampleRate] is NSNull)
        XCTAssertNil(json["analysis"] as? [String: Any], "a flat strip has no beats to measure")

        let after = await CoreEcg.run("ecg.delete", args: ["id": "r1"], store: store)
        XCTAssertEqual(after, #"{"readings":[]}"#)
    }
}
