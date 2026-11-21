import Foundation
import StrandAnalytics
import WhoopStore

/// Correcting a night's bed and wake times, retiring a night, and putting a retired one back: one
/// implementation for both platforms.
///
/// This used to be the Apple app's alone (`Repository.editSleepGroupTimes`), with a thinner Kotlin
/// version beside it. The two did not differ in taste, they differed in what they could do: the Apple
/// side resolved which namespace owns each row, re-staged a night that GREW from the raw streams, and
/// named why a correction was refused, while Android did none of that and, worse, looked for the night's
/// rows in the imported lane alone. A night NOOP had computed itself was therefore unchangeable on
/// Android, in silence, which is how a tester lost every correction he made (2026-11-21).
///
/// Three properties this file exists to keep:
///
/// 1. **The caller names the rows.** Nothing here searches for "the night around this time". The group
///    comes from the screen that drew it (`CoreRead.Night.blocks`), so the rows written are the rows
///    seen. Which namespace owns each one is resolved here, by key, against the same owner list the
///    reads use.
/// 2. **Every outcome is named.** No path returns an indistinguishable nil. A refusal says whether the
///    window was impossible, whether it overlapped nothing, whether a row had no owner, or whether the
///    write failed, and the caller can say so.
/// 3. **Where a marker is kept stays the caller's.** The Apple apps hold "the wearer deleted this"
///    spans in defaults, Android in the store's own table. This decides WHETHER one belongs and hands
///    the caller the rows; it never reaches into either home.
public enum SleepNightEdit {

    /// One row taken out of a night, with everything needed to put it back exactly as it was.
    public struct Retired: Equatable, Sendable {
        public let session: CachedSleepSession
        /// The namespace the row was read from and must be restored into.
        public let ownerDeviceId: String
        /// The night's wake instant, which a deletion marker records alongside the onset.
        public let endTs: Int
        /// The per-epoch motion series, which `CachedSleepSession` does not carry. Deleting the row drops
        /// the column, so a restore must write it back or a hand-edited night loses its timeline.
        public var motion: [Double]?
        /// The per-epoch banked sleep-state series, kept for the same reason as `motion`.
        public var sleepState: [Int]?
        /// Whether a durable "the wearer deleted this" marker belongs with this row. A detected night
        /// needs one or the next analysis pass re-creates it; a hand-made or hand-corrected one is never
        /// re-detected, so a marker would only block a real future night overlapping its window.
        public let writesTombstone: Bool

        public init(session: CachedSleepSession, ownerDeviceId: String, endTs: Int,
                    motion: [Double]? = nil, sleepState: [Int]? = nil, writesTombstone: Bool) {
            self.session = session
            self.ownerDeviceId = ownerDeviceId
            self.endTs = endTs
            self.motion = motion
            self.sleepState = sleepState
            self.writesTombstone = writesTombstone
        }
    }

    /// What one applied correction changed.
    public struct EditSuccess: Sendable {
        /// Fragments that fell outside the new window and were taken out; the caller offers these as one undo.
        public let retired: [Retired]
        /// The local wake days whose figures the correction can have moved.
        public let affectedWakeDays: Set<String>
        /// True when a row NOOP computed itself was touched, so the day must be scored again locally.
        public let requiresLocalRescore: Bool
        /// How many rows were rewritten.
        public let edited: Int
    }

    /// Why a correction did not reach the database. Every one of these was an indistinguishable "nothing
    /// happened" on Android, which is the report this type exists to answer.
    public enum Failure: String, Error, Equatable, Sendable {
        /// The night named no rows at all, so there is nothing this correction could be about.
        case noBlocks
        /// The window was inverted, longer than a day, or wholly in the future.
        case invalidWindow
        /// The window overlaps no fragment of the night and the caller did not allow a move.
        case noOverlap
        /// A fragment has no row in any namespace this install can write.
        case ownerUnresolved
        /// The transaction failed, or matched a different number of rows than planned; nothing was written.
        case writeFailed
    }

    /// The key a stored sleep row is identified by: its immutable detected onset, and the namespace it
    /// was read from when the reader knew it.
    public struct BlockKey: Equatable, Sendable {
        public let deviceId: String?
        public let startTs: Int
        public init(deviceId: String?, startTs: Int) {
            self.deviceId = deviceId
            self.startTs = startTs
        }
    }

    // MARK: - Finding the night's own rows

    /// The stored rows for [keys], oldest first, skipping any key no namespace holds.
    ///
    /// For a caller that holds keys rather than rows (Android, across the bridge). The Apple apps already
    /// hold the sessions the night was drawn from and pass those straight to [editTimes].
    public static func rows(store: WhoopStore, ownerIds: [String],
                            keys: [BlockKey]) async -> [CachedSleepSession] {
        var found: [CachedSleepSession] = []
        for key in keys {
            if let owned = await ownedRow(store: store, ownerIds: ownerIds,
                                          detectedStartTs: key.startTs, preferring: key.deviceId) {
                found.append(owned.session)
            }
        }
        return found.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// The row with this detected onset and the namespace that owns it, or nil when none does.
    ///
    /// `preferring` is tried first, so a key that already knows its namespace cannot be answered by a
    /// coincidental row with the same onset in the other one.
    static func ownedRow(store: WhoopStore, ownerIds: [String], detectedStartTs: Int,
                         preferring: String? = nil) async -> (session: CachedSleepSession, owner: String)? {
        func row(_ deviceId: String) async -> CachedSleepSession? {
            let rows = (try? await store.sleepSessions(deviceId: deviceId, from: detectedStartTs,
                                                       to: detectedStartTs, limit: 4)) ?? []
            return rows.first { $0.startTs == detectedStartTs }
        }
        var order = ownerIds
        if let preferring, let at = order.firstIndex(of: preferring) {
            order.remove(at: at)
            order.insert(preferring, at: 0)
        } else if let preferring {
            order.insert(preferring, at: 0)
        }
        for owner in order {
            if let session = await row(owner) { return (session, owner) }
        }
        return nil
    }

    /// The row at this detected onset with its sidecar series, ready to be put back.
    ///
    /// `preferring` is the namespace the caller already knows the row came from. Pass it wherever it is
    /// known: without it the search falls back to the owner order, and two rows can share a detected
    /// onset across the lanes.
    public static func snapshot(store: WhoopStore, ownerIds: [String], detectedStartTs: Int,
                                preferring: String? = nil) async -> Retired? {
        guard let owned = await ownedRow(store: store, ownerIds: ownerIds,
                                         detectedStartTs: detectedStartTs,
                                         preferring: preferring) else { return nil }
        let motion = try? await store.sessionMotion(deviceId: owned.owner, sessionStart: detectedStartTs)
        let sleepState = try? await store.sessionSleepState(deviceId: owned.owner, sessionStart: detectedStartTs)
        return Retired(session: owned.session, ownerDeviceId: owned.owner, endTs: owned.session.endTs,
                       motion: motion ?? nil, sleepState: sleepState ?? nil,
                       writesTombstone: DismissedSleepSpans.writesTombstoneOnDelete(
                           userEdited: owned.session.userEdited))
    }

    // MARK: - Correcting a night

    /// Apply a hand-corrected bed/wake window across a night, every fragment of it.
    ///
    /// A split night displays as one group whose bedtime is the first fragment's onset and whose wake is
    /// the group's latest end, so correcting only the longest fragment would leave both drawn bounds
    /// untouched and look like nothing happened. Fragments overlapping the new window are clipped to it
    /// and marked as the wearer's; fragments left wholly outside are retired, so a detected one cannot be
    /// re-detected straight back into the night.
    ///
    /// `restage` is asked for new stages only for a fragment whose window GREW. The planner can reshape
    /// stages that exist but cannot invent the ones for time the old window never covered, and a fabricated
    /// trailing "awake" block would become the night's stored truth. A window that only narrows keeps the
    /// cheap re-clip and is unchanged by this.
    ///
    /// `willRetire` runs with the rows about to be taken out, BEFORE the transaction, so a caller can arm
    /// its deletion markers where no concurrent analysis can slip a re-detected edge in between; `rollback`
    /// runs when the write then fails, so the caller can put its own state back.
    public static func editTimes(
        store: WhoopStore, ownerIds: [String], group: [CachedSleepSession],
        newStartTs: Int, newEndTs: Int, allowRelocation: Bool = false,
        now: Int = Int(Date().timeIntervalSince1970),
        restage: (_ start: Int, _ end: Int) async -> String? = { _, _ in nil },
        willRetire: (_ rows: [Retired]) async -> Void = { _ in },
        rollback: () async -> Void = {}
    ) async -> Result<EditSuccess, Failure> {
        guard !group.isEmpty else { return .failure(.noBlocks) }
        guard let window = SleepEditGuard.clampedEditWindow(start: newStartTs, end: newEndTs, now: now) else {
            return .failure(.invalidWindow)
        }
        var plan = SleepGroupEdit.plan(group, newStartTs: window.start, newEndTs: window.end)
        if plan.clipped.isEmpty, allowRelocation {
            plan = SleepGroupEdit.relocationPlan(group, newStartTs: window.start, newEndTs: window.end)
        }
        guard !plan.clipped.isEmpty else { return .failure(.noOverlap) }

        // Which namespace each row came from, read off the GROUP the caller named.
        //
        // Not off the planner's fragments: `SleepGroupEdit.plan` builds its clipped rows as fresh values
        // and constructs them without a deviceId, so a fragment's own field is always nil. Reading it
        // there compiles, looks right, and silently falls back to the owner order — which is the guess
        // this whole type exists to remove, and it would write the other lane's row whenever two share a
        // detected onset.
        let lane = Dictionary(group.compactMap { row in row.deviceId.map { (row.startTs, $0) } },
                              uniquingKeysWith: { first, _ in first })
        // Resolve every immutable key to the namespace that owns it before mutating anything.
        var owners: [Int: String] = [:]
        for fragment in plan.clipped {
            guard let owned = await ownedRow(store: store, ownerIds: ownerIds,
                                             detectedStartTs: fragment.startTs,
                                             preferring: lane[fragment.startTs]) else {
                return .failure(.ownerUnresolved)
            }
            owners[fragment.startTs] = owned.owner
        }
        var retired: [Retired] = []
        for fragment in plan.dropped {
            guard let snapshot = await snapshot(store: store, ownerIds: ownerIds,
                                                detectedStartTs: fragment.startTs,
                                                preferring: lane[fragment.startTs]) else {
                return .failure(.ownerUnresolved)
            }
            retired.append(snapshot)
        }

        let priorBounds = Dictionary(group.map { ($0.startTs, (start: $0.effectiveStartTs, end: $0.endTs)) },
                                     uniquingKeysWith: { first, _ in first })
        var edits: [SleepSessionEditMutation] = []
        edits.reserveCapacity(plan.clipped.count)
        for fragment in plan.clipped {
            guard let owner = owners[fragment.startTs] else { return .failure(.ownerUnresolved) }
            let prior = priorBounds[fragment.startTs]
            let grew = prior.map { fragment.effectiveStartTs < $0.start || fragment.endTs > $0.end } ?? true
            let stages = grew
                ? (await restage(fragment.effectiveStartTs, fragment.endTs) ?? fragment.stagesJSON)
                : fragment.stagesJSON
            edits.append(SleepSessionEditMutation(deviceId: owner, detectedStartTs: fragment.startTs,
                                                  newStartTs: fragment.effectiveStartTs,
                                                  newEndTs: fragment.endTs, stagesJSON: stages))
        }
        let drops = retired.map {
            SleepSessionDeleteMutation(deviceId: $0.ownerDeviceId, detectedStartTs: $0.session.startTs)
        }

        await willRetire(retired)
        do {
            let changed = try await store.applySleepGroupEdit(edits: edits, drops: drops)
            guard changed.edited == edits.count, changed.deleted == drops.count else {
                await rollback()
                return .failure(.writeFailed)
            }
        } catch {
            await rollback()
            return .failure(.writeFailed)
        }
        let affectedWakeDays = Set(group.map { StoreReader.sleepEndDayKey($0.endTs) }
            + plan.clipped.map { StoreReader.sleepEndDayKey($0.endTs) })
        let requiresLocalRescore = (edits.map(\.deviceId) + drops.map(\.deviceId))
            .contains { $0.hasSuffix("-noop") }
        return .success(EditSuccess(retired: retired, affectedWakeDays: affectedWakeDays,
                                    requiresLocalRescore: requiresLocalRescore, edited: edits.count))
    }

    // MARK: - Retiring and restoring

    /// Take one night out of the store, from whichever namespace owns it, and hand back what it takes to
    /// put it back. Nil when no namespace holds a row at that onset, which is the only honest answer: the
    /// caller must not report a deletion that did not happen.
    ///
    /// `willRetire` and `rollback` have the same meaning as in [editTimes].
    public static func deleteNight(
        store: WhoopStore, ownerIds: [String], detectedStartTs: Int, preferring: String? = nil,
        willRetire: (_ row: Retired) async -> Void = { _ in },
        rollback: () async -> Void = {}
    ) async -> Retired? {
        guard let snapshot = await snapshot(store: store, ownerIds: ownerIds,
                                            detectedStartTs: detectedStartTs,
                                            preferring: preferring) else { return nil }
        await willRetire(snapshot)
        var didDelete = false
        for owner in [snapshot.ownerDeviceId] + ownerIds where !didDelete {
            let deleted = (try? await store.deleteSleepSession(deviceId: owner,
                                                               startTs: detectedStartTs)) ?? 0
            if deleted > 0 { didDelete = true }
        }
        guard didDelete else {
            await rollback()
            return nil
        }
        return snapshot
    }

    /// Put retired rows back into the namespaces they came from, sidecars included. The caller lifts its
    /// own deletion markers; this only restores what the store lost.
    public static func restore(store: WhoopStore, rows: [Retired]) async {
        guard !rows.isEmpty else { return }
        for (owner, owned) in Dictionary(grouping: rows, by: \.ownerDeviceId) {
            _ = try? await store.upsertSleepSessions(owned.map(\.session), deviceId: owner)
        }
        for row in rows {
            // Sidecars are not carried by the session, so they go back after the row.
            _ = try? await store.persistSessionMotion(deviceId: row.ownerDeviceId,
                                                      sessionStart: row.session.startTs,
                                                      motionEpochs: row.motion ?? [])
            _ = try? await store.persistSessionSleepState(deviceId: row.ownerDeviceId,
                                                          sessionStart: row.session.startTs,
                                                          states: row.sleepState ?? [])
        }
    }
}
