import Foundation

// MARK: - Did this site grow or shrink?
//
// The question a tape measurement is actually taken to answer: is the arm bigger than it was three
// weeks ago, is the waist smaller. Not left against right — that is a different question, and one
// nobody asks while trying to work out whether a bulk or a cut is working.
//
// TWO THINGS MAKE THIS HONEST, and without them a change readout is worse than no readout.
//
// 1. THE REFERENCE HAS TO EXIST. "Three weeks ago" means the reading in force three weeks ago, and if
//    the nearest one is two months old then the comparison spans two months, not three weeks. Silently
//    reaching back further turns a long slow change into what looks like a fast recent one. So the
//    reference carries its own date, and a reading too far from the requested point is refused.
//
// 2. A CHANGE SMALLER THAN THE WEARER'S OWN SCATTER IS NOT A CHANGE. Tape measurements repeat to
//    somewhere around half a centimetre depending on technique, and +0.2 cm presented as growth is a
//    measurement artefact dressed as progress. Rather than asserting a fixed noise figure, this reads
//    the scatter out of THAT PERSON'S OWN SERIES at THAT SITE — the median step between consecutive
//    readings. It is a conservative floor (real change is inside those steps too, so it overstates the
//    noise slightly), and overstating the bar for what counts as movement is the safe direction to err.

/// One site's change between two points in time.
public struct CircumferenceChange: Equatable, Sendable {
    public let key: String
    public let fromValue: Double
    public let fromDay: String
    public let toValue: Double
    public let toDay: String
    /// The wearer's own typical step between consecutive readings at this site. Nil below two readings.
    public let typicalStepCm: Double?

    public var deltaCm: Double { toValue - fromValue }

    /// Whether the change is bigger than this person's own measurement scatter at this site.
    ///
    /// False does NOT mean nothing happened — it means this series cannot tell the difference between
    /// what happened and how the tape was held, which is a different and more useful statement.
    public var exceedsTypicalStep: Bool {
        guard let typicalStepCm, typicalStepCm > 0 else { return abs(deltaCm) > 0 }
        return abs(deltaCm) > typicalStepCm
    }

    public init(key: String, fromValue: Double, fromDay: String, toValue: Double, toDay: String,
                typicalStepCm: Double?) {
        self.key = key
        self.fromValue = fromValue
        self.fromDay = fromDay
        self.toValue = toValue
        self.toDay = toDay
        self.typicalStepCm = typicalStepCm
    }
}

/// Comparing one measurement site with its own past.
public enum CircumferenceProgress {

    /// How far the reference reading may sit from the requested point before the comparison stops
    /// describing the interval it claims to. Two weeks: wide enough to catch a missed measurement
    /// week, narrow enough that a "six weeks ago" reading is not really three months old.
    public static let maximumReferenceDriftDays = 14

    /// The median absolute step between consecutive readings — this person's own scatter at this site.
    public static func typicalStep(_ readings: [BodyReading]) -> Double? {
        let sorted = readings.sorted { $0.day < $1.day }
        guard sorted.count >= 2 else { return nil }
        let steps = zip(sorted, sorted.dropFirst()).map { abs($1.value - $0.value) }
        let ordered = steps.sorted()
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2)
            ? (ordered[middle - 1] + ordered[middle]) / 2
            : ordered[middle]
    }

    /// The change at `key` between the reading in force on `from` and the one in force on `to`.
    ///
    /// Nil when either end has no reading, when the reference reading drifts further than
    /// `maximumReferenceDriftDays` from the requested point, or when both ends resolve to the same
    /// reading — a site compared with itself has not changed, and saying "0.0 cm" implies it was
    /// measured twice.
    public static func change(key: String, readings: [BodyReading], from: String, to: String,
                              maximumDrift: Int = maximumReferenceDriftDays) -> CircumferenceChange? {
        let sorted = readings.filter { $0.value.isFinite }.sorted { $0.day < $1.day }
        guard let start = inForce(sorted, on: from), let end = inForce(sorted, on: to),
              start.day != end.day else { return nil }
        guard StrengthSession.daysBetween(start.day, and: from) <= maximumDrift else { return nil }
        return CircumferenceChange(key: key, fromValue: start.value, fromDay: start.day,
                                   toValue: end.value, toDay: end.day,
                                   typicalStepCm: typicalStep(sorted))
    }

    /// The newest reading on or before `day`. Never looks forward.
    private static func inForce(_ sorted: [BodyReading], on day: String) -> BodyReading? {
        sorted.last { $0.day <= day }
    }
}

// MARK: - The total, for the weeks the scale refuses to move
//
// The situation this exists for: someone in a deficit whose weight has sat still for three weeks and
// who is about to conclude it is not working. Very often the tape disagrees with the scale, because
// water retention and glycogen mask a real loss on the scale for weeks at a time while circumferences
// keep coming down.
//
// So: direction counts for the sites that actually moved. Two rules keep the underlying tally from
// becoming a motivational fiction:
//
//   • ONLY SITES THAT BEAT THEIR OWN SCATTER COUNT. Summing thirteen sites of ±0.3 cm noise produces a
//     confident-looking number out of nothing, and it would almost always point somewhere flattering
//     because there are more sites than there is signal.
//   • LOSS AND GAIN ARE REPORTED SEPARATELY, never netted into one figure. A centimetre off the waist
//     and a centimetre onto the arm are the recomposition people are usually after; netting them to
//     zero would report the best possible outcome as no progress at all.
//
// The centimetre magnitudes remain available for weight-context logic, but the UI never presents their
// sum as a body measurement — adding a waist to a thigh measures nothing real.

/// What moved, across every site with a usable comparison.
public struct CircumferenceTotal: Equatable, Sendable {
    /// Internal magnitude used to establish that one or more sites shrank beyond their scatter.
    public let lostCm: Double
    /// Internal magnitude used to establish that one or more sites grew beyond their scatter.
    public let gainedCm: Double
    public let shrinkingSites: Int
    public let growingSites: Int
    /// Sites that had a usable comparison at all, including the ones that did not move enough to count.
    public let comparedSites: Int

    /// Whether anything is worth saying. Below this the honest report is "too early to tell".
    public var hasMovement: Bool { shrinkingSites > 0 || growingSites > 0 }
}

extension CircumferenceProgress {

    /// Tallies movement directions, counting only changes that beat their own site's scatter.
    public static func total(_ changes: [CircumferenceChange]) -> CircumferenceTotal {
        var lost = 0.0
        var gained = 0.0
        var shrinking = 0
        var growing = 0
        for change in changes where change.exceedsTypicalStep {
            if change.deltaCm < 0 {
                lost += -change.deltaCm
                shrinking += 1
            } else if change.deltaCm > 0 {
                gained += change.deltaCm
                growing += 1
            }
        }
        return CircumferenceTotal(lostCm: lost, gainedCm: gained, shrinkingSites: shrinking,
                                  growingSites: growing, comparedSites: changes.count)
    }
}
