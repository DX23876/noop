import Foundation
import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

@MainActor
final class CoreCoachDataTests: XCTestCase {
    private let today = "2026-10-27"
    private var now: Date { WeightSeries.date(forDay: today)! }
    private var settings: CoreGoals.Settings {
        .init(profileSex: "female", lastSync: nil, agelessEnabled: false, dismissedWorkoutSpans: [])
    }

    /// The coach host reads the same lanes as the goals host, so the two cannot disagree about one fact.
    func testSharedLanesMatchTheGoalsHost() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        _ = try await store.upsertJournal([.init(day: today, question: "Walked", answeredYes: true, notes: nil)],
                                          deviceId: "noop-journal")
        _ = try await store.upsertMetricSeries([.init(day: today, key: HydrationRead.manualKey, value: 1500)],
                                               deviceId: HydrationRead.sourceId)
        let coach = CoreCoachData(reader: reader, settings: settings, now: now)
        let goals = CoreGoals.Host(reader: reader, settings: settings, motivationEnabled: false, now: now)
        await coach.load()

        let coachJournal = await coach.journalEntries(days: 1)
        let goalJournal = await goals.goalJournalEntries(days: 1)
        XCTAssertEqual(coachJournal.map(\.question), goalJournal.map(\.question))
        XCTAssertEqual(coachJournal.first?.question, "Walked")
        let coachWater = await coach.hydrationHistory(days: 1, now: now)
        XCTAssertEqual(coachWater.first?.value, 1500)
        let coachDays = coach.days.map(\.day)
        let goalDays = await goals.goalDays().map(\.day)
        XCTAssertEqual(coachDays, goalDays)
    }

    /// Series keys and sources come from the store, with the active strap's keys under the WHOOP source.
    func testCatalogReadsTheStore() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        _ = try await store.upsertMetricSeries([.init(day: today, key: "vo2max", value: 44)], deviceId: "apple-health")
        _ = try await store.upsertMetricSeries([.init(day: today, key: "stress", value: 1.2)], deviceId: "owned-strap")
        let coach = CoreCoachData(reader: reader, settings: settings, now: now)
        let whoopKeys = await coach.availableKeys(source: MetricResolver.whoopSource)
        let appleKeys = await coach.availableKeys(source: "apple-health")
        let sources = await coach.metricSources(key: "vo2max")
        let vo2 = await coach.series(key: "vo2max", source: "apple-health", days: 7)
        XCTAssertEqual(whoopKeys, ["stress"])
        XCTAssertEqual(appleKeys, ["vo2max"])
        XCTAssertEqual(sources, ["apple-health"])
        XCTAssertEqual(vo2.map(\.value), [44])
    }

    /// The lanes Apple's `Repository` answers are answered here too: mood from the check-in lane, the Training Load
    /// reading rendered as Apple renders it, and a weigh-in on the core's weight lane; the profile feeds the cardio
    /// pricing inputs. An empty history still has no cardio room.
    func testCoachLanesAnswerAsOnApple() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        _ = try await store.upsertMetricSeries([.init(day: today, key: MoodStore.moodKey, value: 4)],
                                               deviceId: MoodStore.moodDeviceId)
        let coach = CoreCoachData(reader: reader, settings: settings, now: now)
        await coach.load()
        let cardio = await coach.cardioRoomToday()
        let brief = await coach.trainingLoadBrief()
        let mood = await coach.moodSeries(days: 30)
        XCTAssertNil(cardio)
        XCTAssertTrue(brief.hasPrefix("TRAINING LOAD"), brief)
        XCTAssertEqual(mood.map(\.value), [4])
        let row = await coach.logWeight(kg: 81.5, at: now, note: nil, source: .manual)
        XCTAssertEqual(row?.weightKg, 81.5)
        XCTAssertEqual(row?.deviceId, WhoopStore.noopWeightSourceId)
        let weights = await coach.weightSeries(days: 2)
        XCTAssertEqual(weights.last?.value, 81.5)
        XCTAssertEqual(coach.strainProfileSex, "female")
        XCTAssertEqual(coach.cardioLoadMaxHR, Double(StrainScorer.defaultMaxHR()))
        XCTAssertEqual(coach.deviceId, "owned-strap")
        let profile = coach.coachProfile()
        XCTAssertEqual(profile.sex, "female")
        XCTAssertEqual(profile.hrZoneSet.zones.count, 5)
    }

    /// Momentum's cycle line takes the same phase words and day range as Apple's dashboards.
    func testCyclePhaseWording() {
        XCTAssertEqual(MomentumCopy.cyclePhaseTitle(.luteal), "Luteal")
        XCTAssertEqual(MomentumCopy.cycleDayRange(low: 12, high: 12), "~day 12")
        XCTAssertEqual(MomentumCopy.cycleDayRange(low: 12, high: 15), "~day 12-15")
        XCTAssertNil(MomentumCopy.cycleDayRange(low: nil, high: 15))
    }
}
