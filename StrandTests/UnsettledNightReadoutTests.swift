import XCTest
@testable import Strand

/// The card about a night that is not finished yet. Two surfaces show it (Forge's Today notice and the
/// classic morning card), and until 2026-11-18 they said different things about the same state.
final class UnsettledNightReadoutTests: XCTestCase {

    /// 2026-11-18 06:12 UTC, read in UTC so the expected string is stable wherever this runs.
    private let wake = 1_763_446_320
    private let utc = TimeZone(identifier: "UTC")!
    private let en = Locale(identifier: "en_US")

    private func reading(fetching: Bool) -> UnsettledNightReadout.Reading {
        UnsettledNightReadout.reading(wakeTs: wake, fetching: fetching, locale: en, timeZone: utc)
    }

    /// The headline is about the result, not the transfer, and it does not change with the reason: the
    /// reader is in the same state either way.
    func testTheHeadlineIsTheSameInBothStates() {
        XCTAssertEqual(reading(fetching: true).headline, reading(fetching: false).headline)
        XCTAssertFalse(reading(fetching: true).headline.isEmpty)
    }

    /// Both lines name where the data stops. The time alone reads like a finished statement; under this
    /// headline it reads as the edge of what has arrived.
    func testBothLinesNameWhereTheDataStops() {
        for fetching in [true, false] {
            let line = reading(fetching: fetching).line
            XCTAssertTrue(line.contains("6:12"), "the data end belongs in the line: \(line)")
        }
    }

    /// The reason differs, because it is the one thing the headline cannot carry: something is coming in,
    /// or nothing is.
    func testTheLineSaysWhetherAnythingIsComingIn() {
        let fetching = reading(fetching: true).line
        let idle = reading(fetching: false).line
        XCTAssertNotEqual(fetching, idle)
        XCTAssertTrue(fetching.lowercased().contains("coming in"), fetching)
        XCTAssertTrue(idle.lowercased().contains("strap"), idle)
    }

    /// No line may claim that work is running while nothing is: that was the objection to saying "being
    /// processed" on its own, and the idle line is the one that would have carried the lie.
    func testTheIdleLineDoesNotClaimWorkInProgress() {
        let idle = reading(fetching: false).line.lowercased()
        for claim in ["coming in", "being fetched", "in progress"] {
            XCTAssertFalse(idle.contains(claim), "nothing is running in this state: \(idle)")
        }
    }

    /// The wake travels with the reading, for the surfaces that offer confirming it.
    func testTheWakeTravelsWithTheReading() {
        XCTAssertEqual(reading(fetching: true).wakeTs, wake)
        XCTAssertTrue(reading(fetching: true).fetching)
        XCTAssertFalse(reading(fetching: false).fetching)
    }

    /// One formatter for both surfaces: the classic card built its own, Forge printed none.
    ///
    /// The English case is asserted by its digits and its marker, NOT against a pasted "6:12 AM":
    /// Foundation separates the marker with U+202F, a narrow no-break space, so a literal written with an
    /// ordinary space fails against a string that looks identical on screen. The German case has no
    /// marker and is pinned exactly.
    func testTheTimeIsTheWearersLocalShortTime() {
        let english = UnsettledNightReadout.timeString(wake, locale: en, timeZone: utc)
        XCTAssertTrue(english.hasPrefix("6:12"), english)
        XCTAssertTrue(english.uppercased().hasSuffix("AM"), english)
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(UnsettledNightReadout.timeString(wake, locale: Locale(identifier: "de_DE"),
                                                        timeZone: berlin), "07:12")
    }
}
