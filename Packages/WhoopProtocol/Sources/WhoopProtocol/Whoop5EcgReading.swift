import Foundation

// MARK: - WHOOP MG ECG reading: the foreground R17 state machine
//
// Ported from OpenStrap Edge (MIT, Copyright (c) 2026 OpenStrap): `lib/ecg/ecg_policy.dart` and
// `lib/ecg/ecg_models.dart` at release v0.10.0 (edge 71b7761b, protocol bc7d8d0d). The licence notice is
// carried in `docs/fork/research/openstrap-ecg-adaptation.md` and ATTRIBUTION.md. This is a PURE reducer:
// one `LabradorR17` packet in, a new state plus the effects the app layer must perform out. No clock, no
// BLE, no storage.
//
// Transport frames are not the reading. After START the strap streams empty, progress-zero packets until
// the fingers touch the clasp; the accepted window opens at the first presence-positive packet with a
// positive, non-255 progress, clears on contact loss or a progress regression, and ends at the first
// terminal packet (progress 100 or classifier state 2), which arrives about 38 to 39 s after the first
// live frame (#891).
//
// Everything a reading carries is the STRAP'S result. The category comes from the strap's result code plus
// a heart rate through OpenStrap's fixed table; nothing here classifies the waveform, and NOOP is not a
// medical device. The table is OpenStrap's, unvalidated by NOOP on its own hardware.

/// The user-facing category OpenStrap derives from the strap's result code plus a heart rate.
public enum EcgCategory: String, Equatable, Sendable, CaseIterable {
    case unreadable
    case sinusRhythm
    case lowHeartRate
    case possibleAfib
    case afibHighHeartRate
    case highHeartRate
    case highHeartRateNoAfib
    case inconclusive

    /// OpenStrap's result-plus-HR table. Unknown codes, and known codes outside their accepted heart-rate
    /// range, fall back to `.unreadable`.
    public static func from(result: UInt8, heartRate hr: Int) -> EcgCategory {
        switch result {
        case 0, 2:
            return .unreadable
        case 1:
            return (51...99).contains(hr) ? .sinusRhythm : .unreadable
        case 3:
            return hr <= 50 ? .lowHeartRate : .unreadable
        case 4:
            if (51...99).contains(hr) { return .possibleAfib }
            if (100...150).contains(hr) { return .afibHighHeartRate }
            if (151...200).contains(hr) { return .highHeartRate }
            return .unreadable
        case 5:
            if (100...150).contains(hr) { return .highHeartRateNoAfib }
            if (151...200).contains(hr) { return .highHeartRate }
            return .unreadable
        case 6:
            return .inconclusive
        default:
            return .unreadable
        }
    }
}

/// One entry of the accepted window: an accepted R17 packet, or the ONE empty placeholder inserted at a
/// sequence jump (never one per missing sequence number).
public struct EcgAcceptedPacket: Equatable, Sendable {
    public let sequence: UInt32
    public let strapSeconds: UInt32
    public let strapSubseconds: UInt16
    public let samples: [Int16]
    public let isPlaceholder: Bool

    public init(sequence: UInt32, strapSeconds: UInt32, strapSubseconds: UInt16, samples: [Int16],
                isPlaceholder: Bool) {
        self.sequence = sequence
        self.strapSeconds = strapSeconds
        self.strapSubseconds = strapSubseconds
        self.samples = samples
        self.isPlaceholder = isPlaceholder
    }

    public init(_ packet: LabradorR17) {
        self.init(sequence: packet.sequence, strapSeconds: packet.strapSeconds,
                  strapSubseconds: packet.subseconds, samples: packet.samples, isPlaceholder: false)
    }

    public static func placeholder(sequence: UInt32) -> EcgAcceptedPacket {
        EcgAcceptedPacket(sequence: sequence, strapSeconds: 0, strapSubseconds: 0, samples: [],
                          isPlaceholder: true)
    }
}

/// Sample statistics over an accepted window. Placeholders contribute only a missing-segment count.
public struct EcgWindowStats: Equatable, Sendable {
    public let sampleCount: Int
    public let minMicrovolts: Int?
    public let maxMicrovolts: Int?
    public let missingSegments: Int

    public init(_ packets: [EcgAcceptedPacket]) {
        var count = 0
        var missing = 0
        var lo: Int?
        var hi: Int?
        for packet in packets {
            if packet.isPlaceholder { missing += 1; continue }
            for sample in packet.samples {
                let value = Int(sample)
                count += 1
                lo = min(lo ?? value, value)
                hi = max(hi ?? value, value)
            }
        }
        sampleCount = count
        minMicrovolts = lo
        maxMicrovolts = hi
        missingSegments = missing
    }
}

/// How a reading ended at its terminal packet.
public enum EcgTerminalKind: String, Equatable, Sendable {
    /// A category worth saving.
    case completed
    /// The strap called it unreadable; the mask says why. Not saved.
    case unreadable
    /// Inconclusive on the first attempt: offer ONE retry. Not saved.
    case inconclusiveOfferRetry
    /// Inconclusive on the retry: saved as inconclusive.
    case inconclusiveFinal
}

/// The terminal packet's verdict. `liveCategory` uses the live heart rate (`inner[20]`), which the state
/// machine branches on; `savedCategory` uses the final average heart rate (`inner[19]`), which a saved
/// reading carries.
public struct EcgTerminalOutcome: Equatable, Sendable {
    public let kind: EcgTerminalKind
    public let liveCategory: EcgCategory
    public let savedCategory: EcgCategory
    public let terminal: LabradorR17
}

public enum EcgReadingPhase: String, Equatable, Sendable {
    case waiting, active, contactLost, done
}

/// What the app layer must do after a step, in order.
public enum EcgReadingEffect: Equatable, Sendable {
    /// The accepted window was cleared.
    case clear
    /// Send the explicit RESTART list (opcode 20, then 124 = restart). Only the exact predicate reaches
    /// this: active, presence, positive nondecreasing nonterminal progress, current-state-one flag clear.
    case sendRestart
    /// The reading failed; the window is gone.
    case fail(reason: String)
    /// The reading reached its terminal packet.
    case terminal(EcgTerminalOutcome)
}

/// The reducer's whole memory. Immutable; every step returns a new value.
public struct EcgReadingState: Equatable, Sendable {
    public private(set) var phase: EcgReadingPhase
    /// The accepted window so far, placeholders included, in order.
    public private(set) var accepted: [EcgAcceptedPacket]
    /// The last ACCEPTED packet; progress regressions and sequence gaps are judged against it. Nil after
    /// every clear, so a window that restarts has no previous packet.
    public private(set) var previous: LabradorR17?
    /// ACTIVE to CONTACT_LOST transitions, counted once per transition. Three end the reading.
    public private(set) var interruptions: Int
    /// Inconclusive retries already taken (0 or 1).
    public let retriesUsed: Int

    public init(retriesUsed: Int = 0) {
        phase = .waiting
        accepted = []
        previous = nil
        interruptions = 0
        self.retriesUsed = retriesUsed
    }

    public static let maxInterruptions = 3

    /// One R17 packet through the state machine.
    public func reduce(_ packet: LabradorR17) -> (state: EcgReadingState, effects: [EcgReadingEffect]) {
        var next = self
        switch phase {
        case .done:
            // The strap repeats its terminal packet; a repeat is not part of the result.
            return (self, [])

        case .waiting:
            guard Self.acceptableStart(packet) else { return (self, []) }
            next.accepted = []
            next.previous = nil
            next.append(packet)
            next.phase = .active
            return (next, [.clear])

        case .active:
            let lost = !packet.presence || packet.progress.raw == 0
                || (previous.map { packet.progress.raw < $0.progress.raw } ?? false)
            if lost {
                next.phase = .contactLost
                next.accepted = []
                next.previous = nil
                next.interruptions += 1
                return (next, [.clear])
            }
            if packet.isTerminal { return next.finish(packet) }
            if packet.isInvalid {
                next.phase = .done
                next.accepted = []
                next.previous = nil
                return (next, [.clear, .fail(reason: "progress_255")])
            }
            if packet.flags.currentStateOne {
                next.append(packet)
                return (next, [])
            }
            // Valid, nondecreasing, nonterminal, presence set, state-one flag clear: the explicit RESTART
            // branch. Only the unfinished window is discarded; interruptions and the retry budget stay.
            next.accepted = []
            next.previous = nil
            return (next, [.clear, .sendRestart])

        case .contactLost:
            if Self.acceptableStart(packet) {
                next.append(packet)
                next.phase = .active
                return (next, [])
            }
            if packet.isInvalid || interruptions >= Self.maxInterruptions {
                next.phase = .done
                next.accepted = []
                next.previous = nil
                return (next, [.clear, .fail(reason: packet.isInvalid ? "progress_255" : "interruptions")])
            }
            return (self, [])
        }
    }

    private static func acceptableStart(_ packet: LabradorR17) -> Bool {
        packet.presence && packet.progress.raw > 0 && packet.progress.raw != 255
    }

    /// Append `packet`, inserting the single placeholder on a sequence jump.
    private mutating func append(_ packet: LabradorR17) {
        if let previous, packet.sequence != previous.sequence &+ 1 {
            accepted.append(.placeholder(sequence: previous.sequence &+ 1))
        }
        accepted.append(EcgAcceptedPacket(packet))
        previous = packet
    }

    private func finish(_ packet: LabradorR17) -> (state: EcgReadingState, effects: [EcgReadingEffect]) {
        let live = EcgCategory.from(result: packet.arrhythmiaCheckResultRaw, heartRate: Int(packet.liveHR))
        let saved = EcgCategory.from(result: packet.arrhythmiaCheckResultRaw, heartRate: Int(packet.averageHR))
        var next = self
        next.phase = .done
        func outcome(_ kind: EcgTerminalKind) -> EcgReadingEffect {
            .terminal(EcgTerminalOutcome(kind: kind, liveCategory: live, savedCategory: saved,
                                         terminal: packet))
        }
        if live == .unreadable {
            next.accepted = []
            return (next, [.clear, outcome(.unreadable)])
        }
        if live == .inconclusive && retriesUsed == 0 {
            next.accepted = []
            return (next, [.clear, outcome(.inconclusiveOfferRetry)])
        }
        next.append(packet)
        return (next, [outcome(live == .inconclusive ? .inconclusiveFinal : .completed)])
    }
}
