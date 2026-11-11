#if os(iOS)
import Foundation
import Observation
import StrandCore

/// The country packs: what the release offers, what is on this iPhone, and a download in progress. The core
/// checks every file's SHA-256 against the manifest before using it.
@MainActor
@Observable
final class FoodPacksModel {
    private(set) var manifest: FoodPackManifest?
    private(set) var manifestFailed = false
    private(set) var installed: [InstalledFoodPack] = []
    private(set) var downloading: String?
    private(set) var progress = 0.0
    private(set) var failure: String?

    func refresh(fetchManifest: Bool) async {
        installed = await FoodCatalog.shared.installedPacks()
        guard fetchManifest, manifest == nil else { return }
        do {
            var request = URLRequest(url: FoodPackManifest.manifestURL, timeoutInterval: 20)
            request.setValue(FoodOnline.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            manifest = FoodPackManifest.decode(data)
            manifestFailed = manifest == nil
        } catch {
            manifestFailed = true
        }
    }

    func download(_ pack: FoodPackManifest.Pack) async {
        guard let manifest, let url = manifest.url(for: pack), downloading == nil else { return }
        downloading = pack.country
        progress = 0
        failure = nil
        defer { downloading = nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.setValue(FoodOnline.userAgent, forHTTPHeaderField: "User-Agent")
            let (file, _) = try await URLSession.shared.download(for: request,
                                                                delegate: FoodDownloadProgress { [weak self] in self?.progress = $0 })
            defer { try? FileManager.default.removeItem(at: file) }
            try await FoodCatalog.shared.installPack(archive: file, expectedSha256: pack.sha256)
            installed = await FoodCatalog.shared.installedPacks()
        } catch FoodCatalog.Failure.notEnoughSpace {
            failure = String(localized: "There is not enough free space on this iPhone.")
        } catch {
            failure = String(localized: "The download did not work. The previous data is still there.")
        }
    }

    func remove(_ pack: InstalledFoodPack) async {
        await FoodCatalog.shared.removePack(country: pack.country)
        installed = await FoodCatalog.shared.installedPacks()
    }

    /// An installed pack the release has a newer build of.
    func update(for pack: InstalledFoodPack) -> FoodPackManifest.Pack? {
        manifest?.usable.first { $0.country == pack.country && $0.sha256 != pack.sha256 }
    }

    var offered: [FoodPackManifest.Pack] {
        (manifest?.usable ?? []).filter { pack in !installed.contains { $0.country == pack.country } }
    }
}
#endif
