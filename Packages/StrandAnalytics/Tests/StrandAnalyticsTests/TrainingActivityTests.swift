import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class TrainingActivityTests: XCTestCase {
    func testLegacyNamesClassifyIntoStableFamilies() {
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Traditional Strength Training"), .strength)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Treadmill walk"), .endurance)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Tai Chi"), .mobilityRecovery)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Basketball"), .conditioning)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Underwater diving"), .outdoorRecreation)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Swim Bike Run"), .multisport)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Unknown future activity"), .other)
    }

    func testCurrentHealthNamesDoNotFallThroughTheirIntendedFamilies() {
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Paddling"), .endurance)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Hiking"), .endurance)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Mixed metabolic cardio training"), .conditioning)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Preparation and recovery"), .mobilityRecovery)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Mind and body"), .mobilityRecovery)
        XCTAssertEqual(TrainingActivityClassifier.kind(forStoredName: "Equestrian sports"), .outdoorRecreation)
    }

    func testCardioLoadExposesAdditiveTRIMPSeparatelyFromEffort() throws {
        let hr = (0..<601).map { HRSample(ts: $0, bpm: 150) }
        let one = try XCTUnwrap(StrainScorer.cardioLoad(hr, maxHR: 190, restingHR: 60))
        XCTAssertGreaterThan(one.trimp, 0)
        XCTAssertEqual(one.effort, StrainScorer.trimpToStrain(one.trimp), accuracy: 0.0001)
        XCTAssertNotEqual(one.effort * 2, StrainScorer.trimpToStrain(one.trimp * 2),
                          "the compressed Effort axis must never be treated as additive")
    }
}
