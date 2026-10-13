import XCTest
@testable import Strand

/// The shared next-alarm resolver and the short phrase Today shows. The phrase follows the Clock setting,
/// so these pin both hour cycles; the resolver carries the gate, so these pin that it says nothing for an
/// alarm that will not buzz.
final class NextStrapAlarmTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // October 2026: the 13th is a Tuesday.
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private let english24 = NextStrapAlarm.Style(locale: Locale(identifier: "en_GB"), uses24Hour: true)
    private let english12 = NextStrapAlarm.Style(locale: Locale(identifier: "en_GB"), uses24Hour: false)

    /// ICU puts a narrow no-break space before AM/PM; compare on plain spaces.
    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testTheSameDayReadsToday() {
        let label = NextStrapAlarm.shortLabel(for: date(13, 15), now: date(13, 9), calendar: cal, style: english24)
        XCTAssertEqual(label, "today 15:00")
    }

    func testTheNextDayReadsTomorrow() {
        let label = NextStrapAlarm.shortLabel(for: date(14, 6), now: date(13, 21), calendar: cal, style: english24)
        XCTAssertEqual(label, "tomorrow 06:00")
    }

    func testFurtherOutNamesTheWeekday() {
        let label = NextStrapAlarm.shortLabel(for: date(17, 8), now: date(13, 21), calendar: cal, style: english24)
        XCTAssertTrue(label.hasPrefix("Sat"), label)
        XCTAssertTrue(label.hasSuffix("08:00"), label)
    }

    func testTheClockSettingDecidesTheHourCycle() {
        let label = NextStrapAlarm.shortLabel(for: date(14, 6), now: date(13, 21), calendar: cal, style: english12)
        XCTAssertEqual(plain(label).lowercased(), "tomorrow 6:00 am")
        XCTAssertEqual(plain(NextStrapAlarm.timeOfDay(minutes: 18 * 60 + 30, style: english12, calendar: cal))
                        .lowercased(), "6:30 pm")
        XCTAssertEqual(NextStrapAlarm.timeOfDay(minutes: 18 * 60 + 30, style: english24, calendar: cal), "18:30")
    }

    func testNothingIsResolvedForAnAlarmThatIsOffOrWillNotArm() {
        let now = date(13, 21)
        XCTAssertNil(NextStrapAlarm.date(enabled: false, willArm: true, minutes: 360, weekdays: [],
                                         overrides: [:], from: now))
        XCTAssertNil(NextStrapAlarm.date(enabled: true, willArm: false, minutes: 360, weekdays: [],
                                         overrides: [:], from: now))
        XCTAssertNotNil(NextStrapAlarm.date(enabled: true, willArm: true, minutes: 360, weekdays: [],
                                            overrides: [:], from: now))
    }

    /// Every alarm readout resolves through `NextStrapAlarm`. A screen that called `nextSmartAlarmDate`
    /// itself would skip the gate and could promise a buzz a 5/MG never gives.
    func testNoScreenResolvesTheAlarmPastTheSharedResolver() throws {
        let root = try Self.repositoryRoot()
        var offenders: [String] = []
        for folder in ["Strand/Screens", "Strand/Liquid", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets"] {
            let dir = root.appendingPathComponent(folder)
            guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("nextSmartAlarmDate(") { offenders.append(url.lastPathComponent) }
            }
        }
        XCTAssertEqual(offenders, [], "these resolve the next alarm without the shared gate")
        let today = try String(contentsOf: root.appendingPathComponent("Strand/Screens/TodayNextAlarmLine.swift"),
                               encoding: .utf8)
        XCTAssertTrue(today.contains("NextStrapAlarm.date("), "Today's line must use the shared resolver")
    }

    private static func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<4 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.yml").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        throw NSError(domain: "NextStrapAlarmTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "repository root not reachable from \(file)"])
    }
}
