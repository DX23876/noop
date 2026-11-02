import Foundation

// FertileWindow.swift — a ROUGH estimate of the likely fertile days of the current cycle, for awareness only.
//
// Not contraception and not a medical device. Wrist skin temperature rises a day or two AFTER ovulation, so it
// confirms ovulation in hindsight and cannot see it coming. The estimate ahead therefore comes from the wearer's
// own history: the cycle days on which their temperature rose in past cycles. Ovulation is taken as the day
// before a rise, and the window as the five days before ovulation plus ovulation itself (sperm survive up to
// five days), stretched over the spread of past rises so an irregular history gives an honestly wider window.
// A positive ovulation (LH) test narrows it to the test day and the day after; a rise detected in this cycle
// fixes it in hindsight and closes it. Pure and deterministic.
public enum FertileWindow {

    /// Past cycles with a clear rise needed before any estimate ahead is shown.
    public static let minCycles = 3
    /// How many recent cycles the spread is taken from.
    public static let recentCycles = 6

    public enum Basis: Equatable, Sendable {
        /// From the rise days of past cycles.
        case history
        /// From a positive ovulation test logged in this cycle.
        case ovulationTest
        /// This cycle's own rise has been detected: the window is known in hindsight and is over.
        case confirmedByRise
    }

    public struct Estimate: Equatable, Sendable {
        /// First and last likely fertile cycle day (1 = the first day of the period).
        public let firstDay: Int
        public let lastDay: Int
        public let basis: Basis
        /// The past rise days the estimate used, newest first.
        public let pastRiseDays: [Int]
        /// The middle of the past rise days, for the explanation.
        public let typicalRiseDay: Int?

        public var length: Int { lastDay - firstDay + 1 }
    }

    public enum Status: Equatable, Sendable {
        case before(daysUntil: Int)
        case during(day: Int, of: Int)
        case over
    }

    /// - Parameters:
    ///   - pastRiseDays: cycle days on which the temperature rose in COMPLETED past cycles, newest first.
    ///   - currentRiseDay: the cycle day of the rise detected in the current cycle, if any.
    ///   - positiveTestDay: the cycle day of a positive ovulation test logged in the current cycle, if any.
    public static func estimate(pastRiseDays: [Int], currentRiseDay: Int?, positiveTestDay: Int?) -> Estimate? {
        let recent = Array(pastRiseDays.filter { (8...30).contains($0) }.prefix(recentCycles))
        let typical = recent.isEmpty ? nil : recent.sorted()[recent.count / 2]
        if let rise = currentRiseDay {
            let ovulation = rise - 1
            return Estimate(firstDay: max(1, ovulation - 5), lastDay: ovulation, basis: .confirmedByRise,
                            pastRiseDays: recent, typicalRiseDay: typical)
        }
        if let test = positiveTestDay {
            return Estimate(firstDay: max(1, test), lastDay: test + 1, basis: .ovulationTest,
                            pastRiseDays: recent, typicalRiseDay: typical)
        }
        guard recent.count >= minCycles, let earliest = recent.min(), let latest = recent.max() else { return nil }
        return Estimate(firstDay: max(1, earliest - 1 - 5), lastDay: latest - 1, basis: .history,
                        pastRiseDays: recent, typicalRiseDay: typical)
    }

    public static func status(_ estimate: Estimate, cycleDay: Int) -> Status {
        if estimate.basis == .confirmedByRise || cycleDay > estimate.lastDay { return .over }
        if cycleDay < estimate.firstDay { return .before(daysUntil: estimate.firstDay - cycleDay) }
        return .during(day: cycleDay - estimate.firstDay + 1, of: estimate.length)
    }
}
