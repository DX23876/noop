import Foundation

// A mirror of `CoachMemory.tokens` and its helpers, which live in the `Strand` app target and are
// therefore unreachable from this executable.
//
// The same situation as `sleepbench`'s mirror of `applyBandStateWakeVeto`, and handled the same way: the
// logic below is transcribed from `Strand/AI/CoachMemory.swift` line for line — the stopword list
// verbatim, the ideographic ranges verbatim, the same 3-character minimum, the same bigram rule — and
// `TokeniserMirrorTests` pins the properties the transcription has to preserve. `CoachMemoryTokenizerTests`
// pins the real implementation.
//
// The mirror is a debt, not a design: the honest fix is to move the tokeniser into
// `Packages/SemanticMemory`, where both the app and this tool can call the one copy. That belongs to the
// stage that introduces IDF weighting anyway (it has to touch this code), not to a benchmark that is
// supposed to change no production behaviour. Until then, the drift risk is real and the tests below are
// what contains it.

enum MirroredTokeniser {
    /// Lowercased, punctuation-stripped word tokens ≥ 3 chars, stopwords removed — plus character bigrams
    /// wherever the text is ideographic.
    static func tokens(_ s: String) -> Set<String> {
        var result: Set<String> = []
        for part in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            addTokens(from: part, into: &result)
        }
        return result
    }

    private static func addTokens(from part: Substring, into result: inout Set<String>) {
        var start = part.startIndex
        while start < part.endIndex {
            let ideographic = isIdeographic(part[start])
            var end = part.index(after: start)
            while end < part.endIndex, isIdeographic(part[end]) == ideographic {
                end = part.index(after: end)
            }
            let run = part[start..<end]
            if ideographic {
                addBigrams(of: run, into: &result)
            } else if run.count >= 3, !stopwords.contains(String(run)) {
                result.insert(String(run))
            }
            start = end
        }
    }

    private static func addBigrams(of run: Substring, into result: inout Set<String>) {
        guard run.count > 1 else {
            result.insert(String(run))
            return
        }
        var index = run.startIndex
        while true {
            let next = run.index(after: index)
            guard next < run.endIndex else { return }
            result.insert(String(run[index...next]))
            index = next
        }
    }

    private static func isIdeographic(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        switch value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK unified ideographs extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0x20000...0x2EBEF, // CJK unified ideographs extensions B–F
             0x2F800...0x2FA1F: // CJK compatibility ideographs supplement
            return true
        default:
            return false
        }
    }

    /// Verbatim from `CoachMemory.stopwords`. Chinese is deliberately absent there (bigrams are not words,
    /// so a word-level list has nothing to match) — but **Polish is absent too**, and `pl` is a shipped
    /// locale. That is a finding, not a transcription slip: the list is copied as it is, and the Polish gap
    /// is measured by the corpus rather than quietly patched here.
    private static let stopwords: Set<String> = [
        // English
        "the", "and", "but", "for", "with", "not", "you", "your", "yours", "our", "its",
        "are", "was", "were", "been", "being", "does", "did", "doing", "have", "has", "had",
        "how", "what", "why", "when", "who", "which", "where", "should", "would", "could",
        "about", "this", "that", "these", "those", "there", "here", "then", "than", "some",
        "any", "all", "can", "will", "just", "from", "into", "out", "get", "got", "much",
        "very", "more", "most", "own",
        // German
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "und", "oder", "aber", "ich", "mir", "mich", "mein", "meine", "meinem", "meinen", "meiner",
        "du", "dir", "dich", "dein", "deine", "sie", "ihr", "wir", "uns", "man", "sich",
        "ist", "sind", "war", "waren", "bin", "bist", "sein", "habe", "hast", "hat", "hatte",
        "haben", "wird", "werden", "wurde", "kann", "kannst", "soll", "sollte", "muss", "will",
        "wie", "was", "wer", "wo", "wann", "warum", "welche", "welcher", "dass", "weil", "wenn",
        "für", "fur", "mit", "von", "vom", "zum", "zur", "auf", "aus", "bei", "nach", "über",
        "uber", "unter", "vor", "durch", "gegen", "ohne", "auch", "noch", "nur", "schon", "sehr",
        "nicht", "kein", "keine", "mehr", "immer", "wieder", "heute", "etwas",
        // Spanish
        "los", "las", "una", "unos", "unas", "del", "que", "con", "por", "para", "como",
        "más", "mas", "pero", "sus", "esta", "este", "esto", "estos", "estas", "son", "era",
        "ser", "estar", "tengo", "tiene", "hay", "muy", "todo", "toda", "cuando", "donde",
        "porque", "qué", "cuál", "cual", "mis", "tus", "nos",
        // French
        "les", "des", "une", "dans", "pour", "avec", "sur", "par", "mais", "plus", "pas",
        "que", "qui", "quoi", "est", "sont", "était", "etait", "être", "etre", "avoir", "fait",
        "mon", "mes", "ton", "tes", "son", "ses", "nos", "vos", "leur", "cette", "ces",
        "comment", "pourquoi", "quand", "très", "tres", "tout", "toute", "aussi", "encore",
        // Italian
        "gli", "delle", "degli", "una", "con", "per", "come", "più", "piu", "non", "che",
        "sono", "era", "essere", "avere", "mio", "mia", "miei", "suo", "sua", "nostro",
        "questo", "questa", "quello", "quella", "quando", "dove", "perché", "perche", "molto",
        // Portuguese
        "dos", "das", "uma", "uns", "umas", "com", "por", "para", "como", "mais", "mas",
        "que", "são", "sao", "era", "ter", "tem", "meu", "minha", "meus", "seu", "sua",
        "este", "esta", "isso", "quando", "onde", "porque", "muito", "todo", "também", "tambem",
        // Russian
        "это", "как", "что", "для", "который", "которая", "мой", "моя", "мои", "меня", "мне",
        "тебя", "они", "она", "оно", "был", "была", "были", "быть", "есть", "нет", "или",
        "если", "когда", "где", "почему", "очень", "уже", "ещё", "еще", "так", "все", "всё",
    ]
}

/// The token set the `exact` category actually needs, and the one the shipped tokeniser cannot produce.
///
/// `MirroredTokeniser.tokens` drops any run shorter than three characters. That rule is right for words
/// and wrong for everything the two rescue slots were kept for: "42" (a resting heart rate), "8h" (a sleep
/// duration), and the day and month of "2026-03-14" all disappear, leaving only "2026". So the arm that
/// exists to catch an exact number or date is blind to numbers and dates.
///
/// This variant keeps a short run when it contains a digit, and additionally keeps the full undivided run
/// so "2026-03-14" survives as a token in its own right. It is a bench-side proposal, measured by the
/// `exact` category against the mirrored behaviour above — nothing ships on it yet.
enum NumericAwareTokeniser {
    static func tokens(_ s: String) -> Set<String> {
        var result = MirroredTokeniser.tokens(s)
        let lowered = s.lowercased()
        for run in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if run.contains(where: \.isNumber) { result.insert(String(run)) }
        }
        // Whole hyphen/slash/colon-joined runs: an ISO date, a "3x8" set scheme, a "12:30" time.
        for run in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber && !"-/:.".contains($0) }) {
            let trimmed = run.trimmingCharacters(in: CharacterSet(charactersIn: "-/:."))
            if trimmed.count >= 3, trimmed.contains(where: \.isNumber) { result.insert(trimmed) }
        }
        return result
    }
}
