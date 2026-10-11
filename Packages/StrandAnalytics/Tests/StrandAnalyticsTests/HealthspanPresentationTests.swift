import XCTest
@testable import StrandAnalytics

final class HealthspanPresentationTests: XCTestCase {

    private typealias E = HealthspanEngine

    /// The wearer's 2026-10-07 trial values (backlog plan): the levers must name the big, reachable gains.
    private let trial = HealthspanEngine.Inputs(age: 35, sex: .male, sleepHours: 7.49, sleepConsistencyPct: 56.9,
                                                dailySteps: 9646, zone13MinPerWeek: 284, zone45MinPerWeek: 6.1,
                                                strengthMinPerWeek: 23, vo2max: 23.1, restingHR: 66.1)

    /// The three domain totals add up to the whole delta, grouped as the paper groups them.
    func testDomainTotalsSumToDelta() {
        let r = E.compute(trial)!
        let total = HealthspanDomain.allCases.reduce(0) { $0 + r.years(in: $1) }
        XCTAssertEqual(total, r.deltaYears, accuracy: 1e-9)
        XCTAssertEqual(E.Component.vo2max.domain, .fitness)
        XCTAssertEqual(E.Component.zone45.domain, .activity)
        XCTAssertEqual(E.Component.sleepConsistency.domain, .sleep)
    }

    /// Each lever is one realistic step, its gain is exactly what the engine says that step is worth,
    /// and they come strongest first.
    func testLeversAreRealStepsStrongestFirst() {
        let levers = E.levers(trial)
        XCTAssertEqual(levers.count, 3)
        XCTAssertEqual(levers.map(\.component), [.sleepConsistency, .zone45, .vo2max])
        for l in levers {
            var after = trial
            switch l.component {
            case .sleepConsistency: after.sleepConsistencyPct = l.newValue
            case .zone45: after.zone45MinPerWeek = l.newValue
            case .vo2max: after.vo2max = l.newValue
            default: continue
            }
            XCTAssertEqual(l.years, E.compute(after)!.deltaYears - E.compute(trial)!.deltaYears, accuracy: 1e-9)
        }
        XCTAssertTrue(zip(levers, levers.dropFirst()).allSatisfy { $0.years <= $1.years })
        XCTAssertTrue(levers.allSatisfy { $0.years < 0 })
    }

    /// Someone already past every curve's end has nothing left to suggest.
    func testNoLeversAtTheTop() {
        let top = HealthspanEngine.Inputs(age: 30, sex: .female, sleepHours: 8, sleepConsistencyPct: 95,
                                          dailySteps: 12000, zone13MinPerWeek: 700, zone45MinPerWeek: 60,
                                          strengthMinPerWeek: 90, vo2max: 60, restingHR: 45)
        XCTAssertTrue(E.levers(top).isEmpty)
    }

    /// Projection in years is the pace read back: half a year at the current pace.
    func testProjection() {
        XCTAssertEqual(E.projectedAge(currentAge: 40, pace: 1.0), 40.5, accuracy: 1e-9)
        XCTAssertEqual(E.projectedAge(currentAge: 40, pace: -1.0), 39.5, accuracy: 1e-9)
    }
}
