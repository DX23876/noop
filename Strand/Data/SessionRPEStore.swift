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
    let sessionId: String?
    let startTs: Int
    let rpe: Double
    let sport: String?
    let ratedAtTs: Int?
    let source: String

    init(id: String, sessionId: String?, startTs: Int, rpe: Double, sport: String?,
         ratedAtTs: Int? = nil, source: String = Repository.sessionRPESource) {
        self.id = id
        self.sessionId = sessionId
        self.startTs = startTs
        self.rpe = rpe
        self.sport = sport
        self.ratedAtTs = ratedAtTs
        self.source = source
    }
}

extension Repository {
    nonisolated static let sessionRPEDeviceId = "training-load"
    nonisolated static let sessionRPECategory = "trainingLoad"
    nonisolated static let sessionRPEMarkerKey = "session_rpe"
    nonisolated static let sessionRPESource = "manual-session-rpe"

    /// Every whole-session rating in the requested time range, oldest first.
    func sessionRPEEntries(from: Int, to: Int) async -> [SessionRPEEntry] {
        guard let store = await storeHandle() else { return [] }
        let rows = (try? await store.trainingSessionRatings(from: from, to: to)) ?? []
        return rows.map { row in
            SessionRPEEntry(id: row.id, sessionId: row.sessionId,
                            startTs: row.workoutStartTs, rpe: row.rpe, sport: row.sport,
                            ratedAtTs: row.ratedAtTs, source: row.source)
        }
    }

    /// The rating attached to one workout start, if the athlete supplied one.
    func sessionRPE(at startTs: Int) async -> SessionRPEEntry? {
        await sessionRPEEntries(from: startTs, to: startTs).last
    }

    func sessionRPE(sessionId: String) async -> SessionRPEEntry? {
        await sessionRPEEntries(from: 0, to: Int.max).last { $0.sessionId == sessionId }
    }

    /// Store or replace one whole-session RPE. Values use the conventional 1–10 session scale.
    @discardableResult
    func recordSessionRPE(_ rpe: Double, startTs: Int, sport: String,
                          sessionId: String? = nil,
                          ratedAtTs: Int = Int(Date().timeIntervalSince1970)) async -> Bool {
        guard rpe.isFinite, (1...10).contains(rpe), let store = await storeHandle() else { return false }
        let row = TrainingSessionRating(id: "session-rpe-\(startTs)", sessionId: sessionId,
                                        workoutStartTs: startTs, ratedAtTs: ratedAtTs,
                                        rpe: rpe, sport: sport, source: Self.sessionRPESource)
        do { try await store.upsertTrainingSessionRating(row); return true }
        catch { return false }
    }

    /// Remove only NOOP's rating for this workout; the workout itself is untouched.
    @discardableResult
    func deleteSessionRPE(at startTs: Int) async -> Bool {
        guard let entry = await sessionRPE(at: startTs), let store = await storeHandle() else {
            return false
        }
        return (try? await store.deleteTrainingSessionRating(id: entry.id)) == true
    }

    @discardableResult
    func deleteSessionRPE(id: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        return (try? await store.deleteTrainingSessionRating(id: id)) == true
    }
}
