import Foundation
import Crypto
import ZIPFoundation

/// Optional local exercise media. Downloading and playback belong to the hosts; archive interpretation,
/// checksums, provenance and opaque-id matching have one implementation on Apple and Android.
public enum ExerciseMediaPack {
    public static let maximumMediaBytes: Int64 = 200_000_000
    public static let maximumMetadataBytes: Int64 = 25_000_000
    public static let freeSpaceMarginBytes: Int64 = 50_000_000
    public static let withdrawnProviderIds: Set<String> = []

    public struct Provider: Equatable, Codable, Sendable {
        public let id: String, version: String, source: URL, attribution: String, rightsStatus: String
        public let approximateBytes: Int64
        public var rightsHolder: String
        public var expectedSHA256: String?
        public init(id: String, version: String, source: URL, attribution: String, rightsStatus: String,
                    approximateBytes: Int64, rightsHolder: String = "Unknown", expectedSHA256: String? = nil) {
            self.id = id; self.version = version; self.source = source; self.attribution = attribution
            self.rightsStatus = rightsStatus; self.approximateBytes = approximateBytes
            self.rightsHolder = rightsHolder; self.expectedSHA256 = expectedSHA256
        }
        public static let upstream = Provider(id: "hasaneyldrm-exercises-dataset",
            version: "7455efae41b330c265e7cd4b78dfa848e7ce5ebd",
            source: URL(string: "https://github.com/hasaneyldrm/exercises-dataset/archive/7455efae41b330c265e7cd4b78dfa848e7ce5ebd.zip")!,
            attribution: "© Gym visual — gymvisual.com. Distributed by hasaneyldrm/exercises-dataset (ExerciseDB).",
            rightsStatus: "The images and animations belong to Gym visual. Keep this attribution and use them only for personal, non-commercial purposes. NOOP does not grant any licence for these files.",
            approximateBytes: 130_000_000, rightsHolder: "Gym visual (gymvisual.com)")
        public static let displayCredit = "© Gym visual"
    }

    public struct Limits: Sendable {
        public let media: Int64, metadata: Int64
        public init(media: Int64 = maximumMediaBytes, metadata: Int64 = maximumMetadataBytes) {
            self.media = media; self.metadata = metadata
        }
    }
    public enum Failure: String, Error { case invalidArchive, unsafeArchive, packTooLarge, checksumMismatch, notEnoughSpace }

    public struct Manifest: Codable, Sendable {
        public struct File: Codable, Sendable {
            public let path: String, bytes: Int64, sha256: String
        }
        public let providerID: String, version: String, source: String, attribution: String, rightsStatus: String, rightsHolder: String
        public let downloadedAt: Date, downloadedBytes: Int64, archiveSHA256: String, expectedSHA256: String?
        public let files: [File]
        public var fileCount: Int { files.count }
    }

    public static func hasRoom(forUncompressedBytes required: Int64, availableBytes: Int64) -> Bool {
        required >= 0 && availableBytes >= freeSpaceMarginBytes && required <= availableBytes - freeSpaceMarginBytes
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Roots come from private app storage, never the archive. Every file is streamed with an actual byte
    /// bound and CRC check; the manifest's hashes describe the extracted bytes, not directory declarations.
    public static func install(archive: URL, provider: Provider, root: URL, limits: Limits = .init()) throws -> Int64 {
        guard safeComponent(provider.id), safeComponent(provider.version), !withdrawnProviderIds.contains(provider.id) else { throw Failure.unsafeArchive }
        let fm = FileManager.default
        let downloaded = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        guard limits.media >= 0, limits.media <= maximumMediaBytes,
              limits.metadata >= 0, limits.metadata <= maximumMetadataBytes,
              downloaded <= maximumMediaBytes + maximumMetadataBytes else { throw Failure.packTooLarge }
        let digest = try sha256(of: archive)
        if let expected = provider.expectedSHA256, expected.lowercased() != digest { throw Failure.checksumMismatch }
        let zip: Archive
        do { zip = try Archive(url: archive, accessMode: .read) } catch { throw Failure.invalidArchive }
        var planned: [(entry: Archive.Element, path: String)] = []
        var paths = Set<String>()
        var size: Int64 = 0
        for entry in zip {
            try Task.checkCancellation()
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !entry.path.contains("\\"), !entry.path.contains(":"),
                  !components.contains(".."), entry.type != .symlink else { throw Failure.unsafeArchive }
            guard entry.type == .file, let folder = components.firstIndex(where: { $0 == "images" || $0 == "videos" }),
                  folder + 1 < components.count, let name = components.last.map(String.init), safeComponent(name)
            else { continue }
            let path = "\(components[folder])/\(name)"
            guard paths.insert(path.lowercased()).inserted else { throw Failure.unsafeArchive }
            guard entry.uncompressedSize <= UInt64(limits.media),
                  size <= limits.media - Int64(entry.uncompressedSize), planned.count < 20_000 else { throw Failure.packTooLarge }
            size += Int64(entry.uncompressedSize)
            planned.append((entry, path))
        }
        guard !planned.isEmpty else { throw Failure.invalidArchive }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let attributes = try fm.attributesOfFileSystem(forPath: root.path)
        if let available = attributes[.systemFreeSize] as? NSNumber,
           !hasRoom(forUncompressedBytes: size + limits.metadata, availableBytes: available.int64Value) { throw Failure.notEnoughSpace }
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var files: [Manifest.File] = []
        for item in planned {
            let destination = staging.appendingPathComponent(item.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: destination.path, contents: nil) else { throw Failure.invalidArchive }
            let handle = try FileHandle(forWritingTo: destination)
            var written: Int64 = 0
            var hasher = SHA256()
            let crc: CRC32
            do {
                crc = try zip.extract(item.entry) { chunk in
                    try Task.checkCancellation()
                    guard Int64(chunk.count) <= Int64(item.entry.uncompressedSize) - written else { throw Failure.packTooLarge }
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    hasher.update(data: chunk)
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            guard written == Int64(item.entry.uncompressedSize), crc == item.entry.checksum else { throw Failure.invalidArchive }
            files.append(.init(path: item.path, bytes: written, sha256: hex(hasher.finalize())))
        }
        let manifest = Manifest(providerID: provider.id, version: provider.version, source: provider.source.absoluteString,
            attribution: provider.attribution, rightsStatus: provider.rightsStatus, rightsHolder: provider.rightsHolder,
            downloadedAt: Date(), downloadedBytes: downloaded, archiveSHA256: digest,
            expectedSHA256: provider.expectedSHA256, files: files)
        let data = try JSONEncoder().encode(manifest)
        guard Int64(data.count) <= limits.metadata else { throw Failure.packTooLarge }
        try data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        #if canImport(Darwin)
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        var excluded = staging; try excluded.setResourceValues(resources)
        #endif
        try Task.checkCancellation()
        let active = root.appendingPathComponent(provider.version, isDirectory: true)
        let previous = root.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: active.path) { try fm.moveItem(at: active, to: previous) }
        do { try fm.moveItem(at: staging, to: active); try? fm.removeItem(at: previous) }
        catch { if fm.fileExists(atPath: previous.path) { try? fm.moveItem(at: previous, to: active) }; throw error }
        return size + Int64(data.count)
    }

    public static func manifest(versionDirectory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: versionDirectory.appendingPathComponent("manifest.json")),
              data.count <= maximumMetadataBytes else { return nil }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.files.count <= 20_000 else { return nil }
        var total: Int64 = 0
        for file in manifest.files {
            let parts = file.path.split(separator: "/")
            guard parts.count == 2, parts[0] == "images" || parts[0] == "videos",
                  safeComponent(String(parts[1])), file.bytes >= 0, file.bytes <= maximumMediaBytes - total else { return nil }
            total += file.bytes
        }
        return manifest
    }

    /// Existing catalogue ids may be URL-shaped metadata; they resolve only to a local basename.
    public static func localFileName(from mediaID: String) -> String? {
        let candidate = mediaID.split(separator: "/").last.map(String.init) ?? mediaID
        return safeComponent(candidate) ? candidate : nil
    }
    private static func safeComponent(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("..") && !name.contains("/") && !name.contains("\\")
            && !name.contains(":") && !name.contains("\0") && name != "."
    }

    /// A deterministic local-only index. Unknown media never starts a network request.
    public struct Index: Sendable {
        private var animation: [String: URL] = [:], still: [String: URL] = [:]
        public init(versionDirectory: URL) {
            for folder in ["images", "videos"] {
                let root = versionDirectory.appendingPathComponent(folder)
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
                var index: [String: URL] = [:]
                for name in names {
                    let file = root.appendingPathComponent(name)
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let stem = (name as NSString).deletingPathExtension
                    for key in [name, stem, stem.split(separator: "-").last.map(String.init) ?? stem] where index[key] == nil {
                        index[key] = file
                    }
                }
                if folder == "videos" { animation = index } else { still = index }
            }
        }
        public func url(mediaId: String, preferStill: Bool = false) -> URL? {
            guard let key = localFileName(from: mediaId) else { return nil }
            return preferStill ? still[key] ?? animation[key] : animation[key] ?? still[key]
        }
    }
}
