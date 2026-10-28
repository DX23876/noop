import Foundation
import WhoopStore

/// Reads journal answers without rewriting their original keys or sources. Native answers win an
/// imported duplicate, then the chosen wording and explicit alias order resolve merged questions.
public enum JournalRead {
    public static let nativeSource = "noop-journal"

    public static func normalize(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    public static func entries(reader: StoreReader, from: String, to: String,
                               aliases: [String: String], aliasOrder: [String: Int]) async -> [JournalEntry] {
        var imported: [JournalEntry] = []
        for id in reader.importedReadIds {
            imported += (try? await reader.store.journalEntries(deviceId: id, from: from, to: to)) ?? []
        }
        let native = (try? await reader.store.journalEntries(deviceId: nativeSource, from: from, to: to)) ?? []
        return fold(imported: imported, native: native, aliases: aliases, aliasOrder: aliasOrder)
    }

    public static func fold(imported: [JournalEntry],
                     native: [JournalEntry],
                     aliases: [String: String],
                     aliasOrder: [String: Int] = [:]) -> [JournalEntry] {
        // An untouched catalog must behave exactly as before, through the very same function every
        // other read has always used.
        guard !aliases.isEmpty else {
            return unaliased(imported: imported, native: native)
        }

        var best: [String: (entry: JournalEntry, rank: (Int, Int, Int))] = [:]
        for (isNative, list) in [(false, imported), (true, native)] {
            for (index, entry) in list.enumerated() {
                let key = normalize(entry.question)
                let target = aliases[key]
                let question = target ?? entry.question
                // Bucketing on the VERBATIM resolved question, not its normalised form: a row that no
                // alias touches must land exactly where `mergeJournal` puts it today, so this only ever
                // merges what the user explicitly merged.
                let bucket = entry.day + "\u{1F}" + question
                // Negative index so that, all else equal, the LAST row wins — `mergeJournal`'s
                // last-write-wins within a list (two imported source ids can carry the same day and
                // question), preserved.
                let aliasRank = aliasOrder[key].map { $0 + 1 } ?? Int.max - 1
                let rank = (isNative ? 0 : 1,
                            target == nil ? 0 : aliasRank,
                            -index)
                if let existing = best[bucket], existing.rank <= rank { continue }
                let folded = target == nil ? entry : JournalEntry(day: entry.day,
                                                                  question: question,
                                                                  answeredYes: entry.answeredYes,
                                                                  notes: entry.notes,
                                                                  numericValue: entry.numericValue)
                best[bucket] = (folded, rank)
            }
        }
        return best.values.map(\.entry).sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }

    public static func foldDay<V>(_ values: [String: V],
                           aliases: [String: String],
                           aliasOrder: [String: Int] = [:]) -> [String: V] {
        guard !aliases.isEmpty else { return values }
        var out: [String: V] = [:]
        var rank: [String: Int] = [:]
        for (question, value) in values.sorted(by: { $0.key < $1.key }) {
            let key = normalize(question)
            let target = aliases[key]
            let resolved = target ?? question
            let candidate = target == nil ? 0 : aliasOrder[key].map { $0 + 1 } ?? Int.max - 1
            if let held = rank[resolved], held <= candidate { continue }
            out[resolved] = value
            rank[resolved] = candidate
        }
        return out
    }

    public static func writeTarget(_ question: String, aliases: [String: String]) -> String {
        aliases[normalize(question)] ?? question
    }

    private static func unaliased(imported: [JournalEntry], native: [JournalEntry]) -> [JournalEntry] {
        var byKey: [String: JournalEntry] = [:]
        for e in imported { byKey[e.day + "\u{1F}" + e.question] = e }
        for e in native { byKey[e.day + "\u{1F}" + e.question] = e }
        return byKey.values.sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }
}
