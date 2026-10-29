import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// The pills under Android's Today hero: a readiness verdict over the core's days and the wearer's status, which
/// lands under the key goals, Momentum and the coach read (`ActivityStatusStore`).
final class CoreTodayStatusTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ActivityStatusStore.key)
        super.tearDown()
    }

    func testTheDemoDaysGiveAVerdictAndTheStatusRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await CoreDemo.seedIfEmpty(store: store, deviceId: "my-whoop")
        let r = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let first = await CoreTodayStatus.read(reader: r, maxHR: 190, sex: "male", dismissedWorkoutSpans: [])
        XCTAssertNotEqual(first.level, "insufficient", "six weeks of scored days are enough for a verdict")
        XCTAssertEqual(first.activity, "active")
        XCTAssertTrue(CoreTodayStatus.setActivity(state: "sick", duration: "threeDays", customUntil: nil))
        let sick = await CoreTodayStatus.read(reader: r, maxHR: 190, sex: "male", dismissedWorkoutSpans: [])
        XCTAssertEqual(sick.activity, "sick")
        XCTAssertNotNil(sick.validUntil)
        XCTAssertTrue(ActivityStatusStore.load().suppressesTrainingSuggestions)
        XCTAssertFalse(CoreTodayStatus.setActivity(state: "asleep", duration: "today", customUntil: nil))
        XCTAssertTrue(CoreTodayStatus.setActivity(state: "active", duration: "today", customUntil: nil))
        XCTAssertNil(ActivityStatusStore.load().validUntil, "back to active carries no end")
    }
}
