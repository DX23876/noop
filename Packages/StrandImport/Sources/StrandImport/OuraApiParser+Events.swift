import Foundation

public extension OuraApiParser {

    /// Parse `workout` documents → `OuraWorkout`. Rows without a valid time span are skipped.
    static func parseWorkouts(_ docs: [[String: Any]]) -> [OuraWorkout] {
        var out: [OuraWorkout] = []
        for w in docs {
            guard let start = WhoopTime.parseISOWithOffset(WearableJSON.str(w, "start_datetime")),
                  let end = WhoopTime.parseISOWithOffset(WearableJSON.str(w, "end_datetime")),
                  end > start else { continue }
            out.append(OuraWorkout(
                start: start, end: end,
                activity: WearableJSON.str(w, "activity") ?? "workout",
                source: WearableJSON.str(w, "source") ?? "oura",
                energyKcal: WearableJSON.posDbl(w, "calories"),
                distanceM: WearableJSON.posDbl(w, "distance")))
        }
        return out
    }

    /// Parse a `/v2/usercollection/heartrate` page's `data[]` → HR points. Each row is
    /// {timestamp, bpm, source}; non-positive bpm is dropped. (The `source` enum is preserved in the raw
    /// archive, not in the compact hrSample.)
    static func parseHeartRate(_ docs: [[String: Any]]) -> [OuraHRPoint] {
        var out: [OuraHRPoint] = []
        for h in docs {
            guard let ts = WhoopTime.parseISOWithOffset(WearableJSON.str(h, "timestamp")),
                  let bpm = WearableJSON.posInt(h, "bpm") else { continue }
            out.append(OuraHRPoint(ts: Int(ts.timeIntervalSince1970), bpm: bpm))
        }
        return out
    }
}
