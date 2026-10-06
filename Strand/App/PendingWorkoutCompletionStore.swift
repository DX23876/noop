import Foundation

/// Atomic recovery file written before ending capture, removed only after the database commit.
struct PendingWorkoutCompletionStore {
    var url = URL.applicationSupportDirectory.appending(path: "ActiveSession/completion.json")

    func save(_ recording: CompletedWorkoutRecording) throws {
        let data = try JSONEncoder().encode(recording)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func load() throws -> CompletedWorkoutRecording? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CompletedWorkoutRecording.self, from: Data(contentsOf: url))
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
