import XCTest
@testable import Strand

/// The Steps calibration affordance is a WHOOP 4.0 feature, except when a profile already owns a working
/// coefficient from an earlier 4.0 calibration. WHOOP 5.0 motion rows can advance the shared fitter's
/// sample-day counter, so that counter cannot stand in for an actual calibration (#1523).
final class TodayStepsPipelineTests: XCTestCase {

    private func active(model: WhoopModel?,
                        hasDayData: Bool,
                        calibrationCoefficient: Double = 0,
                        manualCoefficient: Double = 0,
                        sampleDays: Int = 0) -> Bool {
        TodayView.stepsPipelineActive(
            selectedModelRaw: model?.rawValue ?? "",
            hasDayData: hasDayData,
            calibrationCoefficient: calibrationCoefficient,
            manualCoefficient: manualCoefficient,
            calibrationSampleDays: sampleDays)
    }

    func testWhoop5PartialSampleDaysDoNotActivateFourPointZeroPipeline() {
        XCTAssertFalse(active(model: .whoop5mg, hasDayData: true, sampleDays: 3))
    }

    func testWhoop4WithDayDataActivatesBeforeCalibrationStarts() {
        XCTAssertTrue(active(model: .whoop4, hasDayData: true))
    }

    func testWhoop4WithoutDayDataIsNotActivatedByPartialSampleDays() {
        XCTAssertFalse(active(model: .whoop4, hasDayData: false, sampleDays: 3))
    }

    func testFittedCoefficientPreservesMigratedFourPointZeroProfile() {
        XCTAssertTrue(active(model: .whoop5mg,
                             hasDayData: true,
                             calibrationCoefficient: 0.42,
                             sampleDays: 5))
    }

    func testManualCoefficientPreservesMigratedFourPointZeroProfile() {
        XCTAssertTrue(active(model: .whoop5mg,
                             hasDayData: true,
                             manualCoefficient: 0.35,
                             sampleDays: 1))
    }

    func testUnsetModelAndPartialSampleDaysStayInactive() {
        XCTAssertFalse(active(model: nil, hasDayData: true, sampleDays: 3))
    }
}
