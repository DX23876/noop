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
}
