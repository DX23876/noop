import Foundation

/// A mirror of `CoachSemanticMemory.chunks` / `slice`, transcribed from `Strand/AI/CoachSemanticMemory.swift`.
/// Same debt and same containment as `MirroredTokeniser` — see the note there.
///
/// The bench needs it because chunking is what makes P4 (a candidate pool that collapses when several
/// chunks share one source) reachable at all: without it every corpus document would be exactly one
/// candidate, the 32-candidate limit would never bind, and the measurement would show a defect the real
/// app has as absent.
enum MirroredChunker {
    /// A word longer than this is not a word: it is unsegmented script that arrived as one run.
    static let unbrokenWordLimit = 60
    static let characterChunkSize = 240
    static let characterChunkOverlap = 30
    static let wordChunkSize = 192
    static let wordChunkOverlap = 24

    /// The chunk texts for one document, in `chunkIndex` order.
    static func chunks(_ text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        if words.contains(where: { $0.count > unbrokenWordLimit }) {
            let characters = Array(words.joined(separator: " "))
            return slice(count: characters.count,
                         size: characterChunkSize,
                         overlap: characterChunkOverlap) { String(characters[$0]) }
        }
        return slice(count: words.count, size: wordChunkSize, overlap: wordChunkOverlap) {
            words[$0].joined(separator: " ")
        }
    }

    private static func slice(count: Int,
                              size: Int,
                              overlap: Int,
                              build: (Range<Int>) -> String) -> [String] {
        var result: [String] = []
        var start = 0
        while start < count {
            let end = min(count, start + size)
            result.append(build(start..<end))
            guard end < count else { break }
            start = max(start + 1, end - overlap)
        }
        return result
    }
}
