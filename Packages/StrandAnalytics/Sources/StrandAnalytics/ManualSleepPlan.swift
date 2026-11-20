import Foundation

/// What a hand-added sleep window would do, decided once for both platforms (2026-11-20).
///
/// Three testers asked for this within a week: a night the detector missed entirely, a nap it did not pick
/// up, and a Log entry that promised to add sleep and only opened a tab. The rules it holds are the ones
/// neither screen may answer for itself:
///
///   - a window that lies on top of a sleep already stored is REFUSED. The insert alone would take it,
///     because only an identical onset second is rejected, and the day would then count those hours twice
///     in its Rest total. Clipping or merging the two would decide something the wearer never said, so the
///     caller names the session in the way and offers to edit that instead.
///   - a window the strap has no dense data for is accepted, with a warning first. The entry is still worth
///     storing (the post-sync self-heal swaps in real stages when the raw lands), but until then it carries
///     a length and no stages, and Charge for that day stays empty, because HRV and resting heart rate are
///     measured during sleep. Saying so once beats a wearer wondering why nothing moved.
///
/// Pure: the caller reads the rows and asks whether raw data exists; this decides.
public enum ManualSleepPlan {
    public enum Outcome: Equatable {
        /// Store it.
        case ok
        /// Store it, after saying that it will carry a length and nothing else for now.
        case noRawData
        /// Refuse: this stored sleep covers part of the window.
        case blocked(start: Int, end: Int)
        /// Not a window a sleep can occupy at all (inverted, longer than a day, or in the future).
        case invalidWindow
    }

    /// Where the two pickers start, for the day being looked at.
    ///
    /// Two fields starting at zero are unusable, and the right seed is not the same on every day: a day
    /// with no main sleep is almost always a night the detector missed, a day that has one is almost
    /// always a nap. So the previous evening to the morning for the first, the last hour for the second.
    /// Both stay freely editable; this only decides where they start.
    ///
    /// The seed never reaches into the future (`clampedEditWindow` would refuse it), so a night seeded on
    /// the current day is cut at now, and falls back to the last hour when that leaves under two hours,
    /// which is a nap's shape rather than a night's.
    public static func seed(dayStart: Date, hasMainSleep: Bool, now: Date,
                            calendar: Calendar = .current) -> (start: Int, end: Int) {
        let lastHour = (start: Int(now.timeIntervalSince1970) - 3600, end: Int(now.timeIntervalSince1970))
        guard !hasMainSleep,
              let bed = calendar.date(byAdding: .hour, value: -1, to: calendar.startOfDay(for: dayStart)),
              let morning = calendar.date(byAdding: .hour, value: 7, to: calendar.startOfDay(for: dayStart))
        else { return lastHour }
        let wake = min(morning, now)
        guard wake.timeIntervalSince(bed) >= 2 * 3600 else { return lastHour }
        return (start: Int(bed.timeIntervalSince1970), end: Int(wake.timeIntervalSince1970))
    }

    public static func decide(start: Int, end: Int, now: Int,
                              existing: [SleepEditGuard.Span], hasRawData: Bool) -> Outcome {
        guard let window = SleepEditGuard.clampedEditWindow(start: start, end: end, now: now) else {
            return .invalidWindow
        }
        if let hit = SleepEditGuard.overlapping(start: window.start, end: window.end, existing: existing) {
            return .blocked(start: hit.start, end: hit.end)
        }
        return hasRawData ? .ok : .noRawData
    }
}
