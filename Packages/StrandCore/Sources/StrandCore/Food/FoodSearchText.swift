import Foundation

/// The one text normalisation the food search uses, for the index and for the query alike, so a word typed
/// matches the word stored on both platforms. Deliberately not `folding(options:)`: Foundation on Android is
/// not guaranteed to fold the same way, and a fold table written out here is.
public enum FoodSearchText {
    /// Shortest token kept. One letter matches too much to be a useful search.
    public static let minTokenLength = 2
    /// Shortest compound tail indexed ("brot" in "vollkornbrot").
    public static let minSuffixLength = 4

    /// Lower case, accents removed, ß as ss, everything that is not a letter or digit a separator.
    public static func normalised(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.lowercased().unicodeScalars {
            if let folded = fold[scalar] {
                out += folded
            } else if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += " "
            }
        }
        return out
    }

    /// The words of a text, in order, duplicates removed.
    public static func tokens(_ text: String) -> [String] {
        var seen = Set<String>()
        return normalised(text).split(separator: " ").map(String.init).filter {
            $0.count >= minTokenLength && seen.insert($0).inserted
        }
    }

    /// Neighbouring words written together ("hafer flocken" also as "haferflocken"), because a catalogue may
    /// spell a compound apart that the wearer types as one word, or the other way round.
    public static func joinedPairs(_ text: String) -> [String] {
        let words = normalised(text).split(separator: " ").map(String.init).filter { $0.count >= minTokenLength }
        guard words.count > 1 else { return [] }
        return (0..<(words.count - 1)).map { words[$0] + words[$0 + 1] }
    }

    /// The tails of a word worth indexing for compounds, longest first, the word itself excluded.
    public static func suffixes(_ token: String) -> [String] {
        let chars = Array(token)
        guard chars.count > minSuffixLength else { return [] }
        return (1...(chars.count - minSuffixLength)).map { String(chars[$0...]) }
    }

    /// Latin letters with marks, to their base letters. Covers the languages Open Food Facts has most
    /// products in; any other letter is kept as it is.
    static let fold: [Unicode.Scalar: String] = {
        let pairs: [(String, String)] = [
            ("àáâãäåāăą", "a"), ("æ", "ae"), ("çćĉċč", "c"), ("ďđ", "d"), ("èéêëēĕėęě", "e"),
            ("ĝğġģ", "g"), ("ĥħ", "h"), ("ìíîïĩīĭįı", "i"), ("ĵ", "j"), ("ķ", "k"), ("ĺļľŀł", "l"),
            ("ñńņňŉ", "n"), ("òóôõöøōŏő", "o"), ("œ", "oe"), ("ŕŗř", "r"), ("śŝşšș", "s"), ("ß", "ss"),
            ("ţťŧț", "t"), ("ùúûüũūŭůűų", "u"), ("ŵ", "w"), ("ýÿŷ", "y"), ("źżž", "z"), ("þ", "th"), ("ð", "d"),
        ]
        var table: [Unicode.Scalar: String] = [:]
        for (letters, base) in pairs {
            for scalar in letters.unicodeScalars { table[scalar] = base }
        }
        return table
    }()
}
