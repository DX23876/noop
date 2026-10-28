import Foundation
import WhoopStore

/// The fork's analysis recipe lineage (AI-n): which version the stored derived values mean, and what a
/// migration from an older recipe has to redo. Moved out of `IntelligenceEngine` (Android plan B3 step 2) so
/// every platform reads one recipe; the rules for bumping it are in `docs/fork/AGENT_RULES.md`.
public enum AnalysisRecipe {
    /// Version of the *meaning* of persisted derived scores. App marketing/build versions are
    /// deliberately unrelated: bump this only when an analytics change makes existing scores stale.
    // v2: RyanBR v11 changes persisted analysis inputs/outputs (including absolute nightly skin
    // temperature and scoring-source handling). Existing v1 rows need one bounded refresh.
    //
    // v3: the 2026-09-09 upstream sync (through 5cb134711) moves scored VALUES, not just how they are
    // presented, so a row computed under v2 no longer means what the current code would produce for the
    // same inputs. Each of these changes an output on some subset of nights:
    //   • #1990/#1982 an UNUSABLE resting-HR baseline is treated as absent, so Charge stops scoring
    //     against foldHistory's synthetic ~75 bpm midpoint on a cold-start install;
    //   • #1978 an absent HRV baseline now refuses to score at all, where the raw overload could
    //     previously return a Charge carrying no HRV term;
    //   • #1977 an out-of-domain strain denominator is rejected rather than producing a number;
    //   • RMSSD is WITHHELD on a night whose R-R over-counts, so those nights lose a wrong avgHrv
    //     (and with it the baseline contribution that wrong value was making);
    //   • #1943 a resting-HR bin must be well-populated AND physiologically plausible to win the
    //     night's floor, which moves restingHr on nights with a thin or dropout-driven bin;
    //   • the final HR/HRV window now CLOSES on the session end, so a sample sitting exactly on an
    //     aligned boundary counts — it moves sessionRestingHR and avgHRV on those nights;
    //   • heart-rate recovery now requires ONE CONTINUOUS effort rather than a sum of bursts;
    //   • #1984 nights fragmented under minSleepMin are bridged, which changes the staged night, its
    //     totals and therefore Rest;
    //   • #2015 a day's motion is re-folded only when that day's gravity moved.
    // The migration is the existing bounded 21-day forced pass (`runAnalysisMaintenance`): it is the
    // narrowest interval this can prove, since every one of the above is a per-night derivation and the
    // engine's own scoring window is 21 nights. Nights older than that keep their v2 values until they
    // are re-scored for another reason — the same contract v1→v2 shipped with.
    //
    // NOT part of this bump: the skin-temp absolute backfill for nights OUTSIDE that window. It is its
    // own resumable walker (`SkinTempBackfillWalker`), fill-only on a NULL column, and reachable
    // deliberately rather than on launch.
    // v4 repairs recipe v3's destructive legacy-RR interaction. v3 correctly gated over-counted tagged
    // streams, but older databases had no transport provenance, so it replaced recent HRV/Recovery with
    // nil even though the prior value was the only recoverable result. v4 restores those legacy values as
    // explicitly unverified, while new tagged data is reconciled before scoring and remains gated if it is
    // still physically impossible. The bounded 21-day pass restores the same affected window; raw samples
    // and manual sleep corrections are untouched.
    // v5 changes workout-source precedence from winner-takes-all rows to canonical fused sessions and
    // makes Cardio Load additive in raw TRIMP. The standard resumable 21-day pass refreshes recent
    // workout-derived daily outputs; fusion links and raw source rows are additive and never erased.
    // v6 admits the source-neutral native strength log into the canonical workout spine. Existing v5
    // installs must revisit the bounded workout window so a session first logged in NOOP contributes
    // exactly once after its Apple Health mirror is fused. Native sets and source rows are never erased.
    // v7 (2026-09 upstream sync) changes which R-R beat is scored and at what value. A WHOOP 5 now prefers
    // its native history over the standard 0x2A37 copy of the same beat, and restores the standard copy
    // stored before #2195 from its spec conversion (2.34 % low) to the milliseconds the strap sent. The
    // same pass carries #2042 (Charge re-scored with the night's skin-temperature deviation) and #2220
    // (a pass no longer deletes and re-creates detected workouts). Legacy unlabelled rows keep scoring,
    // so no night loses HRV or Charge to the update. Bounded 21-day pass; no raw row is rewritten.
    // v8 separates legacy custom Lab Book percentage rows from their count-valued siblings. The
    // transactionally versioned marker migration moves identifiable percent-unit rows and rebuilds both
    // daily projections before its own cursor advances; the bounded analysis pass then refreshes recent
    // consumers that may have read the old projected key. User-entered readings and raw samples remain.
    // AI-9 moves the Training Load cardio lane from Edwards' %HRmax zones to Banister's TRIMP over
    // heart-rate reserve (resting rate = median of the week around each session; b = 1.92 / 1.67 /
    // 1.795 by profile). The stored per-session loads change meaning, so the migration fills the cardio
    // load ledger with the new method — the whole history where heart rate remains, newest first,
    // resumable. No daily row changes: Effort keeps its own recipe, so an install already at AI-8 runs
    // no daily pass at all. Rows of the old method are kept, unread.
    // AI-10 (2026-09-26 upstream sync) changes what several nights and days are scored from: the daily
    // resting HR comes from the primary sleep session rather than the night with the lowest bin (#2358); a
    // 5-min HRV window counts only with `HRVAnalyzer.minBeats` clean intervals; a refused main night's HRV is
    // no longer replaced by the day's naps (#2426); a WHOOP 4 beat labelled as type-47 history outranks the
    // standard-BLE copy of it; an Oura ring is scored from one beat channel per window (#2423) with records
    // a redrain stored twice collapsed (#2456); and today's live Effort uses the manual HRmax override
    // (#2460). All are per-night or per-day derivations inside the engine's window, so the migration is
    // the standard bounded 21-day pass; no raw row is rewritten and the cardio ledger is not refilled.
    // AI-11 (2026-09-28) takes the daily resting HR back to the lowest 5-min bin, now of the primary
    // session: AI-10 had carried #2358's whole-session mean, which reads ~9–10 bpm higher and moved Effort,
    // Fitness Age, energy, workout detection and the Health export with it (docs/fork/decisions.md;
    // ryanbr/noop#2522). The primary-session selection (the nap fix) stays, and the mean stays recorded as
    // the `rhr_primary_session` shadow metric. The pass reaches back to `restingHRMeanWindowStart` so no day
    // scored with the mean survives; no raw row is rewritten and the cardio ledger is not refilled.
    // AI-12 (2026-09-28) changes which R-R beats every HRV, respiration and Charge input is built from: a
    // WHOOP's delivery paths (history, standard 0x2A37, realtime) are chosen per five-minute segment instead
    // of per beat, so a drifting offset between the strap's and the phone's clocks can no longer splice the
    // two copies of a beat into one train (`RRTransportReconciler`, #1118). Per-night derivations inside
    // the engine's window, so the standard bounded 21-day pass; no raw row is rewritten and the cardio
    // ledger is not refilled.
    // AI-13 (2026-09-29) corrects stored session energy NOOP computed with Keytel. Keytel was fitted on
    // 47–120 kg regular exercisers and priced a 212 kg wearer's walks at three times their cost; energy
    // model v8 prices sessions by pace or by heart rate against the day's aerobic ceiling. The migration
    // re-prices every manual row whose stored figure reproduces an old formula on the strap's heart rate
    // (`Repository.correctLegacyWorkoutEnergy`), records it as computed, and has Apple Health rewrite the
    // corrected span. Marked entered figures are left alone. No daily row is re-scored.
    // AI-14 (2026-09-29) retries AI-13 across every physical and canonical workout owner and
    // recognizes live GPS summaries when the later offloaded HR trace differs from live capture.
    // AI-15 (2026-09-30) runs it again with the day's real resting rate: AI-13/AI-14 read it from
    // imported rows only, which end at the last WHOOP export, so rows were recognised and priced
    // without one. Rows already marked computed are priced again as they stand.
    // AI-16 (2026-09-30) fills average, peak and Effort into Apple Health workouts that came without them,
    // from the band's trace where it covers the session, else the workout's own Watch minutes
    // (`Repository.fillAppleWorkoutHeartRate`, stored beside the rows in `workoutHeartRateFill`). Effort
    // uses the day's own resting rate or a Watch reading within three days. Cardio-load rows priced
    // without a trace are freed for those sessions. No daily row is re-scored.
    // AI-17 (2026-10-01) re-scores the standard window after the upstream sync through 7f396e98e. Three
    // inputs to stored daily rows moved: SleepStagerV2's deep prior drops from 0.18 to 0.15 on PSG evidence
    // (upstream bbeb20e83), a WHOOP 5/MG's 500 ms filler beats at rest are marked suspect and leave every
    // R-R read (WhoopStore v74, upstream 2d0b01d8a), and an unmatched WRIST_OFF tail ends where sustained
    // heart rate resumes instead of at the window end (upstream 7f1e42f7b). The daily resting HR also no
    // longer falls back to a nap's nadir when the main night has none (upstream 5de051909). Per-night
    // derivations inside the engine's window, so the standard bounded 21-day pass; no raw row is rewritten
    // beyond the v74 mark and the cardio ledger is not refilled.
    // AI-18 (2026-10-04) re-scores the standard window after the upstream sync through 9f98f811a (12.0.0).
    // The Charge baselines (HRV, resting HR, respiration, skin temperature) now fold only nights inside
    // the 21-day window, and an imported WHOOP history only seeds them until the wearer's own nights are
    // trusted, then drops out (`ChargeBaselines`, upstream #2525). Before, a finished import kept about a
    // third of the weight for good, so a stored Charge still leaned on months-old vendor nights. Per-night
    // derivations inside the engine's window, so the standard bounded 21-day pass (raw strap history is
    // kept about 35 days, so older days have nothing to re-score from); no raw row is rewritten and the
    // cardio ledger is not refilled.
    // AI-19 (2026-10-06) repairs retained Apple daily projections in resumable batches (see its block in
    // `runAnalysisMaintenance`). No daily row is re-scored.
    // AI-20 (2026-10-09) re-scores the standard window after the upstream sync through 18de275ef (12.1.0
    // test beta). Charge now leaves out an optional personal baseline that is not yet usable: the
    // respiration and Effort baselines, like resting HR before them, no longer enter the score or its
    // drivers until they are trusted (upstream 0b7294054). Before, a thin respiration or Effort baseline
    // still moved a stored Charge. Per-night derivations inside the engine's window, so the standard
    // bounded 21-day pass; no raw row is rewritten and the cardio ledger is not refilled.
    // AI-21 (2026-10-12, fork AgeLess) changes what the stored AgeLess weeks mean: VO₂max no longer comes from
    // the non-exercise weekly estimate but from an entered value, Apple Health or walks and runs; lean mass
    // enters from body fat; and a week without the four band measures has no age. The migration deletes
    // every AgeLess weekly row, so the next pass rebuilds all weeks from banked inputs. Banked zone minutes
    // are kept (their raw HR is gone). No daily row is re-scored and the cardio ledger is not refilled.
    // AI-22 (2026-10-12, fork AgeLess) rebuilds the AgeLess weeks once more: the training-based VO₂max now
    // comes from the one estimator Training Load reads (fused sessions, the cardio load's trace, the week's
    // median resting HR as the reference) instead of AgeLess's own copy, and a first run banks zone minutes
    // over every day the raw heart rate still covers. The migration deletes the AgeLess weeks and the
    // training VO₂max days AI-21 banked; zone minutes are kept. No daily row is re-scored.
    // AI-23 (2026-10-13, fork AgeLess) stores what each week's measures stand on: days with data, banked zone
    // days, strength sessions, VO₂max readings and the days of the newest VO₂max and body-fat readings, for the
    // detail screen's basis lines. No stored value changes meaning, but every week written before has none of
    // them, so the migration deletes the AgeLess weeks once more and the next pass rebuilds them all. Zone
    // minutes are kept. No daily row is re-scored.
    // AI-24 (2026-10-13, fork AgeLess) changes which VO₂max a week reads: an entered value now stands only until
    // two newer measurements arrive (a year at most), and Apple Health leads only while it measured in the last
    // 30 days, else walks and runs do. Weeks stored under the old order can name a VO₂max the new one would not,
    // so the AgeLess weeks are deleted once more and the next pass rebuilds them; zone minutes are kept. No daily
    // row is re-scored. VO₂max goals set before this re-read their start once (`rebaselineVO2maxGoals`).
    // AI-25 (2026-10-13, fork GPS elevation) changes the training-based VO₂max that AgeLess weeks read: a walk
    // or run whose climb is known (NOOP's barometer, Apple Health's ascent, an imported file) now pays the
    // ACSM uphill term for the metres climbed per minute, where before every session counted as level. Weeks
    // stored under the flat assumption can carry a lower VO₂max, so the AgeLess weeks are deleted once more
    // and the next pass rebuilds them; zone minutes are kept. No daily row is re-scored, no workout row is
    // touched and the cardio ledger is not refilled. Goal starts are not re-read. Climbs that Apple Health
    // delivers later (the one-time elevation read) clear the weeks again when that read completes.
    // AI-26 (2026-10-14, fork AgeLess) takes the estimate from walks and runs out of AgeLess. A lab check against
    // 981 treadmill tests showed it does not track measured VO₂max at walking pace, and a pulse raised by
    // medication or a meal reads as effort. A week's VO₂max is now an entered value (a year) or Apple Health's
    // readings (six months), else none; long walks give only a pulse-free lower bound shown beside it. Stored
    // weeks can name a VO₂max the new rule would not, so the AgeLess weeks are deleted once more and the next pass
    // rebuilds them; zone minutes are kept. No daily row is re-scored. VO₂max goals re-read their start once more.
    // AI-27 (2026-10-15, fork AgeLess) stops crediting body fat below the lean-mass target. The body-fat study's
    // curve is J-shaped with its lowest risk near 25 % body fat, so less fat than the target shows no further
    // benefit; before, up to 3 points earned years. Stored weeks can carry that credit, so the AgeLess weeks are
    // deleted once more and the next pass rebuilds them; zone minutes are kept. No daily row is re-scored and no
    // goal start is re-read (a body-fat goal is kept in kilograms and not priced).
    // AI-28 (2026-10-20, fork) reads the daily stress proxy against the nights after a manual "Recalibrate
    // baseline" only (HRV on its epoch, resting HR on the recovery epoch). Stored rows are gap-filled and never
    // overwritten, so the days whose 30-row window reaches back across the cut kept a reading against the reset
    // baseline. The migration recomputes NOOP's own rows on those days (`repairStressProxyAfterRecalibration`)
    // and leaves imported WHOOP rows alone; nothing happens without a recalibration. No daily row is re-scored.
    // AI-29 (2026-10-21, fork AgeLess) changes where a week's daily steps come from: the app's one step resolver
    // (`Repository.resolvedSteps`: the strap's count, then Apple Health, then the motion estimate) instead of the
    // strap's computed daily row alone. A WHOOP 4.0 sends no step count, so its rows carry none and AgeLess never
    // gave such a wearer an age, however many nights; a 5.0 or MG day without a strap count now takes the phone's.
    // The current week without an age also stores why (`HealthspanWindow.Gap`). Stored weeks can average other
    // steps, so the AgeLess weeks are deleted once more and the next pass rebuilds them; zone minutes are kept. No
    // daily row is re-scored and no goal start is re-read.
    // AI-30 (2026-10-21, fork) reads Apple Health's body fat and lean mass in the one body resolver
    // (`Repository.bodyMetrics`). Both arrive as daily metric points under `apple-health`, which the resolver
    // never read: AgeLess, the Katch–McArdle basal rate, the Body page, body goals and the coach saw only body
    // fat typed into NOOP. AgeLess weeks can now carry a lean mass they lacked, so they are deleted once more and
    // rebuilt (zone minutes kept). A wearer on Katch–McArdle has energy days priced without a body fat that
    // existed, so the energy window (`Repository.energyRefreshMaxDays`) is priced again; every other formula
    // reads no body fat and is left alone. No daily row is re-scored.
    // AI-31 (2026-10-25, fork, Android plan C1) is the first recipe under the one rule (D19): a bump rebuilds every
    // derived value from the stored inputs instead of re-scoring a window chosen per recipe. Every day with raw
    // strap data is scored again, the weekly scores, the stress proxy, the daily rhythm rows, workout heart-rate
    // fills, the cardio load ledger, the energy history and the AgeLess weeks are rebuilt (`RebuildStep`). Raw
    // samples are never rewritten, and no value an import or the wearer supplied is replaced. What the daily
    // pass already did for recent days now reaches the whole history: a workout without heart rate gets it from
    // the strap trace, and a corrected night keeps its bed and wake times while its stages are derived again.
    // AI-31 changes no formula: what moves is every day scored under an older recipe or outside the windows
    // the earlier migrations re-scored, which now reads what the current code produces.
    // AI-32 (2026-10-28, fork, #2438 step 0) resolves the maximum heart rate in one place (`MaxHeartRate`): the
    // manual setting, else the level held for five samples in workouts on two days of the 90 before a day,
    // else Gellish (192 − 0.007 × age²) instead of Tanaka, all in whole bpm. Effort, workout detection and
    // scores, zones, workout energy, AgeLess, the VO₂max fallback and the coach read it. The workout peaks
    // are banked over the whole raw history first (`RebuildStep.workoutPeaks`), then the full rebuild runs.
    // Its own number although AI-31 has not shipped in a release: the testing build of 2026-10-26 carries
    // AI-31, so a store that ran it would otherwise keep its history on the old maximum (decisions.md).
    public static let currentVersion = 32

    /// The first recipe whose migration is the full rebuild. A store below it may still owe the legacy
    /// repairs of older recipes, which fix stored inputs rather than derive anything (`LegacyRepair`).
    public static let oneRuleRecipe = 31

    /// The work every recipe bump does, in order. A step is done for one target recipe once its cursor
    /// position says so, so an interrupted rebuild resumes at the step it was in; the recipe cursor itself
    /// moves only after the last step.
    public enum RebuildStep: Int, CaseIterable, Sendable {
        /// Legacy input repairs a store below `oneRuleRecipe` still owes (`legacyRepairs(from:)`).
        case legacyRepairs
        /// Every AgeLess week is deleted, so the daily pass rebuilds them all from the banked inputs.
        case healthspanReset
        /// Each day's sustained workout peak over the whole raw history, which the daily step reads for the
        /// measured maximum heart rate (`MaxHeartRate.measuredLevels`).
        case workoutPeaks
        /// Every day that has raw strap data, scored again in one pass.
        case dailyHistory
        /// The Saturday-keyed weekly scores (Fitness Age, VO2max estimate, Vitality, Body Age) for every
        /// week the raw history covers.
        case weeklyScores
        /// NOOP's own stress proxy rows over the whole history; imported days are left alone.
        case stressProxy
        /// Every day that carries a daily rhythm row, scored again.
        case rhythmDays
        /// Heart rate of Apple Health and recorded workouts, computed again across the history.
        case workoutHeartRate
        /// Every cardio load priced again wherever its raw heart rate remains.
        case cardioLoad
        /// The energy history over every day with raw strap data, at least the standard refresh window.
        case energyHistory
        /// The screens' snapshot, refreshed before the recipe cursor moves.
        case publish
    }

    /// Where the rebuild for a target recipe stands: `target * 100 + next step`. Kept in its own cursor so
    /// the recipe cursor keeps meaning "fully applied".
    public static let rebuildCursor = "noopai:analysisRebuildPosition"

    /// The cursor value once `step` is done for `target`.
    public static func rebuildPosition(target: Int, after step: RebuildStep) -> Int {
        target * 100 + step.rawValue + 1
    }

    /// The first step still owed for `target`, given the stored rebuild cursor. A position written for
    /// another target (an older bump that never finished, or none) starts the rebuild from the beginning.
    public static func firstOwedStep(target: Int, storedPosition: Int?) -> RebuildStep {
        guard let storedPosition, storedPosition / 100 == target,
              let step = RebuildStep(rawValue: storedPosition % 100) else { return .legacyRepairs }
        return step
    }

    /// Repairs of stored INPUTS that older recipes shipped. They fix rows the rebuild reads, so a store that
    /// predates them still runs them first; the rebuild covers everything the other old recipes derived.
    public enum LegacyRepair: Equatable, Sendable {
        /// AI-13 to AI-15: session energy NOOP stored with Keytel, priced again by the current model.
        case workoutEnergy
        /// AI-19: Apple daily projections retained from before their repair.
        case healthProjections
    }

    /// The legacy repairs a migration from `from` still owes, in order.
    public static func legacyRepairs(from: Int) -> [LegacyRepair] {
        var repairs: [LegacyRepair] = []
        if from < 15 { repairs.append(.workoutEnergy) }
        if from < 19 { repairs.append(.healthProjections) }
        return repairs
    }

    /// Days the daily step must walk so it reaches the oldest day with raw strap data: from that local day
    /// through `today`, never fewer than the standard 21. No raw data at all keeps the standard window.
    public static func rebuildDays(earliestRawDay: String?, today: String, standard: Int = 21) -> Int {
        // Day keys are calendar dates; counting them in UTC keeps a DST change from shifting the span.
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let earliestRawDay, let from = parser.date(from: earliestRawDay),
              let to = parser.date(from: today) else { return standard }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let span = (utc.dateComponents([.day], from: from, to: to).day ?? 0) + 1
        return max(standard, span)
    }

    /// The recipe lineage is this fork's own: ryanbr/noop has no analysis recipe at all. Its cursor
    /// therefore lives under a fork namespace, and is shown as "AI-n", so that an upstream counter
    /// introduced later under a plain name can never be read as one of these numbers — a store carried
    /// over from upstream would otherwise look up to date and skip a rescore it still owes.
    public static let cursor = "noopai:analysisRecipeVersion"
    /// Where recipes 1–8 were stored before the rename. Read once and adopted, never written.
    public static let legacyCursor = "analysis:recipeVersion"
    /// The last recipe this fork wrote under the legacy name. A larger value there did not come from
    /// this fork and is ignored.
    public static let lastLegacyVersion = 8

    /// "AI-8": the recipe as Settings and the logs name it.
    public static func label(_ version: Int) -> String { "AI-\(version)" }

    /// The legacy cursor's value when this fork could have written it, otherwise nil.
    public static func adoptableLegacy(_ legacy: Int?) -> Int? {
        guard let legacy, (1...lastLegacyVersion).contains(legacy) else { return nil }
        return legacy
    }

    /// The stored recipe, adopting a pre-rename value into the fork-namespaced cursor the first time.
    public static func storedVersion(_ store: WhoopStore) async throws -> Int? {
        if let stored = try await store.cursor(Self.cursor) { return stored }
        guard let legacy = adoptableLegacy(try await store.cursor(legacyCursor)) else {
            return nil
        }
        try await store.setCursor(Self.cursor, legacy)
        return legacy
    }

    public enum Decision: Equatable {
        /// Existing installs predate the cursor. Trust their current rows and establish the baseline
        /// without turning an ordinary reinstall into a historical reanalysis.
        case anchorCurrent
        case upToDate
        case migrate(from: Int, to: Int)
    }

    /// `openedFromUpstream`: the store was created by upstream NOOP (see `UpstreamMigrationBridge`). It has
    /// no cursor for the same reason a pre-coordinator install has none, but its rows were NOT scored by
    /// this fork: upstream 11.6/11.7 persisted nights with sleep and no HRV or Charge. Anchoring would
    /// freeze those blanks, so it migrates from 0 instead.
    public static func decision(storedVersion: Int?, openedFromUpstream: Bool = false) -> Decision {
        guard let storedVersion else {
            return openedFromUpstream ? .migrate(from: 0, to: currentVersion) : .anchorCurrent
        }
        guard storedVersion < currentVersion else { return .upToDate }
        return .migrate(from: storedVersion, to: currentVersion)
    }
}
