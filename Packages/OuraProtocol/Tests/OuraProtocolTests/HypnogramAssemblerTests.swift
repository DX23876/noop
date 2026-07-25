import XCTest
@testable import OuraProtocol

/// Tests for the hypnogram time-axis reconstruction (OuraHypnogramAssembler): burst grouping by
/// envelope ring-time gap, and the 30 s/code backward layout from the anchored burst end.
final class HypnogramAssemblerTests: XCTestCase {

    private func phases(_ stages: [OuraSleepStage], rt: UInt32) -> [OuraSleepPhase] {
        stages.enumerated().map { OuraSleepPhase(ringTimestamp: rt, index: $0.offset, stage: $0.element) }
    }

    // MARK: - Backward layout

    func testSingleRecordLaysCodesBackwardFromEnd() {
        let a = OuraHypnogramAssembler()
        XCTAssertNil(a.feed(ringTimestamp: 1000, phases: phases([.awake, .light, .deep, .rem], rt: 1000)))
        let burst = a.flush()!
        // 4 codes ending at t=10_000: starts at 10_000 - 4*30 = 9_880, spaced 30 s.
        let laid = burst.codesWithTimes(endUnixSeconds: 10_000)
        XCTAssertEqual(laid.map { $0.ts }, [9_880, 9_910, 9_940, 9_970])
        XCTAssertEqual(laid.map { $0.phase.stage }, [.awake, .light, .deep, .rem])
        // The final code's 30 s interval ends exactly at the burst end.
        XCTAssertEqual(laid.last!.ts + 30, 10_000)
    }

    // MARK: - 0x49 onset start-clamp (clips leading pre-window codes)

    private func fourCodeBurst() -> OuraHypnogramBurst {
        let a = OuraHypnogramAssembler()
        _ = a.feed(ringTimestamp: 1000, phases: phases([.awake, .light, .deep, .rem], rt: 1000))
        return a.flush()!   // codes at ts [9_880, 9_910, 9_940, 9_970] for end 10_000
    }

    func testStartClampDropsCodesBeforeOnset() {
        // Onset 9_910 drops the first code (9_880 < 9_910); the rest keep their end-anchored times.
        let laid = fourCodeBurst().codesWithTimes(endUnixSeconds: 10_000, sleepStartUnixSeconds: 9_910)
        XCTAssertEqual(laid.map { $0.ts }, [9_910, 9_940, 9_970])
        XCTAssertEqual(laid.map { $0.phase.stage }, [.light, .deep, .rem])
    }

    func testStartClampBoundaryInclusiveAndOnsetBeforeStartKeepsAll() {
        // Onset exactly on the first code is inclusive (>=); an onset before the burst drops nothing.
        XCTAssertEqual(fourCodeBurst().codesWithTimes(endUnixSeconds: 10_000, sleepStartUnixSeconds: 9_880).count, 4)
        XCTAssertEqual(fourCodeBurst().codesWithTimes(endUnixSeconds: 10_000, sleepStartUnixSeconds: 0).count, 4)
    }

    func testStartClampNeverEmptiesTheNight() {
        // An onset AFTER every code (a mis-paired 0x49) must fall back to the full unclamped lay.
        let laid = fourCodeBurst().codesWithTimes(endUnixSeconds: 10_000, sleepStartUnixSeconds: 99_999)
        XCTAssertEqual(laid.map { $0.ts }, [9_880, 9_910, 9_940, 9_970])
    }

    func testNilOnsetMatchesUnclampedLay() {
        let burst = fourCodeBurst()
        XCTAssertEqual(burst.codesWithTimes(endUnixSeconds: 10_000, sleepStartUnixSeconds: nil).map { $0.ts },
                       burst.codesWithTimes(endUnixSeconds: 10_000).map { $0.ts })
    }

    func testBurstWriteRecordsShareOneSequence() {
        // The on-device shape: multiple records written in one burst (envelope rts a few ticks apart)
        // form ONE contiguous sequence — record 2's codes precede the end, record 1's come before them.
        let a = OuraHypnogramAssembler()
        XCTAssertNil(a.feed(ringTimestamp: 5_000, phases: phases([.awake, .light], rt: 5_000)))
        XCTAssertNil(a.feed(ringTimestamp: 5_010, phases: phases([.deep, .awake], rt: 5_010)))
        let burst = a.flush()!
        XCTAssertEqual(burst.totalCodes, 4)
        XCTAssertEqual(burst.lastRingTimestamp, 5_010)
        let laid = burst.codesWithTimes(endUnixSeconds: 100_000)
        XCTAssertEqual(laid.map { $0.ts }, [99_880, 99_910, 99_940, 99_970])
        XCTAssertEqual(laid.map { $0.phase.stage }, [.awake, .light, .deep, .awake])
    }

    func testFullNightScaleWindow() {
        // The real 2026-07-12 shape: 23 records x 52 codes = 1,196 codes -> 9 h 58 m window ending at
        // the finalization time. Start must be end - 1,196 * 30 s.
        let a = OuraHypnogramAssembler()
        for k in 0..<23 {
            _ = a.feed(ringTimestamp: 3_970_000 + UInt32(k), phases: phases(Array(repeating: .light, count: 52), rt: 3_970_000))
        }
        let burst = a.flush()!
        XCTAssertEqual(burst.totalCodes, 1_196)
        let end = 1_760_000_000
        let laid = burst.codesWithTimes(endUnixSeconds: end)
        XCTAssertEqual(laid.first!.ts, end - 1_196 * 30)          // 35,880 s = 9 h 58 m before end
        XCTAssertEqual(laid.count, 1_196)
        // Strictly increasing, 30 s apart — every code lands on a unique persistence slot.
        XCTAssertTrue(zip(laid, laid.dropFirst()).allSatisfy { $1.ts - $0.ts == 30 })
    }

    // MARK: - Burst splitting

    func testLargeRingTimeGapSplitsBursts() {
        // Two nights in one full dump: finalization writes hours apart must NOT merge.
        let a = OuraHypnogramAssembler()
        XCTAssertNil(a.feed(ringTimestamp: 1_000_000, phases: phases([.light, .light], rt: 1_000_000)))
        // 24 h later in deciseconds = 864_000 ticks — far beyond the 600-tick burst gap.
        let closed = a.feed(ringTimestamp: 1_864_000, phases: phases([.deep], rt: 1_864_000))
        XCTAssertNotNil(closed, "a big rt gap must close the previous burst")
        XCTAssertEqual(closed!.totalCodes, 2)
        XCTAssertEqual(closed!.lastRingTimestamp, 1_000_000)
        // The new record started the next burst.
        let second = a.flush()!
        XCTAssertEqual(second.totalCodes, 1)
        XCTAssertEqual(second.lastRingTimestamp, 1_864_000)
    }

    func testFlushEmptyReturnsNilAndResetClears() {
        let a = OuraHypnogramAssembler()
        XCTAssertNil(a.flush())
        _ = a.feed(ringTimestamp: 10, phases: phases([.rem], rt: 10))
        a.reset()
        XCTAssertNil(a.flush(), "reset discards partial state")
        XCTAssertEqual(a.pendingRecordCount, 0)
    }

    func testNonMonotonicRingTimesAreSurfacedNotResorted() {
        // A record whose envelope rt steps BACKWARD (within the burst gap) must be flagged — but the
        // layout still trusts arrival order (envelope rts of a burst are near-identical write moments;
        // re-sorting on them could scramble the true code sequence).
        let a = OuraHypnogramAssembler()
        XCTAssertNil(a.feed(ringTimestamp: 5_010, phases: phases([.light, .deep], rt: 5_010)))
        XCTAssertNil(a.feed(ringTimestamp: 5_000, phases: phases([.rem, .awake], rt: 5_000)))   // backward
        let burst = a.flush()!
        XCTAssertTrue(burst.hasNonMonotonicRingTimes)
        // Arrival order preserved in the layout.
        XCTAssertEqual(burst.codesWithTimes(endUnixSeconds: 1_000).map { $0.phase.stage },
                       [.light, .deep, .rem, .awake])
        // And a clean forward burst is NOT flagged.
        let b = OuraHypnogramAssembler()
        _ = b.feed(ringTimestamp: 100, phases: phases([.light], rt: 100))
        _ = b.feed(ringTimestamp: 110, phases: phases([.deep], rt: 110))
        XCTAssertFalse(b.flush()!.hasNonMonotonicRingTimes)
    }

    func testEmptyRecordIsIgnored() {
        let a = OuraHypnogramAssembler()
        XCTAssertNil(a.feed(ringTimestamp: 10, phases: []))
        XCTAssertNil(a.flush(), "a record with no codes never opens a burst")
    }
}
