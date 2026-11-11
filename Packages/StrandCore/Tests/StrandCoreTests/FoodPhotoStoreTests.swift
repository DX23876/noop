import XCTest
@testable import StrandCore
import WhoopStore

final class FoodPhotoStoreTests: XCTestCase {
    private var photos: FoodPhotoStore!

    override func setUp() {
        photos = FoodPhotoStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("food-photos-\(UUID().uuidString)", isDirectory: true))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: photos.directory) }

    func testSaveFindsThePreviewFirstAndRemoveClearsBoth() throws {
        let id = try XCTUnwrap(photos.save(jpeg: Data([1, 2, 3]), preview: Data([4])))
        XCTAssertEqual(photos.existingURL(id), photos.url(id, preview: true))
        XCTAssertEqual(photos.existingURL(id, preview: false), photos.url(id))
        photos.remove(id)
        XCTAssertNil(photos.existingURL(id))
    }

    func testSweepKeepsNamedAndFreshPhotos() throws {
        let kept = try XCTUnwrap(photos.save(jpeg: Data([1]), preview: Data([2])))
        let orphan = try XCTUnwrap(photos.save(jpeg: Data([1]), preview: Data([2])))
        let fresh = try XCTUnwrap(photos.save(jpeg: Data([1]), preview: nil))
        let old = Date().addingTimeInterval(-3 * 86_400)
        for url in [photos.url(kept), photos.url(kept, preview: true), photos.url(orphan), photos.url(orphan, preview: true)] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        photos.sweep(keeping: [kept])
        XCTAssertNotNil(photos.existingURL(kept))
        XCTAssertNil(photos.existingURL(orphan))
        XCTAssertNotNil(photos.existingURL(fresh))
    }

    func testDeletingTheLastEntryOfAPhotoRemovesTheFile() async throws {
        let store = try await WhoopStore.inMemory()
        let id = try XCTUnwrap(photos.save(jpeg: Data([1]), preview: nil))
        let item = FoodItem(id: "bls:C133000", source: .bls, name: "Haferflocken", per100g: NutrientAmounts([.energyKcal: 370]))
        let at = Date(timeIntervalSince1970: 1_762_600_000)
        let first = FoodLog.entry(for: item, grams: 50, at: at, origin: .search, photoId: id, id: "a")
        let second = FoodLog.entry(for: item, grams: 30, at: at, origin: .search, photoId: id, id: "b")
        _ = await FoodLog.save(store: store, [first, second])
        _ = await FoodLog.delete(store: store, ids: ["a"], photos: photos)
        XCTAssertNotNil(photos.existingURL(id))
        _ = await FoodLog.delete(store: store, ids: ["b"], photos: photos)
        XCTAssertNil(photos.existingURL(id))
    }
}
