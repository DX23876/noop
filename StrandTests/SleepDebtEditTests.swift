import XCTest
@testable import Strand

final class SleepDebtEditTests: XCTestCase {
    func testEditedNightAdjustsImportedDebtBySleepDurationDelta() {
        let imported = ImportedSleepFigures(
            debtMin: 60,
            originalSleepMin: 480
        )

        let debt = Repository.resolvedSleepDebtMinutes(
            imported: imported,
            actualSleepMin: 410,
            fallbackNeedMin: 450,
            isUserEdited: true
        )

        XCTAssertEqual(debt, 130)
    }

    func testEditedNightWithoutOriginalDurationUsesExistingFallback() {
        let debt = Repository.resolvedSleepDebtMinutes(
            imported: ImportedSleepFigures(debtMin: 60),
            actualSleepMin: 410,
            fallbackNeedMin: 450,
            isUserEdited: true
        )

        XCTAssertEqual(debt, 40)
    }
}
