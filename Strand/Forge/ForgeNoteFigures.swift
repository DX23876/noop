import Foundation

/// The guard behind "figures come from the device, words from the coach" (2026-11-07).
///
/// Timeline notes are asked to carry no figures; the device draws them under the note. When a figure gets
/// into a note anyway, it must match a value the coach actually read in the same turn (a tool output, or the
/// context text on the path without tools), after rounding to the precision it was written with. A sentence
/// holding a figure that matches nothing is struck: in real notes the coach wrote "HRV 50" over a stored 44,
/// and Effort "13.2/21" for a wearer who reads Effort from 0 to 100.
///
/// Clock times ("22:20") and dates are not checked: they are not readings. Hours and minutes are the same
/// quantity ("0.5 h" matches a source of 30).
///
/// Analysis migration required: no. It filters coach text only.
enum ForgeNoteFigures {

    struct Result: Equatable {
        let text: String
        let struck: Int
    }

    /// `text` with every sentence removed whose figures do not all match a number in `sources`.
    /// `effortOutOf100` is true when the wearer reads Effort on 0 to 100: a "/21" figure is then on the
    /// wrong scale whatever its value.
    static func filter(_ text: String, sources: [String], effortOutOf100: Bool) -> Result {
        let known = sources.flatMap(numbers(in:))
        var kept: [String] = []
        var struck = 0
        for paragraph in text.components(separatedBy: "\n") {
            var keptHere: [String] = []
            for sentence in sentences(paragraph) {
                if passes(sentence, known: known, effortOutOf100: effortOutOf100) {
                    keptHere.append(sentence)
                } else {
                    struck += 1
                }
            }
            kept.append(keptHere.joined(separator: " "))
        }
        let joined = kept.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(text: joined, struck: struck)
    }

    /// Counters for how often the guard had to act, so it can be seen whether the instruction alone holds.
    static let struckSentencesKey = "noop.forge.noteFigures.struckSentences"
    static let droppedNotesKey = "noop.forge.noteFigures.droppedNotes"

    /// `filter` on the wearer's Effort scale, counting what it struck. Returns the text to store, empty
    /// when nothing true was left.
    static func guarded(_ text: String, sources: [String], defaults: UserDefaults = .standard) -> String {
        let result = filter(text, sources: sources, effortOutOf100: UnitPrefs.currentEffortScale() == .hundred)
        if result.struck > 0 {
            defaults.set(defaults.integer(forKey: struckSentencesKey) + result.struck, forKey: struckSentencesKey)
            if result.text.isEmpty {
                defaults.set(defaults.integer(forKey: droppedNotesKey) + 1, forKey: droppedNotesKey)
            }
        }
        return result.text
    }

    // MARK: Pieces

    private static func passes(_ sentence: String, known: [Double], effortOutOf100: Bool) -> Bool {
        if effortOutOf100, sentence.range(of: #"\d\s*/\s*21\b"#, options: .regularExpression) != nil { return false }
        let written = figures(in: sentence)
        return written.allSatisfy { figure in
            known.contains { source in
                [source, source / 60, source * 60].contains { matches(figure, $0) }
            }
        }
    }

    /// A written figure matches a source value when the source, rounded to the figure's own decimals,
    /// is the figure.
    private static func matches(_ figure: (value: Double, decimals: Int), _ source: Double) -> Bool {
        let scale = pow(10, Double(figure.decimals))
        return abs((source * scale).rounded() - (figure.value * scale).rounded()) < 0.5
    }

    /// Figures as written, with their decimals. Clock times are taken out first; a sign is dropped (the
    /// words carry the direction).
    static func figures(in sentence: String) -> [(value: Double, decimals: Int)] {
        let withoutTimes = sentence.replacingOccurrences(
            of: #"\b\d{1,2}:\d{2}\s*(?:am\b|pm\b)?|\b\d{1,2}\.\d{2}\s*Uhr"#, with: " ", options: .regularExpression)
        let withoutDates = withoutTimes.replacingOccurrences(
            of: #"\b\d{1,2}\.\s?(?:Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\w*"#, with: " ",
            options: [.regularExpression, .caseInsensitive])
        // "out of 21" names the scale, not a reading.
        let withoutScale = withoutDates.replacingOccurrences(of: #"/\s*(?:21|100)\b"#, with: " ",
                                                             options: .regularExpression)
        return tokens(in: withoutScale).map { token in
            let normal = token.replacingOccurrences(of: ",", with: ".")
            let decimals = normal.split(separator: ".").dropFirst().first.map(\.count) ?? 0
            return (Double(normal) ?? 0, decimals)
        }
    }

    static func numbers(in source: String) -> [Double] {
        tokens(in: source).compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }

    private static func tokens(in text: String) -> [String] {
        let pattern = #"\d+(?:[.,]\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// Sentences of one paragraph. A stop inside a number ("7.5") is no end.
    static func sentences(_ paragraph: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(paragraph)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if ".!?".contains(chars[i]) {
                // Emphasis the stop closes stays with its sentence.
                var j = i + 1
                while j < chars.count, chars[j] == "*" { current.append(chars[j]); j += 1 }
                if j >= chars.count || chars[j].isWhitespace {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { out.append(trimmed) }
                    current = ""
                }
                i = j
                continue
            }
            i += 1
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }
}

/// What Today shows for the day while a note is written: the Charge and the night's sleep it stands over.
/// Today sets it each time it loads; the coach stores it with every timeline note. When the two later differ
/// (the night arrived late, a correction, a rebuild), the note says its figures were updated since.
///
/// Analysis migration required: no. A presentation marker.
enum ForgeNoteBasis {
    @MainActor static var current: String?

    /// One string per state, so comparing two is comparing what the reader saw.
    static func make(day: String, charge: Double?, asleepMinutes: Double?) -> String {
        let c = charge.map { String(Int($0.rounded())) } ?? "-"
        let s = asleepMinutes.map { String(Int($0.rounded())) } ?? "-"
        return "\(day)|\(c)|\(s)"
    }

    /// True when a note written over `stored` now stands over other figures of the same day. A note from
    /// another day, or one written before notes kept their basis, is never marked.
    static func isOutdated(stored: String?, current: String?) -> Bool {
        guard let stored, let current else { return false }
        let a = stored.split(separator: "|", omittingEmptySubsequences: false)
        let b = current.split(separator: "|", omittingEmptySubsequences: false)
        guard a.count == 3, b.count == 3, a[0] == b[0] else { return false }
        return a != b
    }
}
