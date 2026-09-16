import Foundation
import CryptoKit
import ZIPFoundation
import StrandTraining

/// The offline media-pack provider: the only place the app knows how an optional pack is obtained,
/// validated and stored. Workout, routine and analytics records only keep their own exercise
/// identifiers, never a file.
@MainActor
final class ExerciseMediaStore: ObservableObject, ExerciseMediaProvider {
    static let maximumMediaBytes: Int64 = 200_000_000
    static let maximumMetadataBytes: Int64 = 25_000_000
    /// Free space a pack must leave behind, so installing media can never fill the device.
    static let freeSpaceMarginBytes: Int64 = 50_000_000
    /// One store per app. A download belongs to the app, not to the screen that started it, so
    /// closing that screen can no longer discard an in-flight pack.
    static let shared = ExerciseMediaStore()

    struct Provider: Identifiable, Sendable {
        let id: String
        let version: String
        let source: URL
        let attribution: String
        let rightsStatus: String
        let approximateBytes: Int64
        var rightsHolder: String = String(localized: "Unknown")
        /// Set only where the upstream publishes a stable digest for this exact archive. GitHub's
        /// generated source archives are not byte-stable, so pinning one here would fail honest
        /// downloads; the digest NOOP computed is recorded in the local manifest either way.
        var expectedSHA256: String?

        static let upstream = Provider(
            id: "hasaneyldrm-exercises-dataset",
            version: "7455efae41b330c265e7cd4b78dfa848e7ce5ebd",
            source: URL(string: "https://github.com/hasaneyldrm/exercises-dataset/archive/7455efae41b330c265e7cd4b78dfa848e7ce5ebd.zip")!,
            attribution: "Exercise media: Gym visual / ExerciseDB, distributed by hasaneyldrm/exercises-dataset.",
            rightsStatus: String(localized: "Media ownership and redistribution rights are disputed. NOOP does not grant any licence for these files."),
            approximateBytes: 140_000_000,
            rightsHolder: String(localized: "The hasaneyldrm/exercises-dataset repository; the underlying media rights holders may differ."))
    }

    enum State: Equatable {
        case unavailable
        case ready(bytes: Int64)
        case downloading(progress: Double)
        case installing
        case failed(String)
        case disabled
    }

    @Published private(set) var state: State = .unavailable
    @Published private(set) var provider: Provider

    private static let disabledKey = "training.exerciseMedia.disabled"
    private static let activeVersionKey = "training.exerciseMedia.activeVersion"
    private let rootDirectoryOverride: URL?
    private let defaults: UserDefaults
    private let maximumMediaBytes: Int64
    private let maximumMetadataBytes: Int64
    private let usesBackgroundTransfer: Bool
    private var downloader: ExerciseMediaDownloader?
    private var isTransferring = false
    /// Per-folder name index, dropped whenever the installed pack changes.
    private var fileIndexCache: [URL: [String: String]] = [:]

    init(provider: Provider = .upstream, rootDirectory: URL? = nil,
         defaults: UserDefaults = .standard,
         maximumMediaBytes: Int64 = ExerciseMediaStore.maximumMediaBytes,
         maximumMetadataBytes: Int64 = ExerciseMediaStore.maximumMetadataBytes,
         usesBackgroundTransfer: Bool = true) {
        self.provider = provider
        rootDirectoryOverride = rootDirectory
        self.defaults = defaults
        self.maximumMediaBytes = maximumMediaBytes
        self.maximumMetadataBytes = maximumMetadataBytes
        self.usesBackgroundTransfer = usesBackgroundTransfer
        refresh()
    }

    // MARK: - ExerciseMediaProvider

    var providerId: String { provider.id }

    var isAvailable: Bool {
        if case .ready = state { return true }
        return false
    }

    /// A local lookup, deliberately without any network fallback: logging must never wait on media.
    func media(for exercise: TrainingExercise) -> ExerciseMedia? {
        mediaURL(for: exercise).map(ExerciseMedia.init(url:))
    }

    func mediaURL(for exercise: TrainingExercise) -> URL? {
        guard isAvailable, let mediaId = exercise.mediaId else { return nil }
        guard let allowed = Self.localFileName(from: mediaId) else { return nil }
        // Videos first: where a pack ships both, the animation is the more useful of the two, and the
        // still is the fallback the presentation already knows how to draw.
        let roots = [versionDirectory.appendingPathComponent("videos"),
                     versionDirectory.appendingPathComponent("images")]
        for root in roots {
            let url = root.appendingPathComponent(allowed)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            if let match = fileIndex(root)[allowed] { return root.appendingPathComponent(match) }
        }
        return nil
    }

    /// media id → file name, for one installed folder.
    ///
    /// A catalogue entry carries an OPAQUE media id (`2gPfomN`), never a file name — that is the point
    /// of the identifier, and it is what keeps a licence question out of the catalogue. A pack, though,
    /// names its files for its own storage: this one ships `0001-2gPfomN.gif`, prefixed with the
    /// upstream's numeric id and carrying the extension the presentation needs to tell an animation
    /// from a still. Matching the id against the bare name alone therefore resolved NOTHING, and the
    /// feature looked correct because nothing in the catalogue or the store is wrong on its own.
    ///
    /// So the lookup indexes what is actually on disk: each file is registered under its whole stem and
    /// under the part after the last `-`. Built once per folder and cached, because the alternative is a
    /// directory scan per row while scrolling a library of 1,324 exercises.
    private func fileIndex(_ root: URL) -> [String: String] {
        if let cached = fileIndexCache[root] { return cached }
        var index: [String: String] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            let stem = (name as NSString).deletingPathExtension
            guard !stem.isEmpty else { continue }
            index[stem] = name
            if let tail = stem.split(separator: "-").last.map(String.init), tail != stem {
                index[tail] = name
            }
        }
        fileIndexCache[root] = index
        return index
    }

    // MARK: - Availability

    /// True when the wearer switched the provider off, or when NOOP withdrew it centrally.
    var isDisabled: Bool {
        ExerciseMediaRegistry.isWithdrawn(provider.id) || defaults.bool(forKey: disabledKey)
    }

    var isWithdrawn: Bool { ExerciseMediaRegistry.isWithdrawn(provider.id) }

    var canResumeDownload: Bool { downloader?.canResume ?? false }

    func refresh() {
        fileIndexCache.removeAll(keepingCapacity: true)
        guard !isDisabled else { state = .disabled; return }
        let root = versionDirectory
        guard FileManager.default.fileExists(atPath: root.path) else { state = .unavailable; return }
        if let recorded = (defaults.object(forKey: activeBytesKey) as? NSNumber)?.int64Value {
            state = .ready(bytes: recorded)
            return
        }
        // A pack installed before sizes were recorded is measured once, off the main thread.
        state = .ready(bytes: 0)
        Task.detached(priority: .utility) { [weak self] in
            let bytes = Self.directorySize(root)
            await self?.recordMeasuredSize(bytes)
        }
    }

    private func recordMeasuredSize(_ bytes: Int64) {
        defaults.set(NSNumber(value: bytes), forKey: activeBytesKey)
        if case .ready = state { state = .ready(bytes: bytes) }
    }

    func setDisabled(_ disabled: Bool) {
        defaults.set(disabled, forKey: disabledKey)
        if disabled { cancel() }
        refresh()
    }

    // MARK: - Transfer

    /// Explicitly user initiated. The archive is fetched from the provider's upstream URL, staged,
    /// checked and activated atomically; existing usable media is never overwritten in place.
    func download() {
        guard !isDisabled, !isTransferring else { return }
        isTransferring = true
        state = .downloading(progress: 0)
        let provider = provider
        // Reusing the existing downloader is what makes "Resume" cost only the remaining bytes.
        let transfer = downloader ?? ExerciseMediaDownloader(background: usesBackgroundTransfer)
        downloader = transfer
        transfer.start(url: provider.source) { [weak self] value in
            Task { @MainActor in self?.progressed(value) }
        } onCompletion: { [weak self] result in
            Task { @MainActor in await self?.finish(result, provider: provider) }
        }
    }

    func cancel() {
        guard isTransferring else { return }
        downloader?.cancel()
        isTransferring = false
        if case .downloading = state { state = .unavailable }
    }

    func deleteMedia() {
        cancel()
        downloader = nil
        try? FileManager.default.removeItem(at: providerRoot)
        defaults.removeObject(forKey: activeVersionKey)
        defaults.removeObject(forKey: activeBytesKey)
        refresh()
    }

    private func progressed(_ value: Double) {
        guard case .downloading = state else { return }
        state = .downloading(progress: value)
    }

    private func finish(_ result: Result<URL, Error>, provider: Provider) async {
        isTransferring = false
        switch result {
        case .failure(let error):
            if case ExerciseMediaTransferError.cancelled = error { state = .unavailable }
            else { state = .failed(error.localizedDescription) }
        case .success(let archive):
            state = .installing
            let root = providerRoot
            let limits = Limits(media: maximumMediaBytes, metadata: maximumMetadataBytes)
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    try Self.stageAndActivate(archive: archive, provider: provider, root: root, limits: limits)
                }.value
                try? FileManager.default.removeItem(at: archive)
                defaults.set(provider.version, forKey: activeVersionKey)
                defaults.set(NSNumber(value: bytes), forKey: activeBytesKey)
                state = .ready(bytes: bytes)
            } catch {
                try? FileManager.default.removeItem(at: archive)
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Installs a previously downloaded archive. Internal so archive handling can be tested without
    /// fetching third-party files or adding a test-only provider to production views.
    func install(archive: URL) throws {
        let bytes = try Self.stageAndActivate(
            archive: archive, provider: provider, root: providerRoot,
            limits: Limits(media: maximumMediaBytes, metadata: maximumMetadataBytes))
        defaults.set(provider.version, forKey: activeVersionKey)
        defaults.set(NSNumber(value: bytes), forKey: activeBytesKey)
        state = .ready(bytes: bytes)
    }

    // MARK: - Validation and activation

    struct Limits: Sendable {
        let media: Int64
        let metadata: Int64
    }

    enum MediaError: LocalizedError, Equatable {
        case invalidArchive
        case unsafeArchive
        case packTooLarge
        case checksumMismatch
        case notEnoughSpace

        var errorDescription: String? {
            switch self {
            case .invalidArchive: return String(localized: "The downloaded media pack could not be validated.")
            case .unsafeArchive: return String(localized: "The downloaded media pack contained an unsafe file path.")
            case .packTooLarge: return String(localized: "The exercise media pack exceeds NOOP's 200 MB storage limit.")
            case .checksumMismatch: return String(localized: "The downloaded media pack did not match its published checksum.")
            case .notEnoughSpace: return String(localized: "There is not enough free space to install the exercise media pack.")
            }
        }
    }

    /// Whether a pack of this size may be installed, leaving `freeSpaceMarginBytes` behind.
    nonisolated static func hasRoom(forUncompressedBytes required: Int64, availableBytes: Int64) -> Bool {
        availableBytes >= required + freeSpaceMarginBytes
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stages, validates and atomically activates one archive. Runs off the main actor: a 140 MB pack
    /// is unzipped and hashed here, which must never happen while the wearer is logging a set.
    nonisolated private static func stageAndActivate(archive: URL, provider: Provider,
                                                     root: URL, limits: Limits) throws -> Int64 {
        let fm = FileManager.default
        let digest = try sha256(of: archive)
        if let expected = provider.expectedSHA256, expected.lowercased() != digest {
            throw MediaError.checksumMismatch
        }
        let downloadedBytes = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0

        let zip: Archive
        do {
            zip = try Archive(url: archive, accessMode: .read)
        } catch {
            throw MediaError.invalidArchive
        }

        var planned: [(entry: Archive.Element, relativePath: String)] = []
        var uncompressed: Int64 = 0
        for entry in zip {
            let path = entry.path
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw MediaError.unsafeArchive
            }
            guard path.contains("/images/") || path.contains("/videos/") else { continue }
            let suffix = path.components(separatedBy: "/images/").last
                ?? path.components(separatedBy: "/videos/").last ?? ""
            guard !suffix.isEmpty, !suffix.hasSuffix("/") else { continue }
            guard let name = localFileName(from: suffix) else { throw MediaError.unsafeArchive }
            uncompressed += Int64(entry.uncompressedSize)
            guard uncompressed <= limits.media else { throw MediaError.packTooLarge }
            let folder = path.contains("/images/") ? "images" : "videos"
            planned.append((entry, "\(folder)/\(name)"))
        }
        guard !planned.isEmpty else { throw MediaError.invalidArchive }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let available = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        if let available, !hasRoom(forUncompressedBytes: uncompressed, availableBytes: Int64(available)) {
            throw MediaError.notEnoughSpace
        }

        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var cleanUpStaging = true
        defer { if cleanUpStaging { try? fm.removeItem(at: staging) } }

        var files: [MediaManifest.File] = []
        for item in planned {
            let destination = staging.appendingPathComponent(item.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            _ = try zip.extract(item.entry, to: destination)
            files.append(.init(path: item.relativePath,
                               bytes: Int64(item.entry.uncompressedSize),
                               sha256: try sha256(of: destination)))
        }

        let manifest = MediaManifest(provider: provider, archiveSHA256: digest,
                                     downloadedBytes: downloadedBytes, files: files)
        let manifestData = try JSONEncoder().encode(manifest)
        guard Int64(manifestData.count) <= limits.metadata else { throw MediaError.packTooLarge }
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var stagingURL = staging
        try stagingURL.setResourceValues(resource)

        let active = root.appendingPathComponent(provider.version, isDirectory: true)
        let previous = root.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: active.path) { try fm.moveItem(at: active, to: previous) }
        do {
            try fm.moveItem(at: staging, to: active)
            cleanUpStaging = false
            try? fm.removeItem(at: previous)
        } catch {
            if fm.fileExists(atPath: previous.path) { try? fm.moveItem(at: previous, to: active) }
            throw error
        }
        return directorySize(active)
    }

    // MARK: - Paths

    private var providerRoot: URL {
        let base = rootDirectoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ExerciseMedia", isDirectory: true)
            .appendingPathComponent(provider.id, isDirectory: true)
    }

    private var versionDirectory: URL { providerRoot.appendingPathComponent(provider.version, isDirectory: true) }

    /// The local manifest of the installed pack, for provenance and support questions.
    func installedManifest() -> MediaManifest? {
        let url = versionDirectory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MediaManifest.self, from: data)
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        guard let values = FileManager.default.enumerator(at: url,
                                                          includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in values {
            if let size = try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(size) }
        }
        return total
    }

    private var disabledKey: String { "\(Self.disabledKey).\(provider.id)" }
    private var activeVersionKey: String { "\(Self.activeVersionKey).\(provider.id)" }
    private var activeBytesKey: String { "training.exerciseMedia.activeBytes.\(provider.id)" }

    nonisolated static func localFileName(from mediaID: String) -> String? {
        let candidate = mediaID.split(separator: "/").last.map(String.init) ?? mediaID
        guard !candidate.isEmpty,
              !candidate.contains(".."),
              !candidate.contains("\\"),
              !candidate.contains(":"),
              candidate == URL(fileURLWithPath: candidate).lastPathComponent
        else { return nil }
        return candidate
    }
}

/// What was installed, where it came from and what it contains. This is provenance, not a second
/// exercise database: it stores file paths and checksums, never exercise or workout data.
struct MediaManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    let providerID: String
    let version: String
    let source: String
    let attribution: String
    let rightsStatus: String
    let rightsHolder: String
    let downloadedAt: Date
    let downloadedBytes: Int64
    let archiveSHA256: String
    let expectedSHA256: String?
    let files: [File]

    var fileCount: Int { files.count }

    init(provider: ExerciseMediaStore.Provider, archiveSHA256: String,
         downloadedBytes: Int64, files: [File]) {
        providerID = provider.id
        version = provider.version
        source = provider.source.absoluteString
        attribution = provider.attribution
        rightsStatus = provider.rightsStatus
        rightsHolder = provider.rightsHolder
        downloadedAt = Date()
        self.downloadedBytes = downloadedBytes
        self.archiveSHA256 = archiveSHA256
        expectedSHA256 = provider.expectedSHA256
        self.files = files
    }
}
