import Foundation
import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// Android's `training.guidance` reads the same snapshot as the iPhone (Training Load plan, phase 2).
@MainActor
final class CoreTrainingGuidanceTests: XCTestCase {
    private struct Out: Decodable {
        struct Advice: Decodable { var stance: String; var reason: String; var state: String; var effortLow: Double? }
        struct Offer: Decodable { var kind: String; var minutes: Int? }
        struct Focus: Decodable { var focus: String; var source: String }
        struct Week: Decodable { var targetLow: Int; var complete: Bool; var minutes: Int }
        var advice: Advice
        var offers: [Offer]
        var cardioFocus: Focus
        var weeks: [Week]
    }

    private func read(_ args: [String: Any], store: WhoopStore) async throws -> Out {
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let json = CoreRead.json(await CoreTrainingGuidance.read(args, store: store, reader: reader))
        return try JSONDecoder().decode(Out.self, from: Data(json.utf8))
    }

    func testANewWearerGetsTheGuidelineAndAStartingWalk() async throws {
        let store = try await WhoopStore.inMemory()
        let out = try await read(["maxHR": 190, "sex": "male"], store: store)
        XCTAssertEqual(out.cardioFocus.focus, "health")
        XCTAssertEqual(out.weeks.count, TrainingGuidanceReader.weeksRead)
        XCTAssertEqual(out.weeks.first?.targetLow, 150)
        XCTAssertEqual(out.weeks.last?.complete, false, "the running week is not complete")
        XCTAssertNotEqual(out.advice.stance, "push", "no night measured never pushes")
        XCTAssertEqual(out.offers.first?.kind, "startWalk")
        XCTAssertEqual(out.offers.first?.minutes, 30)
    }

    func testADietPlanToLoseWeightRaisesTheTarget() async throws {
        let store = try await WhoopStore.inMemory()
        let plan = DietPlan(goal: .lose, pacePercent: 0.5, form: .balanced, goalWeightKg: 90, startDay: "2026-09-01",
                            startWeightKg: 100)
        let out = try await read(["maxHR": 190, "sex": "male", "plan": plan.encoded()!], store: store)
        XCTAssertEqual(out.cardioFocus.focus, "loseWeight")
        XCTAssertEqual(out.cardioFocus.source, "dietPlan")
        XCTAssertEqual(out.weeks.first?.targetLow, 250)
    }

    /// Q17, Q27: a hard planned session on a held-back day can be moved to tomorrow; on a steady day it stays.
    func testAHardPlanOnAnEasyDayIsOfferedToMove() {
        var o = TrainingGuidanceReader.Options(maxHR: 190, sex: "male")
        o.plannedProposalId = UUID()
        o.plannedTitle = "Intervals"
        o.plannedHard = true
        let easy = MorningAdvice.resolve(.init(charge: 20, night: .scored, plannedToday: true))
        XCTAssertEqual(TrainingGuidanceReader.movable(options: o, advice: easy, today: "2026-11-28")?.tomorrow, "2026-11-29")
        let steady = MorningAdvice.resolve(.init(charge: 80, night: .scored, plannedToday: true))
        XCTAssertNil(TrainingGuidanceReader.movable(options: o, advice: steady, today: "2026-11-28"))
    }

    func testTheActiveMinutesSeriesFillsTheWeek() async throws {
        let store = try await WhoopStore.inMemory()
        let today = StoreReader.localDayKey(Date())
        let keys = ActiveMinutesDay.seriesKeys
        _ = try await store.upsertMetricSeries([MetricPoint(day: today, key: keys.everydayModerate, value: 20),
                                                MetricPoint(day: today, key: keys.sessionVigorous, value: 10)],
                                               deviceId: StoreReader.computedReadIds(activeDeviceId: "my-whoop").first!)
        let out = try await read(["maxHR": 190, "sex": "male"], store: store)
        XCTAssertEqual(out.weeks.last?.minutes, 40, "vigorous minutes count double")
    }
}
