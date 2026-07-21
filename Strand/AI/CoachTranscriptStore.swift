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
    /// A short distilled summary of the conversation, produced by the cheap memory model. Feeds
    /// cross-conversation recall (the digest + the search tool). `nil` until summarised. Optional, so
    /// conversations saved before this field existed decode fine.
    var summary: String?
    /// How many messages had been summarised at the last run, so the maintainer only re-summarises when
    /// enough new turns have accrued (cost control).
    var summarizedCount: Int?
    /// Whether this thread has been auto-archived out of the main history list (#R8). Set by the
    /// day-boundary sweep on stale, auto-only threads — a "Today's brief" the user never replied to,
    /// once its day has passed. Archived threads stay on disk and stay findable in the history's
    /// "Archived" section; nothing is deleted. Additive, back-compat decode (old JSON lacks the key).
    var archived: Bool
    /// Kept at the top of the history, by the user's own choice — the plan they keep coming back to, the
    /// explanation worth re-reading. Additive and back-compat like `archived`: JSON written before this
    /// field existed decodes as `false`.
    var pinned: Bool

    /// True when the user never took a turn here — the thread is purely auto-generated coach content
    /// (a morning brief, a nudge, a weekly review). Those are what the sweep may archive; a thread the
    /// user actually replied in is a real conversation and is left alone. Empty threads are neither.
    var isAutoOnly: Bool {
        !messages.isEmpty && !messages.contains { $0.role == .user }
    }

    init(id: UUID = UUID(),
         title: String = "",
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         messages: [ChatMessage] = [],
         charts: [String: CoachChartSnapshot] = [:],
         summary: String? = nil,
         summarizedCount: Int? = nil,
         archived: Bool = false,
         pinned: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.charts = charts
        self.summary = summary
        self.summarizedCount = summarizedCount
        self.archived = archived
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages, charts, summary, summarizedCount, archived
        case pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        charts = try c.decodeIfPresent([String: CoachChartSnapshot].self, forKey: .charts) ?? [:]
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summarizedCount = try c.decodeIfPresent(Int.self, forKey: .summarizedCount)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    /// Whether this thread matches a history search. Deliberately SUBSTRING matching over title,
    /// summary and every message — not the whole-word token overlap `search_past_conversations` uses.
    /// The two answer different questions: the model searches by topic, a person typing into a field
    /// expects "schl" to find "Schlaf" while they are still typing. Case- and diacritic-insensitive so
    /// "grosse" finds "größe".
    func matches(search query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = ([title, summary ?? ""] + messages.map(\.text)).joined(separator: "\n")
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The conversation as Markdown, for sharing or keeping a copy.
    ///
    /// Built here rather than in the view so it is testable and so the export can never disagree with
    /// what was stored. Charts are named, not embedded: their snapshots are images that belong to the
    /// app, and a link to a file the recipient doesn't have would be worse than an honest placeholder.
    func markdownExport(coachName: String) -> String {
        let stamp = updatedAt.formatted(date: .abbreviated, time: .shortened)
        var out = ["# \(title.isEmpty ? "Coach conversation" : title)", "*\(stamp)*", ""]
        for message in messages {
            let who = message.role == .user ? "**You**" : "**\(coachName)**"
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                // An empty assistant turn is a chart host (see `charts`), not a blank reply.
                if charts[message.id.uuidString] != nil { out.append("\(who): *[chart]*") }
                continue
            }
            out.append("\(who): \(text)")
            out.append("")
        }
        return out.joined(separator: "\n")
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
        let capped = applyCap(conversations).map { convo -> CoachConversation in
            var c = convo
            c.messages = Array(c.messages.suffix(maxMessagesPerConversation))
            return c
        }
        guard let data = try? JSONEncoder().encode(capped) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Apply the conversation cap, keeping every PINNED thread regardless of age.
    ///
    /// A plain `prefix(maxConversations)` over a most-recent-first list silently deletes the oldest —
    /// which is exactly the thread someone pins: the plan they keep returning to, months old and rarely
    /// reopened. Pinning something and having the app quietly bin it would be the worst possible
    /// outcome, so pinned threads are exempt and the cap falls on unpinned ones instead. Pure and
    /// order-preserving, so the caller's most-recent-first ordering survives.
    static func applyCap(_ conversations: [CoachConversation]) -> [CoachConversation] {
        guard conversations.count > maxConversations else { return conversations }
        var unpinnedBudget = max(0, maxConversations - conversations.filter(\.pinned).count)
        return conversations.filter { convo in
            if convo.pinned { return true }
            guard unpinnedBudget > 0 else { return false }
            unpinnedBudget -= 1
            return true
        }
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
