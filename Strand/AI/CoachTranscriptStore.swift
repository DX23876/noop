import Foundation

/// On-device persistence for the coach chat transcript, so a conversation survives an app restart.
/// One JSON file in the app's Application Support directory (same location pattern as
/// `RawHistoryArchive`) — never synced, never leaves the device. Own file: merge-clean vs upstream.
enum CoachTranscriptStore {

    /// Keep at most this many messages on disk — plenty of scrollback without unbounded growth.
    static let maxStoredMessages = 200

    private static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("coach-transcript.json")
    }

    /// Persist the transcript (tail-capped). Best-effort: a failed write just means the next launch
    /// starts without the newest turns — never a crash.
    static func save(_ messages: [ChatMessage]) {
        let tail = Array(messages.suffix(maxStoredMessages))
        guard let data = try? JSONEncoder().encode(tail) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Load the saved transcript, dropping empty assistant messages — those were chart-host bubbles
    /// whose chart artifacts (intentionally) aren't persisted, so restoring them would show blanks.
    static func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let msgs = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return [] }
        return msgs.filter { !($0.role == .assistant && $0.text.isEmpty) }
    }

    /// Delete the stored transcript ("New chat").
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
