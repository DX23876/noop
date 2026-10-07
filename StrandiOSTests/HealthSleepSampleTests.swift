import XCTest
import HealthKit
import StrandImport
@testable import NOOP_Staging

@MainActor
final class HealthSleepSampleTests: XCTestCase {
    func testSleepSamplesAreValidBeforeTheVersionedWriterRuns() throws {
        let start = 1_791_158_400
        let kinds: [HealthWriteback.StageKind] = [.awake, .light, .deep, .rem, .unspecified]
        let entry = HealthWriteback.MergedSleepEntry(
            keyStartTs: start, spanStart: start, spanEnd: start + 300,
            intervals: kinds.enumerated().map {
                .init(start: start + $0.offset * 60, end: start + ($0.offset + 1) * 60, kind: $0.element)
            }, allKeyStartTs: [start])
        // HealthKit validates at construction, before save() can supply durable sync versions.
        let samples = HealthKitBridge.sleepSamples(for: entry)
        XCTAssertEqual(samples.count, 6)
        let ids = samples.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String }
        XCTAssertEqual(Set(ids).count, 6)
        XCTAssertTrue(ids.contains("noop:sleep:\(start):inBed"))
        XCTAssertEqual(samples.map(\.value), [HKCategoryValueSleepAnalysis.inBed.rawValue,
            HKCategoryValueSleepAnalysis.awake.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue])
        for sample in samples {
            XCTAssertEqual((sample.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue, 1)
            XCTAssertEqual(sample.metadata?[HKMetadataKeyExternalUUID] as? String, "noop:sleep:\(start)")
            var metadata = try XCTUnwrap(sample.metadata)
            metadata[HKMetadataKeySyncVersion] = NSNumber(value: 42)
            let versioned = HKCategorySample(type: sample.categoryType, value: sample.value,
                start: sample.startDate, end: sample.endDate, metadata: metadata)
            XCTAssertEqual(try HealthSampleWriter.fingerprint(sample),
                           try HealthSampleWriter.fingerprint(versioned),
                           "The construction version must not change durable export identity")
        }
    }
}
