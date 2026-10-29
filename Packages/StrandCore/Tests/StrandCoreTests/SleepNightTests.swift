import StrandAnalytics
@testable import StrandCore
import WhoopStore
import XCTest

/// The night the Sleep screens show, on both platforms (`SleepNight`, Android plan E-3).
final class SleepNightTests: XCTestCase {
    private let utc = 0

    private func block(_ start: Int, _ end: Int, _ segments: [(String, Int, Int)]) -> CachedSleepSession {
        let json = "[" + segments.map { "{\"stage\":\"\($0.0)\",\"start\":\($0.1),\"end\":\($0.2)}" }
            .joined(separator: ",") + "]"
        return CachedSleepSession(startTs: start, endTs: end, efficiency: nil, restingHr: nil, avgHrv: nil,
                                  stagesJSON: json)
    }

    /// The shape of the owner's 2026-10-24: a night stored as two blocks with a 27-minute gap, then an evening
    /// nap. The night is one, from the first block's onset to the second's wake; the nap is not it.
    /// Android's WHOOP CSV and Health Connect imports store minute totals as an array; adopted into the core
    /// they must still make a night (they decoded to none, so the Android Sleep tab stayed empty).
    func testTheAndroidImportMinuteArrayDecodes() {
        let json = #"[{"stage":"light","min":84.6},{"stage":"deep","min":51.5},{"stage":"rem","min":40},{"stage":"awake","min":10}]"#
        XCTAssertEqual(SleepNight.minutes(json), SleepNight.Minutes(awake: 10, light: 84.6, deep: 51.5, rem: 40))
        XCTAssertEqual(SleepNight.asleepMinutes(json, effectiveStartTs: 0), 176.1, accuracy: 0.001)
        XCTAssertNil(SleepNight.minutes(#"[{"start":0,"end":600,"stage":"deep"}]"#), "a computed timeline is not minutes")
        let night = SleepNight.main([CachedSleepSession(startTs: 1_000_000, endTs: 1_000_000 + 186 * 60, efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: json)],
                                    offsetSec: 0, habitualMidsleepSec: nil)
        XCTAssertEqual(night?.minutes.deep, 51.5)
    }

    func testASplitNightIsOneNightAndTheEveningNapIsNot() throws {
        let d = 1_761_264_000   // 2026-10-24 00:00 UTC
        let first = block(d - 10_200, d + 3_000, [("light", d - 10_200, d - 3_000), ("deep", d - 3_000, d + 3_000)])
        let second = block(d + 4_620, d + 21_780, [("light", d + 4_620, d + 14_000), ("rem", d + 14_000, d + 21_780)])
        let nap = block(d + 62_640, d + 70_020, [("light", d + 62_640, d + 70_020)])
        let day = try XCTUnwrap(SleepNight.days([first, second, nap], calendar: utcCalendar()).first)
        XCTAssertEqual(day.count, 3, "the three blocks end on the same day")

        let main = try XCTUnwrap(SleepNight.main(day, offsetSec: utc, habitualMidsleepSec: nil))
        XCTAssertEqual(main.group.map(\.startTs), [first.startTs, second.startTs])
        XCTAssertEqual(main.onset, first.startTs)
        XCTAssertEqual(main.wake, second.endTs)
        // The 27-minute gap between the blocks is drawn as awake but is not time in bed.
        XCTAssertTrue(main.intervals.contains { $0.stage == "awake" && $0.start == Double(first.endTs - main.onset) })
        XCTAssertEqual(main.minutes.awake, 0)
        XCTAssertEqual(main.minutes.total, Double((first.endTs - first.startTs) + (second.endTs - second.startTs)) / 60)
    }

    /// A short, sleepless lead before the night does not move the bedtime (#736), whatever stages format it has.
    func testASleeplessLeadStubDoesNotMoveTheBedtime() throws {
        let d = 1_761_264_000
        let stub = block(d - 7_200, d - 5_400, [("wake", d - 7_200, d - 5_400)])
        let night = block(d - 4_800, d + 21_600, [("light", d - 4_800, d + 10_000), ("deep", d + 10_000, d + 21_600)])
        let main = try XCTUnwrap(SleepNight.main([stub, night], offsetSec: utc, habitualMidsleepSec: nil))
        XCTAssertEqual(main.group.count, 2, "the stub is bridged into the night")
        XCTAssertEqual(main.onset, night.startTs, "but the bedtime is the real sleep's")
        XCTAssertEqual(main.shown.map(\.startTs), [night.startTs])
    }

    /// The rule's thresholds (#736 / #259): sleepless and brief is a stub; a real episode never is.
    func testThePreOnsetStubRule() {
        XCTAssertTrue(SleepNight.isPreOnsetAwakeStub(spanMin: 120, asleepMin: 3))
        XCTAssertFalse(SleepNight.isPreOnsetAwakeStub(spanMin: 241, asleepMin: 0))
        XCTAssertTrue(SleepNight.isPreOnsetAwakeStub(spanMin: 60, asleepMin: 10, refAsleepMin: 400))
        XCTAssertFalse(SleepNight.isPreOnsetAwakeStub(spanMin: 60, asleepMin: 20, refAsleepMin: 400))
        XCTAssertFalse(SleepNight.isPreOnsetAwakeStub(spanMin: 60, asleepMin: 10))
    }

    /// Both stored formats decode: an imported night's minutes dict and a computed night's segment array, the
    /// latter trimmed to the effective onset (#259).
    func testBothStageFormatsDecode() throws {
        let m = try XCTUnwrap(SleepNight.minutes(#"{"light":200,"deep":80,"rem":90,"awake":20}"#))
        XCTAssertEqual(m.asleep, 370)
        XCTAssertNil(SleepNight.minutes(#"[{"stage":"light","start":0,"end":60}]"#))
        let seg = try XCTUnwrap(SleepNight.segments(#"[{"stage":"wake","start":0,"end":600},{"stage":"deep","start":600,"end":1800}]"#,
                                                     sessionStart: 300))
        XCTAssertEqual(seg.minutes.awake, 5)
        XCTAssertEqual(seg.minutes.deep, 20)
        XCTAssertEqual(seg.intervals.first, SleepNight.Interval(stage: "awake", start: 0, end: 300))
        XCTAssertEqual(SleepNight.asleepMinutes(#"[{"stage":"rem","start":0,"end":1200}]"#, effectiveStartTs: 0), 20)
    }

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}
