import Foundation
import StrandCore

/// App-private optional media. The Android host downloads only after confirmation; this actor owns
/// installation, invalidation and local lookups, independently of a BLE/store session.
actor CoreExerciseMedia {
    static let shared = CoreExerciseMedia()
    struct Resolved: Encodable { var available = true; var path: String }
    struct Info: Encodable {
        var provider = ExerciseMediaPack.Provider.upstream
        var state: String
        var disabled: Bool
        var withdrawn: Bool
        var bytes: Int64
        var manifest: ExerciseMediaPack.Manifest?
        var error: String?
    }
    private var root: URL?
    private var disabled = false
    private var installation: Task<Int64, Error>?
    private var generation = UUID()
    private var index: ExerciseMediaPack.Index?
    private var failure: String?
    private let provider = ExerciseMediaPack.Provider.upstream
    private var providerRoot: URL? { root?.appendingPathComponent("ExerciseMedia").appendingPathComponent(provider.id) }
    private var versionDirectory: URL? { providerRoot?.appendingPathComponent(provider.version) }

    func configure(root: URL, disabled: Bool) async -> Info {
        if self.root != root { await cancel(); self.root = root; index = nil; failure = nil }
        if self.disabled != disabled { await setDisabled(disabled) }
        return info()
    }
    func info() -> Info {
        let withdrawn = ExerciseMediaPack.withdrawnProviderIds.contains(provider.id)
        let manifest = versionDirectory.flatMap { ExerciseMediaPack.manifest(versionDirectory: $0) }
        let valid = manifest?.providerID == provider.id && manifest?.version == provider.version
        let state = disabled || withdrawn ? "disabled" : installation != nil ? "installing" : valid ? "ready" : failure != nil ? "failed" : "unavailable"
        let fileBytes = manifest?.files.reduce(Int64(0)) { $0 + $1.bytes } ?? 0
        let manifestBytes = versionDirectory.flatMap { try? $0.appendingPathComponent("manifest.json").resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        return Info(state: state, disabled: disabled, withdrawn: withdrawn,
            bytes: fileBytes + Int64(manifestBytes), manifest: manifest, error: failure)
    }
    func install(archive: URL) async -> Info {
        guard !disabled, !ExerciseMediaPack.withdrawnProviderIds.contains(provider.id),
              installation == nil, let root = providerRoot else { return info() }
        let ticket = UUID(); generation = ticket; failure = nil
        let provider = provider
        let task = Task.detached(priority: .utility) { try ExerciseMediaPack.install(archive: archive, provider: provider, root: root) }
        installation = task
        do {
            _ = try await task.value
            guard generation == ticket else { return info() }
            installation = nil; index = nil
        } catch {
            guard generation == ticket else { return info() }
            installation = nil
            if !(error is CancellationError) { failure = (error as? ExerciseMediaPack.Failure)?.rawValue ?? "installFailed" }
        }
        return info()
    }
    func cancel() async {
        generation = UUID()
        let pending = installation
        pending?.cancel()
        await pending?.result
        installation = nil
    }
    func setDisabled(_ value: Bool) async {
        disabled = value
        if value { await cancel() }
        index = nil
    }
    func delete() async -> Bool {
        await cancel()
        guard let root = providerRoot else { return false }
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            index = nil; failure = nil; return true
        } catch { return false }
    }
    func resolve(mediaId: String, still: Bool) -> String? {
        guard info().state == "ready", let directory = versionDirectory else { return nil }
        if index == nil { index = .init(versionDirectory: directory) }
        return index?.url(mediaId: mediaId, preferStill: still)?.path
    }
}
