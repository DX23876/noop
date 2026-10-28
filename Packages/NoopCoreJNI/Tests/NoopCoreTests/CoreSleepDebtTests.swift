import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// The sleep-debt ledger on Android (parity plan 2.3) words its card as `SleepDebtLedgerCard` does.
final class CoreSleepDebtTests: XCTestCase {
    func testAnEmptyStoreHasNoNightsAndADebtReadsAsOne() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let empty = await CoreSleepDebt.read(reader: reader)
        XCTAssertEqual(empty.nightCount, 0)

        let short = (0..<14).map { (day: String(format: "2026-10-%02d", $0 + 1), totalSleepMin: Optional(360.0)) }
        let debt = CoreSleepDebt.output(SleepDebt.ledger(series: short, needHours: 8))
        XCTAssertTrue(debt.isDebt)
        XCTAssertEqual(debt.tag, "sleep debt")
        XCTAssertTrue(debt.headline.hasPrefix("≈"))
        XCTAssertTrue(debt.balanceText.hasPrefix("−"))
        XCTAssertEqual(debt.needText, "8h 0m")
        XCTAssertEqual(debt.deltas.count, 14)
        XCTAssertEqual(CoreSleepDebt.duration(45), "45m")
    }
}
