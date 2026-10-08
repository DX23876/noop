import Foundation

/// One outstanding MG control request. The echoed request sequence is at frame byte 11, distinct
/// from the notification's own sequence at byte 9. A BLE write completion is not this acknowledgement.
public struct EcgCommandAcknowledgement: Sendable {
    public enum Resolution: Equatable, Sendable { case accepted, refused, timedOut }

    public let opcode: UInt8
    public let sequence: UInt8
    public let deadline: TimeInterval

    public init(opcode: UInt8, sequence: UInt8, now: TimeInterval, timeout: TimeInterval = 4) {
        self.opcode = opcode
        self.sequence = sequence
        deadline = now + timeout
    }

    public func resolve(frame: [UInt8], now: TimeInterval) -> Resolution? {
        guard now < deadline else { return .timedOut }
        guard verifyFrame(frame, family: .whoop5).ok, frame.count > 12,
              frame[8] == 36 || frame[8] == 38,
              frame[10] == opcode, frame[11] == sequence else { return nil }
        switch Whoop5EcgProbe.outcome(frame: frame) {
        case .success: return .accepted
        case .pending: return nil
        default: return .refused
        }
    }
}

/// The capture's command lists, using the protocol's existing reversible ECG controls.
public enum EcgControlPlan {
    public struct Command: Equatable, Sendable {
        public let opcode: UInt8
        public let payload: [UInt8]
        public init(opcode: UInt8, payload: [UInt8]) { self.opcode = opcode; self.payload = payload }
    }

    public static func start(wrist: Whoop5Ecg.WristSelection) -> [Command] {
        [Command(opcode: 123, payload: Whoop5Ecg.selectWristPayload(wrist)),
         Command(opcode: 139, payload: Whoop5Ecg.togglePayload(on: true)),
         Command(opcode: 125, payload: Whoop5Ecg.togglePayload(on: true)),
         Command(opcode: 20, payload: [0]),
         Command(opcode: 124, payload: Whoop5Ecg.controlPayload(.start))]
    }

    public static let restart = [Command(opcode: 20, payload: [0]),
                                 Command(opcode: 124, payload: Whoop5Ecg.commandPayload(arg: 3))]
    public static let cleanup = [Command(opcode: 124, payload: Whoop5Ecg.controlPayload(.stop)),
                                 Command(opcode: 125, payload: Whoop5Ecg.togglePayload(on: false)),
                                 Command(opcode: 139, payload: Whoop5Ecg.togglePayload(on: false))]
}
