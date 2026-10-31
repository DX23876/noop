import Foundation
import WhoopStore
import StrandCore

// The localized side of `WorkoutSource` (StrandCore): sport names in the wearer's language. Kept in the app so the
// string catalogue keeps extracting them.
extension WorkoutSource {
    /// Sport-cell text. The detector stores the machine token "detected"; show it as a neutral
    /// "Activity" (we don't claim a sport we didn't actually classify). WHOOP sport names arrive as
    /// concatenated camelCase (e.g. "TraditionalStrengthTraining"), which reads as one long
    /// unbreakable word and truncates badly — split it into words on the lower→Upper boundary so it
    /// renders "Traditional Strength Training". Already-spaced labels (manual/edited) pass through. (#175)
    static func displaySport(_ sport: String) -> String {
        if sport == "detected" { return String(localized: "Activity") }
        return splitCamelCase(sport)
    }

    /// Localized display for stable system/import labels. Unknown and user-entered names pass through
    /// unchanged so presentation can never rewrite a locale-stable stored sport.
    static func localizedDisplaySport(_ sport: String) -> String {
        let display = displaySport(sport)
        switch display.lowercased() {
        // Its own key: the bare "Running" is the state word ("Läuft") on timers and goals.
        case "running":                     return String(localized: "sport.running", defaultValue: "Running")
        case "walking":                     return String(localized: "Walking")
        case "hiking":                      return String(localized: "Hiking")
        case "cycling":                     return String(localized: "Cycling")
        case "open-water swim":             return String(localized: "Open-water swim")
        case "rowing":                      return String(localized: "Rowing")
        case "treadmill run":               return String(localized: "Treadmill run")
        case "treadmill walk":              return String(localized: "Treadmill walk")
        case "indoor cycle":                return String(localized: "Indoor cycle")
        case "pool swim":                   return String(localized: "Pool swim")
        case "row machine":                 return String(localized: "Row machine")
        case "elliptical":                  return String(localized: "Elliptical")
        case "hiit":                        return String(localized: "HIIT")
        case "yoga":                        return String(localized: "Yoga")
        case "functional strength training": return String(localized: "Functional strength training")
        case "strength training":            return String(localized: "Strength Training")
        case "strength":                     return String(localized: "Strength")
        // The rest of the catalogue under its own `sport.<name>` keys: a bare "Football" or "Polo" key could
        // collide with UI copy that means something else. An unknown or user-typed name passes through.
        default:
            return Bundle.main.localizedString(forKey: "sport." + display.lowercased(), value: display, table: nil)
        }
    }
}

/// One workout-list filter state. `sport` is a displayed-sport key (`WorkoutSource.displaySport`), nil =
/// all sports. `sourceClass` is the origin class, nil = all sources. `search` is a free-text query over
/// the displayed sport name (trimmed, case-insensitive; empty = no search).
struct WorkoutFilter: Equatable {
    var sport: String?
    var sourceClass: WorkoutSource?
    var search: String

    init(sport: String? = nil, sourceClass: WorkoutSource? = nil, search: String = "") {
        self.sport = sport
        self.sourceClass = sourceClass
        self.search = search
    }

    /// True when no facet is active — the caller can skip the walk and keep the input verbatim.
    var isActive: Bool {
        sport != nil || sourceClass != nil
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The class a row is filed under in the source filter: a confirmed suggestion carries the Detected
    /// badge, so it is found under Detected rather than as an option of its own.
    static func filterClass(_ source: WorkoutSource) -> WorkoutSource {
        source == .confirmed ? .detected : source
    }

    /// Does one row pass every active facet? Sport matches on the DISPLAYED name (so "detected" folds to
    /// "Activity", camelCase splits) exactly as the picker lists it; source matches on `classify`; search
    /// is a case-insensitive substring of the displayed sport.
    func matches(_ row: WorkoutRow) -> Bool {
        if let sport, WorkoutSource.displaySport(row.sport) != sport { return false }
        if let sourceClass, Self.filterClass(WorkoutSource.classify(row.source)) != sourceClass { return false }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty,
           WorkoutSource.displaySport(row.sport).range(of: q, options: .caseInsensitive) == nil {
            return false
        }
        return true
    }

    /// Apply the filter to a windowed list, preserving order. A no-op when nothing is active.
    func apply(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        guard isActive else { return rows }
        return rows.filter(matches)
    }
}

// MARK: - Merge (#64)
//
// Merge two or more overlapping / adjacent MANUAL or DETECTED sessions into one, keeping the richer
// captured signals. Imported history (whoop / apple / lifting / activityFile) is read-only and is NEVER
// merged — the eligibility gate below enforces it, and the persistence path (Repository.mergeWorkouts)
// only ever writes through the manual-row path. Pure + deterministic so both platforms and the unit test
// share one rule; the persistence sequence lives in the repository.

enum WorkoutMerge {

    /// Only MANUAL and DETECTED rows can be merged (imported history stays read-only). A merge needs at
    /// least two eligible rows.
    static func isMergeable(_ row: WorkoutRow) -> Bool {
        switch WorkoutSource.classify(row.source) {
        case .manual, .confirmed, .detected: return true
        case .whoop, .apple, .lifting, .activityFile, .hevy, .oura: return false
        }
    }

    /// True when a set of selected rows can be merged: two or more, and every one is mergeable.
    static func canMerge(_ rows: [WorkoutRow]) -> Bool {
        rows.count >= 2 && rows.allSatisfy(isMergeable)
    }

    /// The sport the merge should carry: the most-frequent non-"detected" sport across the inputs (ties
    /// broken by first appearance), or nil when every input is a bare detected bout — then the caller
    /// asks the user to pick one. "detected"/"Activity" never wins so a merge with any real label keeps it.
    static func resolvedSport(_ rows: [WorkoutRow]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for r in rows where r.sport != "detected" {
            let s = r.sport
            if counts[s] == nil { order.append(s) }
            counts[s, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        // Stable: highest count, ties resolved by first appearance (order index).
        return order.max(by: { (counts[$0] ?? 0, order.firstIndex(of: $1) ?? 0)
                                < (counts[$1] ?? 0, order.firstIndex(of: $0) ?? 0) })
    }

    /// Merge the given rows into one manual row. `sport` overrides the resolved sport (used when the
    /// inputs are all detected and the user picked one); when nil the resolved sport is used, falling back
    /// to "Activity" only if there is genuinely no label. Returns nil for fewer than two rows.
    ///
    /// Math (per the #64 brief): startTs = min, endTs = max (the honest span); durationS = SUM of the
    /// per-session durations (honest active time, NOT the span); energyKcal = SUM; avgHr = duration-
    /// weighted mean of the sessions that carry one; maxHr = max; distanceM = SUM; strain = nil (the repo
    /// rescores it from the strap HR via analyzeRecent, the #598 pattern); zonesJSON = nil; notes = joined.
    static func merge(_ rows: [WorkoutRow], sport: String? = nil) -> WorkoutRow? {
        guard rows.count >= 2 else { return nil }
        let start = rows.map(\.startTs).min() ?? rows[0].startTs
        let end = rows.map(\.endTs).max() ?? rows[0].endTs

        // Duration = sum of each session's active duration (fall back to its own span when nil).
        let durationS = rows.reduce(0.0) { $0 + ($1.durationS ?? Double(max(0, $1.endTs - $1.startTs))) }

        // Energy + distance + steps sum only the present values; nil when NOTHING carried one (never a
        // fake 0). #1444: steps is cumulative per session exactly like distance, so a merge sums it too —
        // it was silently dropped here until making the field explicit forced the question.
        let kcals = rows.compactMap(\.energyKcal)
        let energyKcal = kcals.isEmpty ? nil : kcals.reduce(0, +)
        let dists = rows.compactMap(\.distanceM)
        let distanceM = dists.isEmpty ? nil : dists.reduce(0, +)
        let stepCounts = rows.compactMap(\.steps)
        let mergedSteps = stepCounts.isEmpty ? nil : stepCounts.reduce(0, +)

        // Avg HR = duration-weighted mean over the rows that HAVE an avg; weight = that row's duration
        // (fall back to its span). maxHr = the max present peak. Both nil when no row carried the field.
        var hrWeight = 0.0, hrSum = 0.0
        for r in rows {
            guard let hr = r.avgHr else { continue }
            let w = r.durationS ?? Double(max(1, r.endTs - r.startTs))
            hrWeight += w
            hrSum += Double(hr) * w
        }
        let avgHr = hrWeight > 0 ? Int((hrSum / hrWeight).rounded()) : nil
        let maxHrs = rows.compactMap(\.maxHr)
        let maxHr = maxHrs.max()

        // Notes = the non-empty notes joined (order-stable), nil when none.
        let notes = rows.compactMap { $0.notes?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let mergedNotes = notes.isEmpty ? nil : notes.joined(separator: " · ")

        let mergedSport = sport ?? resolvedSport(rows) ?? "Activity"

        return WorkoutRow(startTs: start, endTs: end, sport: mergedSport, source: "manual",
                          durationS: durationS, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr,
                          strain: nil, distanceM: distanceM, zonesJSON: nil, notes: mergedNotes,
                          steps: mergedSteps)
    }
}
