import Foundation
import GRDB

/// A consistent copy of a database that is still being written to.
///
/// Backups used to stream the LIVE `whoop.sqlite` straight into the archive while the app's pool stayed
/// open. The ZIP came out complete and the container check passed, but a WAL checkpoint landing during
/// that read rewrites pages in the main file under the reader, so the database INSIDE the archive could
/// hold a mix of old and new pages and fail `PRAGMA quick_check` at restore — which is the one moment
/// nobody wants to discover it (#2885, two daily backups lost in a row).
///
/// SQLite's own backup API exists for this: it reads the source through a connection, restarts if a
/// writer moves pages beneath it, and produces a file that is a whole database as of some point in time.
/// The alternative — holding a write transaction for the length of the copy, as Android does (#1014) —
/// is equally correct but blocks every strap write until the archive is written, which on a large store
/// is minutes.
public enum LiveDatabaseCopy {

    /// Copy the database at `sourcePath` to `destinationPath`, checkpointed and with no sidecars left
    /// beside it, while writers carry on.
    ///
    /// The destination and any `-wal` / `-shm` / `-journal` left by an earlier copy are removed first: a
    /// fresh main file beside a stale WAL is its own kind of torn database.
    ///
    /// Note for callers: this needs free space of about the size of the live database, and it fails
    /// rather than producing a short file when there is not enough. A backup that cannot be made
    /// correctly must say so instead of quietly writing one that will not restore.
    public static func copy(fromPath sourcePath: String, toPath destinationPath: String) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: sourcePath) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: sourcePath])
        }
        for suffix in ["", "-wal", "-shm", "-journal"] where files.fileExists(atPath: destinationPath + suffix) {
            try files.removeItem(atPath: destinationPath + suffix)
        }
        // Read-only on the source: a backup must never be the thing that writes to the live store. The
        // destination is a plain queue — one connection, nothing else touches it — and GRDB's `backup`
        // drives sqlite3_backup across the two.
        var sourceConfig = Configuration()
        sourceConfig.readonly = true
        let source = try DatabaseQueue(path: sourcePath, configuration: sourceConfig)
        let destination = try DatabaseQueue(path: destinationPath)
        try source.backup(to: destination)
        // Leave the copy as a single file: the backup API writes through the destination's own journal,
        // and a checkpoint here means the archive carries one `.sqlite` with nothing beside it, which is
        // what every reader of a `.noopbak` expects.
        try destination.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        for suffix in ["-wal", "-shm"] where files.fileExists(atPath: destinationPath + suffix) {
            try? files.removeItem(atPath: destinationPath + suffix)
        }
    }
}
