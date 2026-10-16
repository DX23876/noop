import XCTest
@testable import Strand

/// A 0x2A37 subscription confirmed before the 5/MG bond, or one that stays silent, is renewed once.
final class LiveHeartRateResubscribeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_792_140_000)

    func testASubscriptionConfirmedBeforeTheBondIsFlagged() {
        XCTAssertTrue(LiveHeartRateResubscribe.confirmedBeforeBond(isNotifying: true, encryptedBond: false,
                                                                   isWhoop5: true))
    }

    func testASubscriptionConfirmedAfterTheBondIsNotFlagged() {
        XCTAssertFalse(LiveHeartRateResubscribe.confirmedBeforeBond(isNotifying: true, encryptedBond: true,
                                                                    isWhoop5: true))
        XCTAssertFalse(LiveHeartRateResubscribe.confirmedBeforeBond(isNotifying: false, encryptedBond: false,
                                                                    isWhoop5: true))
    }

    func testAWhoop4IsNeverFlagged() {
        XCTAssertFalse(LiveHeartRateResubscribe.confirmedBeforeBond(isNotifying: true, encryptedBond: false,
                                                                    isWhoop5: false))
    }

    func testASilentSubscriptionIsRenewedAfterTheWindow() {
        XCTAssertFalse(LiveHeartRateResubscribe.shouldRenewSilent(
            now: t0.addingTimeInterval(80), confirmedAt: t0, lastValueAt: nil, alreadyTried: false))
        XCTAssertTrue(LiveHeartRateResubscribe.shouldRenewSilent(
            now: t0.addingTimeInterval(91), confirmedAt: t0, lastValueAt: nil, alreadyTried: false))
    }

    func testAStreamThatStoppedCountsFromItsLastValue() {
        let last = t0.addingTimeInterval(600)
        XCTAssertFalse(LiveHeartRateResubscribe.shouldRenewSilent(
            now: last.addingTimeInterval(60), confirmedAt: t0, lastValueAt: last, alreadyTried: false))
        XCTAssertTrue(LiveHeartRateResubscribe.shouldRenewSilent(
            now: last.addingTimeInterval(120), confirmedAt: t0, lastValueAt: last, alreadyTried: false))
    }

    func testAFreshConfirmationRestartsTheWindow() {
        let reconfirmed = t0.addingTimeInterval(600)
        XCTAssertFalse(LiveHeartRateResubscribe.shouldRenewSilent(
            now: reconfirmed.addingTimeInterval(30), confirmedAt: reconfirmed, lastValueAt: t0,
            alreadyTried: false))
    }

    func testOneRenewalPerSilentStretch() {
        XCTAssertFalse(LiveHeartRateResubscribe.shouldRenewSilent(
            now: t0.addingTimeInterval(3600), confirmedAt: t0, lastValueAt: nil, alreadyTried: true))
    }

    func testNothingToRenewWithoutAConfirmedSubscription() {
        XCTAssertFalse(LiveHeartRateResubscribe.shouldRenewSilent(
            now: t0.addingTimeInterval(3600), confirmedAt: nil, lastValueAt: nil, alreadyTried: false))
    }
}
