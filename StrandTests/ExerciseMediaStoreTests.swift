import XCTest
import ZIPFoundation
import StrandTraining
@testable import Strand

@MainActor
final class ExerciseMediaStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("exercise-media-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "exercise-media-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMediaPackInstallsLocallyAndCanBeDisabledWithoutChangingWorkoutData() throws {
        let archiveURL = root.appendingPathComponent("media.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "upstream/images/bench.gif", type: .file,
                             uncompressedSize: UInt32(3), compressionMethod: .deflate,
                             provider: { position, size in
                                 let start = Int(position)
                                 return Data("gif".utf8).subdata(in: start..<(start + size))
                             })
        let provider = ExerciseMediaStore.Provider(id: "test-media", version: "v1", source: URL(string: "https://example.com/media.zip")!, attribution: "Test", rightsStatus: "Unknown", approximateBytes: 3)
        let store = ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults)

        try store.install(archive: archiveURL)
        XCTAssertTrue(store.isAvailable)
        XCTAssertNotNil(store.mediaURL(for: .init(id: "bench", title: "Bench", mode: .weightReps, mediaId: "bench.gif")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ExerciseMedia/test-media/v1/manifest.json").path))

        store.setDisabled(true)
        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(store.state, .disabled)
    }

    /// The shape that actually ships: the CATALOGUE carries an opaque media id with no extension and no
    /// path (`BundledExerciseCatalogTests` enforces that), while the PACK names its files for its own
    /// storage — here `<upstream id>-<media id>.gif`. Matching the id against the bare file name
    /// resolved nothing, and neither side looked wrong on its own. Also pins that the animation wins
    /// over the still when a pack ships both, since the presentation picks its player from the
    /// extension.
    func testAnOpaqueCatalogueMediaIdResolvesToThePacksOwnFileName() throws {
        let archiveURL = root.appendingPathComponent("named.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for path in ["upstream/images/0001-2gPfomN.jpg", "upstream/videos/0001-2gPfomN.gif"] {
            try archive.addEntry(with: path, type: .file, uncompressedSize: UInt32(3),
                                 compressionMethod: .deflate,
                                 provider: { position, size in
                                     let start = Int(position)
                                     return Data("bin".utf8).subdata(in: start..<(start + size))
                                 })
        }
        let provider = ExerciseMediaStore.Provider(id: "named-media", version: "v1", source: URL(string: "https://example.com/named.zip")!, attribution: "Test", rightsStatus: "Unknown", approximateBytes: 6)
        let store = ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults)
        try store.install(archive: archiveURL)

        let exercise = TrainingExercise(id: "exdb:0001", title: "3/4 sit-up", mode: .bodyweightReps,
                                        mediaId: "2gPfomN")
        let resolved = try XCTUnwrap(store.mediaURL(for: exercise))
        XCTAssertEqual(resolved.lastPathComponent, "0001-2gPfomN.gif")
        XCTAssertEqual(ExerciseMedia(url: resolved).kind, .animation)

        // An id that names no file stays unresolved rather than matching a neighbour.
        XCTAssertNil(store.mediaURL(for: .init(id: "exdb:9999", title: "Unknown",
                                               mode: .bodyweightReps, mediaId: "nothing")))
    }

    func testReopenedStoreReportsTheRecordedSizeAndDeletionClearsIt() throws {
        let archiveURL = root.appendingPathComponent("sized.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "upstream/videos/row.mp4", type: .file,
                             uncompressedSize: UInt32(5), compressionMethod: .deflate,
                             provider: { position, size in
                                 let start = Int(position)
                                 return Data("video".utf8).subdata(in: start..<(start + size))
                             })
        let provider = ExerciseMediaStore.Provider(
            id: "sized", version: "v1", source: URL(string: "https://example.com/media.zip")!,
            attribution: "Test", rightsStatus: "Unknown", approximateBytes: 5)
        let store = ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults)
        try store.install(archive: archiveURL)
        guard case .ready(let bytes) = store.state else { return XCTFail("pack was not activated") }

        let reopened = ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults)
        XCTAssertEqual(reopened.state, .ready(bytes: bytes))

        reopened.deleteMedia()
        XCTAssertEqual(reopened.state, .unavailable)
        XCTAssertEqual(ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults).state,
                       .unavailable)
    }

    func testAPublishedChecksumThatDoesNotMatchRefusesThePack() throws {
        let archiveURL = try makeArchive(named: "checked.zip", path: "upstream/images/row.gif",
                                         payload: Data("gif".utf8))
        let provider = ExerciseMediaStore.Provider(
            id: "checked", version: "v1", source: URL(string: "https://example.com/media.zip")!,
            attribution: "Test", rightsStatus: "Unknown", approximateBytes: 3,
            expectedSHA256: String(repeating: "a", count: 64))
        let store = ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults)

        XCTAssertThrowsError(try store.install(archive: archiveURL)) { error in
            XCTAssertEqual(error as? ExerciseMediaStore.MediaError, .checksumMismatch)
        }
        XCTAssertFalse(store.isAvailable)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ExerciseMedia/checked/v1").path))
    }

    func testInstalledManifestRecordsEveryFileWithItsOwnDigest() throws {
        let archiveURL = try makeArchive(named: "manifest.zip", path: "upstream/images/press.gif",
                                         payload: Data("gif".utf8))
        let provider = ExerciseMediaStore.Provider(
            id: "manifest", version: "v1", source: URL(string: "https://example.com/media.zip")!,
            attribution: "Test", rightsStatus: "Unknown", approximateBytes: 3)
        let store = ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults)

        try store.install(archive: archiveURL)

        let manifest = try XCTUnwrap(store.installedManifest())
        XCTAssertEqual(manifest.files.map(\.path), ["images/press.gif"])
        XCTAssertEqual(manifest.files.first?.bytes, 3)
        XCTAssertEqual(manifest.files.first?.sha256,
                       try ExerciseMediaStore.sha256(of: root.appendingPathComponent(
                           "ExerciseMedia/manifest/v1/images/press.gif")))
        XCTAssertEqual(manifest.archiveSHA256, try ExerciseMediaStore.sha256(of: archiveURL))
        XCTAssertNil(manifest.expectedSHA256)
        XCTAssertEqual(manifest.rightsHolder, provider.rightsHolder)
    }

    func testInstallationRefusesToFillTheDevice() {
        XCTAssertFalse(ExerciseMediaStore.hasRoom(forUncompressedBytes: 140_000_000,
                                                  availableBytes: 150_000_000))
        XCTAssertTrue(ExerciseMediaStore.hasRoom(forUncompressedBytes: 140_000_000,
                                                 availableBytes: 260_000_000))
    }

    func testADisabledProviderResolvesToNoMediaThroughTheRegistry() throws {
        let archiveURL = try makeArchive(named: "registry.zip", path: "upstream/images/curl.gif",
                                         payload: Data("gif".utf8))
        let provider = ExerciseMediaStore.Provider(
            id: "registry", version: "v1", source: URL(string: "https://example.com/media.zip")!,
            attribution: "Test", rightsStatus: "Unknown", approximateBytes: 3)
        let store = ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults)
        try store.install(archive: archiveURL)
        let registry = ExerciseMediaRegistry(providers: [store])
        let exercise = TrainingExercise(id: "curl", title: "Curl", mode: .weightReps, mediaId: "curl.gif")

        XCTAssertEqual(registry.media(for: exercise)?.kind, .animation)

        store.setDisabled(true)
        XCTAssertNil(registry.media(for: exercise))
        XCTAssertEqual(store.state, .disabled)
    }

    private func makeArchive(named name: String, path: String, payload: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: path, type: .file, uncompressedSize: UInt32(payload.count),
                             compressionMethod: .deflate) { position, size in
            let start = Int(position)
            return payload.subdata(in: start..<(start + size))
        }
        return url
    }

    /// The only endpoint the app can reach for media is the one the disclosure screen names. There is
    /// no second provider, no mirror and no NOOP-operated host.
    func testTheOnlyConfiguredEndpointIsTheDisclosedUpstream() {
        let provider = ExerciseMediaStore.Provider.upstream
        XCTAssertEqual(provider.source.scheme, "https")
        XCTAssertEqual(provider.source.host, "github.com")
        XCTAssertTrue(provider.source.absoluteString.contains(provider.version),
                      "the endpoint must be pinned to the disclosed immutable revision")
        XCTAssertFalse(provider.rightsStatus.isEmpty)
        XCTAssertFalse(provider.rightsHolder.isEmpty)
        XCTAssertNil(provider.expectedSHA256,
                     "a generated source archive is not byte-stable, so no digest may be pinned")
    }

    func testInstalledMediaIsExcludedFromDeviceBackup() throws {
        let archiveURL = try makeArchive(named: "backup.zip", path: "upstream/images/squat.gif",
                                         payload: Data("gif".utf8))
        let provider = ExerciseMediaStore.Provider(
            id: "backup", version: "v1", source: URL(string: "https://example.com/media.zip")!,
            attribution: "Test", rightsStatus: "Unknown", approximateBytes: 3)
        let store = ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults)

        try store.install(archive: archiveURL)

        let installed = root.appendingPathComponent("ExerciseMedia/backup/v1")
        let values = try installed.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testMediaLookupRejectsUnsafeExternalPaths() {
        // A URL-like id is reduced to its filename, so traversal can never escape the local pack.
        XCTAssertEqual(ExerciseMediaStore.localFileName(from: "../../secret.gif"), "secret.gif")
        XCTAssertNil(ExerciseMediaStore.localFileName(from: "C:\\secret.gif"))
        XCTAssertEqual(ExerciseMediaStore.localFileName(from: "https://example.com/assets/bench.gif"), "bench.gif")
    }

    func testOversizedPackIsRejectedWithoutActivatingPartialMedia() throws {
        let archiveURL = root.appendingPathComponent("oversized.zip")
        let payload = Data(repeating: 7, count: 8)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "upstream/images/bench.gif", type: .file,
                             uncompressedSize: UInt32(payload.count), compressionMethod: .deflate,
                             provider: { position, size in
                                 let start = Int(position)
                                 return payload.subdata(in: start..<(start + size))
                             })
        let provider = ExerciseMediaStore.Provider(
            id: "limited", version: "v1", source: URL(string: "https://example.com/media.zip")!,
            attribution: "Test", rightsStatus: "Unknown", approximateBytes: 8)
        let store = ExerciseMediaStore(provider: provider, rootDirectory: root, defaults: defaults,
                                       maximumMediaBytes: 4)

        XCTAssertThrowsError(try store.install(archive: archiveURL))
        XCTAssertFalse(store.isAvailable)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ExerciseMedia/limited/v1").path))
    }
}
