import Foundation
import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// The Profile page on Android asks the shared code for the maximum heart rate with its source, the VO₂max hint and
/// the zone editor's drafts, so both phones answer with the rules the Apple Profile page uses.
@MainActor
final class CoreProfileTests: XCTestCase {

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    func testMaxHeartRateIsTheManualSettingThenTheMeasuredLevelThenTheAgeFormula() {
        let manual = CoreProfile.resolveMaxHeartRate(age: 40, override: 187, measured: nil)
        XCTAssertEqual(manual.bpm, 187)
        XCTAssertEqual(manual.source, "override")

        let formula = CoreProfile.resolveMaxHeartRate(age: 40, override: 0, measured: nil)
        XCTAssertEqual(formula.bpm, Int(MaxHeartRate.gellish(age: 40) ?? 0))
        XCTAssertEqual(formula.source, "gellish")
        XCTAssertNil(formula.confirmedOn)

        // A measured level above the formula counts, and says the day it was confirmed.
        let measured = CoreProfile.resolveMaxHeartRate(age: 40, override: 0,
                                                       measured: .init(bpm: 196, confirmedOn: "2026-11-02"))
        XCTAssertEqual(measured.bpm, 196)
        XCTAssertEqual(measured.source, "measured")
        XCTAssertEqual(measured.confirmedOn, "2026-11-02")

        // The manual setting still wins over a measured level.
        let both = CoreProfile.resolveMaxHeartRate(age: 40, override: 180,
                                                   measured: .init(bpm: 196, confirmedOn: "2026-11-02"))
        XCTAssertEqual(both.bpm, 180)
        XCTAssertNil(both.confirmedOn)
    }

    func testTheCallAnswersWithoutAStore() async {
        let answer = object(await CoreCall.run("profile.maxHeartRate", #"{"age":30,"override":0}"#))
        XCTAssertEqual(answer["source"] as? String, "gellish")
        XCTAssertEqual(answer["bpm"] as? Int, Int(MaxHeartRate.gellish(age: 30) ?? 0))
    }

    func testTheHintAppearsOnlyForTheFormulaOnABodyBeyondItsRange() async {
        // No store and no energy day: no source, so no hint however heavy.
        let none = object(await CoreCall.run("profile.vo2Hint", #"{"weightKg":212,"heightCm":175}"#))
        XCTAssertEqual(none["advised"] as? Bool, false)
    }

    func testZonesSeedFromTheStandardBandsAndStepOneBoundAtATime() {
        // Percent mode with nothing stored: seeded 50/60/70/80/90, then one notch of half a percent.
        let seeded = object(CoreProfile.zones(["mode": "percent", "maxHR": 200]))
        XCTAssertEqual(seeded["percents"] as? [Double], [50, 60, 70, 80, 90])
        XCTAssertEqual(seeded["bpms"] as? [Double], [100, 120, 140, 160, 180])
        XCTAssertEqual(seeded["legal"] as? Bool, true)

        let stepped = object(CoreProfile.zones(["mode": "percent", "maxHR": 200, "percents": [50, 60, 70, 80, 90],
                                                "step": ["index": 1, "up": true]]))
        XCTAssertEqual(stepped["percents"] as? [Double], [50, 60.5, 70, 80, 90])
        let rows = stepped["zones"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 5)
        XCTAssertEqual(rows?[1]["lowerPercentText"] as? String, "60.5")
        XCTAssertEqual(rows?[4]["upperBpm"] as? Int, 200)
        XCTAssertEqual(rows?[0]["upperBpm"] as? Int, 120)   // 60.5 % of 200 is 121; zone 1 ends one beat before
    }

    func testAnIllegalDraftIsFlaggedAndTheStoredZonesStayInThePreview() {
        // Zone 3 raised past zone 4: not a partition, so not legal, and the preview keeps the standard bands.
        let draft = object(CoreProfile.zones(["mode": "bpm", "maxHR": 200, "bpms": [100, 120, 170, 160, 180]]))
        XCTAssertEqual(draft["legal"] as? Bool, false)
        XCTAssertEqual(draft["custom"] as? Bool, false)
        let rows = draft["zones"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["lowerBpm"] as? Int, 100)
    }

    func testBpmBoundsAreClampedAndTheTopBandLeavesRoomUnderTheMaximum() {
        let low = object(CoreProfile.zones(["mode": "bpm", "maxHR": 190, "bpms": [40, 60, 80, 100, 120],
                                            "step": ["index": 0, "up": false]]))
        XCTAssertEqual((low["bpms"] as? [Double])?.first, 40)   // never below the floor
        let high = object(CoreProfile.zones(["mode": "bpm", "maxHR": 190, "bpms": [100, 120, 140, 160, 189],
                                             "step": ["index": 4, "up": true]]))
        XCTAssertEqual((high["bpms"] as? [Double])?.last, 189)  // one beat under the maximum at most
        XCTAssertEqual(high["legal"] as? Bool, true)
    }

    func testTheSummaryNamesTheWearersOwnBoundsInTheirUnit() {
        let bpm = object(CoreProfile.zones(["mode": "bpm", "maxHR": 190, "bpms": [110, 125, 140, 155, 170]]))
        XCTAssertEqual(bpm["custom"] as? Bool, true)
        XCTAssertEqual(bpm["bounds"] as? String, "110/125/140/155/170 bpm")
        let auto = object(CoreProfile.zones(["mode": "auto", "maxHR": 190]))
        XCTAssertEqual(auto["custom"] as? Bool, false)
        let percent = object(CoreProfile.zones(["mode": "percent", "maxHR": 200, "percents": [55, 62.5, 72, 82, 91]]))
        XCTAssertEqual(percent["bounds"] as? String, "55/62.5/72/82/91%")
    }

    func testTheEquipmentChoicesAreTheOnesSettingsOffersOnApple() async {
        let answer = object(await CoreCall.run("profile.equipmentChoices", "{}"))
        XCTAssertEqual(answer["ids"] as? [String], TrainingPreferences.knownEquipment)
        XCTAssertEqual((answer["ids"] as? [String])?.count, 11)
    }

    // MARK: - The weekly-goal notices

    func testWeeklyGoalNoticesComeOnlyForTheKindsSwitchedOn() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        // A Wednesday noon, so this week still has its Thursday evening and Sunday review ahead.
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!
        let added = await CoreGoals.addPeriodGoal(store: store, metric: "workouts", period: "week", target: 3,
                                                  threshold: nil, now: now)
        XCTAssertTrue(added.ok)
        let settings = CoreGoals.Settings(profileSex: "male", lastSync: nil, agelessEnabled: false,
                                          dismissedWorkoutSpans: [])
        var host = CoreGoalNotices.Host(kinds: [], quiet: false, eveningMinute: 19 * 60, workoutInProgress: false,
                                        appIsActive: false, state: nil)

        let off = try await CoreGoalNotices.evaluate(reader: reader, settings: settings, host: host, now: now,
                                                     calendar: calendar)
        XCTAssertTrue(off.periodNotices.isEmpty)

        host.periodKinds = ["weekStart", "review"]
        host.firstWeekday = 2
        let on = try await CoreGoalNotices.evaluate(reader: reader, settings: settings, host: host, now: now,
                                                    calendar: calendar)
        XCTAssertEqual(on.periodNotices.map(\.id), ["goals.notify.weekStart", "goals.notify.review"])
        // The review is Sunday 19:00, the next week starts Monday 08:00.
        let review = Date(timeIntervalSince1970: TimeInterval(on.periodNotices[1].at))
        XCTAssertEqual(calendar.component(.weekday, from: review), 1)
        XCTAssertEqual(calendar.component(.hour, from: review), 19)
        let next = Date(timeIntervalSince1970: TimeInterval(on.periodNotices[0].at))
        XCTAssertEqual(calendar.component(.weekday, from: next), 2)
        XCTAssertEqual(calendar.component(.hour, from: next), 8)

        // Quiet hours that cover Sunday evening drop the review (Monday 08:00 stays), as `GoalNotifier` does on Apple.
        host.quietEnabled = true
        host.quietStartMinutes = 18 * 60
        host.quietEndMinutes = 7 * 60
        let quiet = try await CoreGoalNotices.evaluate(reader: reader, settings: settings, host: host, now: now,
                                                       calendar: calendar)
        XCTAssertEqual(quiet.periodNotices.map(\.id), ["goals.notify.weekStart"])
    }
}
