import Foundation
import WhoopStore

// MARK: - The athlete's own rating of one whole session
//
// Set RPE and session RPE are different observations. A hard top set can be RPE 9 inside a session
// that felt moderate overall; averaging set RPEs and calling it session RPE would manufacture an
// answer. This sidecar therefore stores only a rating the athlete deliberately supplied for the whole
// workout. The duration comes from the workout itself when Session Load is calculated.
//
// The existing Lab Book table is used because it already provides precise timestamps, edit/delete,
// durable local SQLite storage and `.noopbak` backup. These rows use their own category and device id,
// so they do not appear among body or clinical markers and never overwrite an imported source.

struct SessionRPEEntry: Equatable, Sendable {
    let id: String
    let startTs: Int
    let rpe: Double
    let sport: String?
}

extension Repository {
    nonisolated static let sessionRPEDeviceId = "training-load"
    nonisolated static let sessionRPECategory = "trainingLoad"
    nonisolated static let sessionRPEMarkerKey = "session_rpe"
    nonisolated static let sessionRPESource = "manual-session-rpe"

    /// Every whole-session rating in the requested time range, oldest first.
    func sessionRPEEntries(from: Int, to: Int) async -> [SessionRPEEntry] {
        guard let store = await storeHandle() else { return [] }
        let rows = (try? await store.labMarkers(deviceId: Self.sessionRPEDeviceId,
                                                category: Self.sessionRPECategory)) ?? []
        return rows.compactMap { row in
            guard row.markerKey == Self.sessionRPEMarkerKey,
                  row.takenAt >= from, row.takenAt <= to,
                  let value = row.value, (1...10).contains(value) else { return nil }
            return SessionRPEEntry(id: row.id, startTs: row.takenAt, rpe: value, sport: row.note)
        }
    }

    /// The rating attached to one workout start, if the athlete supplied one.
    func sessionRPE(at startTs: Int) async -> SessionRPEEntry? {
        await sessionRPEEntries(from: startTs, to: startTs).last
    }

    /// Store or replace one whole-session RPE. Values use the conventional 1–10 session scale.
    @discardableResult
    func recordSessionRPE(_ rpe: Double, startTs: Int, sport: String) async -> Bool {
        guard rpe.isFinite, (1...10).contains(rpe), let store = await storeHandle() else { return false }
        let row = LabMarkerRow(
            id: "session-rpe-\(startTs)", deviceId: Self.sessionRPEDeviceId,
            markerKey: Self.sessionRPEMarkerKey, category: Self.sessionRPECategory,
            day: Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(startTs))),
            takenAt: startTs, value: rpe, valueText: nil, unit: "RPE",
            source: Self.sessionRPESource, note: sport, referenceText: nil)
        return (try? await store.upsertLabMarkers([row])) != nil
    }

    /// Remove only NOOP's rating for this workout; the workout itself is untouched.
    @discardableResult
    func deleteSessionRPE(at startTs: Int) async -> Bool {
        guard let entry = await sessionRPE(at: startTs), let store = await storeHandle() else {
            return false
        }
        return (try? await store.deleteLabMarker(id: entry.id)) == true
    }
}
