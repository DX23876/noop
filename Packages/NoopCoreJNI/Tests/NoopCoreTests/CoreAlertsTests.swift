import Foundation
import XCTest
import StrandAnalytics
@testable import NoopCore

/// The alert settings on Android ask the shared code for the Training Load alert's once-per-high-phase decision and
/// the heart-rate ceiling's buzz decision, so both phones notify and buzz by the rules the iPhone runs.
final class CoreAlertsTests: XCTestCase {

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    private func ask(_ op: String, _ args: [String: Any]) async -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
        return object(await CoreCall.run(op, String(decoding: data, as: UTF8.self)))
    }

    func testTheTrainingLoadAlertPostsOncePerHighPhaseAndTracksItWhileOff() async {
        let lanes: [[String: Any]] = [["kind": "strength", "band": "muchHigher", "episodeOpen": false],
                                      ["kind": "cardio", "band": "usual", "episodeOpen": true]]
        let on = await ask("alerts.trainingLoad", ["enabled": true, "lanes": lanes])
        let first = (on["lanes"] as? [[String: Any]]) ?? []
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0]["kind"] as? String, "strength")
        XCTAssertEqual(first[0]["notify"] as? Bool, true)
        XCTAssertEqual(first[0]["episodeOpen"] as? Bool, true)
        XCTAssertEqual(first[1]["notify"] as? Bool, false)
        XCTAssertEqual(first[1]["episodeOpen"] as? Bool, false, "a lane back within its usual closes the episode")

        // The same high lane again: the episode is open, so nothing more is posted.
        let again = await ask("alerts.trainingLoad", ["enabled": true, "lanes": [["kind": "strength", "band": "muchHigher", "episodeOpen": true]]])
        XCTAssertEqual(((again["lanes"] as? [[String: Any]]) ?? []).first?["notify"] as? Bool, false)

        // Off: silent, but the phase is kept, so switching on mid-phase posts nothing for a week already under way.
        let off = await ask("alerts.trainingLoad", ["enabled": false, "lanes": [["kind": "strength", "band": "muchHigher", "episodeOpen": false]]])
        let row = ((off["lanes"] as? [[String: Any]]) ?? []).first
        XCTAssertEqual(row?["notify"] as? Bool, false)
        XCTAssertEqual(row?["episodeOpen"] as? Bool, true)
    }

    func testTheCeilingIsAProfileZoneEdgeOrAFixedValue() async {
        let bands = [110.0, 125, 140, 155, 170]
        // Zone 4 allowed: the alert boundary is the start of Zone 5.
        let zone = await ask("alerts.hrCeiling", ["mode": "zone", "allowedZone": 4, "zoneLowerBpm": bands, "maxHR": 190])
        XCTAssertEqual(zone["ceiling"] as? Double, 170)
        XCTAssertEqual(zone["displayBpm"] as? Int, 170)
        // Zone 2 allowed: the start of Zone 3.
        let two = await ask("alerts.hrCeiling", ["mode": "zone", "allowedZone": 2, "zoneLowerBpm": bands, "maxHR": 190])
        XCTAssertEqual(two["ceiling"] as? Double, 140)
        // A fractional edge first admits the next whole beat.
        let fractional = await ask("alerts.hrCeiling", ["mode": "zone", "allowedZone": 4, "zoneLowerBpm": [100.0, 120, 140, 160, 142.4], "maxHR": 190])
        XCTAssertEqual(fractional["displayBpm"] as? Int, 143)
        // A fixed value ignores the zones and stays inside 40 to 220.
        let fixed = await ask("alerts.hrCeiling", ["mode": "bpm", "fixedBpm": 150])
        XCTAssertEqual(fixed["ceiling"] as? Double, 150)
        let high = await ask("alerts.hrCeiling", ["mode": "bpm", "fixedBpm": 400])
        XCTAssertEqual(high["ceiling"] as? Double, 220)
        // No zones and no fixed value: nothing to resolve.
        let none = await ask("alerts.hrCeiling", ["mode": "zone", "allowedZone": 4])
        XCTAssertNil(none["ceiling"])
    }

    /// Feeds one trace through the call, carrying the state as Kotlin does, and through the engine directly.
    func testTheCallRunsTheSameEngineAsTheApp() async {
        let trace: [(Int, Int?)] = [(0, 140), (1, 150), (2, 151), (3, 152), (63, 152), (64, 150), (65, 140), (70, 140), (81, 140), (82, 140)]
        var engine = HRCeilingAlertEngine()
        var state: [String: Any]?
        for (t, bpm) in trace {
            var args: [String: Any] = ["mode": "bpm", "fixedBpm": 150, "gate": true, "now": t, "reminderMode": "standard"]
            if let bpm { args["bpm"] = bpm }
            if let state { args["state"] = state }
            let answer = await ask("alerts.hrCeiling", args)
            let expected = engine.update(now: t, bpm: bpm, ceilingBPM: 150, enabled: true)
            let name = expected.map { $0 == .warning ? "warning" : "recovered" }
            XCTAssertEqual(answer["cue"] as? String, name, "at t=\(t)")
            XCTAssertEqual(answer["loops"] as? Int, expected == nil ? 0 : (expected == .warning ? 3 : 1))
            XCTAssertEqual(answer["episodeActive"] as? Bool, engine.episodeActive)
            state = answer["state"] as? [String: Any]
        }
    }

    func testAChangedCeilingOrGateStartsAFreshEpisode() async {
        var args: [String: Any] = ["mode": "bpm", "fixedBpm": 150, "gate": true, "now": 0, "bpm": 160, "reminderMode": "standard"]
        let first = await ask("alerts.hrCeiling", args)
        XCTAssertEqual(first["cue"] as? String, "warning")
        // The wearer lifts the ceiling to 170 while above 160: the old episode must not carry over.
        args["fixedBpm"] = 170; args["now"] = 1; args["state"] = first["state"]
        let lifted = await ask("alerts.hrCeiling", args)
        XCTAssertNil(lifted["cue"])
        XCTAssertEqual(lifted["episodeActive"] as? Bool, false)
        // Every two seconds buzzes once per warning.
        let quick = await ask("alerts.hrCeiling", ["mode": "bpm", "fixedBpm": 150, "gate": true, "now": 0, "bpm": 160, "reminderMode": "everyTwoSeconds"])
        XCTAssertEqual(quick["loops"] as? Int, 1)
        // A closed gate is silent and leaves no episode.
        let closed = await ask("alerts.hrCeiling", ["mode": "bpm", "fixedBpm": 150, "gate": false, "now": 0, "bpm": 200])
        XCTAssertNil(closed["cue"])
        XCTAssertEqual(closed["episodeActive"] as? Bool, false)
    }
}
