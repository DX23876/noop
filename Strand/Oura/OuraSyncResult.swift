// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
import Foundation
import StrandImport
import WhoopStore   // OuraRawRow lives in WhoopStore (OuraRawStore.swift), not StrandImport

/// The fully-assembled, parsed output of one Oura backfill, ready to persist. The coordinator (Task 2)
/// builds this (merging per-day rows across endpoints); the writer (below) maps it to WhoopStore.
struct OuraSyncResult {
    var days: [WearableDailyRow]        // already coalesced per calendar day
    var sleepPeriods: [OuraSleepPeriod]
    var extras: [OuraDailyExtra]        // every ref_*/oura_*/vo2max scalar → metricSeries
    var workouts: [OuraWorkout]
    var heartRate: [OuraHRPoint]        // from the /heartrate endpoint (whole-day)
    var rawPages: [OuraRawRow]          // every fetched page, verbatim
    var ringModel: String?             // from ring_configuration, for the PairedDevice model

    init(days: [WearableDailyRow] = [], sleepPeriods: [OuraSleepPeriod] = [], extras: [OuraDailyExtra] = [],
         workouts: [OuraWorkout] = [], heartRate: [OuraHRPoint] = [], rawPages: [OuraRawRow] = [],
         ringModel: String? = nil) {
        self.days = days; self.sleepPeriods = sleepPeriods; self.extras = extras
        self.workouts = workouts; self.heartRate = heartRate; self.rawPages = rawPages; self.ringModel = ringModel
    }
}

/// Counts written, for the honest import summary. `skippedEndpoints` lists endpoints whose fetch failed
/// (e.g. a scope 401) — the backfill continues past them (honest partial, spec §7) and the UI surfaces
/// the skips so a partial import never silently looks complete.
struct OuraSyncSummary: Equatable {
    var days = 0, sleeps = 0, workouts = 0, hrSamples = 0, metricPoints = 0, rawPages = 0
    var skippedEndpoints: [String] = []
}
#endif // OURA_CLOUD_IMPORT
