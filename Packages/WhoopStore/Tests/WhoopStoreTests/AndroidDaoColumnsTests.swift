import XCTest
import GRDB
@testable import WhoopStore

/// Since Android dropped Room (5b5c4aa56) this store is Android's only store, written through the hand-written SQL in
/// `android/app/src/main/java/com/noop/data/CoreWhoopDao.kt`. That SQL still named three columns only Room had
/// (`workout.routePolyline`, `stepSample.synced`, `ppgHrSample.synced`), so every workout write on Android failed,
/// a Health Connect import with a workout included (2026-11-11). This test reads every INSERT and UPDATE in that file
/// and asserts each table and column it names exists after the full migration, so such a write cannot ship again.
final class AndroidDaoColumnsTests: XCTestCase {
    private var daoURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/java/com/noop/data/CoreWhoopDao.kt")
    }

    func testEveryColumnTheAndroidDaoWritesExists() async throws {
        guard let source = try? String(contentsOf: daoURL, encoding: .utf8) else {
            throw XCTSkip("The Android tree is not in this checkout.")
        }
        let store = try await WhoopStore.inMemory()
        let schema: [String: Set<String>] = try await store.dbWriter.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            var out: [String: Set<String>] = [:]
            for t in tables { out[t] = Set(try db.columns(in: t).map(\.name)) }
            return out
        }
        var checked = 0
        var problems: [String] = []
        let insert = try NSRegularExpression(pattern: #"(?:INSERT|REPLACE)[A-Z ]* INTO `(\w+)` \(([^)]*)\)"#)
        let update = try NSRegularExpression(pattern: #"UPDATE `(\w+)` SET ([^"]*?) WHERE"#)
        let ns = source as NSString
        func columns(_ list: String, splitOnEquals: Bool) -> [String] {
            list.split(separator: ",").map { part in
                let name = splitOnEquals ? String(part.split(separator: "=").first ?? "") : String(part)
                return name.trimmingCharacters(in: CharacterSet(charactersIn: " `"))
            }.filter { !$0.isEmpty }
        }
        for (regex, splitOnEquals) in [(insert, false), (update, true)] {
            for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let table = ns.substring(with: m.range(at: 1))
                guard let known = schema[table] else { problems.append("table \(table)"); continue }
                for column in columns(ns.substring(with: m.range(at: 2)), splitOnEquals: splitOnEquals) {
                    checked += 1
                    if !known.contains(column) { problems.append("\(table).\(column)") }
                }
            }
        }
        XCTAssertGreaterThan(checked, 100, "the parser found too few columns; the DAO's SQL shape changed")
        XCTAssertEqual(problems, [], "CoreWhoopDao.kt writes columns this store does not have")
    }
}
