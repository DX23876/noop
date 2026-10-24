import Foundation
/// Raw-outbox retention. Raw is transient working data — there is NO server and no archive;
/// the decoded streams are the durable record. Pruning never loses a decoded metric because
/// decoded is persisted before the raw batch is enqueued (E2 invariant), so the oldest raw is
/// always the safest to drop. The byte cap bounds local storage (#27): an experimental capture
/// toggle would otherwise grow without limit (a 5/MG user saw 19 GB).
public enum PrunePolicy {
    public static let keepWindowSeconds = 24 * 3600        // keep synced raw browsable ~24h
    public static let maxUnsyncedBytes = 50 * 1024 * 1024  // total raw footprint cap; evict oldest beyond ~50MB
}
