import XCTest
import WhoopStore
@testable import Strand

/// The workout tile's caption, which has now lost two segments to the same cause.
///
/// The tile is one cell of a three-column grid (~110pt) and the caption is `lineLimit(1)`, so past
/// roughly sixteen characters it ellipsises. "· N bpm" was dropped first; the END TIME is what still
/// pushed "14 Aug · 18:27-19:11" over, rendering in the simulator as "14 Aug · 18:27…". Dropping it
/// loses nothing the tile does not already show — the DURATION is the headline value directly above
/// this line, so start + duration gives the end.
///
/// These exist so a third segment is not added back without noticing.
final class TodayWorkoutCaptionTests: XCTestCase {

    /// `workoutDateFmt`/`hrTimeFmt` pin the LOCALE (en_US_POSIX) but not the time zone, so a caption's
    /// clock time follows the machine. Building the fixture in the same zone keeps the assertions
    /// stable on any runner rather than only where they were written.
    private func workout(startingAt components: DateComponents, minutes: Int) -> WorkoutRow {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let start = Int(cal.date(from: components)!.timeIntervalSince1970)
        return WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: "Running",
                          source: "test", durationS: Double(minutes * 60), energyKcal: 347,
                          avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                          zonesJSON: nil, notes: nil, steps: nil)
    }

    private let august14 = DateComponents(year: 2026, month: 8, day: 14, hour: 18, minute: 27)

    /// The date and ONE clock time. The time itself is formatted in the reader's own convention —
    /// `hrTimeFmt` uses the "j" template, so a 24-hour reader sees "18:27" and a 12-hour reader
    /// "6:27 PM" — so the assertion pins the SHAPE rather than one region's rendering.
    func testCaptionCarriesTheDateAndStartTimeOnly() {
        let caption = TodayView.workoutCaption(workout(startingAt: august14, minutes: 44))
        XCTAssertTrue(caption.hasPrefix("14 Aug · "), "unexpected caption: \(caption)")
        XCTAssertTrue(caption.contains("27"), "the START minute belongs in the caption: \(caption)")
    }

    /// The specific regression: no "HH:mm-HH:mm" range, which is what overflowed the tile.
    func testCaptionHasNoTimeRange() {
        let caption = TodayView.workoutCaption(workout(startingAt: august14, minutes: 44))
        XCTAssertFalse(caption.contains("-"),
                       "an end time puts the caption past the tile's width and it ellipsises")
        XCTAssertEqual(caption.filter { $0 == ":" }.count, 1, "exactly one clock time")
    }

    /// #157 — a row with no real end used to need its own branch. Both shapes are the same now, so the
    /// branch is gone and this pins that they cannot diverge again.
    func testARowWithNoRealEndReadsTheSameAsAnyOther() {
        let normal = TodayView.workoutCaption(workout(startingAt: august14, minutes: 44))
        let noEnd = TodayView.workoutCaption(workout(startingAt: august14, minutes: 0))
        XCTAssertEqual(normal, noEnd)
    }

    /// The budget the tile has. Not a pixel measure — a coarse ceiling sized to catch this class of
    /// overflow, like `tileLabelBudget` in `MetricNameLocalizationTests`.
    ///
    /// 17 rather than 16 because the clock format is the READER's, not ours: "28 Dec · 23:59" is 14
    /// characters and "28 Dec · 11:59 PM" is 17, from the same instant. The tile absorbs that last
    /// stretch by shrinking the caption slightly (`minimumScaleFactor` on StatTile) instead of
    /// ellipsising — this pins that a THIRD segment can never be added back on top of it.
    func testCaptionFitsTheTileWidthBudget() {
        // A worst case for width: two-digit day, wide month abbreviation, two-digit hour and minute.
        let wide = DateComponents(year: 2026, month: 12, day: 28, hour: 23, minute: 59)
        let caption = TodayView.workoutCaption(workout(startingAt: wide, minutes: 90))
        XCTAssertLessThanOrEqual(caption.count, 17,
                                 "\"\(caption)\" is wider than the tile can carry")
    }
}
