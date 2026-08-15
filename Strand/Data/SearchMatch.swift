import Foundation

/// The one text matcher behind every in-app index search (the More tab's row index, the Settings
/// section filter). Pure and locale-aware, so it can be unit-tested with no app, no strap and no view.
///
/// Matching rules, chosen for how people actually type into a filter field:
/// - **Case- and diacritic-insensitive.** A German user typing "warmemessung" has to find
///   "Wärmemessung", and someone typing "hrv" has to find "HRV".
/// - **Every query word must land somewhere.** "live activity" matches an entry whose title carries
///   "Live" and whose keywords carry "Activity"; it does NOT match an entry that only has "Live".
///   Narrowing by adding a word is the behaviour a filter field trains people to expect.
/// - **Substring, not prefix.** Half-remembered middles ("cover" → "Recovery") still land.
///
/// Deliberately NOT fuzzy: no edit distance, no ranking. An index of a few dozen rows is small enough
/// that a wrong-but-close match is more confusing than an empty result, and an unranked list keeps the
/// section order the user already learned.
enum SearchMatch {

    /// Case- and diacritic-folded form used on BOTH sides of every comparison.
    ///
    /// `.current` is right here rather than a fixed locale: this folds text the user reads in their
    /// own language, and Turkish dotted/dotless i is exactly the case where folding under the wrong
    /// locale quietly stops matching.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Split a raw query field into the words that must each find a home. Empty when the user has
    /// typed nothing but whitespace — callers treat that as "no search", not as "no results".
    static func tokens(_ query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// True when every word of `query` appears in at least one of `haystack`'s entries.
    ///
    /// An empty (or whitespace-only) query matches everything, so a caller can pass the field's raw
    /// text straight through without special-casing the resting state.
    static func matches(query: String, in haystack: [String]) -> Bool {
        let needles = tokens(query)
        guard !needles.isEmpty else { return true }
        let hay = haystack.map(normalize)
        return needles.allSatisfy { needle in
            hay.contains { $0.contains(needle) }
        }
    }
}
