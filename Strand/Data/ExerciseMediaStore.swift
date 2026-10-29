import Foundation
import StrandTraining
import StrandCore

/// The offline media-pack provider: the only place the app knows how an optional pack is obtained,
/// validated and stored. Workout, routine and analytics records only keep their own exercise
/// identifiers, never a file.
@MainActor
final class ExerciseMediaStore: ObservableObject, ExerciseMediaProvider {
    static let maximumMediaBytes = ExerciseMediaPack.maximumMediaBytes
    static let maximumMetadataBytes = ExerciseMediaPack.maximumMetadataBytes
    /// Free space a pack must leave behind, so installing media can never fill the device.
    static let freeSpaceMarginBytes = ExerciseMediaPack.freeSpaceMarginBytes
    /// One store per app. A download belongs to the app, not to the screen that started it, so
    /// closing that screen can no longer discard an in-flight pack. Creating it reconnects the
    /// background session, which is what delivers a pack that finished while the app was closed.
    static let shared: ExerciseMediaStore = {
        let store = ExerciseMediaStore()
        store.reconnectPendingTransfer()
        return store
    }()

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

        static let upstream: Provider = {
            let source = ExerciseMediaPack.Provider.upstream
            return Provider(id: source.id, version: source.version, source: source.source,
                attribution: source.attribution,
                rightsStatus: String(localized: "The images and animations belong to Gym visual. Keep this attribution and use them only for personal, non-commercial purposes. NOOP does not grant any licence for these files."),
                approximateBytes: source.approximateBytes, rightsHolder: source.rightsHolder,
                expectedSHA256: source.expectedSHA256)
        }()

        var core: ExerciseMediaPack.Provider {
            .init(id: id, version: version, source: source, attribution: attribution, rightsStatus: rightsStatus,
                approximateBytes: approximateBytes, rightsHolder: rightsHolder, expectedSHA256: expectedSHA256)
        }

        /// Shown wherever the media is displayed.
        static let displayCredit = ExerciseMediaPack.Provider.displayCredit
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
    @Published private(set) var canResumeDownload = false
    private var isTransferring = false
    /// Per-folder name index, dropped whenever the installed pack changes.
    private var mediaIndex: ExerciseMediaPack.Index?
    private var installTask: Task<Int64, Error>?
    private var activeInstallation: UUID?
    private var installationGeneration = UUID()
    private var isDeleting = false

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
    func media(for exercise: TrainingExercise, variant: ExerciseMediaVariant) -> ExerciseMedia? {
        mediaURL(for: exercise, variant: variant).map(ExerciseMedia.init(url:))
    }

    func mediaURL(for exercise: TrainingExercise, variant: ExerciseMediaVariant = .animation) -> URL? {
        guard isAvailable, let mediaId = exercise.mediaId else { return nil }
        if mediaIndex == nil { mediaIndex = .init(versionDirectory: versionDirectory) }
        return mediaIndex?.url(mediaId: mediaId, preferStill: variant == .still)
    }

    // MARK: - Availability

    /// True when the wearer switched the provider off, or when NOOP withdrew it centrally.
    var isDisabled: Bool {
        ExerciseMediaRegistry.isWithdrawn(provider.id) || defaults.bool(forKey: disabledKey)
    }

    var isWithdrawn: Bool { ExerciseMediaRegistry.isWithdrawn(provider.id) }

    func refresh() {
        mediaIndex = nil
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
        if disabled {
            installationGeneration = UUID()
            installTask?.cancel()
            cancel()
        }
        refresh()
    }

    // MARK: - Transfer

    /// Explicitly user initiated. The archive is fetched from the provider's upstream URL, staged,
    /// checked and activated atomically; existing usable media is never overwritten in place.
    func download() {
        guard !isDisabled, !isTransferring, !isDeleting, installTask == nil else { return }
        isTransferring = true
        state = .downloading(progress: 0)
        // Reusing the existing downloader is what makes "Resume" cost only the remaining bytes.
        transfer().start(url: provider.source)
    }

    /// Picks up a transfer from an earlier launch: a finished one is delivered by the session itself,
    /// a running one shows its progress again instead of offering a second download.
    func reconnectPendingTransfer() {
        guard usesBackgroundTransfer, !isDisabled else { return }
        transfer().pendingTransfer { [weak self] running in
            guard running else { return }
            Task { @MainActor in self?.adoptRunningTransfer() }
        }
    }

    private func adoptRunningTransfer() {
        guard !isTransferring, !isAvailable, !isDisabled, !isDeleting, installTask == nil else { return }
        isTransferring = true
        state = .downloading(progress: 0)
    }

    private func transfer() -> ExerciseMediaDownloader {
        if let downloader { return downloader }
        let transfer = usesBackgroundTransfer ? ExerciseMediaDownloader.background
            : ExerciseMediaDownloader(background: false)
        transfer.attach(expectedBytes: provider.approximateBytes) { [weak self] value in
            Task { @MainActor in self?.progressed(value) }
        } onCompletion: { [weak self] result in
            Task { @MainActor in await self?.finish(result) }
        }
        downloader = transfer
        return transfer
    }

    func cancel() {
        guard isTransferring else { return }
        downloader?.cancel()
        isTransferring = false
        if case .downloading = state { state = .unavailable }
        // The resume data arrives from the session a moment after the cancel.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.canResumeDownload = self?.downloader?.canResume ?? false
        }
    }

    /// Removes the installed pack together with anything a transfer left behind: a running download,
    /// its resume data and a failure message. Afterwards the pack can be downloaded again from scratch.
    func deleteMedia() {
        installationGeneration = UUID()
        let pending = installTask
        pending?.cancel()
        downloader?.discard()
        isTransferring = false
        canResumeDownload = false
        defaults.removeObject(forKey: activeVersionKey)
        defaults.removeObject(forKey: activeBytesKey)
        if let pending {
            isDeleting = true
            state = .unavailable
            Task {
                _ = await pending.result
                try? FileManager.default.removeItem(at: providerRoot)
                installTask = nil; isDeleting = false
                refresh()
            }
        } else {
            try? FileManager.default.removeItem(at: providerRoot)
            refresh()
        }
    }

    /// Whether there is anything to delete: an installed pack, a failed or half-finished transfer.
    var hasDownloadedData: Bool {
        if isAvailable || canResumeDownload || isTransferring { return true }
        if case .failed = state { return true }
        return FileManager.default.fileExists(atPath: providerRoot.path)
    }

    private func progressed(_ value: Double) {
        guard case .downloading = state else { return }
        state = .downloading(progress: value)
    }

    private func finish(_ result: Result<URL, Error>) async {
        let wasTransferring = isTransferring
        isTransferring = false
        canResumeDownload = downloader?.canResume ?? false
        switch result {
        case .failure(let error):
            // A transfer from an earlier launch that nobody is waiting for changes nothing on screen.
            guard wasTransferring else { return }
            if case ExerciseMediaTransferError.cancelled = error { state = .unavailable }
            else { state = .failed(error.localizedDescription) }
        case .success(let archive):
            defer { try? FileManager.default.removeItem(at: archive) }
            // Delivered after a relaunch or as a second copy: install only when nothing is installed
            // yet and no install is already running.
            if isDisabled || isAvailable || isDeleting || installTask != nil {
                try? FileManager.default.removeItem(at: archive)
                return
            }
            let provider = provider
            state = .installing
            let root = providerRoot
            let limits = Limits(media: maximumMediaBytes, metadata: maximumMetadataBytes)
            let generation = UUID()
            installationGeneration = generation
            activeInstallation = generation
            defer {
                if activeInstallation == generation { installTask = nil; activeInstallation = nil }
            }
            do {
                let task = Task.detached(priority: .userInitiated) {
                    try Self.stageAndActivate(archive: archive, provider: provider, root: root, limits: limits)
                }
                installTask = task
                let bytes = try await task.value
                guard installationGeneration == generation, !isDisabled else { return }
                installTask = nil
                try? FileManager.default.removeItem(at: archive)
                defaults.set(provider.version, forKey: activeVersionKey)
                defaults.set(NSNumber(value: bytes), forKey: activeBytesKey)
                mediaIndex = nil
                state = .ready(bytes: bytes)
            } catch {
                try? FileManager.default.removeItem(at: archive)
                guard installationGeneration == generation else { return }
                installTask = nil
                if error is CancellationError { return }
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
        mediaIndex = nil
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
        ExerciseMediaPack.hasRoom(forUncompressedBytes: required, availableBytes: availableBytes)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        try ExerciseMediaPack.sha256(of: url)
    }

    nonisolated private static func stageAndActivate(archive: URL, provider: Provider,
                                                     root: URL, limits: Limits) throws -> Int64 {
        do {
            return try ExerciseMediaPack.install(archive: archive, provider: provider.core, root: root,
                                                 limits: .init(media: limits.media, metadata: limits.metadata))
        } catch let error as ExerciseMediaPack.Failure {
            switch error {
            case .invalidArchive: throw MediaError.invalidArchive
            case .unsafeArchive: throw MediaError.unsafeArchive
            case .packTooLarge: throw MediaError.packTooLarge
            case .checksumMismatch: throw MediaError.checksumMismatch
            case .notEnoughSpace: throw MediaError.notEnoughSpace
            }
        }
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
        ExerciseMediaPack.manifest(versionDirectory: versionDirectory)
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
        ExerciseMediaPack.localFileName(from: mediaID)
    }
}

typealias MediaManifest = ExerciseMediaPack.Manifest
