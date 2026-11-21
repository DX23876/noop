import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Correcting, retiring and restoring a night, for the Android screens: the same `SleepNightEdit` the
/// Apple apps call, reached across the bridge.
///
/// Until this existed Android had its own, thinner version of the same job, and it looked for the night's
/// rows in the imported lane alone. The Sleep screen draws a night built from BOTH lanes, so a night NOOP
/// had computed itself could not be corrected at all, and every layer below swallowed the fact: the empty
/// group was dropped, the write was wrapped in a catch, and nothing was logged. A tester lost every
/// correction he made and had no way to find out why (2026-11-21).
///
/// So the caller now names the rows it means — `CoreRead.Night.blocks`, the group the night was drawn
/// from — and every answer here carries an `outcome` the screen can put into words.
///
/// Deletion markers stay Android's own (`dismissedSleep`): this reports which retired rows want one, and
/// the Kotlin side writes them where it always has.
enum CoreSleepEdit {

    /// Retired rows kept for the undo strip, by the token handed to the caller.
    ///
    /// They live here rather than crossing the bridge because a row carries its per-epoch motion and band
    /// state, and those are what a restore must put back: sending them to Kotlin and back would be a
    /// kilobyte of JSON each way for state nobody over there reads. One token at a time, which is what the
    /// undo is — one level, a few seconds, gone on the next retirement.
    ///
    /// An actor, not a bare static: the bridge is entered from whatever context the app is on, two
    /// retirements can be in flight at once (a nap deleted from the timeline while a correction is still
    /// writing), and a shared mutable static would be a data race as well as an error under the Swift 6
    /// language mode.
    private actor Held {
        static let shared = Held()
        private var slot: (token: String, rows: [SleepNightEdit.Retired])?

        /// Keep [rows] for one undo and name them, or nil when there is nothing to keep.
        func retain(_ rows: [SleepNightEdit.Retired]) -> String? {
            guard !rows.isEmpty else { return nil }
            let token = UUID().uuidString
            slot = (token, rows)
            return token
        }

        /// The rows [token] names, taken out: an undo is one level, so a second attempt finds nothing.
        func take(_ token: String) -> [SleepNightEdit.Retired]? {
            guard let slot, slot.token == token else { return nil }
            self.slot = nil
            return slot.rows
        }
    }

    static func run(_ op: String, _ args: [String: Any], store: WhoopStore,
                    reader: StoreReader) async -> String? {
        switch op {
        case "sleep.editTimes": return await editTimes(args, store: store, reader: reader)
        case "sleep.deleteNight": return await deleteNight(args, store: store, reader: reader)
        case "sleep.undoRetired": return await undoRetired(args, store: store)
        default: return nil
        }
    }

    /// The namespaces a sleep row can be owned by, computed first, exactly as the Apple side orders them.
    private static func ownerIds(_ reader: StoreReader) -> [String] {
        reader.rawComputedReadIds + reader.rawPhysiologyReadIds
    }

    private static func keys(_ args: [String: Any]) -> [SleepNightEdit.BlockKey] {
        ((args["blocks"] as? [[String: Any]]) ?? []).compactMap { block in
            guard let startTs = (block["startTs"] as? NSNumber)?.intValue else { return nil }
            return SleepNightEdit.BlockKey(deviceId: block["deviceId"] as? String, startTs: startTs)
        }
    }

    private static func staging(_ args: [String: Any]) -> EditedSleepHeal.Staging {
        .init(method: SleepStager.Method(rawValue: args["method"] as? String ?? "") ?? .v2,
              motionAwareWake: args["motionAwareWake"] as? Bool ?? false)
    }

    private struct RetiredWire: Encodable {
        let deviceId: String, startTs: Int, endTs: Int, writesTombstone: Bool
    }

    private struct Answer: Encodable {
        let ok: Bool
        /// "saved", "partial", "notFound", or the name of the refusal, so the screen can say which one
        /// it was.
        let outcome: String
        var edited: Int = 0
        var retired: [RetiredWire] = []
        var undoToken: String?
        var wakeDays: [String] = []
        var rescore: Bool = false
    }

    private static func wire(_ rows: [SleepNightEdit.Retired]) -> [RetiredWire] {
        rows.map { RetiredWire(deviceId: $0.ownerDeviceId, startTs: $0.session.startTs,
                               endTs: $0.endTs, writesTombstone: $0.writesTombstone) }
    }


    private static func editTimes(_ args: [String: Any], store: WhoopStore,
                                  reader: StoreReader) async -> String {
        let block = keys(args)
        guard !block.isEmpty else {
            return CoreRead.json(Answer(ok: false, outcome: SleepNightEdit.Failure.noBlocks.rawValue))
        }
        let owners = ownerIds(reader)
        let group = await SleepNightEdit.rows(store: store, ownerIds: owners, keys: block)
        let staging = staging(args)
        let deviceId = args["deviceId"] as? String ?? reader.activeDeviceId
        let result = await SleepNightEdit.editTimes(
            store: store, ownerIds: owners, group: group,
            newStartTs: (args["start"] as? NSNumber)?.intValue ?? 0,
            newEndTs: (args["end"] as? NSNumber)?.intValue ?? 0,
            allowRelocation: args["allowRelocation"] as? Bool ?? false,
            now: (args["now"] as? NSNumber)?.intValue ?? Int(Date().timeIntervalSince1970),
            restage: { start, end in
                await EditedSleepHeal.restage(store: store, deviceId: deviceId, start: start, end: end,
                                              staging: staging)
            })
        switch result {
        case .failure(let why):
            return CoreRead.json(Answer(ok: false, outcome: why.rawValue))
        case .success(let done):
            // A block the night named but the store no longer holds was dropped on the way in, so the
            // correction reached fewer rows than the wearer was looking at. It happened, but not whole,
            // and saying "saved" to that is the kind of half-truth this file exists to stop.
            let outcome = group.count == block.count ? "saved" : "partial"
            return CoreRead.json(Answer(ok: true, outcome: outcome, edited: done.edited,
                                        retired: wire(done.retired), undoToken: await Held.shared.retain(done.retired),
                                        wakeDays: done.affectedWakeDays.sorted(),
                                        rescore: done.requiresLocalRescore))
        }
    }

    private static func deleteNight(_ args: [String: Any], store: WhoopStore,
                                    reader: StoreReader) async -> String {
        let owners = ownerIds(reader)
        // Every block of the night, so a split night goes as a whole rather than leaving its other halves
        // on screen — the same group the correction acts on.
        let block = keys(args)
        guard !block.isEmpty else {
            return CoreRead.json(Answer(ok: false, outcome: SleepNightEdit.Failure.noBlocks.rawValue))
        }
        var rows: [SleepNightEdit.Retired] = []
        for key in block {
            // The lane the key names goes with it: two rows can share a detected onset across the
            // imported and the computed namespace, and deleting the other one would leave the night the
            // wearer is looking at on screen.
            if let gone = await SleepNightEdit.deleteNight(store: store, ownerIds: owners,
                                                           detectedStartTs: key.startTs,
                                                           preferring: key.deviceId) {
                rows.append(gone)
            }
        }
        guard !rows.isEmpty else { return CoreRead.json(Answer(ok: false, outcome: "notFound")) }
        let rescore = rows.contains { $0.ownerDeviceId.hasSuffix("-noop") }
        // A block whose row has already gone is not a failure — what is gone is gone — but it is not a
        // whole deletion either, and the leftover fragment stays on screen. So it is named, rather than
        // reported as if every block had been taken out.
        let outcome = rows.count == block.count ? "saved" : "partial"
        return CoreRead.json(Answer(ok: true, outcome: outcome, edited: 0, retired: wire(rows),
                                    undoToken: await Held.shared.retain(rows),
                                    wakeDays: Set(rows.map { StoreReader.sleepEndDayKey($0.endTs) }).sorted(),
                                    rescore: rescore))
    }

    private static func undoRetired(_ args: [String: Any], store: WhoopStore) async -> String {
        let token = args["token"] as? String ?? ""
        guard let rows = await Held.shared.take(token) else {
            return CoreRead.json(Answer(ok: false, outcome: "notFound"))
        }
        await SleepNightEdit.restore(store: store, rows: rows)
        return CoreRead.json(Answer(ok: true, outcome: "saved", edited: rows.count,
                                    retired: wire(rows),
                                    wakeDays: Set(rows.map { StoreReader.sleepEndDayKey($0.endTs) }).sorted(),
                                    rescore: rows.contains { $0.ownerDeviceId.hasSuffix("-noop") }))
    }
}
