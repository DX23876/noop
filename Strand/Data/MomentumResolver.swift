import Foundation
import StrandAnalytics
import WhoopStore

/// Turns a screen's `Context` into the ranked feed, and owns the small persisted bookkeeping around it.
///
/// The classic and the Liquid Today screen both show the Momentum card. SwiftUI forces each to declare
/// its own `@AppStorage` / `@State`, but the *logic* between those values and the feed must exist once —
/// two copies is how the two screens end up disagreeing about what matters today, which is exactly what
/// `MomentumStore` and `MomentumCopy` were introduced to prevent.
///
/// `@MainActor` only because `MomentumBuilder.inputs` reads the main-actor `GoalTrackingStore`; the
/// ranking underneath (`MomentumFeed`) stays actor-free and testable without one.
@MainActor
enum MomentumResolver {

    /// The ranked feed for a screen, with anything snoozed today removed.
    ///
    /// `lastKind`/`lastAt` are the dwell bookkeeping, passed in rather than read here so the function
    /// stays a plain transformation. Both screens read the SAME `@AppStorage` keys, which is deliberate:
    /// it is one wearer and one card, so switching Today variants must not restart the dwell or
    /// resurrect a message they hid an hour ago.
    static func feed(context: MomentumBuilder.Context,
                     snoozedRaw: String,
                     lastKind: String,
                     lastAt: Double,
                     retrospective: Bool,
                     now: Date = Date()) -> [MomentumMessage] {
        let snoozed = snoozedKinds(snoozedRaw, now: now)
        let pool = MomentumBuilder.candidates(MomentumBuilder.inputs(context))
            .filter { !snoozed.contains($0.kind.rawValue) }
        let last = MomentumKind(rawValue: lastKind).map {
            MomentumLastShown(kind: $0, at: Date(timeIntervalSince1970: lastAt))
        }
        return MomentumFeed.rank(pool,
                                 hour: Calendar.current.component(.hour, from: now),
                                 lastShown: last,
                                 now: now,
                                 retrospective: retrospective)
    }

    /// The kinds hidden TODAY. Stored as "yyyy-MM-dd|kind,kind" so it self-clears at the day rollover
    /// rather than needing a cleanup pass, and so one stored value covers every kind — a dozen separate
    /// `@AppStorage` booleans would not scale.
    static func snoozedKinds(_ raw: String, now: Date = Date()) -> Set<String> {
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == Repository.logicalDayKey(now) else { return [] }
        return Set(parts[1].split(separator: ",").map(String.init))
    }

    /// The stored value after hiding one more kind for today.
    static func snoozing(_ kind: MomentumKind, into raw: String, now: Date = Date()) -> String {
        var kinds = snoozedKinds(raw, now: now)
        kinds.insert(kind.rawValue)
        return "\(Repository.logicalDayKey(now))|\(kinds.sorted().joined(separator: ","))"
    }
}
