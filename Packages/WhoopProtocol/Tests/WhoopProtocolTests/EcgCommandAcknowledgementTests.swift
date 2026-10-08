import XCTest
@testable import WhoopProtocol

final class EcgCommandAcknowledgementTests: XCTestCase {
    private let reply = stride(from: 0, to: 40, by: 2).map { i -> UInt8 in
        let hex = Array("aa010c000100271124167c3101010000ef4bcf45")
        return UInt8(String(hex[i..<i + 2]), radix: 16)!
    }

    func testMatchesEchoedSequenceRatherThanNotificationSequence() {
        let ack = EcgCommandAcknowledgement(opcode: 124, sequence: 49, now: 10)
        XCTAssertEqual(ack.resolve(frame: reply, now: 11), .accepted)
        XCTAssertNil(EcgCommandAcknowledgement(opcode: 124, sequence: 22, now: 10).resolve(frame: reply, now: 11))
        XCTAssertNil(EcgCommandAcknowledgement(opcode: 125, sequence: 49, now: 10).resolve(frame: reply, now: 11))
    }

    func testIntegrityAndDeadlineAreRequired() {
        let ack = EcgCommandAcknowledgement(opcode: 124, sequence: 49, now: 10)
        var corrupt = reply
        corrupt[12] = 0
        XCTAssertNil(ack.resolve(frame: corrupt, now: 11))
        XCTAssertEqual(ack.resolve(frame: reply, now: 14), .timedOut)
    }

    func testCleanupContainsEveryOffCommandInOrder() {
        XCTAssertEqual(EcgControlPlan.cleanup.map(\.opcode), [124, 125, 139])
        XCTAssertEqual(EcgControlPlan.cleanup.map(\.payload), [
            Whoop5Ecg.controlPayload(.stop), Whoop5Ecg.togglePayload(on: false),
            Whoop5Ecg.togglePayload(on: false)])
        XCTAssertEqual(EcgControlPlan.start(wrist: .left).map(\.opcode), [123, 139, 125, 20, 124])
    }
}
