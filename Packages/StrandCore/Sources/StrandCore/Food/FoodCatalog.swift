import Foundation
import GRDB
import Crypto
import ZIPFoundation

/// One food the add sheet can offer: from the bundled BLS table, an installed country pack, the wearer's own
/// foods or an online result. Nutrients are per 100 g.
public struct FoodItem: Equatable, Sendable, Identifiable, Codable {
    public enum Source: String, Sendable, Codable { case bls, off, own, online, recipe }

    public var id: String
    public var source: Source
    public var name: String
    public var nameEn: String?
    public var brand: String?
    public var group: String?
    public var nova: Int?
    public var servingG: Double?
    public var servingLabel: String?
    public var per100g: NutrientAmounts
    /// The product barcode, for packs, online results and the wearer's scanned foods.
    public var barcode: String?
    /// The BLS food whose values filled this one's gaps, and which nutrients they are (`FoodEstimate`).
    public var estimatedFrom: String?
    public var estimatedKeys: [String]?

    public init(id: String, source: Source, name: String, nameEn: String? = nil, brand: String? = nil,
                group: String? = nil, nova: Int? = nil, servingG: Double? = nil, servingLabel: String? = nil,
                per100g: NutrientAmounts, barcode: String? = nil, estimatedFrom: String? = nil, estimatedKeys: [String]? = nil) {
        self.estimatedFrom = estimatedFrom; self.estimatedKeys = estimatedKeys
        self.id = id; self.source = source; self.name = name; self.nameEn = nameEn; self.brand = brand
        self.group = group; self.nova = nova; self.servingG = servingG; self.servingLabel = servingLabel
        self.per100g = per100g; self.barcode = barcode
    }
}

extension FoodItem {
    /// The name to show in `language` (an ISO language code): BLS rows carry an English name beside the German
    /// one, and every language but German reads the English one, since it is closer than German to all of them.
    /// Every other source has a single name.
    public static func displayName(name: String, nameEn: String?, source: Source, language: String) -> String {
        guard source == .bls, language != "de",
              let english = nameEn?.trimmingCharacters(in: .whitespaces), !english.isEmpty else { return name }
        return english
    }
}

/// An installed country pack of Open Food Facts products.
public struct InstalledFoodPack: Equatable, Sendable, Codable {
    public var country: String
    public var iso: String
    public var rows: Int
    public var builtAt: String
    public var sha256: String
}

/// The read-only food catalogues: the BLS table every build carries, and the country packs the wearer chose
/// to download. Each lives in its own SQLite file in Application Support (never in the wearer's store, never
/// in a backup), built by `FoodCatalogImporter` from the shared table format, so iOS and Android search the
/// same index with the same normalisation.
public actor FoodCatalog {
    public static let shared = FoodCatalog()

    /// Format of the table the builders write (`TABLE_FORMAT` in `Tools/food_catalog_common.py`).
    public static let tableFormat = 1
    /// Format of the SQLite files built here; a change rebuilds them from their source.
    static let fileFormat = 1

    /// Folder holding `food-bls.tsv` and `food-bls.json`. Android ships them as assets and sets this before the
    /// first read; nil on Apple, where the package bundle has them.
    nonisolated(unsafe) public static var resourceDirectory: URL?
    /// The app language the catalogue names its foods in (`FoodItem.displayName`). Set once at launch, before the
    /// first read; German until then, which is also what Android shows.
    nonisolated(unsafe) public static var nameLanguage = "de"

    public enum Failure: String, Error {
        case bundledTableMissing, invalidArchive, unsafeArchive, checksumMismatch, unknownFormat, packTooLarge,
             notEnoughSpace
    }

    private let directoryOverride: URL?
    private var queues: [String: DatabaseQueue] = [:]
    /// The BLS rows held for composition matching; 7,140 foods, read once.
    private var blsRows: [FoodItem]?
    private var blsMaxima: [FoodNutrient: Double]?

    public init(directory: URL? = nil) {
        self.directoryOverride = directory
    }

    public var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FoodCatalog", isDirectory: true)
    }

    // MARK: Bundled BLS

    /// The BLS table's provenance, as `Tools/build_food_catalog.py` wrote it.
    public struct BundledMeta: Codable, Equatable, Sendable {
        public var tableFormat: Int, source: String, version: String, rows: Int, licence: String, citation: String,
                   doi: String, publisher: String, url: String, tableSha256: String
    }

    public nonisolated static func bundledURL(_ name: String, _ ext: String) -> URL? {
        if let resourceDirectory {
            let url = resourceDirectory.appendingPathComponent("\(name).\(ext)")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        #if os(Android)
        return nil
        #else
        return Bundle.module.url(forResource: name, withExtension: ext)
        #endif
    }

    public nonisolated static func bundledMeta() -> BundledMeta? {
        guard let url = bundledURL("food-bls", "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BundledMeta.self, from: data)
    }

    /// Builds the BLS search file when it is missing or older than the bundled table. Cheap when current.
    public func prepareBundled() throws {
        guard let table = Self.bundledURL("food-bls", "tsv"), let meta = Self.bundledMeta(),
              meta.tableFormat == Self.tableFormat else { throw Failure.bundledTableMissing }
        let target = fileURL("bls")
        if let current = try? openFile(target), (try? current.read({ try Self.metaValue($0, "tableSha256") })) == meta.tableSha256,
           (try? current.read({ try Self.metaValue($0, "fileFormat") })) == String(Self.fileFormat) {
            queues["bls"] = current
            return
        }
        queues["bls"] = nil
        try FoodCatalogImporter.build(table: table, into: target, meta: [
            "source": "bls", "tableSha256": meta.tableSha256, "rows": String(meta.rows), "version": meta.version,
        ], indexSuffixes: true)
        queues["bls"] = try openFile(target)
    }

    // MARK: Packs

    public func installedPacks() -> [InstalledFoodPack] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("off-") && $0.hasSuffix(".sqlite") }.sorted().compactMap { name in
            let key = String(name.dropLast(".sqlite".count))
            guard let queue = try? queue(for: key) else { return nil }
            return try? queue.read { db in
                guard let country = try Self.metaValue(db, "country") else { return nil }
                return InstalledFoodPack(country: country, iso: try Self.metaValue(db, "iso") ?? "",
                                         rows: Int(try Self.metaValue(db, "rows") ?? "") ?? 0,
                                         builtAt: try Self.metaValue(db, "builtAt") ?? "",
                                         sha256: try Self.metaValue(db, "archiveSha256") ?? "")
            }
        }
    }

    /// Installs a downloaded pack. Checks the archive's SHA-256 against the manifest's, reads only the two
    /// entries a pack has, builds the search file beside the old one and swaps it in last, so a failure at any
    /// point leaves the previous pack in place.
    @discardableResult
    public func installPack(archive: URL, expectedSha256: String) throws -> InstalledFoodPack {
        guard try ExerciseMediaPack.sha256(of: archive) == expectedSha256.lowercased() else { throw Failure.checksumMismatch }
        let zip: Archive
        do { zip = try Archive(url: archive, accessMode: .read) } catch { throw Failure.invalidArchive }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var table: URL?
        var packMeta: [String: Any] = [:]
        for entry in zip {
            guard entry.type == .file, !entry.path.contains("/"), !entry.path.contains("\\") else {
                if entry.type == .symlink { throw Failure.unsafeArchive }
                continue
            }
            switch entry.path {
            case "products.tsv":
                guard entry.uncompressedSize <= 2_000_000_000 else { throw Failure.packTooLarge }
                let out = staging.appendingPathComponent("products.tsv")
                try Self.extract(entry, from: zip, to: out, limit: Int64(entry.uncompressedSize))
                table = out
            case "pack.json":
                guard entry.uncompressedSize <= 100_000 else { throw Failure.packTooLarge }
                var data = Data()
                _ = try zip.extract(entry) { data.append($0) }
                packMeta = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            default:
                continue
            }
        }
        guard let table, let country = packMeta["country"] as? String,
              country.range(of: "^[a-z0-9-]{2,60}$", options: .regularExpression) != nil else { throw Failure.invalidArchive }
        guard (packMeta["tableFormat"] as? Int) == Self.tableFormat else { throw Failure.unknownFormat }
        let attributes = try fm.attributesOfFileSystem(forPath: directory.path)
        let tableBytes = (try? fm.attributesOfItem(atPath: table.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < tableBytes * 2 + 50_000_000 {
            throw Failure.notEnoughSpace
        }
        let key = "off-\(country)"
        let built = staging.appendingPathComponent("\(key).sqlite")
        try FoodCatalogImporter.build(table: table, into: built, meta: [
            "source": "off", "country": country, "iso": packMeta["iso"] as? String ?? "",
            "rows": String(packMeta["rows"] as? Int ?? 0), "builtAt": packMeta["builtAt"] as? String ?? "",
            "archiveSha256": expectedSha256.lowercased(),
        ], indexSuffixes: false)
        queues[key] = nil
        let target = fileURL(key)
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: built) }
        else { try fm.moveItem(at: built, to: target) }
        Self.excludeFromBackup(target)
        guard let installed = installedPacks().first(where: { $0.country == country }) else { throw Failure.invalidArchive }
        return installed
    }

    public func removePack(country: String) {
        let key = "off-\(country)"
        queues[key] = nil
        try? FileManager.default.removeItem(at: fileURL(key))
    }

    // MARK: Search

    /// Foods whose words start with every word of the query, best first, across BLS and every installed pack.
    public func search(_ query: String, limit: Int = 40) -> [FoodItem] {
        let words = FoodSearchText.tokens(query)
        guard !words.isEmpty, limit > 0 else { return [] }
        var scored: [(item: FoodItem, score: Double)] = []
        for key in catalogKeys() {
            guard let queue = try? queue(for: key) else { continue }
            let sourceBonus = key == "bls" ? 0.5 : 0
            scored += ((try? queue.read { try Self.search(db: $0, words: words, limit: limit) }) ?? [])
                .map { ($0.item, $0.score + sourceBonus) }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.name < $1.item.name }
            .prefix(limit).map(\.item)
    }

    /// BLS foods with the most similar make-up per 100 g (`FoodEstimate.distance`), for borrowing missing values by
    /// composition rather than by name: a protein pudding resembles low-fat quark more than vanilla pudding.
    public func nearestBLS(to item: FoodItem, limit: Int = 8) -> [FoodItem] {
        loadBLSRows().compactMap { candidate in FoodEstimate.distance(item, candidate).map { (candidate, $0) } }
            .sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// The highest value any BLS food has for `nutrient`, the plausibility ceiling for a model's estimate.
    public func blsMaximum(_ nutrient: FoodNutrient) -> Double? {
        if blsMaxima == nil {
            var maxima: [FoodNutrient: Double] = [:]
            for row in loadBLSRows() {
                for (n, value) in row.per100g.values where value > (maxima[n] ?? -1) { maxima[n] = value }
            }
            blsMaxima = maxima
        }
        return blsMaxima?[nutrient]
    }

    /// The BLS rows, read once and held for composition matching.
    private func loadBLSRows() -> [FoodItem] {
        if let blsRows { return blsRows }
        let rows = (try? queue(for: "bls").read { db in try Row.fetchAll(db, sql: "SELECT * FROM food").compactMap(Self.item) }) ?? []
        if !rows.isEmpty { blsRows = rows }
        return rows
    }

    public func item(id: String) -> FoodItem? {
        for key in catalogKeys() {
            guard let queue = try? queue(for: key),
                  let row = try? queue.read({ try Row.fetchOne($0, sql: "SELECT * FROM food WHERE id = ?", arguments: [id]) })
            else { continue }
            return Self.item(row)
        }
        return nil
    }

    /// A packaged product by barcode. EAN-13 and the 12-digit UPC-A of the same product are one code.
    public func item(barcode: String) -> FoodItem? {
        for code in Self.barcodeVariants(barcode) {
            if let found = item(id: "off:\(code)") { return found }
        }
        return nil
    }

    public nonisolated static func barcodeVariants(_ raw: String) -> [String] {
        let digits = raw.filter(\.isNumber)
        guard (6...14).contains(digits.count) else { return [] }
        var out = [digits]
        if digits.count == 12 { out.append("0" + digits) }
        if digits.count == 13, digits.hasPrefix("0") { out.append(String(digits.dropFirst())) }
        return out
    }

    // MARK: Files

    private func catalogKeys() -> [String] {
        var keys = ["bls"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        keys += names.filter { $0.hasPrefix("off-") && $0.hasSuffix(".sqlite") }.sorted().map { String($0.dropLast(7)) }
        return keys
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).sqlite") }

    private func queue(for key: String) throws -> DatabaseQueue {
        if let queue = queues[key] { return queue }
        let queue = try openFile(fileURL(key))
        queues[key] = queue
        return queue
    }

    private func openFile(_ url: URL) throws -> DatabaseQueue {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.bundledTableMissing }
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    static func metaValue(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    static func excludeFromBackup(_ url: URL) {
        #if os(iOS) || os(macOS)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }

    private static func extract(_ entry: Entry, from archive: Archive, to out: URL, limit: Int64) throws {
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        var written: Int64 = 0
        _ = try archive.extract(entry) { chunk in
            guard written + Int64(chunk.count) <= limit else { throw Failure.packTooLarge }
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
        }
    }

    // MARK: Query

    /// Candidates per word, intersected; ranked by whole-word matches, a name that starts with the first word,
    /// and shorter names (a plain "Apfel roh" before "Apfelstrudel mit Vanillesoße").
    static func search(db: Database, words: [String], limit: Int) throws -> [(item: FoodItem, score: Double)] {
        var matches: [Int64: Int]?
        for word in words {
            let rows = try Row.fetchAll(db, sql: """
                SELECT food, MAX(whole) AS whole FROM token WHERE token >= ? AND token < ? GROUP BY food LIMIT 20000
                """, arguments: [word, word + "\u{10FFFF}"])
            var next: [Int64: Int] = [:]
            for row in rows {
                let food: Int64 = row["food"], whole: Int = row["whole"]
                if let previous = matches { if let count = previous[food] { next[food] = count + whole } }
                else { next[food] = whole }
            }
            matches = next
            if next.isEmpty { return [] }
        }
        guard let matches else { return [] }
        let best = matches.sorted { $0.value > $1.value }.prefix(max(limit * 8, 200))
        let ids = best.map(\.key)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: "SELECT rowid AS rid, * FROM food WHERE rowid IN (\(placeholders))",
                                    arguments: StatementArguments(ids))
        let first = words[0], query = words.joined()
        return rows.compactMap { row -> (FoodItem, Double)? in
            guard let item = item(row) else { return nil }
            let rid: Int64 = row["rid"]
            let normalised = FoodSearchText.normalised(item.name)
            let compact = normalised.replacingOccurrences(of: " ", with: "")
            var score = Double(matches[rid] ?? 0) * 3
            if normalised.hasPrefix(first) || compact.hasPrefix(first) { score += 4 }
            // The whole name typed: "haferflocken" for "Hafer Flocken", "hafer flocken roh" for its raw form.
            if compact == query || compact.hasPrefix(query) && compact.count - query.count <= 4 { score += 6 }
            if let brand = item.brand, FoodSearchText.normalised(brand).hasPrefix(first) { score += 1 }
            score -= Double(item.name.count) / 25
            return (item, score)
        }
    }

    static func item(_ row: Row) -> FoodItem? {
        guard let id: String = row["id"], let sourceRaw: String = row["source"],
              let source = FoodItem.Source(rawValue: sourceRaw), let name: String = row["name"] else { return nil }
        var amounts: [FoodNutrient: Double] = [:]
        for nutrient in FoodNutrient.allCases {
            if let value: Double = row["n_\(nutrient.rawValue)"] { amounts[nutrient] = value }
        }
        func text(_ column: String) -> String? { (row[column] as String?).flatMap { $0.isEmpty ? nil : $0 } }
        let nameEn = text("name_en")
        return FoodItem(id: id, source: source,
                        name: FoodItem.displayName(name: name, nameEn: nameEn, source: source, language: nameLanguage),
                        nameEn: nameEn, brand: text("brand"),
                        group: text("grp"), nova: row["nova"], servingG: row["serving_g"],
                        servingLabel: text("serving_label"), per100g: NutrientAmounts(amounts),
                        barcode: source == .off ? String(id.dropFirst(4)) : nil)
    }
}

/// Builds a catalogue's search file from the shared table format.
public enum FoodCatalogImporter {
    static let metaColumns = ["id", "source", "name", "name_en", "brand", "group", "nova", "serving_g", "serving_label"]

    /// Reads `table` line by line and writes `into` (replaced). `indexSuffixes` adds compound tails to the
    /// index ("brot" finds "Vollkornbrot"); worth it for the 7,000 BLS foods, too large for country packs.
    public static func build(table: URL, into target: URL, meta: [String: String], indexSuffixes: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).sqlite")
        defer { try? fm.removeItem(at: temporary) }
        let queue = try DatabaseQueue(path: temporary.path)
        let nutrientColumns = FoodNutrient.allCases.map { "n_\($0.rawValue) REAL" }.joined(separator: ", ")
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                CREATE TABLE food (rowid INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, source TEXT NOT NULL,
                    name TEXT NOT NULL, name_en TEXT, brand TEXT, grp TEXT, nova INTEGER, serving_g REAL,
                    serving_label TEXT, \(nutrientColumns));
                CREATE TABLE token (token TEXT NOT NULL, food INTEGER NOT NULL, whole INTEGER NOT NULL);
                """)
        }
        let reader = try LineReader(url: table)
        guard let header = reader.next()?.components(separatedBy: "\t"),
              header == metaColumns + FoodNutrient.allCases.map(\.rawValue) else { throw FoodCatalog.Failure.unknownFormat }
        let insertColumns = ["id", "source", "name", "name_en", "brand", "grp", "nova", "serving_g", "serving_label"]
            + FoodNutrient.allCases.map { "n_\($0.rawValue)" }
        let insertSQL = "INSERT OR IGNORE INTO food (\(insertColumns.joined(separator: ", "))) VALUES ("
            + Array(repeating: "?", count: insertColumns.count).joined(separator: ", ") + ")"
        var rows = 0
        var done = false
        while !done {
            // Batches keep one transaction from holding hundreds of thousands of rows in memory.
            try queue.write { db in
                let insert = try db.makeStatement(sql: insertSQL)
                let token = try db.makeStatement(sql: "INSERT INTO token (token, food, whole) VALUES (?, ?, ?)")
                var batch = 0
                while batch < 5_000 {
                    guard let line = reader.next() else { done = true; return }
                    let cells = line.components(separatedBy: "\t")
                    guard cells.count == header.count, !cells[0].isEmpty, !cells[2].isEmpty else { continue }
                    var values: [DatabaseValueConvertible?] = []
                    for (index, cell) in cells.enumerated() {
                        switch index {
                        case 0...5, 8: values.append(cell.isEmpty && index > 2 ? nil : cell)
                        case 6: values.append(Int(cell))
                        default: values.append(Double(cell))
                        }
                    }
                    try insert.execute(arguments: StatementArguments(values))
                    guard db.changesCount > 0 else { continue }
                    let food = db.lastInsertedRowID
                    var words: [String: Int] = [:]
                    for word in FoodSearchText.tokens(cells[2] + " " + cells[4]) { words[word] = 1 }
                    for word in FoodSearchText.tokens(cells[3]) where words[word] == nil { words[word] = 1 }
                    for pair in FoodSearchText.joinedPairs(cells[2]) where words[pair] == nil { words[pair] = 1 }
                    if indexSuffixes {
                        for word in Array(words.keys) {
                            for tail in FoodSearchText.suffixes(word) where words[tail] == nil { words[tail] = 0 }
                        }
                    }
                    for (word, whole) in words { try token.execute(arguments: [word, food, whole]) }
                    rows += 1
                    batch += 1
                }
            }
        }
        try queue.write { db in
            try db.execute(sql: "CREATE INDEX token_prefix ON token(token)")
            var all = meta
            all["fileFormat"] = String(FoodCatalog.fileFormat)
            all["importedRows"] = String(rows)
            for (key, value) in all {
                try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
            }
        }
        try queue.vacuum()
        try queue.close()
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: temporary, to: target)
        FoodCatalog.excludeFromBackup(target)
    }
}

/// UTF-8 lines of a file, read in 1 MiB chunks, so a country pack is never held in memory whole.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false

    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }

    func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                var text = String(decoding: line, as: UTF8.self)
                if text.hasSuffix("\r") { text.removeLast() }
                return text
            }
            if finished {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
            if let chunk, !chunk.isEmpty { buffer.append(chunk) } else { finished = true }
        }
    }
}
