import XCTest
@testable import Strand

/// The bell is a recent local history for events that actually fired. These checks pin the persistence
/// semantics independently of operating-system notification permission or delivery.
@MainActor
final class UpdateInboxAlertTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UpdateStore.shared.clearAll()
    }

    override func tearDown() {
        UpdateStore.shared.clearAll()
        super.tearDown()
    }

    func testSameAlertKeyRefreshesOneRowAndRearmsUnread() throws {
        let store = UpdateStore.shared
        let first = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let expiry = first.addingTimeInterval(24 * 60 * 60)

        store.postOrRefreshAlert(
            key: "battery-low:2028-07-10", title: "Low battery", message: "20% remaining",
            deepLink: NavRouter.Destination.devices.rawValue, expiresAt: expiry, now: first
        )
        let id = try XCTUnwrap(store.items.first?.id)
        store.markRead(id)

        let refreshed = first.addingTimeInterval(60)
        store.postOrRefreshAlert(
            key: "battery-low:2028-07-10", title: "Low battery", message: "15% remaining",
            deepLink: NavRouter.Destination.devices.rawValue,
            expiresAt: refreshed.addingTimeInterval(24 * 60 * 60), now: refreshed
        )

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.id, id)
        XCTAssertEqual(store.items.first?.message, "15% remaining")
        XCTAssertEqual(store.items.first?.deepLink, NavRouter.Destination.devices.rawValue)
        XCTAssertFalse(store.items.first?.read ?? true)
    }

    func testExpiredAlertsArePrunedButOrdinaryUpdatesRemain() {
        let store = UpdateStore.shared
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        store.post(UpdateItem(kind: .whatsNew, title: "Release", message: "Still here", date: now))
        store.postOrRefreshAlert(
            key: "inactivity:2028-07-10", title: "Time to move", message: "A short walk helps.",
            expiresAt: now.addingTimeInterval(60), now: now
        )

        store.pruneExpired(now: now.addingTimeInterval(60))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.kind, .whatsNew)
    }

    func testDistinctDayScopedKeysRemainDistinctAlerts() {
        let store = UpdateStore.shared
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        for day in ["2028-07-10", "2028-07-11"] {
            store.postOrRefreshAlert(
                key: "smart-alarm:\(day)", title: "Smart alarm", message: "Good morning.",
                expiresAt: now.addingTimeInterval(24 * 60 * 60), now: now
            )
        }
        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(store.items.allSatisfy { $0.kind == .strapAlert && $0.deepLink == nil })
    }
}
