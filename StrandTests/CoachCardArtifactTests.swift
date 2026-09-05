import XCTest
import WhoopStore
@testable import Strand

/// Pins the card artifact — the second thing the coach can put in the transcript besides text.
///
/// The property worth defending is the division of labour: **the model chooses which card, the app
/// supplies every number.** A card is read as a measurement, so a figure on one that came from a
/// language model summarising a tool result would be exactly the kind of confident-looking invention
/// this app refuses to display. These tests hold that a card's values come from the same resolver the
/// chart uses, and that an absent value produces no card rather than a card reading zero.
@MainActor
final class CoachCardArtifactTests: XCTestCase {

    private func engine(days: [DailyMetric] = []) -> AICoachEngine {
        let repo = Repository(deviceId: "card-artifact-\(UUID().uuidString)")
        repo.days = days
        return AICoachEngine(repo: repo)
    }

    private func day(_ key: String, recovery: Double? = nil, hrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv,
                    recovery: recovery, strain: nil, exerciseCount: nil, spo2Pct: nil,
                    skinTempDevC: nil, respRateBpm: nil, steps: nil, activeKcalEst: nil,
                    spo2Red: nil, spo2Ir: nil, avgSdnn: nil)
    }

    private func fortnight(_ values: [Double]) -> [DailyMetric] {
        values.enumerated().map { index, value in
            day(String(format: "2026-09-%02d", index + 1), recovery: value)
        }
    }

    // MARK: - The numbers come from the app

    /// The headline is the latest value, formatted by the app's own rule for that metric — not a
    /// string the model passed in. `show_card` has no parameter that could carry a number at all.
    func testTheHeadlineIsTheUsersLatestValue() async throws {
        let coach = engine(days: fortnight([60, 62, 58, 64, 61, 63, 59, 65, 62, 71]))
        let built = await coach.metricCardArtifact(metric: "charge")
        let card = try XCTUnwrap(built)
        XCTAssertEqual(card.value, "71")
        XCTAssertEqual(card.kind, .metric)
        XCTAssertEqual(card.tintName, "charge", "a Charge card reads green, like everywhere else")
    }

    /// The caption compares against the user's OWN trailing average, never a population range. NOOP has
    /// no evidence about what is normal for people in general, and stating one as if it did is the
    /// whole failure mode this app avoids.
    func testTheCaptionComparesAgainstTheirOwnAverage() async throws {
        let coach = engine(days: fortnight([60, 60, 60, 60, 60, 60, 60, 60, 60, 80]))
        let built = await coach.metricCardArtifact(metric: "charge")
        let card = try XCTUnwrap(built)
        let caption = try XCTUnwrap(card.caption)
        XCTAssertTrue(caption.contains("average"), caption)
        XCTAssertTrue(caption.lowercased().contains("above"), caption)
    }

    /// A value in line with the average says so, rather than calling a one-point difference a rise.
    func testAFlatValueIsDescribedAsInLineNotAsAChange() async throws {
        let coach = engine(days: fortnight([60, 61, 60, 59, 60, 61, 60, 59, 60, 60]))
        let built = await coach.metricCardArtifact(metric: "charge")
        let card = try XCTUnwrap(built)
        let caption = try XCTUnwrap(card.caption)
        XCTAssertTrue(caption.lowercased().contains("in line with"), caption)
    }

    /// Too little history means no comparison is offered — rather than one drawn from three days and
    /// presented with the same confidence as one drawn from thirty.
    func testThinHistoryOmitsTheComparison() async throws {
        let coach = engine(days: fortnight([60, 62, 58]))
        let built = await coach.metricCardArtifact(metric: "charge")
        let card = try XCTUnwrap(built)
        XCTAssertNil(card.caption)
        XCTAssertTrue(card.rows.contains { $0.label.contains("Days") },
                      "the reader still has to be able to see how thin it is")
    }

    /// No data produces NO CARD. A card is read as a measurement; an empty one reading "0" or "—" would
    /// be a measurement claim about a day nobody wore the strap.
    func testNoDataProducesNoCard() async {
        let coach = engine(days: [])
        let card = await coach.metricCardArtifact(metric: "charge")
        XCTAssertNil(card)
    }

    /// A metric key the user has no data for likewise produces nothing, and the tool says so in words.
    func testAnUnknownMetricIsReportedInWordsRatherThanShown() async {
        let coach = engine(days: fortnight([60, 61, 62]))
        let reply = await coach.handleShowCard(kind: "metric", metric: "not_a_metric",
                                               workoutStart: nil)
        XCTAssertTrue(reply.contains("No data"), reply)
        XCTAssertTrue(coach.pendingCards.isEmpty, "nothing may be queued for a metric with no data")
    }

    /// A successful call queues exactly one card and hands the model a confirmation it can refer to —
    /// the same contract `plot_metric` has.
    func testASuccessfulCallQueuesOneCard() async {
        let coach = engine(days: fortnight([60, 62, 58, 64, 61, 63, 59, 65, 62, 71]))
        let reply = await coach.handleShowCard(kind: "metric", metric: "charge", workoutStart: nil)
        XCTAssertEqual(coach.pendingCards.count, 1)
        XCTAssertTrue(reply.contains("71"), "the model needs to know what the user is looking at: \(reply)")
    }

    // MARK: - Units follow the metric

    /// Each metric formats with its own unit, taken from the same table the chart uses — so a card and
    /// a chart of the same metric can never disagree about what the number means.
    func testUnitsFollowTheMetric() async throws {
        let days = (1...10).map { i in
            day(String(format: "2026-09-%02d", i), hrv: 55 + Double(i))
        }
        let coach = engine(days: days)
        let built = await coach.metricCardArtifact(metric: "hrv")
        let card = try XCTUnwrap(built)
        XCTAssertTrue(card.value.hasSuffix("ms"), card.value)
    }

    // MARK: - Persistence

    /// A card survives a relaunch through its snapshot, unchanged. The tint travels as a name because a
    /// SwiftUI `Color` has no business being persisted.
    func testASnapshotRoundTripsTheCard() {
        let art = CoachCardArtifact(kind: .workout, title: "Push Day", value: "Sep 4, 18:00",
                                    caption: nil,
                                    rows: [.init(label: "Working sets", value: "14 · 5 exercises"),
                                           .init(label: "Volume", value: "8,400 kg")],
                                    tintName: "effort")
        let restored = CoachCardSnapshot(art).artifact
        XCTAssertEqual(restored, art)
    }

    /// An unknown kind from a future build decodes to something renderable rather than failing the
    /// whole transcript load — the same tolerance every other stored enum in this app has.
    func testAnUnknownStoredKindStillRenders() throws {
        let json = #"{"kind":"something_new","title":"X","value":"1","rows":[],"tintName":"accent"}"#
        let snap = try JSONDecoder().decode(CoachCardSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.artifact.kind, .metric)
    }

    /// A transcript written before cards existed still loads — the field decodes with a default, like
    /// `charts` before it.
    func testAConversationWithoutCardsStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","createdAt":0,"updatedAt":0,"messages":[]}
        """
        let convo = try JSONDecoder().decode(CoachConversation.self, from: Data(json.utf8))
        XCTAssertTrue(convo.cards.isEmpty)
    }
}
