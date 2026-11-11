import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// The cycle as both platforms read it (`CycleReading.swift`): the page's snapshot, the day log and the training
/// pattern, through the operations Android calls.
@MainActor
final class CoreCycleTests: XCTestCase {
    private func result(_ shifts: [String], phase: CyclePhaseEngine.Phase = .luteal) -> CyclePhaseEngine.Result {
        CyclePhaseEngine.Result(phase: phase, confidence: .solid, cycleDayLow: nil, cycleDayHigh: nil, cycleLengthDays: 29,
                                nextPeriodWindow: nil, shiftMarkers: shifts.map(CyclePhaseEngine.ShiftMarker.init(day:)), note: "")
    }

    func testTheLoggedPeriodWinsThenThisCyclesRisePlacesToday() {
        let period = CycleSnapshot.make(result: result([]), starts: ["2026-11-18"], log: [:], days: [], today: "2026-11-20")
        XCTAssertEqual(period.cycleDay, 3)
        XCTAssertEqual(period.phase, .period)
        let luteal = CycleSnapshot.make(result: result(["2026-11-15"]), starts: ["2026-11-01"], log: [:], days: [], today: "2026-11-20")
        XCTAssertEqual(luteal.cycleDay, 20)
        XCTAssertEqual(luteal.shiftDay, 15)
        XCTAssertEqual(luteal.phase, .luteal)
        XCTAssertEqual(luteal.phase(onDay: 15), .shift)
        XCTAssertEqual(luteal.phase(onDay: 10), .follicular)
    }

    func testPastRisesAndTheTestDayGiveTheFertileWindow() {
        let starts = ["2026-08-08", "2026-09-05", "2026-10-03", "2026-10-31", "2026-11-12"]
        let shifts = ["2026-08-22", "2026-09-19", "2026-10-17", "2026-11-10"]
        let log = ["2026-11-19": CycleLog.Day(ovulationTest: true)]
        let snap = CycleSnapshot.make(result: result(shifts, phase: .follicular), starts: starts, log: log, days: [],
                                      today: "2026-11-20", showFertile: true)
        // The positive test on cycle day 8 narrows it to days 8 and 9.
        XCTAssertEqual(snap.fertile?.basis, .ovulationTest)
        XCTAssertEqual(snap.fertile?.firstDay, 8)
        XCTAssertEqual(snap.fertileDays, ["2026-11-19", "2026-11-20"])
        XCTAssertEqual(snap.fertile?.pastRiseDays, [11, 15, 15, 15])
        let hidden = CycleSnapshot.make(result: result(shifts), starts: starts, log: log, days: [], today: "2026-11-20")
        XCTAssertNil(hidden.fertile)
    }

    func testDayKeysCrossMonthsAndYears() {
        XCTAssertEqual(CycleSnapshot.add(1, to: "2026-12-31"), "2027-01-01")
        XCTAssertEqual(CycleSnapshot.days(from: "2026-02-27", to: "2026-03-01"), 2)
    }

    func testTheLogRoundTripsAndFlowStartsACycle() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let today = StoreReader.localDayKey(Date())
        let log = CoreCycle.LogDay(flow: 3, symptoms: ["cramps", "bogus"], moods: ["calm"], ovulationTest: false)
        let empty = CoreCycle.LogDay(flow: nil, symptoms: [], moods: [], ovulationTest: false)
        let started = await CoreCycle.save(store: store, day: today, log: log, previous: empty, starts: [])
        XCTAssertTrue(started)
        let out = await CoreCycle.read(reader: reader, showFertile: true, learning: true, dismissedWorkouts: [])
        XCTAssertEqual(out.starts, [today])
        XCTAssertEqual(out.todayLog.flow, 3)
        XCTAssertEqual(out.todayLog.symptoms, ["cramps"])
        XCTAssertEqual(out.snapshot.cycleDay, 1)
        XCTAssertEqual(out.snapshot.phase, "period")
        XCTAssertEqual(Set(out.pattern?.verdicts.keys ?? [:].keys), ["period", "follicular", "luteal"])
        // Clearing the flow deletes its row and logs no second start.
        let again = await CoreCycle.save(store: store, day: today, log: empty, previous: log, starts: out.starts)
        XCTAssertFalse(again)
        let cleared = await CoreCycle.read(reader: reader, showFertile: false, learning: false, dismissedWorkouts: [])
        XCTAssertNil(cleared.todayLog.flow)
        XCTAssertEqual(cleared.starts, [today])
    }

    func testPatternVerdictReadsHarderLuteal() {
        let starts = ["2026-05-01", "2026-05-29", "2026-06-26", "2026-07-24"]
        let shifts = ["2026-05-15", "2026-06-12", "2026-07-10", "2026-08-07"]
        let cycles = zip(starts, shifts).map { CycleTrainingPattern.Cycle(start: $0, shift: $1) }
        var sessions: [CycleTrainingPattern.Session] = []
        for (a, b) in zip(["2026-05-08", "2026-06-05", "2026-07-03", "2026-07-31"], ["2026-05-20", "2026-06-17", "2026-07-15", "2026-08-12"]) {
            sessions.append(.init(day: a, rpe: 6))
            sessions.append(.init(day: b, rpe: 7.2))
        }
        let out = CoreCycle.output(CycleTrainingPattern.analyse(sessions: sessions, cycles: cycles))
        XCTAssertEqual(out.verdicts["luteal"]?.kind, "harder")
        XCTAssertEqual(out.verdicts["luteal"]?.rpeDelta ?? 0, 1.2, accuracy: 1e-9)
    }
}
