import XCTest
import GRDB
@testable import WhoopStore

final class EcgReadingStoreTests: XCTestCase {
    private func reading(id: String = "ecg_1", start: Int = 1_000) -> EcgReadingRow {
        EcgReadingRow(id: id, deviceId: "mg", wrist: "left", startTs: start, endTs: start + 40,
                      strapTerminalTs: 77, resultCode: 1, category: "sinusRhythm", averageHr: 62,
                      variabilityRaw: nil, quality: 3, unreadableMask: 0, interruptions: 0, sampleCount: 4,
                      missingSegments: 1, status: "completed")
    }

    private let packets = [
        EcgReadingPacketRow(sequence: 3, strapSeconds: 10, strapSubseconds: 5, isPlaceholder: false,
                            samples: [0, -1, 32_767, -32_768]),
        EcgReadingPacketRow(sequence: 4, strapSeconds: nil, strapSubseconds: nil, isPlaceholder: true, samples: []),
    ]

    func testRoundTripKeepsSamplesBitExactAndOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveEcgReading(reading(), packets: packets)
        let rows = try await store.ecgReadings()
        XCTAssertEqual(rows, [reading()])
        let loaded = try await store.ecgReadingPackets(id: "ecg_1")
        XCTAssertEqual(loaded, packets)
    }

    func testNewestFirstVariabilityUpdateAndCascadingDelete() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveEcgReading(reading(id: "old", start: 100), packets: packets)
        try await store.saveEcgReading(reading(id: "new", start: 200), packets: packets)
        try await store.updateEcgReadingVariability(id: "new", variabilityRaw: 21)
        let rows = try await store.ecgReadings()
        XCTAssertEqual(rows.map(\.id), ["new", "old"])
        XCTAssertEqual(rows.first?.variabilityRaw, 21)
        try await store.deleteEcgReading(id: "new")
        let gone = try await store.ecgReadingPackets(id: "new")
        XCTAssertTrue(gone.isEmpty)
        let kept = try await store.ecgReadingPackets(id: "old")
        XCTAssertEqual(kept.count, 2)
    }

    func testDeleteAllDeviceDataRemovesReadingsAndTheirPackets() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveEcgReading(reading(), packets: packets)
        try await store.deleteAllData(deviceId: "mg")
        let rows = try await store.ecgReadings()
        XCTAssertTrue(rows.isEmpty)
        let orphans = try await store.ecgReadingPackets(id: "ecg_1")
        XCTAssertTrue(orphans.isEmpty)
    }
}
