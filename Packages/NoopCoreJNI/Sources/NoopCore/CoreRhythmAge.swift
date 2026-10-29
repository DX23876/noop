import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The daily-rhythm readout on Android (parity plan 2.3): the shared `RhythmAgeSnapshot` over the core's store, with
/// its comparisons, busiest window, day sentence and step already resolved in the wearer's language.
enum CoreRhythmAge {
    struct Output: Encodable {
        var state: String
        var collectedHours: Double?
        var day: String?
        var advance: Double?
        var sdYears: Double?
        var hourly: [Double?]
        var typical: [Double]
        var movementLevel: Int?
        var contrastLevel: Int?
        var busiestStart: Int?
        var daySentence: String?
        var lever: String?
        var history: [Point]
    }
    struct Point: Encodable { var day: String; var advance: Double }

    @MainActor
    static func snapshot(reader: StoreReader, now: Date = Date()) async -> Output {
        let (snapshot, history) = await RhythmAgeSnapshot.load(repo: CoreAgeLess.Reader(reader: reader, now: now))
        var out = Output(state: "empty", hourly: [], typical: RhythmAge.typicalDay,
                         history: history.map { Point(day: $0.day, advance: $0.advance) })
        switch snapshot {
        case .empty: break
        case .collecting(let hours):
            out.state = "collecting"; out.collectedHours = hours
        case .reading(let r):
            out.state = "reading"; out.day = r.day; out.advance = r.advance; out.sdYears = r.sdYears; out.hourly = r.hourly
            out.movementLevel = index(RhythmAge.movementLevel(mesorMg: r.mesor))
            out.contrastLevel = index(RhythmAge.contrastLevel(amplitudeMg: r.amplitude))
            out.busiestStart = RhythmAge.busiestWindowStart(r.hourly)
            out.daySentence = RhythmAgeText.daySentence(r.hourly)
            out.lever = RhythmAgeText.lever(r)
        }
        return out
    }

    /// Less, like most people, more: the three steps the screen draws.
    private static func index(_ level: RhythmAge.Level) -> Int {
        switch level { case .below: return 0; case .typical: return 1; case .above: return 2 }
    }
}
