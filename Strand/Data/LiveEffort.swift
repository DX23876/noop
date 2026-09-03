import Foundation
import StrandAnalytics
import WhoopStore

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
// must not drift: the window (logical-day midnight → now), Tanaka HRmax from the profile's age, today's
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
    /// `restingHr` is the displayed day's own resting HR (the daily pass's input); nil falls back to
    /// `StrainScorer.defaultRestingHR`, exactly as the pass does.
    ///
    /// COST: one indexed HR read bounded by `Repository.hrSamples`' own 8000-row limit, plus an O(n)
    /// accumulation. It is the single heaviest read on the classic Today day-scoped pass, which is why
    /// every caller runs it LAST — after the state its rings already draw from is set — so the screen
    /// paints on the stored row and only refines afterwards. Because `effectiveEffort` takes the MAX,
    /// that refinement can only ever raise the number, never flicker it downward.
    static func today(repo: Repository, profile: ProfileStore, restingHr: Int?) async -> Double? {
        let dayStart = Calendar.current.startOfDay(for: Repository.logicalDay(Date()))
        let from = Int(dayStart.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let hr = await repo.hrSamples(from: from, to: to)
        let maxHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
        let restHR = restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        return StrainScorer.strain(hr, maxHR: maxHR, restingHR: restHR,
                                   method: PuffinExperiment.effortMethod, sex: profile.sex)
    }
}
