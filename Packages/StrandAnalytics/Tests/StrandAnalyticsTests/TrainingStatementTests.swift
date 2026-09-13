import XCTest
@testable import StrandAnalytics

/// The page's single statement has to survive every pair of verdicts, including the pairs that point in
/// opposite directions. These are contract tests: they assert the properties the statement must hold
/// for, not the branch order it happens to be written in.
final class TrainingStatementTests: XCTestCase {
    private let statuses = TrainingStatus.allCases
    /// Cardio can never be `unproductive` — only the strength lane reads the lifts' e1RM response.
    private var cardioStatuses: [TrainingStatus] { statuses.filter { $0 != .unproductive } }
    private let recoveries: [RecoveryState] = [.holding, .strained, .unknown]

    private func lane(_ statement: TrainingStatusModel.TrainingStatement)
        -> (low: TrainingStatusModel.TrainingStatementLane, high: TrainingStatusModel.TrainingStatementLane)? {
        if case let .split(low, high, _) = statement { return (low, high) }
        return nil
    }

    private func isBehind(_ status: TrainingStatus) -> Bool {
        status == .detraining || status == .recovering
    }

    private func isAhead(_ status: TrainingStatus) -> Bool {
        status == .productive || status == .overreaching
    }

    /// Every input, including both lanes missing, resolves to a statement. A page that fell through to
    /// nothing would print an empty card.
    func testEveryPairResolves() {
        for strength in statuses + [nil] {
            for cardio in cardioStatuses + [nil] {
                for recovery in recoveries {
                    _ = TrainingStatusModel.statement(strength: strength, cardio: cardio,
                                                       recovery: recovery)
                }
            }
        }
    }

    /// The defect this exists for: a lane that is losing ground must never be dropped from the
    /// statement because the other lane is louder.
    func testALaneLosingGroundIsNamedWheneverTheOtherIsAhead() {
        for strength in statuses where isBehind(strength) {
            for cardio in cardioStatuses where isAhead(cardio) {
                let statement = TrainingStatusModel.statement(strength: strength, cardio: cardio,
                                                              recovery: .holding)
                let lanes = lane(statement)
                XCTAssertEqual(lanes?.low, .strength, "\(strength) vs \(cardio) dropped the strength lane")
                XCTAssertEqual(lanes?.high, .cardio)
            }
        }
        for cardio in cardioStatuses where isBehind(cardio) {
            for strength in statuses where isAhead(strength) {
                let statement = TrainingStatusModel.statement(strength: strength, cardio: cardio,
                                                              recovery: .holding)
                let lanes = lane(statement)
                XCTAssertEqual(lanes?.low, .cardio, "\(strength) vs \(cardio) dropped the cardio lane")
                XCTAssertEqual(lanes?.high, .strength)
            }
        }
    }

    /// `aligned` claims both lanes agree, so it must never appear when they do not.
    func testAlignedNeverSpeaksForTwoLanesThatDisagree() {
        for strength in statuses {
            for cardio in cardioStatuses {
                for recovery in recoveries {
                    guard case .aligned = TrainingStatusModel.statement(strength: strength,
                                                                        cardio: cardio,
                                                                        recovery: recovery) else { continue }
                    let bothBehind = isBehind(strength) && isBehind(cardio)
                    let bothQuiet = !isBehind(strength) && !isBehind(cardio)
                    XCTAssertTrue(bothBehind || bothQuiet,
                                  "aligned claimed agreement for \(strength) vs \(cardio)")
                }
            }
        }
    }

    /// Swapping the lanes swaps them in the answer. Checked only on the verdicts both lanes can hold —
    /// `unproductive` exists for strength alone.
    func testTheAnswerIsSymmetricBetweenTheLanes() {
        for first in cardioStatuses {
            for second in cardioStatuses {
                let forwards = TrainingStatusModel.statement(strength: first, cardio: second,
                                                              recovery: .holding)
                let backwards = TrainingStatusModel.statement(strength: second, cardio: first,
                                                               recovery: .holding)
                switch (forwards, backwards) {
                case let (.split(lowA, highA, severityA), .split(lowB, highB, severityB)):
                    XCTAssertEqual(lowA, highB)
                    XCTAssertEqual(highA, lowB)
                    XCTAssertEqual(severityA, severityB)
                case let (.excessive(laneA, _), .excessive(laneB, _)):
                    XCTAssertNotEqual(laneA, laneB, "\(first) vs \(second) named the same lane both ways")
                case let (.oneBehind(laneA), .oneBehind(laneB)):
                    XCTAssertNotEqual(laneA, laneB)
                default:
                    XCTAssertEqual(forwards, backwards, "\(first) vs \(second) is not symmetric")
                }
            }
        }
    }

    func testTheTwoCasesThatPromptedThis() {
        XCTAssertEqual(
            TrainingStatusModel.statement(strength: .detraining, cardio: .overreaching, recovery: .holding),
            .split(low: .strength, high: .cardio, severity: .sharp))
        XCTAssertEqual(
            TrainingStatusModel.statement(strength: .productive, cardio: .detraining, recovery: .holding),
            .split(low: .cardio, high: .strength, severity: .mild))
    }

    func testTheStatementsThatWereAlreadyRight() {
        XCTAssertEqual(TrainingStatusModel.statement(strength: nil, cardio: nil, recovery: .unknown),
                       .noHistory)
        XCTAssertEqual(TrainingStatusModel.statement(strength: .unproductive, cardio: .maintaining,
                                                      recovery: .holding),
                       .spinning(cardioAlsoHigh: false))
        XCTAssertEqual(TrainingStatusModel.statement(strength: .maintaining, cardio: .maintaining,
                                                      recovery: .strained),
                       .strainedRecovery)
        XCTAssertEqual(TrainingStatusModel.statement(strength: .overreaching, cardio: .maintaining,
                                                      recovery: .strained),
                       .excessive(.strength, recoveryStrained: true))
    }

    /// Both lanes over the top used to read as a strength-only problem.
    func testBothLanesOverTheTopSaySo() {
        XCTAssertEqual(TrainingStatusModel.statement(strength: .overreaching, cardio: .overreaching,
                                                      recovery: .holding),
                       .bothExcessive(recoveryStrained: false))
        XCTAssertEqual(TrainingStatusModel.statement(strength: .overreaching, cardio: .overreaching,
                                                      recovery: .strained),
                       .bothExcessive(recoveryStrained: true))
    }

    /// Volume without return, with the cardio lane also running high: both facts, no claim that one
    /// causes the other.
    func testSpinningNotesAHighCardioLaneBesideIt() {
        XCTAssertEqual(TrainingStatusModel.statement(strength: .unproductive, cardio: .overreaching,
                                                      recovery: .holding),
                       .spinning(cardioAlsoHigh: true))
    }

    /// A single measured lane speaks only for itself.
    func testOneMeasuredLaneNeverSpeaksForTheOther() {
        for status in statuses {
            XCTAssertEqual(TrainingStatusModel.statement(strength: status, cardio: nil, recovery: .holding),
                           .laneOnly(.strength, status))
        }
        for status in cardioStatuses {
            XCTAssertEqual(TrainingStatusModel.statement(strength: nil, cardio: status, recovery: .holding),
                           .laneOnly(.cardio, status))
        }
    }

    /// Strained recovery sharpens or displaces a quiet statement, but never silences a split or a lane
    /// that is falling behind.
    func testStrainedRecoveryNeverHidesASplit() {
        for strength in statuses {
            for cardio in cardioStatuses {
                let holding = TrainingStatusModel.statement(strength: strength, cardio: cardio,
                                                             recovery: .holding)
                guard case .split = holding else { continue }
                XCTAssertEqual(TrainingStatusModel.statement(strength: strength, cardio: cardio,
                                                              recovery: .strained),
                               holding)
            }
        }
    }
}
