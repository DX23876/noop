import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Open Food Facts online, only when the wearer chose online search (decision 2026-11-08). What leaves the
/// phone is the search text or the barcode and the chosen countries: no account, no identifier, a generic
/// User-Agent. Results are converted into the same `FoodItem` the packs give, and a result the wearer logs is
/// saved as their own food (`FoodLibrary.saveOwn`), so it works offline afterwards.
public enum FoodOnline {
    public static let host = "https://world.openfoodfacts.org"
    /// Open Food Facts asks every client to name itself; this names the app, never the person.
    public static let userAgent = "NOOP-Forge/1 (offline-first health app; food search)"
    /// The search endpoint allows about ten requests a minute: callers wait for a pause in typing.
    public static let minimumQueryLength = 3

    static let fields = "code,product_name,product_name_de,product_name_en,generic_name,brands,serving_size,"
        + "serving_quantity,nova_group,pnns_groups_2,categories_tags,ingredients_text,quantity,product_quantity,"
        + "product_quantity_unit,nutriments"

    /// The fields to ask for, with the product name in the app language when that is neither German nor English,
    /// so a Spanish app reads `product_name_es` where a product has one.
    static func fields(language: String) -> String {
        // The language part alone: "pt-PT" asks for product_name_pt.
        let code = (language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "")
            .filter(\.isLetter)
        guard !code.isEmpty, code != "de", code != "en" else { return fields }
        return fields + ",product_name_\(code)"
    }

    /// Products matching `query`, sold in one of `countries` (Open Food Facts tags such as "germany").
    public static func search(_ query: String, countries: [String], language: String,
                              session: URLSession = .shared) async throws -> [FoodItem] {
        guard let url = searchURL(query, countries: countries, language: language) else { return [] }
        let object = try await get(url, session: session)
        let products = (object["products"] as? [[String: Any]]) ?? []
        return ranked(products, countries: countries).compactMap { product($0, language: language) }
    }

    /// The search request. One country is a filter. Several are not: the search ANDs its tag filters, so a
    /// product had to be sold in every chosen country at once, and "haferflocken" in Germany and Portugal
    /// found one product where Germany alone found 523 (measured 2026-11-25). With several countries the
    /// request goes out unfiltered and wider, and `ranked` puts their products first.
    static func searchURL(_ query: String, countries: [String], language: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumQueryLength else { return nil }
        let chosen = Array(countries.prefix(3))
        let filtered = chosen.count == 1
        var items: [URLQueryItem] = [
            .init(name: "search_terms", value: trimmed), .init(name: "search_simple", value: "1"),
            .init(name: "action", value: "process"), .init(name: "json", value: "1"),
            .init(name: "page_size", value: filtered ? "25" : "50"),
            .init(name: "fields", value: fields(language: language) + (filtered ? "" : ",countries_tags")),
            .init(name: "lc", value: language),
        ]
        if filtered, let country = chosen.first {
            items += [.init(name: "tagtype_0", value: "countries"),
                      .init(name: "tag_contains_0", value: "contains"),
                      .init(name: "tag_0", value: country)]
        }
        var components = URLComponents(string: host + "/cgi/search.pl")!
        components.queryItems = items
        return components.url
    }

    /// Products sold in one of `countries` first, in the order the search gave them, then the rest.
    static func ranked(_ products: [[String: Any]], countries: [String]) -> [[String: Any]] {
        guard countries.count > 1 else { return products }
        let wanted = Set(countries.map { "en:" + $0.lowercased() })
        func sold(_ product: [String: Any]) -> Bool {
            ((product["countries_tags"] as? [String]) ?? []).contains { wanted.contains($0.lowercased()) }
        }
        return products.filter(sold) + products.filter { !sold($0) }
    }

    /// One product by barcode, or nil when Open Food Facts does not know it.
    public static func product(barcode: String, language: String, session: URLSession = .shared) async throws -> FoodItem? {
        guard let code = FoodCatalog.barcodeVariants(barcode).first else { return nil }
        var components = URLComponents(string: host + "/api/v2/product/\(code).json")!
        components.queryItems = [.init(name: "fields", value: fields(language: language)), .init(name: "lc", value: language)]
        let object = try await get(components.url!, session: session)
        guard (object["status"] as? NSNumber)?.intValue == 1, let product = object["product"] as? [String: Any] else { return nil }
        var withCode = product
        if withCode["code"] == nil { withCode["code"] = code }
        return self.product(withCode, language: language)
    }

    static func get(_ url: URL, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Open Food Facts answers "temporarily unavailable" now and then (a 503 on 2026-11-25, the next
        // request a second later fine). One quiet second try, then the failure goes to the screen.
        for attempt in 0..<2 {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if (200..<300).contains(http.statusCode) {
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            guard attempt == 0, [502, 503, 504].contains(http.statusCode) else { break }
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }
        throw URLError(.badServerResponse)
    }

    /// The export's per-100 g fields, the same conversion `Tools/build_food_packs.py` applies to packs.
    static let nutrimentKeys: [(FoodNutrient, String)] = [
        (.energyKcal, "energy-kcal_100g"), (.proteinG, "proteins_100g"), (.carbsG, "carbohydrates_100g"),
        (.fatG, "fat_100g"), (.fiberG, "fiber_100g"), (.sugarG, "sugars_100g"), (.satFatG, "saturated-fat_100g"),
        (.monoFatG, "monounsaturated-fat_100g"), (.polyFatG, "polyunsaturated-fat_100g"), (.omega3G, "omega-3-fat_100g"),
        (.sodiumMg, "sodium_100g"), (.saltG, "salt_100g"), (.potassiumMg, "potassium_100g"), (.calciumMg, "calcium_100g"),
        (.magnesiumMg, "magnesium_100g"), (.ironMg, "iron_100g"), (.zincMg, "zinc_100g"), (.vitaminCMg, "vitamin-c_100g"),
        (.vitaminDUg, "vitamin-d_100g"), (.vitaminB12Ug, "vitamin-b12_100g"), (.cholesterolMg, "cholesterol_100g"),
    ]

    static func product(_ json: [String: Any], language: String) -> FoodItem? {
        func text(_ key: String) -> String? {
            (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard let code = text("code") ?? (json["code"] as? NSNumber)?.stringValue,
              let name = text("product_name_\(language)") ?? text("product_name") ?? text("generic_name") else { return nil }
        let nutriments = json["nutriments"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? {
            if let n = nutriments[key] as? NSNumber { return n.doubleValue }
            if let s = nutriments[key] as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
            return nil
        }
        var amounts: [FoodNutrient: Double] = [:]
        for (nutrient, key) in nutrimentKeys {
            guard let grams = number(key) else { continue }
            switch nutrient.unit {
            case .kcal, .g: amounts[nutrient] = grams
            case .mg: amounts[nutrient] = grams * 1_000
            case .ug: amounts[nutrient] = grams * 1_000_000
            }
        }
        if amounts[.energyKcal] == nil, let kj = number("energy_100g") { amounts[.energyKcal] = kj / 4.184 }
        // A product that states its macronutrients but no energy at all is worked out from them (`FoodEnergy`),
        // instead of being thrown away and typed in by hand. An implausible result still fails the ceiling below.
        let energy = FoodEnergy.filling(NutrientAmounts(amounts))
        guard FoodEnergy.required.allSatisfy({ energy.amounts[$0] != nil }),
              let kcal = energy.amounts[.energyKcal], kcal <= 950 else { return nil }
        let serving = (json["serving_quantity"] as? NSNumber)?.doubleValue
            ?? (json["serving_quantity"] as? String).flatMap(Double.init)
        // The category IDs first: they are the same in every language and say more than the coarse group.
        let categories = FoodCategoryGroups.group(for: (json["categories_tags"] as? [String]) ?? [])
        let group = categories ?? text("pnns_groups_2").flatMap {
            $0 == "unknown" ? nil : $0.lowercased().replacingOccurrences(of: " ", with: "-")
        }
        // The package, and whether this is a drink. `nutrition_data_per` says "100g" for a cola whose values are
        // per 100 ml (seen 2026-11-25), so the package's own unit and the drink categories decide.
        let productQuantity = (json["product_quantity"] as? NSNumber)?.doubleValue
            ?? (json["product_quantity"] as? String).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        let package = FoodPackage.parse(quantity: text("quantity"), productQuantity: productQuantity,
                                        unit: text("product_quantity_unit"))
        let liquid = package?.liquid == true || (group?.split(separator: ",").contains { $0.contains("beverage") } ?? false)
        return FoodItem(id: "off:\(code)", source: .online, name: name,
                        brand: text("brands")?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces),
                        group: group, nova: (json["nova_group"] as? NSNumber)?.intValue,
                        servingG: serving.flatMap { $0 > 0 && $0 <= 5_000 ? $0 : nil }, servingLabel: text("serving_size"),
                        per100g: energy.amounts, barcode: code,
                        estimatedKeys: energy.filled ? [FoodEnergy.mark] : nil,
                        liquid: liquid ? true : nil, packageAmount: package?.amount,
                        packageCount: package.map { $0.count },
                        // The ingredient list and the full category tags, so the coach can read what a product is
                        // made of instead of guessing it from the name (owner, 2026-11-22). Neither is stored: they
                        // are read once, when the food is classified.
                        ingredients: text("ingredients_text"),
                        categories: (json["categories_tags"] as? [String])?.prefix(12).joined(separator: ", "))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The wearer's choice of product data, the same names on both platforms (`FoodProductData` in Kotlin).
public enum FoodProductDataMode: String, CaseIterable, Sendable, Codable {
    /// Not chosen yet: nothing leaves the phone, BLS and own foods only.
    case none
    /// Search Open Food Facts online, limited to the chosen countries.
    case online
    /// Downloaded country packs, searched on the phone.
    case packs
}

/// The downloadable packs on offer, as `Tools/build_food_packs.py` writes `manifest.json`.
public struct FoodPackManifest: Codable, Equatable, Sendable {
    public struct Pack: Codable, Equatable, Sendable {
        public var country: String, iso: String, rows: Int, builtAt: String, file: String, bytes: Int, sha256: String
    }
    public var tableFormat: Int
    public var attribution: String
    public var builtAt: String
    public var packs: [Pack]

    /// The fork's release that carries the packs (`.github/workflows/food-packs.yml`): a public file host,
    /// not a NOOP server; no request carries anything about the wearer.
    public static let releaseBase = "https://github.com/DX23876/noop/releases/download/food-packs/"
    public static var manifestURL: URL { URL(string: releaseBase + "manifest.json")! }

    public func url(for pack: Pack) -> URL? { URL(string: Self.releaseBase + pack.file) }

    /// Packs this build can read, largest first.
    public var usable: [Pack] {
        tableFormat == FoodCatalog.tableFormat ? packs.sorted { $0.rows > $1.rows } : []
    }

    public static func decode(_ data: Data) -> FoodPackManifest? { try? JSONDecoder().decode(Self.self, from: data) }
}
