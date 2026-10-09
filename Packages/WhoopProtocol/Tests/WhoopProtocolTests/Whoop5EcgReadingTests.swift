import XCTest
@testable import WhoopProtocol

/// The ported OpenStrap reading state machine (`EcgReadingState`) and its category table.
final class Whoop5EcgReadingTests: XCTestCase {

    /// A synthetic R17 packet. `flags` defaults to presence (bit 3) plus current-state-one (bit 1), the
    /// shape of an ordinary active frame.
    private func packet(seq: UInt32, progress: UInt8, flags: UInt8 = 0x0A, state: UInt8 = 1,
                        result: UInt8 = 0, avgHr: UInt8 = 0, liveHr: UInt8 = 0,
                        samples: [Int16] = [1, -2, 3]) -> LabradorR17 {
        LabradorR17(packetType: 43, headerSecondary: 0, sequence: seq, strapSeconds: 1_000 + seq,
                    subseconds: 0, signalQuality: .high, signalQualityRaw: 3,
                    flags: EcgLabradorFlags(raw: flags), arrhythmiaCheckResult: nil,
                    arrhythmiaCheckResultRaw: result, classifierState: state,
                    progress: EcgHeartKeyProgress(raw: progress), unreadable: EcgUnreadableMask(raw: 0),
                    averageHR: avgHr, liveHR: liveHr, variabilityRaw: nil, reserved: 0,
                    sampleCount: UInt16(samples.count), samples: samples, tail: [])
    }

    private func run(_ packets: [LabradorR17], from start: EcgReadingState = EcgReadingState())
        -> (EcgReadingState, [EcgReadingEffect]) {
        var state = start
        var effects: [EcgReadingEffect] = []
        for p in packets {
            let step = state.reduce(p)
            state = step.state
            effects += step.effects
        }
        return (state, effects)
    }

    func testCategoryTable() {
        XCTAssertEqual(EcgCategory.from(result: 1, heartRate: 60), .sinusRhythm)
        XCTAssertEqual(EcgCategory.from(result: 1, heartRate: 50), .unreadable)
        XCTAssertEqual(EcgCategory.from(result: 1, heartRate: 100), .unreadable)
        XCTAssertEqual(EcgCategory.from(result: 3, heartRate: 45), .lowHeartRate)
        XCTAssertEqual(EcgCategory.from(result: 3, heartRate: 51), .unreadable)
        XCTAssertEqual(EcgCategory.from(result: 4, heartRate: 70), .possibleAfib)
        XCTAssertEqual(EcgCategory.from(result: 4, heartRate: 120), .afibHighHeartRate)
        XCTAssertEqual(EcgCategory.from(result: 4, heartRate: 170), .highHeartRate)
        XCTAssertEqual(EcgCategory.from(result: 4, heartRate: 201), .unreadable)
        XCTAssertEqual(EcgCategory.from(result: 5, heartRate: 120), .highHeartRateNoAfib)
        XCTAssertEqual(EcgCategory.from(result: 5, heartRate: 80), .unreadable)
        XCTAssertEqual(EcgCategory.from(result: 6, heartRate: 0), .inconclusive)
        XCTAssertEqual(EcgCategory.from(result: 0, heartRate: 70), .unreadable)
        XCTAssertEqual(EcgCategory.from(result: 2, heartRate: 70), .unreadable)
        XCTAssertEqual(EcgCategory.from(result: 9, heartRate: 70), .unreadable)
    }

    func testWaitsThroughEmptyPacketsThenOpensTheWindow() {
        let (state, effects) = run([
            packet(seq: 1, progress: 0, flags: 0x00, samples: []),
            packet(seq: 2, progress: 0, flags: 0x08),
            packet(seq: 3, progress: 3),
        ])
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.accepted.map(\.sequence), [3])
        XCTAssertEqual(effects, [.clear])
    }

    func testCompletedReadingKeepsTheWholeWindowAndUsesAverageHrForTheSavedCategory() {
        let terminal = packet(seq: 6, progress: 100, flags: 0x0C, state: 2, result: 1, avgHr: 62, liveHr: 64)
        let (state, effects) = run([
            packet(seq: 3, progress: 10), packet(seq: 4, progress: 40), packet(seq: 5, progress: 70), terminal,
        ])
        XCTAssertEqual(state.phase, .done)
        XCTAssertEqual(state.accepted.map(\.sequence), [3, 4, 5, 6])
        guard case .terminal(let outcome)? = effects.last else { return XCTFail("no terminal effect") }
        XCTAssertEqual(outcome.kind, .completed)
        XCTAssertEqual(outcome.liveCategory, .sinusRhythm)
        XCTAssertEqual(outcome.savedCategory, .sinusRhythm)
        XCTAssertEqual(EcgWindowStats(state.accepted).sampleCount, 12)
    }

    func testRepeatedTerminalIsIgnored() {
        let terminal = packet(seq: 4, progress: 100, state: 2, result: 1, avgHr: 62, liveHr: 64)
        let (done, _) = run([packet(seq: 3, progress: 10), terminal])
        let again = done.reduce(packet(seq: 5, progress: 100, state: 2, result: 1, avgHr: 62, liveHr: 64))
        XCTAssertEqual(again.state, done)
        XCTAssertTrue(again.effects.isEmpty)
    }

    func testSequenceJumpInsertsOnePlaceholder() {
        let (state, _) = run([packet(seq: 3, progress: 10), packet(seq: 7, progress: 20)])
        XCTAssertEqual(state.accepted.map(\.sequence), [3, 4, 7])
        XCTAssertEqual(state.accepted.map(\.isPlaceholder), [false, true, false])
        XCTAssertEqual(EcgWindowStats(state.accepted).missingSegments, 1)
    }

    func testContactLossClearsAndResumesWithoutPlaceholder() {
        let (state, effects) = run([
            packet(seq: 3, progress: 10), packet(seq: 4, progress: 20),
            packet(seq: 5, progress: 20, flags: 0x02),           // presence gone
            packet(seq: 6, progress: 5),                          // contact back
        ])
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.interruptions, 1)
        XCTAssertEqual(state.accepted.map(\.sequence), [6])
        XCTAssertEqual(effects, [.clear, .clear])
    }

    func testProgressRegressionCountsAsContactLoss() {
        let (state, _) = run([packet(seq: 3, progress: 30), packet(seq: 4, progress: 12)])
        XCTAssertEqual(state.phase, .contactLost)
        XCTAssertEqual(state.interruptions, 1)
    }

    func testThreeInterruptionsFail() {
        var packets: [LabradorR17] = [packet(seq: 1, progress: 5)]
        var seq: UInt32 = 2
        for _ in 0..<3 {
            packets.append(packet(seq: seq, progress: 0, flags: 0x00)); seq += 1
            packets.append(packet(seq: seq, progress: 5)); seq += 1
        }
        packets.removeLast()
        packets.append(packet(seq: seq, progress: 0, flags: 0x00))
        let (state, effects) = run(packets)
        XCTAssertEqual(state.phase, .done)
        XCTAssertEqual(effects.last, .fail(reason: "interruptions"))
    }

    func testInvalidProgressFails() {
        let (state, effects) = run([packet(seq: 3, progress: 10), packet(seq: 4, progress: 255)])
        XCTAssertEqual(state.phase, .done)
        XCTAssertEqual(effects.last, .fail(reason: "progress_255"))
    }

    func testStateOneFlagClearAsksForRestart() {
        let (state, effects) = run([packet(seq: 3, progress: 10), packet(seq: 4, progress: 15, flags: 0x08)])
        XCTAssertEqual(state.phase, .active)
        XCTAssertTrue(state.accepted.isEmpty)
        XCTAssertEqual(effects.suffix(2), [.clear, .sendRestart])
    }

    func testUnreadableTerminalIsNotKept() {
        let (state, effects) = run([packet(seq: 3, progress: 10),
                                    packet(seq: 4, progress: 100, state: 2, result: 2, avgHr: 70, liveHr: 70)])
        XCTAssertTrue(state.accepted.isEmpty)
        guard case .terminal(let outcome)? = effects.last else { return XCTFail("no terminal effect") }
        XCTAssertEqual(outcome.kind, .unreadable)
    }

    func testInconclusiveOffersOneRetryThenIsFinal() {
        let inconclusive = packet(seq: 4, progress: 100, state: 2, result: 6, avgHr: 70, liveHr: 70)
        let (_, first) = run([packet(seq: 3, progress: 10), inconclusive])
        guard case .terminal(let a)? = first.last else { return XCTFail("no terminal effect") }
        XCTAssertEqual(a.kind, .inconclusiveOfferRetry)
        let (retried, second) = run([packet(seq: 3, progress: 10), inconclusive],
                                    from: EcgReadingState(retriesUsed: 1))
        guard case .terminal(let b)? = second.last else { return XCTFail("no terminal effect") }
        XCTAssertEqual(b.kind, .inconclusiveFinal)
        XCTAssertEqual(retried.accepted.count, 2)
    }

    func testCountdownSpansTheThirtySecondRecording() {
        XCTAssertNil(EcgHeartKeyProgress(raw: 0).remainingSeconds)
        XCTAssertEqual(EcgHeartKeyProgress(raw: 1).remainingSeconds, 30)
        XCTAssertEqual(EcgHeartKeyProgress(raw: 10).remainingSeconds, 27)
        XCTAssertEqual(EcgHeartKeyProgress(raw: 50).remainingSeconds, 15)
        XCTAssertEqual(EcgHeartKeyProgress(raw: 99).remainingSeconds, 1)
        XCTAssertNil(EcgHeartKeyProgress(raw: 100).remainingSeconds)
        XCTAssertNil(EcgHeartKeyProgress(raw: 255).remainingSeconds)
    }
}
