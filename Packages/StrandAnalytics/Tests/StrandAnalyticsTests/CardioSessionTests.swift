import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the cardio derivations.
///
/// Two kinds of test again. The arithmetic ones (pace, speed, beats per kilometre) exist so the units
/// can never silently invert — a pace that is really a speed reads plausibly and is wrong by a factor
/// of sixty. The rest hold restraint: a strength session must never acquire a pace, a 30-metre GPS
/// artefact must not become a sprint record, and a "fastest" must only ever compare sessions of
/// comparable length.
final class CardioSessionTests: XCTestCase {

    private func row(_ sport: String, at ts: Int, minutes: Double? = 60, km: Double? = nil,
                     avgHr: Int? = nil, kcal: Double? = nil, strain: Double? = nil,
                     source: String = "whoop") -> WorkoutRow {
        WorkoutRow(startTs: ts, endTs: ts + Int((minutes ?? 0) * 60), sport: sport, source: source,
                   durationS: minutes.map { $0 * 60 }, energyKcal: kcal, avgHr: avgHr, maxHr: nil,
                   strain: strain, distanceM: km.map { $0 * 1000 }, zonesJSON: nil, notes: nil,
                   steps: nil)
    }

    private static func ts(_ day: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Int((f.date(from: day) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970) + 43_200
    }

    // MARK: - Classification

    /// A strength session is not cardio, however it is spelled. This is the guard that stops "average
    /// pace" appearing on a bench day.
    func testStrengthSessionsAreNotCardio() {
        for sport in ["Strength", "Strength Training", "TraditionalStrengthTraining",
                      "Functional Strength Training", "Weightlifting", "Bodybuilding"] {
            XCTAssertFalse(CardioModality.of(sport: sport).isCardio, sport)
        }
    }

    /// The stored labels this app actually writes, each landing on the modality whose readout matches.
    func testStoredLabelsClassifyToTheRightReadout() {
        XCTAssertEqual(CardioModality.of(sport: "Running"), .foot)
        XCTAssertEqual(CardioModality.of(sport: "Treadmill walk"), .foot)
        XCTAssertEqual(CardioModality.of(sport: "Indoor cycle"), .cycling)
        XCTAssertEqual(CardioModality.of(sport: "Open-water swim"), .swimming)
        XCTAssertEqual(CardioModality.of(sport: "Row machine"), .rowing)
        XCTAssertEqual(CardioModality.of(sport: "Elliptical"), .other)
        XCTAssertEqual(CardioModality.of(sport: "Kite surfing"), .unknown)
        XCTAssertEqual(CardioModality.of(sport: "Running").readout, .pace)
        XCTAssertEqual(CardioModality.of(sport: "Cycling").readout, .speed)
        XCTAssertEqual(CardioModality.of(sport: "Elliptical").readout, .none)
    }

    // MARK: - Units

    /// 10 km in 50 minutes is 5:00 /km and 12 km/h. Both directions pinned, because a swapped
    /// numerator reads perfectly plausibly.
    func testPaceAndSpeedAreDerivedFromDistanceAndTime() {
        let m = CardioSession.metrics(for: row("Running", at: 0, minutes: 50, km: 10))
        XCTAssertEqual(try XCTUnwrap(m.paceSecPerKm), 300, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.speedKmh), 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.paceSecPer100m), 30, accuracy: 1e-9)
    }

    /// Beats per kilometre: 150 bpm over 50 minutes is 7500 beats, over 10 km that is 750 a kilometre.
    func testBeatsPerKilometreIsBeatsOverKilometres() {
        let m = CardioSession.metrics(for: row("Running", at: 0, minutes: 50, km: 10, avgHr: 150))
        XCTAssertEqual(try XCTUnwrap(m.beatsPerKm), 750, accuracy: 1e-9)
    }

    /// A 30-metre "session" gets no pace at all. Below the floor the figure describes where the GPS
    /// thought the session started, not how fast anyone moved.
    func testATinyDistanceGetsNoPace() {
        let m = CardioSession.metrics(for: row("Running", at: 0, minutes: 5, km: 0.03))
        XCTAssertNil(m.paceSecPerKm)
        XCTAssertNil(m.speedKmh)
        XCTAssertNil(m.beatsPerKm)
    }

    /// No distance, no pace — and the session still counts its minutes. A treadmill run with no
    /// distance is a real session, not a broken one.
    func testASessionWithoutDistanceStillCountsItsMinutes() {
        let m = CardioSession.metrics(for: row("Treadmill run", at: 0, minutes: 40))
        XCTAssertNil(m.paceSecPerKm)
        XCTAssertEqual(m.minutes, 40)
    }

    // MARK: - A week

    /// The week totals, and the coverage figure beside the distance.
    func testWeekTotalsCarryTheirDistanceCoverage() {
        let sessions = CardioSession.sessions([
            row("Running", at: Self.ts("2026-07-06"), minutes: 50, km: 10, kcal: 600, strain: 12),
            row("Indoor cycle", at: Self.ts("2026-07-08"), minutes: 45, kcal: 400, strain: 9),
            row("Strength", at: Self.ts("2026-07-08"), minutes: 60),
        ])
        let week = CardioSession.week(containing: "2026-07-08", sessions: sessions)
        XCTAssertEqual(week.mondayKey, "2026-07-06")
        XCTAssertEqual(week.sessionCount, 2, "the strength session is not cardio")
        XCTAssertEqual(week.minutes, 95)
        XCTAssertEqual(week.distanceM, 10_000)
        XCTAssertEqual(week.sessionsWithDistance, 1)
        XCTAssertEqual(week.energyKcal, 1000)
        XCTAssertEqual(week.effort, 21)
        XCTAssertEqual(week.bySport.first?.sport, "Running")
    }

    /// A week with no Effort at all reports nil, not zero — "not scored" and "an easy week" are
    /// different statements.
    func testAWeekWithoutEffortReportsNothingRatherThanZero() {
        let sessions = CardioSession.sessions([row("Running", at: Self.ts("2026-07-06"), minutes: 30)])
        XCTAssertNil(CardioSession.week(containing: "2026-07-06", sessions: sessions).effort)
    }

    // MARK: - Load

    /// Cardio load follows HR-derived Effort rather than duration: two equal-duration weeks separate
    /// when the recent one asked more of the cardiovascular system. Rest days remain real zeros.
    func testCardioLoadUsesEffortAndCountsRestDaysAsZero() throws {
        var rows: [WorkoutRow] = []
        var day = Self.ts("2026-04-01")
        // Four weeks of three equally long, moderate sessions; the final week keeps the duration but
        // doubles the measured Effort. A minutes-based implementation would report no change.
        for i in 0..<21 {
            rows.append(row("Running", at: day + i * 86_400, minutes: 60,
                            strain: i % 2 == 0 ? 10 : nil))
        }
        day += 21 * 86_400
        for i in 0..<7 {
            rows.append(row("Running", at: day + i * 86_400, minutes: 60,
                            strain: i % 2 == 0 ? 20 : nil))
        }
        let sessions = CardioSession.sessions(rows)
        let asOf = Date(timeIntervalSince1970: TimeInterval(day + 6 * 86_400))
        let trend = try XCTUnwrap(CardioSession.cardioLoadTrend(sessions, asOf: asOf))
        XCTAssertGreaterThan(trend.percentChange, 40)
        XCTAssertEqual(trend.recentPerDay, 80.0 / 7.0, accuracy: 1e-6)
    }

    /// Under four weeks of history there is no ratio — a figure from a fortnight is mostly a statement
    /// about how little data there is.
    func testAThinHistoryYieldsNoCardioLoadTrend() {
        let sessions = CardioSession.sessions([
            row("Running", at: Self.ts("2026-07-01"), minutes: 40, strain: 12),
            row("Running", at: Self.ts("2026-07-03"), minutes: 40, strain: 12),
        ])
        XCTAssertNil(CardioSession.cardioLoadTrend(
            sessions, asOf: Date(timeIntervalSince1970: TimeInterval(Self.ts("2026-07-05")))))
    }

    // MARK: - Bests

    /// A "fastest" only ever compares sessions of comparable length: a fast 3 km must not become the
    /// record a half marathon is measured against.
    func testFastestPaceIsKeptPerBandOfSessionLength() throws {
        let sessions = CardioSession.sessions([
            row("Running", at: Self.ts("2026-06-01"), minutes: 12, km: 3),      // 4:00 /km, short
            row("Running", at: Self.ts("2026-06-08"), minutes: 105, km: 21.5),  // 4:53 /km, very long
        ])
        let bests = CardioSession.bests(sport: "Running", sessions: sessions)
        XCTAssertEqual(try XCTUnwrap(bests.fastestPaceByBand[.short]).value, 240, accuracy: 1e-6)
        XCTAssertEqual(bests.fastestPaceByBand[.veryLong]?.day, "2026-06-08")
        XCTAssertEqual(bests.farthest?.value, 21_500)
        XCTAssertEqual(bests.longest?.value, 105 * 60)
    }

    /// Bands are per modality: 30 km is a long RUN and a medium RIDE, and one set of cut points for
    /// both would put every ride in the top band.
    func testDistanceBandsAreModalityAware() {
        XCTAssertEqual(CardioDistanceBand.of(distanceM: 30_000, modality: .foot), .veryLong)
        XCTAssertEqual(CardioDistanceBand.of(distanceM: 30_000, modality: .cycling), .medium)
        XCTAssertNil(CardioDistanceBand.of(distanceM: 30_000, modality: .other))
    }

    /// History is matched on the stored label, not on modality: a treadmill pace and a road pace are
    /// not one curve, whatever they have in common.
    func testHistoryDoesNotFoldTreadmillIntoOutdoorRunning() {
        let sessions = CardioSession.sessions([
            row("Running", at: Self.ts("2026-06-01"), minutes: 50, km: 10),
            row("Treadmill run", at: Self.ts("2026-06-03"), minutes: 40, km: 8),
        ])
        XCTAssertEqual(CardioSession.history(sport: "Running", sessions: sessions).count, 1)
        XCTAssertEqual(CardioSession.sportFrequency(sessions).count, 2)
    }

    /// The typical-week band skips weeks with no training, for the same reason every other band in this
    /// app does: a fortnight of illness is not evidence about a usual week.
    func testTypicalWeeklyMinutesSkipsEmptyWeeks() throws {
        var rows: [WorkoutRow] = []
        for week in 1...4 {
            rows.append(row("Running", at: Self.ts("2026-06-01") + (week - 1) * 7 * 86_400,
                            minutes: 60))
        }
        let sessions = CardioSession.sessions(rows)
        let band = try XCTUnwrap(CardioSession.typicalWeeklyMinutes(sessions,
                                                                    endingBefore: "2026-07-06"))
        XCTAssertEqual(band.lowerBound, 60, accuracy: 1e-6)
        XCTAssertEqual(band.upperBound, 60, accuracy: 1e-6)
    }
}

/// Pins which sports are read in which unit.
final class CardioModalityUnitTests: XCTestCase {

    /// Swimming is spoken per hundred metres — every pool clock and every written set says so. The
    /// arithmetic is identical; the unit is the part swimmers can read.
    func testOnlySwimmingIsReadPerHundredMetres() {
        XCTAssertTrue(CardioModality.swimming.usesPerHundredMetres)
        for modality in [CardioModality.foot, .cycling, .rowing, .other, .unknown, .strength] {
            XCTAssertFalse(modality.usesPerHundredMetres, "\(modality)")
        }
    }

    /// The unit question is separate from the pace-or-speed question: swimming still reports a pace.
    func testSwimmingStillReportsAPace() {
        XCTAssertEqual(CardioModality.swimming.readout, .pace)
        XCTAssertEqual(CardioModality.cycling.readout, .speed)
    }
}
