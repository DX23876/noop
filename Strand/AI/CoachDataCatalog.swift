import Foundation
import WhoopStore

/// Presentation boundary for locally discovered metric series. It intentionally exposes only coverage
/// metadata, and turns opaque local source identifiers into generic labels before a provider can see it.
struct CoachDataCatalog {
    /// A consent-filtered, content-free local store summary. Its text is deliberately authored by the
    /// app, not copied from a user entry, so catalog discovery never becomes a hidden second log reader.
    struct Area: Equatable {
        let name: String
        let summary: String
    }

    /// A query narrows discovery *on-device* before any catalog metadata reaches a provider. It is not a
    /// semantic model or a diagnosis engine: it is a small transparent vocabulary of metric aliases.
    /// An omitted query is deliberately the only way to request the full metadata inventory.
    static func report(entries: [MetricCatalogEntry], areas: [Area] = [], query: String? = nil, limit: Int = 80) -> String {
        guard !entries.isEmpty || !areas.isEmpty else { return "No granted local data inventory is available yet." }

        if entries.isEmpty {
            return areaReport(areas)
        }

        var byKey: [String: [MetricCatalogEntry]] = [:]
        for entry in entries { byKey[entry.key, default: []].append(entry) }
        let allKeys = byKey.keys.sorted()
        let queryText = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keys: [String]
        if queryText.isEmpty {
            keys = allKeys
        } else {
            keys = rankedKeys(allKeys, entriesByKey: byKey, query: queryText)
            guard !keys.isEmpty else {
                let noMetric = "No locally stored metric key matched that focused catalog search. "
                    + "Ask for an unfiltered catalog only if a broad inventory is genuinely needed."
                return areas.isEmpty ? noMetric : noMetric + "\n\n" + areaReport(areas)
            }
        }
        let visibleLimit = max(1, limit)
        var lines = [queryText.isEmpty
            ? "LOCAL DATA CATALOG (metadata only; no readings):"
            : "LOCAL DATA CATALOG MATCHES (metadata only; no readings):"]

        for key in keys.prefix(visibleLimit) {
            guard let series = byKey[key] else { continue }
            let earliest = series.map(\.earliestDay).min() ?? "—"
            let latest = series.map(\.latestDay).max() ?? "—"
            let count = series.reduce(0) { $0 + $1.pointCount }
            let sources = Array(Set(series.map { CoachLocalSourceLabel.label($0.source) }))
                .sorted().joined(separator: ", ")
            lines.append("  • \(key): \(count) points, \(earliest) → \(latest); sources: \(sources)")
        }
        if keys.count > visibleLimit {
            lines.append("  • \(keys.count - visibleLimit) further metric keys are available; request a likely key by name.")
        }
        if !areas.isEmpty {
            lines.append("")
            lines.append(areaReport(areas))
        }
        return lines.joined(separator: "\n")
    }

    private static func areaReport(_ areas: [Area]) -> String {
        guard !areas.isEmpty else { return "" }
        return (["OTHER GRANTED LOCAL DATA (metadata only; no entries or values):"]
                + areas.map { "  • \($0.name): \($0.summary)" })
            .joined(separator: "\n")
    }

    /// Removes Lab Book's projected series unless the separate Logs purpose is enabled. Those values are
    /// stored in the generic metric-series table for charts, but must not become core biometrics merely
    /// because the coach is querying that table.
    static func entriesVisibleToCoach(_ entries: [MetricCatalogEntry], includesLabBook: Bool) -> [MetricCatalogEntry] {
        entries.filter { CoachLocalSourceAccess.permits($0.source, includesLabBook: includesLabBook) }
    }

    /// Finds one locally stored key from explicit words in a question. This stays in-process: callers use
    /// the result to request an aggregate, never to emit the inventory that was considered.
    static func bestMatchingKey(entries: [MetricCatalogEntry], query: String) -> String? {
        let grouped = Dictionary(grouping: entries, by: \.key)
        return rankedKeys(grouped.keys.sorted(), entriesByKey: grouped, query: query).first
    }

    private static func rankedKeys(_ keys: [String], entriesByKey: [String: [MetricCatalogEntry]], query: String) -> [String] {
        let queryTerms = terms(query)
        guard !queryTerms.isEmpty else { return [] }
        return keys.compactMap { key -> (key: String, score: Int)? in
            var haystack = vocabulary(for: key)
            for source in entriesByKey[key] ?? [] { haystack.formUnion(terms(CoachLocalSourceLabel.label(source.source))) }
            let score = haystack.intersection(queryTerms).count
            return score > 0 ? (key, score) : nil
        }
        .sorted { left, right in left.score == right.score ? left.key < right.key : left.score > right.score }
        .map(\.key)
    }

    private static func vocabulary(for key: String) -> Set<String> {
        var terms = Self.terms(key.replacingOccurrences(of: "_", with: " "))
        switch key {
        case "weight", "body_weight": terms.formUnion(["weight", "gewicht", "body", "mass", "kg"])
        case "hrv": terms.formUnion(["hrv", "variability", "variabilitat", "heart", "herz"])
        case "resting_hr", "rhr": terms.formUnion(["resting", "heart", "rate", "pulse", "puls", "ruhepuls"])
        case "sleep_total_min", "asleep_min": terms.formUnion(["sleep", "schlaf", "asleep", "duration"])
        case "steps": terms.formUnion(["steps", "schritte", "walking", "walk"])
        case "spo2": terms.formUnion(["spo2", "oxygen", "sauerstoff"])
        case "ferritin": terms.formUnion(["ferritin", "iron", "eisen"])
        case "vitamin_d": terms.formUnion(["vitamin", "vitamin_d", "d"])
        case "fasting_glucose", "hba1c": terms.formUnion(["glucose", "zucker", "blood", "blut"])
        default: break
        }
        return terms
    }

    private static func terms(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 })
    }
}

/// A deliberately small allow-list. The source column may contain a device id, a filename, or an
/// importer-specific token, none of which belongs in an external model prompt.
enum CoachLocalSourceLabel {
    static func label(_ source: String) -> String {
        switch source {
        case Repository.whoopSource: return "WHOOP / NOOP"
        case Repository.appleHealthSource: return "Apple Health"
        case Repository.healthConnectSource: return "Health Connect"
        case WhoopStore.labBookSourceId: return "Lab Book"
        case WhoopStore.noopWeightSourceId: return "Weigh-ins logged in NOOP"
        case "oura-import", "oura-api": return "Oura import"
        case "garmin-import": return "Garmin import"
        case "fitbit-import": return "Fitbit import"
        default:
            // Active straps use a durable `whoop-<uuid>` identifier rather than the canonical import
            // id. It is still WHOOP data; never turn that opaque identifier into a misleading generic
            // import label in a coach provenance line.
            if source.hasPrefix("whoop-") || source.hasSuffix("-noop") { return "WHOOP / NOOP" }
            return "Another local import"
        }
    }
}

/// A single source-level privacy boundary shared by catalog discovery and long-range aggregation.
/// `lab-book` is a projection implementation detail; its visibility follows the Lab Book/Logs consent.
enum CoachLocalSourceAccess {
    static func permits(_ source: String, includesLabBook: Bool) -> Bool {
        source != WhoopStore.labBookSourceId || includesLabBook
    }
}
