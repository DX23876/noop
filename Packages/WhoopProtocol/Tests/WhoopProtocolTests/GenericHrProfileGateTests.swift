import XCTest
@testable import WhoopProtocol

/// `GenericHrProfileGate` — the send allowlist for `TOGGLE_GENERIC_HR_PROFILE(14)`.
///
/// The point of each test is the REFUSAL: the predicate the real 5/MG send path consults is proved here to
/// reject every opcode and body that is not this one command's own, so a test about the predicate is a test
/// about the wire path rather than about a parallel copy of the rule.
final class GenericHrProfileGateTests: XCTestCase {

    func testAdmitsOnlyTheTwoWellFormedBodiesUnderTheOptIn() {
        for on in [true, false] {
            XCTAssertTrue(GenericHrProfileGate.admitsSend(
                opcode: GenericHrProfileGate.toggleGenericHrProfileCmd,
                payload: GenericHrProfileGate.body(on: on),
                broadcastHrOptIn: true), "the opt-in admits \(on ? "01" : "00")")
        }
    }

    func testWithoutTheOptInTheOnWriteIsRefusedAndTheOffWriteIsNot() {
        // The asymmetry IS the fix. The opt-in is bound straight to the Settings switch, so it is already
        // false by the time `setBroadcastHr(false)` runs: gating the off direction on it refuses the one
        // write that stops the strap serving its heart rate, which is the dead undo path #1061 and #174
        // each shipped once already.
        XCTAssertFalse(GenericHrProfileGate.admitsSend(
            opcode: GenericHrProfileGate.toggleGenericHrProfileCmd,
            payload: GenericHrProfileGate.body(on: true),
            broadcastHrOptIn: false), "the ON write needs the opt-in")
        XCTAssertTrue(GenericHrProfileGate.admitsSend(
            opcode: GenericHrProfileGate.toggleGenericHrProfileCmd,
            payload: GenericHrProfileGate.body(on: false),
            broadcastHrOptIn: false), "the OFF write is the undo and must never need the opt-in")
    }

    func testAReplayedEventIsNotTheCurrentState() {
        // A strap banks these events, so an offload hands over an old one. Reporting that as the present
        // state prints the opposite of the truth for a service switched since.
        for event in [GenericHrProfileGate.enabledEvent, GenericHrProfileGate.disabledEvent] {
            XCTAssertNil(GenericHrProfileGate.liveStateFromEvent(event, replayedOffload: true))
            XCTAssertEqual(GenericHrProfileGate.liveStateFromEvent(event, replayedOffload: false),
                           GenericHrProfileGate.stateFromEvent(event))
        }
    }

    func testRefusesEveryOtherOpcodeIncludingTheDeviceConfigWrite() {
        // 119 is the other route the same switch uses on a 5/MG. It keeps its own key-aware gate and must
        // never be reachable from this one, which is why it is named in the gate rather than merely absent.
        XCTAssertFalse(GenericHrProfileGate.admitsSend(
            opcode: GenericHrProfileGate.setDeviceConfigValueCmd,
            payload: [0x01], broadcastHrOptIn: true))
        for opcode in UInt8(0)...UInt8(255)
        where opcode != GenericHrProfileGate.toggleGenericHrProfileCmd {
            XCTAssertFalse(GenericHrProfileGate.admitsSend(opcode: opcode, payload: [0x01],
                                                          broadcastHrOptIn: true),
                           "opcode \(opcode) must not ride this clause")
        }
    }

    func testRefusesAMalformedBody() {
        // Exact-length matching is deliberate: a longer body is not a request this app formed, and "first
        // byte wins" would widen the gate to whatever a future caller happens to pass.
        let bad: [[UInt8]] = [[], [0x02], [0xFF], [0x01, 0x00], [0x00, 0x00], [0x01, 0x01, 0x01]]
        for payload in bad {
            XCTAssertFalse(GenericHrProfileGate.admitsSend(
                opcode: GenericHrProfileGate.toggleGenericHrProfileCmd,
                payload: payload, broadcastHrOptIn: true), "body \(payload) must be refused")
            XCTAssertNil(GenericHrProfileGate.requestedState(inSendPayload: payload))
        }
    }

    func testRequestedStateReadsBackWhatBodyWrote() {
        XCTAssertEqual(GenericHrProfileGate.requestedState(inSendPayload: GenericHrProfileGate.body(on: true)), true)
        XCTAssertEqual(GenericHrProfileGate.requestedState(inSendPayload: GenericHrProfileGate.body(on: false)), false)
    }

    func testStateFromEventNamesOnlyTheTwoEvents() {
        XCTAssertEqual(GenericHrProfileGate.stateFromEvent(GenericHrProfileGate.enabledEvent), true)
        XCTAssertEqual(GenericHrProfileGate.stateFromEvent(GenericHrProfileGate.disabledEvent), false)
        // The decoder appends the raw number to an event name, so the match is a prefix match.
        XCTAssertEqual(GenericHrProfileGate.stateFromEvent("\(GenericHrProfileGate.enabledEvent)(24)"), true)
        XCTAssertEqual(GenericHrProfileGate.stateFromEvent("\(GenericHrProfileGate.disabledEvent)(25)"), false)
        for other in ["BLE_BONDED", "WRIST_ON", "BLE_REALTIME_HR_ON", "BATTERY_LEVEL", ""] {
            XCTAssertNil(GenericHrProfileGate.stateFromEvent(other))
        }
    }
}
