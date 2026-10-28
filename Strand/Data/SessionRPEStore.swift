import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

// MARK: - The athlete's own rating of one whole session
//
// Set RPE and session RPE are different observations. A hard top set can be RPE 9 inside a session
// that felt moderate overall; averaging set RPEs and calling it session RPE would manufacture an
// answer. This sidecar therefore stores only a rating the athlete deliberately supplied for the whole
// workout. The duration comes from the workout itself when Session Load is calculated.
//
// The source-scoped trainingSessionRating sidecar keeps the answer and its recording time durable in
// local SQLite and .noopbak. These rows never overwrite an imported source or a set-level rating.

extension Repository {
    nonisolated static let sessionRPEDeviceId = "training-load"
    nonisolated static let sessionRPECategory = "trainingLoad"
    nonisolated static let sessionRPEMarkerKey = "session_rpe"
    nonisolated static let sessionRPESource = SessionRPEEntry.manualSource

    /// Every whole-session rating in the requested time range, oldest first.
    func sessionRPEEntries(from: Int, to: Int) async -> [SessionRPEEntry] {
        guard let store = await storeHandle() else { return [] }
        return await SessionRPEEntry.read(store: store, from: from, to: to)
    }

    /// The rating attached to one workout start, if the athlete supplied one.
    func sessionRPE(at startTs: Int) async -> SessionRPEEntry? {
        await sessionRPEEntries(from: startTs, to: startTs).last
    }

    func sessionRPE(sessionId: String) async -> SessionRPEEntry? {
        SessionRPEEntry.latest(await sessionRPEEntries(from: 0, to: Int.max), sessionId: sessionId, startTs: nil)
    }

    /// Store or replace one whole-session RPE. Values use the conventional 1–10 session scale.
    @discardableResult
    func recordSessionRPE(_ rpe: Double, startTs: Int, sport: String,
                          sessionId: String? = nil,
                          ratedAtTs: Int = Int(Date().timeIntervalSince1970)) async -> Bool {
        guard let store = await storeHandle() else { return false }
        return await SessionRPEEntry.record(store: store, rpe: rpe, startTs: startTs, sport: sport,
                                            sessionId: sessionId, ratedAtTs: ratedAtTs)
    }

    /// Remove only NOOP's rating for this workout; the workout itself is untouched.
    @discardableResult
    func deleteSessionRPE(at startTs: Int) async -> Bool {
        guard let entry = await sessionRPE(at: startTs), let store = await storeHandle() else {
            return false
        }
        return await SessionRPEEntry.remove(store: store, entry: entry)
    }

    @discardableResult
    func deleteSessionRPE(id: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        guard let entry = await sessionRPEEntries(from: 0, to: Int.max).first(where: { $0.id == id }) else { return false }
        return await SessionRPEEntry.remove(store: store, entry: entry)
    }
}

// MARK: - When to ask

extension Repository {

    /// Both hosts schedule from the core's canonical, unrated session list.
    func refreshSessionRatingReminders(now: Int = Int(Date().timeIntervalSince1970)) async {
        await SessionRPEReminder.synchronize(await pendingSessionRatingReminders(now: now), now: now)
    }

    func pendingSessionRatingReminders(now: Int, forDelivery: Bool = false) async -> [SessionRatingReminders.Candidate] {
        guard let store = await storeHandle() else { return [] }
        return await SessionRatingReminders.candidates(reader: storeReader(store),
            prompt: TrainingPreferences.sessionRatingPrompt, maxHR: strainProfile?.hrMax,
            dismissed: dismissedDetectedWorkoutSpans, now: now, forDelivery: forDelivery)
    }
}
