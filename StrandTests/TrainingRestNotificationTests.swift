import XCTest
import UserNotifications
@testable import Strand

final class TrainingRestNotificationTests: XCTestCase {
    private let restId = TrainingRestNotification.identifierPrefix + UUID().uuidString

    func testWithTheLoggerOnScreenTheRestEndPlaysItsSoundWithoutABanner() {
        XCTAssertEqual(TrainingRestNotification.foregroundOptions(identifier: restId, loggerOnScreen: true), [.sound])
    }

    func testWithTheLoggerMinimizedTheRestEndShowsAsUsual() {
        XCTAssertEqual(TrainingRestNotification.foregroundOptions(identifier: restId, loggerOnScreen: false),
                       [.banner, .sound, .list])
    }

    func testOtherNotificationsAreLeftToTheGeneralRule() {
        XCTAssertNil(TrainingRestNotification.foregroundOptions(identifier: "wind-down", loggerOnScreen: true))
        XCTAssertNil(TrainingRestNotification.foregroundOptions(identifier: SyncReminderPolicy.identifier,
                                                                 loggerOnScreen: true))
    }
}
