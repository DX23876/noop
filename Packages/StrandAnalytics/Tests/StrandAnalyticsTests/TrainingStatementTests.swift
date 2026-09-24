import XCTest
@testable import StrandAnalytics

/// The page's single statement has to survive every pair of verdicts, including the pairs that point in
/// opposite directions. These are contract tests: they assert the properties the statement must hold
/// for, not the branch order it happens to be written in.
final class TrainingStatementTests: XCTestCase {
    /// Every verdict either lane can hold — judgements and plain descriptions alike. Cardio can be
    /// unproductive too now that its evidence is a performance marker, so both lanes share the list.
    private let verdicts: [LaneVerdict] = TrainingStatus.allCases.map { .status($0) }
        + [RelativeLoadBand.below, .usual, .higher, .muchHigher].map { .loadOnly($0) }
    private let recoveries: [RecoveryState] = [.holding, .strained, .unknown]

    private func statement(_ strength: LaneVerdict?, _ cardio: LaneVerdict?,
                           _ recovery: RecoveryState = .holding) -> TrainingStatusModel.TrainingStatement {
        TrainingStatusModel.statement(strength: strength, cardio: cardio, recovery: recovery)
    }

    private func lanes(_ statement: TrainingStatusModel.TrainingStatement)
        -> (low: TrainingStatusModel.TrainingStatementLane, high: TrainingStatusModel.TrainingStatementLane)? {
        if case let .split(low, high, _) = statement { return (low, high) }
        return nil
    }

    private func isBehind(_ verdict: LaneVerdict) -> Bool {
        [.status(.detraining), .status(.recovering), .loadOnly(.below)].contains(verdict)
    }

    /// At or above usual and moving: building, spinning or excessive.
    private func isAhead(_ verdict: LaneVerdict) -> Bool {
        [.status(.productive), .status(.unproductive), .status(.overreaching),
         .loadOnly(.higher), .loadOnly(.muchHigher)].contains(verdict)
    }

    /// Every input, including both lanes missing, resolves to a statement.
    func testEveryPairResolves() {
        for strength in verdicts.map(Optional.some) + [nil] {
            for cardio in verdicts.map(Optional.some) + [nil] {
                for recovery in recoveries { _ = statement(strength, cardio, recovery) }
            }
        }
    }

    /// The defect this exists for: a lane that is losing ground must never be dropped from the
    /// statement because the other lane is louder — including when the louder lane is spinning.
    func testALaneLosingGroundIsNamedWheneverTheOtherIsAhead() {
        for behind in verdicts where isBehind(behind) {
            for ahead in verdicts where isAhead(ahead) {
                for recovery in recoveries {
                    let first = lanes(statement(behind, ahead, recovery))
                    XCTAssertEqual(first?.low, .strength, "\(behind) vs \(ahead) dropped the strength lane")
                    XCTAssertEqual(first?.high, .cardio)
                    let second = lanes(statement(ahead, behind, recovery))
                    XCTAssertEqual(second?.low, .cardio, "\(ahead) vs \(behind) dropped the cardio lane")
                    XCTAssertEqual(second?.high, .strength)
                }
            }
        }
    }

    /// `aligned` claims both lanes agree, so it must never appear when they do not.
    func testAlignedNeverSpeaksForTwoLanesThatDisagree() {
        for strength in verdicts {
            for cardio in verdicts {
                for recovery in recoveries {
                    guard case .aligned = statement(strength, cardio, recovery) else { continue }
                    let bothBehind = isBehind(strength) && isBehind(cardio)
                    let bothQuiet = !isBehind(strength) && !isBehind(cardio)
                    XCTAssertTrue(bothBehind || bothQuiet, "aligned claimed agreement for \(strength) vs \(cardio)")
                }
            }
        }
    }

    /// Productive is only said when a lane has the evidence for it; more load alone is described.
    func testProductiveIsNeverClaimedWithoutEvidence() {
        let unproven = verdicts.filter { $0 != .status(.productive) }
        for strength in unproven {
            for cardio in unproven {
                for recovery in recoveries {
                    let answer = statement(strength, cardio, recovery)
                    XCTAssertNotEqual(answer, .aligned(.status(.productive)), "\(strength) vs \(cardio)")
                }
            }
        }
        XCTAssertEqual(statement(.loadOnly(.higher), .loadOnly(.usual)), .aligned(.loadOnly(.higher)))
        XCTAssertEqual(statement(.status(.productive), .loadOnly(.usual)), .aligned(.status(.productive)))
    }

    /// Swapping the lanes swaps them in the answer — for every verdict, now that both lanes can hold all.
    func testTheAnswerIsSymmetricBetweenTheLanes() {
        for first in verdicts {
            for second in verdicts {
                for recovery in recoveries {
                    let forwards = statement(first, second, recovery)
                    let backwards = statement(second, first, recovery)
                    switch (forwards, backwards) {
                    case let (.split(lowA, highA, severityA), .split(lowB, highB, severityB)):
                        XCTAssertEqual(lowA, highB)
                        XCTAssertEqual(highA, lowB)
                        XCTAssertEqual(severityA, severityB)
                    case let (.excessive(laneA, strainedA), .excessive(laneB, strainedB)):
                        XCTAssertNotEqual(laneA, laneB, "\(first) vs \(second) named the same lane both ways")
                        XCTAssertEqual(strainedA, strainedB)
                    case let (.oneBehind(laneA), .oneBehind(laneB)):
                        XCTAssertNotEqual(laneA, laneB)
                    case let (.spinning(laneA, highA), .spinning(laneB, highB)):
                        XCTAssertNotEqual(laneA, laneB)
                        XCTAssertEqual(highA, highB)
                    default:
                        XCTAssertEqual(forwards, backwards, "\(first) vs \(second) is not symmetric")
                    }
                }
            }
        }
    }

    func testTheTwoCasesThatPromptedTheMatrix() {
        XCTAssertEqual(statement(.status(.detraining), .status(.overreaching)),
                       .split(low: .strength, high: .cardio, severity: .sharp))
        XCTAssertEqual(statement(.status(.productive), .status(.detraining)),
                       .split(low: .cardio, high: .strength, severity: .mild))
    }

    func testTheQuietCases() {
        XCTAssertEqual(statement(nil, nil, .unknown), .noHistory)
        XCTAssertEqual(statement(.status(.maintaining), .loadOnly(.usual), .strained), .strainedRecovery)
        XCTAssertEqual(statement(.status(.maintaining), .loadOnly(.usual)), .aligned(.status(.maintaining)))
        XCTAssertEqual(statement(.loadOnly(.usual), .loadOnly(.usual)), .aligned(.loadOnly(.usual)))
        XCTAssertEqual(statement(.status(.overreaching), .status(.maintaining), .strained),
                       .excessive(.strength, recoveryStrained: true))
    }

    /// A deload beside a genuine decline is a decline; two lanes merely below usual stay a description.
    func testTwoLanesBehindSayTheGraverThing() {
        XCTAssertEqual(statement(.status(.recovering), .status(.detraining)), .aligned(.status(.detraining)))
        XCTAssertEqual(statement(.status(.recovering), .loadOnly(.below)), .aligned(.status(.recovering)))
        XCTAssertEqual(statement(.loadOnly(.below), .loadOnly(.below)), .aligned(.loadOnly(.below)))
    }

    func testBothLanesOverTheTopSaySo() {
        XCTAssertEqual(statement(.status(.overreaching), .loadOnly(.muchHigher)),
                       .bothExcessive(recoveryStrained: false))
        XCTAssertEqual(statement(.status(.overreaching), .status(.overreaching), .strained),
                       .bothExcessive(recoveryStrained: true))
    }

    /// Volume without return names its lane, and notes a high other lane without claiming it is the cause.
    func testSpinningNamesItsLane() {
        XCTAssertEqual(statement(.status(.unproductive), .status(.maintaining)),
                       .spinning(.strength, otherAlsoHigh: false))
        XCTAssertEqual(statement(.status(.unproductive), .status(.overreaching)),
                       .spinning(.strength, otherAlsoHigh: true))
        XCTAssertEqual(statement(.loadOnly(.usual), .status(.unproductive)),
                       .spinning(.cardio, otherAlsoHigh: false))
        XCTAssertEqual(statement(.status(.unproductive), .status(.unproductive)), .bothSpinning)
    }

    /// A single measured lane speaks only for itself.
    func testOneMeasuredLaneNeverSpeaksForTheOther() {
        for verdict in verdicts {
            XCTAssertEqual(statement(verdict, nil), .laneOnly(.strength, verdict))
            XCTAssertEqual(statement(nil, verdict), .laneOnly(.cardio, verdict))
        }
    }

    /// Strained recovery sharpens or displaces a quiet statement, but never silences a split.
    func testStrainedRecoveryNeverHidesASplit() {
        for strength in verdicts {
            for cardio in verdicts {
                let holding = statement(strength, cardio, .holding)
                guard case .split = holding else { continue }
                XCTAssertEqual(statement(strength, cardio, .strained), holding)
            }
        }
    }
}
