import Foundation
import StrandAnalytics
import WhoopStore

/// The wearer's notification choice. The rating editor remains available for every session.
public enum SessionRatingPrompt: String, CaseIterable, Identifiable, Sendable {
    case off, whenUseful, always
    public var id: String { rawValue }
}

/// One clock and one source-aware decision for both notification hosts. No notification is sent here.
public enum SessionRatingReminders {
    public static let delaySeconds = 30 * 60
    public static let deliveryGraceSeconds = 15 * 60

    public struct Candidate: Equatable, Encodable, Sendable {
        public var id: String, sessionId: String, sport: String
        public var startTs: Int, endTs: Int, fireTs: Int
    }

    /// Future sessions, zero-length windows and old sessions never become pending notifications.
    /// A delayed platform wake gets a bounded grace period, rather than a prompt hours after training.
    public static func fireTime(startTs: Int, endTs: Int, now: Int, forDelivery: Bool = false) -> Int? {
        guard endTs > startTs, endTs <= now else { return nil }
        let (fire, overflow) = endTs.addingReportingOverflow(delaySeconds)
        guard !overflow else { return nil }
        if forDelivery {
            let (expiry, expiresOverflow) = fire.addingReportingOverflow(deliveryGraceSeconds)
            guard !expiresOverflow, now >= fire, now <= expiry else { return nil }
        } else if fire <= now { return nil }
        return fire
    }

    public static func isWorthAsking(reader: StoreReader, startTs: Int, endTs: Int, sport: String,
                                     source: String, averageHR: Double?, restingHR: Double?, maxHR: Double?,
                                     prompt: SessionRatingPrompt) async -> Bool {
        switch prompt {
        case .off: return false
        case .always: return true
        case .whenUseful: break
        }
        if SessionRatingPolicy.family(forSport: sport).alwaysWorthRating { return true }
        var average = averageHR
        if average == nil, endTs > startTs {
            let ids = WorkoutPhysiology.deviceIds(source: source, activeStrapId: reader.activeDeviceId,
                                                  importedIds: reader.importedReadIds)
            if let primary = ids.first,
               let stats = try? await reader.store.hrWindowStats(primaryId: primary,
                    secondaryId: ids.dropFirst().first ?? primary, from: startTs, to: endTs), stats.n >= 60 {
                average = stats.avg
            }
        }
        return SessionRatingPolicy.isWorthRating(sport: sport, durationSeconds: Double(endTs - startTs),
            averageHR: average, restingHR: restingHR, maxHR: maxHR)
    }

    /// The canonical session union prevents imported, detected and native copies from each asking once.
    /// Delivery re-reads ratings and session existence, so editing, deleting or dismissing a session wins
    /// over an earlier scheduled request. A rating attributed to another canonical session never gates this one.
    public static func candidates(reader: StoreReader, prompt: SessionRatingPrompt, maxHR: Double?,
                                   dismissed: [String], now: Int = Int(Date().timeIntervalSince1970),
                                   forDelivery: Bool = false) async -> [Candidate] {
        guard prompt != .off else { return [] }
        let fusion = await TrainingSessionResolver.read(reader: reader, from: now - TrainingHistoryWindow.allDays * 86_400, to: now,
                                                        dismissedDetectedSpans: dismissed)
        let timely = fusion.sessions.filter {
            fireTime(startTs: $0.row.startTs, endTs: $0.row.endTs, now: now, forDelivery: forDelivery) != nil
        }
        guard !timely.isEmpty else { return [] }
        guard let ratings = try? await reader.store.trainingSessionRatings(from: 0, to: Int.max) else { return [] }
        let restingByDay = await reader.restingHrByDay(fromDay: "0000-01-01",
            toDay: StoreReader.localDayKey(Date(timeIntervalSince1970: Double(now))))
        let resting = restingByDay.keys.sorted().suffix(14).compactMap { restingByDay[$0] }.sorted()
        let baseline = resting.isEmpty ? nil : resting[resting.count / 2]
        var result: [Candidate] = []
        for session in timely {
            let row = session.row
            guard let fire = fireTime(startTs: row.startTs, endTs: row.endTs, now: now, forDelivery: forDelivery) else { continue }
            let starts = Set(session.components.map { $0.row.startTs } + [row.startTs])
            guard !ratings.contains(where: {
                $0.sessionId == session.id || ($0.sessionId == nil && starts.contains($0.workoutStartTs))
            }) else { continue }
            guard await isWorthAsking(reader: reader, startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                source: row.source, averageHR: row.avgHr.map(Double.init), restingHR: baseline, maxHR: maxHR,
                prompt: prompt) else { continue }
            result.append(Candidate(id: "session-rpe-reminder-\(session.id)", sessionId: session.id,
                sport: row.sport, startTs: row.startTs, endTs: row.endTs, fireTs: fire))
        }
        return result.sorted { ($0.fireTs, $0.id) < ($1.fireTs, $1.id) }
    }
}
