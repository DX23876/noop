import XCTest
import ZIPFoundation
@testable import StrandCore
import WhoopStore

final class FoodCatalogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("food-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func table(_ rows: [[String]]) -> String {
        let header = FoodCatalogImporter.metaColumns + FoodNutrient.allCases.map(\.rawValue)
        return ([header] + rows.map { row in row + Array(repeating: "", count: header.count - row.count) })
            .map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    private func pack(country: String, rows: [[String]], format: Int = FoodCatalog.tableFormat) throws -> (URL, String) {
        let url = directory.appendingPathComponent("download-\(UUID().uuidString).zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, text) in [("products.tsv", table(rows)),
                             ("pack.json", #"{"tableFormat":\#(format),"country":"\#(country)","iso":"DE","rows":\#(rows.count),"builtAt":"2026-11-08T00:00:00Z"}"#)] {
            let data = Data(text.utf8)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) {
                position, size in data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return (url, try ExerciseMediaPack.sha256(of: url))
    }

    // MARK: Text

    func testNormalisationFoldsAccentsAndSplitsWords() {
        XCTAssertEqual(FoodSearchText.tokens("Müsli, Crème brûlée & Weißbrot 3,5%"),
                       ["musli", "creme", "brulee", "weissbrot"])
        XCTAssertEqual(FoodSearchText.suffixes("vollkornbrot"),
                       ["ollkornbrot", "llkornbrot", "lkornbrot", "kornbrot", "ornbrot", "rnbrot", "nbrot", "brot"])
        XCTAssertEqual(FoodSearchText.suffixes("brot"), [])
        XCTAssertEqual(FoodSearchText.joinedPairs("Hafer Flocken, roh"), ["haferflocken", "flockenroh"])
    }

    func testBarcodeVariantsJoinUpcAndEan() {
        XCTAssertEqual(FoodCatalog.barcodeVariants("012345678905"), ["012345678905", "0012345678905"])
        XCTAssertEqual(FoodCatalog.barcodeVariants("0012345678905"), ["0012345678905", "012345678905"])
        XCTAssertEqual(FoodCatalog.barcodeVariants("12"), [])
    }

    // MARK: Bundled BLS

    func testBundledBlsBuildsAndFindsFoodsAndCompounds() async throws {
        let meta = try XCTUnwrap(FoodCatalog.bundledMeta())
        XCTAssertEqual(meta.rows, 7140)
        XCTAssertEqual(meta.licence, "CC BY 4.0")
        let catalog = FoodCatalog(directory: directory)
        try await catalog.prepareBundled()

        let oats = await catalog.search("haferflocken")
        XCTAssertEqual(oats.first?.id, "bls:C133000", "\(oats.map(\.name))")
        let flakes = await catalog.search("hafer flocken")
        XCTAssertEqual(flakes.first?.id, "bls:C133000")

        let bread = await catalog.search("brot", limit: 200)
        XCTAssertTrue(bread.contains { $0.name == "Vollkornbrot" }, "compound tails are indexed")

        let english = await catalog.search("oat flakes")
        XCTAssertTrue(english.contains { $0.id == "bls:C133000" })

        let item = await catalog.item(id: "bls:C133000")
        XCTAssertEqual(item?.per100g[.energyKcal], 348)
        XCTAssertEqual(item?.source, .bls)

        // A second call with the same table keeps the file.
        let path = directory.appendingPathComponent("bls.sqlite").path
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        try await catalog.prepareBundled()
        let after = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    // MARK: Packs

    func testPackInstallsSearchesAndLooksUpBarcodes() async throws {
        let catalog = FoodCatalog(directory: directory)
        let (zip, sha) = try pack(country: "germany", rows: [
            ["off:4000000000017", "off", "Knusper Müsli", "", "Hofgut", "breakfast-cereals", "3", "40", "40 g", "430", "9", "62", "15"],
            ["off:0012345678905", "off", "Cola", "", "Brause", "", "4", "", "", "42", "0", "10.6", "0"],
        ])
        let installed = try await catalog.installPack(archive: zip, expectedSha256: sha)
        XCTAssertEqual(installed.country, "germany")
        XCTAssertEqual(installed.rows, 2)

        let found = await catalog.search("musli hofgut")
        XCTAssertEqual(found.map(\.id), ["off:4000000000017"])
        XCTAssertEqual(found.first?.servingG, 40)
        XCTAssertEqual(found.first?.nova, 3)
        let byUpc = await catalog.item(barcode: "012345678905")
        XCTAssertEqual(byUpc?.name, "Cola")
        XCTAssertEqual(byUpc?.barcode, "0012345678905")

        await catalog.removePack(country: "germany")
        let gone = await catalog.installedPacks()
        XCTAssertTrue(gone.isEmpty)
    }

    func testABadDownloadLeavesTheOldPack() async throws {
        let catalog = FoodCatalog(directory: directory)
        let (zip, sha) = try pack(country: "germany", rows: [["off:4000000000017", "off", "Müsli", "", "", "", "", "", "", "430", "9", "62", "15"]])
        try await catalog.installPack(archive: zip, expectedSha256: sha)
        do {
            try await catalog.installPack(archive: zip, expectedSha256: String(repeating: "0", count: 64))
            XCTFail("a wrong checksum must not install")
        } catch FoodCatalog.Failure.checksumMismatch {}
        let (future, futureSha) = try pack(country: "germany", rows: [], format: 99)
        do {
            try await catalog.installPack(archive: future, expectedSha256: futureSha)
            XCTFail("an unknown format must not install")
        } catch FoodCatalog.Failure.unknownFormat {}
        let still = await catalog.search("musli")
        XCTAssertEqual(still.count, 1)
    }
}

final class FoodLogTests: XCTestCase {
    private let oats = FoodItem(id: "bls:C133000", source: .bls, name: "Hafer Flocken",
                                per100g: NutrientAmounts([.energyKcal: 348, .proteinG: 13.22, .fiberG: 10]))

    private func date(_ day: String, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: WeightSeries.date(forDay: day)!)!
    }

    func testEntryScalesThePer100gSnapshot() {
        let entry = FoodLog.entry(for: oats, grams: 50, at: date("2026-11-08", 7), origin: .search, id: "e")
        XCTAssertEqual(entry.day, "2026-11-08")
        XCTAssertEqual(entry.totals["energy_kcal"], 174)
        XCTAssertEqual(entry.totals["protein_g"]!, 6.61, accuracy: 1e-9)
        let edited = FoodLog.edited(entry, grams: 100)
        XCTAssertEqual(edited.totals["energy_kcal"], 348)
        XCTAssertEqual(edited.per100g, entry.per100g)
    }

    func testMealsGroupByTimeAndByChosenMeal() {
        let a = FoodLog.entry(for: oats, grams: 50, at: date("2026-11-08", 7, 0), origin: .search, id: "a")
        let b = FoodLog.entry(for: oats, grams: 50, at: date("2026-11-08", 7, 30), origin: .search, id: "b")
        let c = FoodLog.entry(for: oats, grams: 50, at: date("2026-11-08", 12, 30), origin: .search, id: "c")
        let d = FoodLog.entry(for: oats, grams: 50, at: date("2026-11-08", 15, 30), origin: .search, meal: .lunch, id: "d")
        let meals = FoodLog.meals([c, b, a, d])
        XCTAssertEqual(meals.map { $0.entries.map(\.id) }, [["a", "b"], ["c"], ["d"]])
        XCTAssertEqual(meals.map(\.kind), [.breakfast, .lunch, .lunch])
        XCTAssertEqual(meals[0].totals[.energyKcal], 348)
    }

    func testCopiesKeepTheTimeOfDayAndDropTheHealthRecord() {
        var entry = FoodLog.entry(for: oats, grams: 50, at: date("2026-11-08", 7, 15), origin: .search, id: "a")
        entry.healthId = "HK"
        let copies = FoodLog.copies(of: [entry], toDays: ["2026-11-09", "2026-11-10"])
        XCTAssertEqual(copies.map(\.day), ["2026-11-09", "2026-11-10"])
        XCTAssertTrue(copies.allSatisfy { $0.healthId == nil && $0.origin == .copy && $0.id != "a" })
        XCTAssertEqual(Calendar.current.component(.minute, from: Date(timeIntervalSince1970: TimeInterval(copies[0].loggedAt))), 15)
    }

    func testRecipeIsPer100gOfThePot() throws {
        let milk = FoodItem(id: "bls:M111000", source: .bls, name: "Milch", per100g: NutrientAmounts([.energyKcal: 64]))
        let entries = [FoodLog.entry(for: oats, grams: 80, at: Date(), origin: .search),
                       FoodLog.entry(for: milk, grams: 320, at: Date(), origin: .search)]
        let recipe = try XCTUnwrap(FoodLog.recipe(name: "Porridge", from: entries, servings: 2, id: "r"))
        let item = try XCTUnwrap(FoodLog.item(for: recipe))
        XCTAssertEqual(item.id, "recipe:r")
        XCTAssertEqual(item.servingG, 200)
        // (80 × 3.48 + 320 × 0.64) / 400 g × 100 g
        XCTAssertEqual(item.per100g[.energyKcal]!, (278.4 + 204.8) / 4, accuracy: 1e-9)
    }

    func testFoodLogDaysFeedNutritionReadsAboveHealthAndBelowAManualDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([MetricPoint(day: "2026-11-08", key: NutritionReads.caloriesKey, value: 2_500),
                                            MetricPoint(day: "2026-11-08", key: NutritionReads.carbsKey, value: 300)],
                                           deviceId: MetricResolver.appleHealthSource)
        let saved = await FoodLog.save(store: store, [FoodLog.entry(for: oats, grams: 100, at: date("2026-11-08", 8), origin: .search)])
        XCTAssertTrue(saved)
        var day = await NutritionReads.nutritionByDay(store: store, from: "2026-11-08", to: "2026-11-08")["2026-11-08"]
        XCTAssertEqual(day?.calories, 348)
        XCTAssertEqual(day?.caloriesSource, .foodLog)
        XCTAssertEqual(try XCTUnwrap(day?.proteinG), 13.22, accuracy: 1e-9)
        XCTAssertEqual(day?.carbsG, 300, "a macro the log does not know keeps the imported value")

        let manual = await NutritionReads.recordManualNutrition(store: store, .init(
            day: "2026-11-08", calories: 2_000, proteinG: nil, carbsG: nil, fatG: nil, isConfirmedNoIntake: false))
        XCTAssertTrue(manual)
        day = await NutritionReads.nutritionByDay(store: store, from: "2026-11-08", to: "2026-11-08")["2026-11-08"]
        XCTAssertEqual(day?.calories, 2_000)
        XCTAssertEqual(day?.caloriesSource, .manual)
    }

    func testTheDayKeysMatchNutritionReads() {
        XCTAssertEqual(WhoopStore.foodLogDayKeys.map(\.key),
                       [NutritionReads.caloriesKey, NutritionReads.proteinKey, NutritionReads.carbsKey, NutritionReads.fatKey])
        XCTAssertEqual(WhoopStore.foodLogDayKeys.map(\.nutrient), FoodNutrient.macros.map(\.rawValue))
    }
}
