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

    /// Lanes the core cannot read yet answer nothing, and the profile feeds the cardio pricing inputs.
    func testUnreadLanesAnswerNothing() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        let coach = CoreCoachData(reader: reader, settings: settings, now: now)
        let cardio = await coach.cardioRoomToday()
        let brief = await coach.trainingLoadBrief()
        let mood = await coach.moodSeries(days: 30)
        XCTAssertNil(cardio)
        XCTAssertEqual(brief, "")
        XCTAssertTrue(mood.isEmpty)
        XCTAssertEqual(coach.strainProfileSex, "female")
        XCTAssertEqual(coach.cardioLoadMaxHR, Double(StrainScorer.defaultMaxHR()))
        XCTAssertEqual(coach.deviceId, "owned-strap")
        let profile = coach.coachProfile()
        XCTAssertEqual(profile.sex, "female")
        XCTAssertEqual(profile.hrZoneSet.zones.count, 5)
    }
}
