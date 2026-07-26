import Foundation

/// Size accounting for the coach's *own* durable memory. It serialises the same Codable shapes that the
/// stores use, so the number is an honest local estimate rather than a token-based guess. It never reads
/// health SQLite data and never includes an API request body.
enum CoachMemoryFootprint {
    struct Snapshot: Equatable {
        let conversationBytes: Int
        let factBytes: Int

        var totalBytes: Int { conversationBytes + factBytes }
    }

    static func estimate(conversations: [CoachConversation], facts: [CoachMemory.MemoryFact]) -> Snapshot {
        let encoder = JSONEncoder()
        let conversationBytes = (try? encoder.encode(conversations).count) ?? 0
        let factBytes = (try? encoder.encode(facts).count) ?? 0
        return Snapshot(conversationBytes: conversationBytes, factBytes: factBytes)
    }

    static func formatted(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
    }
}
