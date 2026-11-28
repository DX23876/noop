import GRDB
import XCTest
@testable import WhoopStore

/// Copying the live database for a backup, while the app keeps writing to it (#2885, reported
/// 2026-10-31).
///
/// The exporter used to stream the LIVE file straight into the archive with the app's pool still open. A
/// WAL checkpoint landing during that read rewrites pages in the main file under the reader, so the
/// archive gets a mix of old and new pages: the ZIP is complete, `unzip -t` passes, the container check
/// passes, and the database inside fails `PRAGMA quick_check` at restore. Two daily backups in a row were
/// lost that way, and only at restore, which is the worst moment to find out.
///
/// `LiveDatabaseCopy` goes through SQLite's own backup API instead, which takes a consistent snapshot
/// while writers carry on.
final class LiveDatabaseCopyTests: XCTestCase {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("livecopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A WAL database with rows in the main file AND rows still in the WAL. A plain file copy of the
    /// `.sqlite` alone loses the second kind; the backup API must carry both.
    func testTheCopyCarriesWhatIsStillOnlyInTheWAL() throws {
        let dir = try scratch()
        let source = dir.appendingPathComponent("live.sqlite").path
        let queue = try DatabaseQueue(path: source)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE note (id INTEGER PRIMARY KEY, body TEXT)")
            try db.execute(sql: "INSERT INTO note (body) VALUES ('before')")
        }
        try queue.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        try queue.write { db in try db.execute(sql: "INSERT INTO note (body) VALUES ('after')") }

        let destination = dir.appendingPathComponent("copy.sqlite").path
        try LiveDatabaseCopy.copy(fromPath: source, toPath: destination)

        XCTAssertNil(DatabaseIntegrity.quickCheckFailure(atPath: destination))
        let copied = try DatabaseQueue(path: destination)
        let bodies = try copied.read { db in try String.fetchAll(db, sql: "SELECT body FROM note ORDER BY id") }
        XCTAssertEqual(bodies, ["before", "after"], "the copy holds the committed rows, WAL included")
    }

    /// The point of the whole exercise: a copy taken WHILE a writer commits and checkpoints is still a
    /// whole database. This is the shape that produced the torn backups — small page cache and a tight
    /// autocheckpoint, so pages move under the reader throughout the copy.
    func testACopyTakenWhileAWriterCommitsIsWhole() throws {
        let dir = try scratch()
        let source = dir.appendingPathComponent("live.sqlite").path
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA wal_autocheckpoint = 200") }
        let pool = try DatabasePool(path: source, configuration: config)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE sample (id INTEGER PRIMARY KEY, blob BLOB)")
        }
        let payload = Data(repeating: 0x5A, count: 4_096)
        for _ in 0..<200 {
            try pool.write { db in try db.execute(sql: "INSERT INTO sample (blob) VALUES (?)", arguments: [payload]) }
        }

        let writing = expectation(description: "the writer keeps going during the copy")
        let queue = DispatchQueue(label: "writer")
        var writerError: Error?
        queue.async {
            do {
                for _ in 0..<400 {
                    try pool.write { db in
                        try db.execute(sql: "INSERT INTO sample (blob) VALUES (?)", arguments: [payload])
                    }
                }
            } catch { writerError = error }
            writing.fulfill()
        }

        let destination = dir.appendingPathComponent("copy.sqlite").path
        try LiveDatabaseCopy.copy(fromPath: source, toPath: destination)
        wait(for: [writing], timeout: 60)
        XCTAssertNil(writerError)

        XCTAssertNil(DatabaseIntegrity.quickCheckFailure(atPath: destination),
                     "a copy taken under a committing writer must still restore")
        let copied = try DatabaseQueue(path: destination)
        let rows = try copied.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sample") ?? 0 }
        XCTAssertGreaterThanOrEqual(rows, 200, "the copy holds at least what was committed before it began")
    }

    /// A copy replaces whatever was at the destination, including the sidecars a previous copy left, so a
    /// second backup never mixes a fresh main file with a stale WAL.
    func testTheDestinationIsReplacedWithItsSidecars() throws {
        let dir = try scratch()
        let source = dir.appendingPathComponent("live.sqlite").path
        let queue = try DatabaseQueue(path: source)
        try queue.write { db in try db.execute(sql: "CREATE TABLE note (id INTEGER PRIMARY KEY)") }

        let destination = dir.appendingPathComponent("copy.sqlite").path
        FileManager.default.createFile(atPath: destination, contents: Data("stale".utf8))
        FileManager.default.createFile(atPath: destination + "-wal", contents: Data("stale".utf8))
        FileManager.default.createFile(atPath: destination + "-shm", contents: Data("stale".utf8))

        try LiveDatabaseCopy.copy(fromPath: source, toPath: destination)

        XCTAssertNil(DatabaseIntegrity.quickCheckFailure(atPath: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination + "-wal"),
                       "the copy is checkpointed, so it needs no WAL beside it")
    }

    /// A missing source is a failure to report, not an empty file to hand on as a backup.
    func testAMissingSourceThrows() throws {
        let dir = try scratch()
        XCTAssertThrowsError(try LiveDatabaseCopy.copy(fromPath: dir.appendingPathComponent("nope.sqlite").path,
                                                       toPath: dir.appendingPathComponent("copy.sqlite").path))
    }
}
