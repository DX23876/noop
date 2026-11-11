import Foundation

/// Meal photos kept on the device (decision 2026-11-08): one JPEG and a small preview per photo, in the app's own
/// folder, never in the database and never in a backup. An entry names its photo by id; the photo goes when the
/// last entry naming it does.
public struct FoodPhotoStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Application Support/FoodPhotos on Apple platforms; nil where the platform names no such folder.
    public static let appDefault: FoodPhotoStore? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return FoodPhotoStore(directory: base.appendingPathComponent("FoodPhotos", isDirectory: true))
    }()

    /// Stores a photo and its preview; returns the new id, or nil when the folder cannot be written.
    public func save(jpeg: Data, preview: Data?, id: String = UUID().uuidString) -> String? {
        do {
            try prepareDirectory()
            try jpeg.write(to: url(id), options: .atomic)
            if let preview { try preview.write(to: url(id, preview: true), options: .atomic) }
            return id
        } catch {
            remove(id)
            return nil
        }
    }

    public func url(_ id: String, preview: Bool = false) -> URL {
        directory.appendingPathComponent(preview ? "\(id)-preview.jpg" : "\(id).jpg")
    }

    /// The preview when there is one, else the full photo; nil when neither exists.
    public func existingURL(_ id: String, preview: Bool = true) -> URL? {
        [url(id, preview: preview), url(id)].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: url(id))
        try? FileManager.default.removeItem(at: url(id, preview: true))
    }

    /// Removes photos no entry names that are older than `grace`, so a photo in a cart still being checked stays.
    public func sweep(keeping: Set<String>, grace: TimeInterval = 86_400, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jpg" {
            let id = Self.id(of: file)
            guard !keeping.contains(id) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > grace { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func id(of file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        return name.hasSuffix("-preview") ? String(name.dropLast("-preview".count)) : name
    }

    private func prepareDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(values)
        #endif
    }
}
