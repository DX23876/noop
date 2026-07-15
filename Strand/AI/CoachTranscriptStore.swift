import Foundation

/// On-device persistence for the coach chat — now a LIST of named conversations, so past chats are
/// kept as their own findable threads instead of one ever-overwritten transcript. One JSON file in the
/// app's Application Support directory (same location pattern as `RawHistoryArchive`) — never synced,
/// never leaves the device. Own file: merge-clean vs upstream.
///
/// `CoachTranscriptStore` (below) remains only as the legacy single-transcript reader, used once to
/// migrate an old `coach-transcript.json` into the first conversation.

/// One saved conversation: its own message history plus the chart snapshots the coach drew in it.
struct CoachConversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    /// Chart snapshots keyed by the id (as a string, for clean JSON) of the empty assistant message
    /// that hosts them in the transcript. Rebuilt into `chartsByMessage` when the conversation loads.
    var charts: [String: CoachChartSnapshot]

    init(id: UUID = UUID(),
         title: String = "",
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         messages: [ChatMessage] = [],
         charts: [String: CoachChartSnapshot] = [:]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.charts = charts
    }

    /// A short title derived from the first user message, for a conversation the user hasn't renamed.
    static func autoTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else { return "New chat" }
        let oneLine = first.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 48 ? String(oneLine.prefix(48)) + "…" : oneLine
    }
}

enum CoachConversationStore {

    /// Keep at most this many conversations, and this many messages within each — plenty of scrollback
    /// and history without unbounded on-disk growth.
    static let maxConversations = 50
    static let maxMessagesPerConversation = 200

    private static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("coach-conversations.json")
    }

    /// Load all saved conversations. On first run after the upgrade, migrate a legacy single transcript
    /// (`coach-transcript.json`) into one conversation so no history is lost. Returns [] for a fresh app.
    static func load() -> [CoachConversation] {
        if let data = try? Data(contentsOf: fileURL),
           let convos = try? JSONDecoder().decode([CoachConversation].self, from: data) {
            return convos
        }
        let legacy = CoachTranscriptStore.load()
        guard !legacy.isEmpty else { return [] }
        let migrated = CoachConversation(title: CoachConversation.autoTitle(from: legacy),
                                         messages: legacy)
        save([migrated])
        return [migrated]
    }

    /// Persist the conversation list, tail-capping each conversation's messages and the list itself.
    /// Best-effort: a failed write just means the newest turns aren't on disk yet — never a crash.
    /// Callers keep `conversations` ordered most-recent-first, so the cap drops the oldest.
    static func save(_ conversations: [CoachConversation]) {
        let capped = conversations.prefix(maxConversations).map { convo -> CoachConversation in
            var c = convo
            c.messages = Array(c.messages.suffix(maxMessagesPerConversation))
            return c
        }
        guard let data = try? JSONEncoder().encode(Array(capped)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Delete all stored conversations (used only for a full reset; normal "new chat" just adds one).
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Legacy single-transcript store — kept only to migrate an old `coach-transcript.json` into the new
/// conversation list on first launch. No longer written to.
enum CoachTranscriptStore {

    private static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
        return dir.appendingPathComponent("coach-transcript.json")
    }

    /// Load the legacy transcript, dropping empty assistant messages — those were old chart-host bubbles
    /// whose charts weren't persisted back then, so restoring them would show blanks.
    static func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let msgs = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return [] }
        return msgs.filter { !($0.role == .assistant && $0.text.isEmpty) }
    }
}
