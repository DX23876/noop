import Foundation
import StrandAnalytics
import WhoopStore
import StrandCore

// MARK: - Today's in-progress Effort (#402/#1001), shared by every Today surface
//
// The stored `DailyMetric.strain` is rewritten only when the heavy daily pass runs, so early in the day
// it still holds yesterday's Effort or a stale 0.0. Classic `TodayView` has always corrected for that by
// re-scoring today's raw HR stream itself (`liveTodayStrain`) and reading the two through
// `StrainScorer.effectiveEffort`, which floors at whatever is already earned so Effort can never visibly
// drop. The three OTHER Today surfaces — Liquid and the two dashboards — read the stored row raw, so on
// an active morning the same wearer saw a different Effort depending only on which Today style they had
// chosen.
//
// The read lives here rather than being copied into each screen because its PARAMETERS are the part that
// must not drift: the window (logical-day midnight → now), the profile's Effort HRmax (`MaxHeartRate`: override, measured, else Gellish), today's
// resting HR with `StrainScorer.defaultRestingHR` as the fallback, the Puffin effort method and the
// profile's sex are exactly what the daily pass will eventually persist. A screen that got any one of
// them wrong would not fail — it would quietly show a different number for the same day, which is the
// failure mode this whole file exists to close.

@MainActor
enum LiveEffort {

    /// Re-score TODAY's Effort over the raw HR stream, or nil when there is too little to score
    /// (`StrainScorer.strain` returns nil below `minReadings`, and callers then fall back to the stored
    /// row rather than to a fabricated value). Only meaningful for the current logical day — a navigated
    /// past day has no in-progress figure and callers must pass nil to `effectiveEffort` for it.
    ///
    /// The resting heart rate is Effort's own for the day in progress (`StoreReader.effortRestingHR`), the
    /// one the daily pass scores it against, not the lower one the day shows.
    ///
    /// COST: one indexed HR read over the whole elapsed day — up to ~18 k rows on a worn day, bounded by
    /// the explicit 200_000 cap at the call site (NOT `hrSamples`' 8000-row default, which used to
    /// truncate this read; see the note there) — plus an O(n) accumulation. It is the single heaviest
    /// read on the classic Today day-scoped pass, which runs it after the stored readouts are available.
    /// Liquid Today reads it independently and retries while active, so the rest of its dashboard load
    /// cannot delay Effort. Because `effectiveEffort` takes the MAX with the same day's stored row,
    /// refinement cannot lower that stored floor. `now` supplies one clock sample for both window ends.
    static func today(repo: Repository, profile: ProfileStore, now: Date = Date()) async -> Double? {
        // The window, the row limit, the resting fallback and which workout time counts are
        // `LiveEffortScore`'s, so the Android Today reads today's Effort by exactly the same rules
        // (issue #41). This does the two reads and supplies the profile's own HRmax.
        //
        // The day in progress is the cycle the pass scores, not the calendar day: in sleep-onset mode a
        // midnight start counts the hours before bed into the wrong day (`CycleDayWindow`).
        let mode = DayCycleMode.persisted(UserDefaults.standard.string(forKey: DayCycleMode.storageKey))
        var cycle: CycleDayWindow.Cycle?
        var restingHR = StrainScorer.defaultRestingHR
        if let store = await repo.storeHandle() {
            let reader = repo.storeReader(store)
            cycle = await CycleDayWindow.current(reader: reader,
                                                 now: Int(now.timeIntervalSince1970),
                                                 offsetSec: TimeZone.current.secondsFromGMT(for: now))
            restingHR = await reader.effortRestingHR(day: LiveEffortScore.day(now: now, mode: mode, cycle: cycle))
        }
        let (from, to) = LiveEffortScore.window(now: now, mode: mode, cycle: cycle)
        let workout = LiveEffortScore.workoutWindow(forWindow: (from, to))
        // #2460: the manual HR-max override, then the measured level, then Gellish, as the daily pass
        // resolves it for the STORED day. The two meet in `effectiveEffort`, which takes the larger, so a live value on the
        // formula's yardstick would outvote an override set because the real maximum is above it.
        let maxHR = profile.effortHRmax
        let hr = await repo.hrSamples(from: from, to: to, limit: LiveEffortScore.hrLimit)
        let rows = await repo.rawWorkoutRows(from: workout.from, to: workout.to)
        guard !Task.isCancelled else { return nil }
        return await runUnescalated {
            LiveEffortScore.score(hr: hr, workoutRows: rows, maxHR: maxHR, restingHR: restingHR)
        }
    }
}
