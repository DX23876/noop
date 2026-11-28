# NOOP Analytics

On-device analytics for **NOOP** — an offline-first companion app for WHOOP straps (4.0 and 5.0/MG). NOOP talks to *your own* strap over Bluetooth, stores its biometric history locally in SQLite, and computes its three daily scores plus HRV and sleep staging on-device. No cloud or account participates in any of the math described here.

## NOOP's three daily scores — Charge / Effort / Rest

NOOP gives you **three daily scores, each on a 0–100 scale**:

| Score | Answers | Engine | Internal key | Was called |
|---|---|---|---|---|
| **Charge** | How recovered are you? | `RecoveryScorer` | `recovery` | Recovery |
| **Effort** | How hard did your heart work? | `StrainScorer` | `strain` | Strain (0–21) |
| **Rest** | How restorative was your sleep? | Rest composite (`AnalyticsEngine`) | `sleep_performance` | Sleep Performance |

Each score is built from your strap's raw signals using **published, peer-reviewed sport science** (Task Force 1996 HRV, Karvonen %HRR, Banister TRIMP for the Training Load cardio lane, Gellish HRmax — all cited in full below), plus an Effort curve fitted on shared WHOOP exports (#2438) and computed **entirely on your device**.

They are **NOT WHOOP's scores.** We don't have WHOOP's private algorithms and don't pretend to. NOOP's scores aim at the same three questions using open science, so they'll usually track WHOOP's *in direction*, but won't match number-for-number — and that's the point.

Every score also carries a small **confidence tier — Solid / Building / Calibrating** (`ScoreConfidence`) so a sparse day reads truthfully instead of faking a number. When NOOP can't compute a score honestly, it shows nothing rather than a fabricated value.

> **Naming & continuity.** The *display* names changed (Recovery→Charge, Strain→Effort, Sleep Performance→Rest) and Effort was **rescaled from 0–21 to 0–100**, but the **internal data keys are unchanged** (`recovery`, `strain`, `sleep_performance`) so years of stored history, imports, and the metric-series substrate keep working. You'll still see the old engine names (`RecoveryScorer`, `StrainScorer`) and internal keys throughout the source and in this document — they back the new scores.

> **Not affiliated with WHOOP.** NOOP interoperates with hardware and data you already own. The scores and metrics below are **independent approximations** of common exercise-physiology and HRV methods, derived from published literature — they are **not** reproductions of any proprietary scoring model, and they are **not a medical device**. Nothing here is medical advice.

All analytics live in the cross-platform `StrandAnalytics` Swift package. Every entry point is a **pure, deterministic, DB-free** function over its inputs — no I/O, no global state, no network. Persistence and BLE are wired in elsewhere (`WhoopStore`, the app target). This makes the whole package straightforward to unit-test against fixed vectors.

- Package: `Packages/StrandAnalytics/Sources/StrandAnalytics/`
- Top-level index: `StrandAnalytics.swift` (`StrandAnalytics.version == "0.1.0"`)
- App integration: shared `Strand/` sources back the released macOS and iOS targets. Both execute the
  same `StrandAnalytics` code; this fork no longer carries an Android/Kotlin twin.

---

## What is actually wired into the app

The package contains more analytics than the app currently surfaces. This section is the honest map
of **library-only** vs **live**, verified against the app sources. The status below applies to the
released macOS and iOS targets.

| Engine | File | Status in the app |
|---|---|---|
| `HRVAnalyzer` | `HRVAnalyzer.swift` | **Live.** Its cleaning (range filter, Malik ectopic rejection, 20-beat gate, gap-aware RMSSD) builds the nightly HRV windows in `DailyAnalysis` and the on-demand HRV snapshot. Live stress check-ins use the dedicated `StressOnsetDetector`. |
| `RecoveryScorer` | `RecoveryScorer.swift` | **Live.** Computes the **Charge** score. Runs inside `AnalyticsEngine.analyzeDay` via `Strand/Data/IntelligenceEngine.swift`; computed values are persisted under the `"<deviceId>-noop"` source and merged **under** any imported `recovery_score_pct` (imports always win). APPROXIMATE. |
| `StrainScorer` | `StrainScorer.swift` | **Live.** Computes the **Effort** score (0–100) on the fitted curve, against the resolved maximum heart rate and the night's Effort resting rate. Day load is computed on-device for nights the strap offloaded; the imported `day_strain` column still wins for imported days. APPROXIMATE. |
| `SleepStager` / `SleepStagerV2` | `SleepStager.swift`, `SleepStagerV2.swift` | **Live.** `SleepStager` detects each offloaded night inside `analyzeDay`; `SleepStagerV2` (the default staging recipe) stages it, and the stages feed the **Rest** composite. Computed sessions are persisted under the `"-noop"` source, with imported sleeps taking precedence. APPROXIMATE. |
| `Baselines` | `Baselines.swift` | **Live.** Seeds the recovery baseline in `IntelligenceEngine.analyzeRecent` (two-pass cold-start). The illness early-warning in `AppModel` still uses its own trailing-window baseline math inline (see below). |
| `WorkoutDetector` / `Calories` | `WorkoutDetector.swift` | **Live analytics helper.** Runs inside `AnalyticsEngine.analyzeDay`; its bouts contribute diagnostics and may fill missing metrics on an overlapping manual/imported workout. It no longer creates or reconciles generic `sport="detected"` rows. All intensity/calorie fields are APPROXIMATE. |
| `AnalyticsEngine` | `AnalyticsEngine.swift` | **Live orchestrator.** `analyzeDay(...)` is called by `Strand/Data/IntelligenceEngine.swift` — every 15 minutes while connected, and from the Intelligence screen — and its `DailyMetric`, sleep sessions and detected workouts are persisted under the `"-noop"` source. |
| `HRZones` | `HRZones.swift` | **Live.** The display zone model, and the ONLY one — every surface that buckets a heart rate resolves through `ProfileStore.hrZoneSet` (live readout, in-workout card, Health hero, workout time-in-zone, haptic zone coaching, the coach's `get_zone_minutes`). Bands are user-definable; see "Two zone models" below. |
| `CorrelationEngine` | `CorrelationEngine.swift` | **Live.** Used by `InsightsView`, `CompareView`, `MetricExplorerView`. |
| `BehaviorInsights` | `BehaviorInsights.swift` | **Live.** Used by `InsightsView` (`rank` + `sentence`). |
| `ComparisonEngine` | `ComparisonEngine.swift` | **Live.** Used by `MetricExplorerView`. |

### Incremental analysis and launch behavior

`IntelligenceEngine` serializes launch, device-adoption, backfill, HealthKit and manual requests into
merged generations. The repository publishes a 120-day recent snapshot first; maintenance and the
ordinary 21-day score refresh run after the first interactive screen rather than competing with it.

Day reuse is revision-based. Every scoring-relevant raw mutation stamps the affected UTC-day buckets
inside its database transaction. A local analysis day can reuse its persisted result only when the
maximum revision across its exact window, device revision, owner, `scoringVersion`, semantic/profile
signature, learned traits and baseline carry values all match. PPG-only, R-R-only and edited external
sleep changes therefore invalidate the same way as measured heart rate, while duplicate offloads and
engine-derived outputs do not.

Raw range reads no longer impose a semantic 200,000-row ceiling. Sorted slices and one-pass bucket
distribution replace the most expensive repeated full-array filters in sleep and recovery. The first
run after a legacy fingerprint upgrade can still perform a CPU-heavy 21-day background refresh; fully
cursor-paged raw reads and a three-UTC-day chunk cache remain future work.

### Analysis recipe (AI-n) and the full rebuild

Stored derived values carry the meaning of the **analysis recipe** that produced them
(`AnalysisRecipe.currentVersion`, the fork's own lineage, shown as "AI-n"; **39** at the time of writing). A
change that can leave stored values stale (scoring math, an input window, the meaning of a stored derived
value, source precedence, baseline semantics, cache invalidation) bumps it; UI, logging and output-identical
performance work do not. The version is never tied to the marketing or build version, and Settings' manual
21-day reanalysis does not advance it.

From AI-31 on, **every bump runs the same rebuild** (`AnalysisRecipe.RebuildStep`, in order): the legacy input
repairs a store below AI-31 still owes, the AgeLess reset, the workout peaks (for the measured maximum heart
rate), every day with raw strap data scored again, the weekly scores, NOOP's own stress proxy rows, the daily
rhythm rows, workout heart-rate fills, the cardio-load ledger, the energy history and a final snapshot
refresh. The rebuild resumes at the step it was in, writes the recipe cursor only after the last step, never
erases raw samples and never replaces a value an import or the wearer supplied (a corrected night keeps its
bed and wake times; only its derived stages are recomputed). At most one bump is made per release. Before
AI-31 each bump re-scored a window chosen per recipe, mostly the last 21 days.

What the recipes since AI-31 changed:

| Recipe | What moved |
|---|---|
| AI-31 | The one rebuild rule itself; no formula changed. |
| AI-32 | Maximum heart rate resolved in one place (`MaxHeartRate`); the new Effort curve; V3 conservative sleep onset on raw-backed history; breath-interval respiratory rate; off-wrist time cut out of kept sleep; deep held back 20 min after onset. |
| AI-33 | No run merges across a data gap longer than `maxGapMin`; a SDNN segment failing the beat gates gives no daily SDNN; AgeLess sleep consistency of a night split by a wake; a short last stretch continuing a night is kept; the day cycle opens on an early bedtime. |
| AI-34 | Superseded detected sleep rows are deleted when a night is detected again with a moved onset. |
| AI-35 | Each day is judged by the nights before it (90-day Charge baselines, per-night Rest need and regularity), day windows cut at the day's own local midnight; Health Connect workouts get their Effort. |
| AI-36 | Sessions recorded in Training get their average, peak and Effort. |
| AI-37 | A session copied back into the health store under another sport name collapses into NOOP's own row (the energy model prices the day from the collapsed list). |
| AI-38 | A deleted night blocks only nights that mostly lie inside it; the wearer's sleep marks bound the night they fall in; Effort's day rule and its resting heart rate; the evening sofa rule; the body mass a day is priced at decays per calendar day. |
| AI-39 | Four `active_min_*` series per day (active minutes, see *Training Load phase 2*). |

**In short:** the *interactive data-interrogation* engines (correlation, behavior effects, period comparison) are wired into screens, and the *recompute-from-raw-streams* engines that produce the three daily scores — Charge (recovery), Effort (strain), Rest (sleep), plus workout detection — run live too: `IntelligenceEngine` calls `analyzeDay` for every night the strap offloaded and persists the APPROXIMATE results under the `"-noop"` source, merged under any imported rows — a WHOOP export still wins wherever it covers a day. The live BLE app additionally runs four small inline analytics in `AppModel`: HR smoothing, RMSSD, HR-zone coaching, an illness/strain early-warning, and a resting-stress nudge.

---

## Live analytics in `AppModel`

Source: `Strand/App/AppModel.swift`. These run against the live BLE stream and the daily history, on the main actor.

### 1. Heart-rate smoothing (`ingestHR`)

Every screen shows a **smoothed** bpm (`AppModel.bpm`), never the raw per-beat value (which swings with HRV). The smoother:

1. Prefers the strap's reported HR; falls back to `60000 / RR` (last R-R interval) if needed.
2. Clamps to a plausible `30…220` bpm range — rejects `0` and garbage spikes.
3. Keeps a ~10-second sliding window (max 40 samples) and **publishes the window median**.

```swift
hrWindow.append((now, inst))
hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10 s window
if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
let vals = hrWindow.map(\.v).sorted()
bpm = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
```

Median (not mean) is deliberate: it rejects single-beat outliers without lagging the signal.

### 2. Heart-rate ceiling haptics (`HRCeilingAlertEngine`)

Watches the same ~10-second median `bpm` as the live UI. In profile-zone mode the ceiling is always the
lower edge of the next band from `ProfileStore.hrZoneSet`, so automatic, custom-percent and custom-bpm
profiles all drive the buzz at exactly the boundary shown on screen. Direct-bpm mode deliberately uses
the independent fixed value instead.

The first accepted smoothed sample at or above the ceiling warns immediately. In standard mode that is a
three-loop warning followed by at most two reminders 60 seconds apart. The optional frequent mode instead
emits one loop every two seconds while the current smoothed value remains at or above the ceiling. Both pause below the ceiling;
15 seconds at least 3 bpm below it produces the one-loop recovery cue and rearms the episode.
Missing/implausible data cannot trigger or mature a reminder. The user chooses always-while-worn or
recorded-workouts-only; both remain gated on bonded + worn and opt-in by default.

### 3. Target-zone training haptics (`HRZoneTrainingEngine`)

An explicitly started workout or Live Session can select no coach or one target Zone 1...5. The engine
classifies the same smoothed `bpm` through `ProfileStore.hrZoneSet`, so automatic, custom-percent and
custom-bpm profile bands remain the sole boundaries. Eight continuous seconds establish below, inside,
or above target: two light taps mean increase intensity, one tap confirms the target, and three heavy
taps mean ease off. Outside reminders are limited to every 30 seconds; the target state stays silent.

Invalid or missing samples reset pending stability and anchor reminder time. A profile-band change resets
the episode. Haptic ownership is ceiling > target-zone coach > adaptive Live Session; selecting a target
keeps the Live Session's visual/stored adaptive analysis but suppresses its competing wrist cues.

### 4. Illness / strain early-warning (`evaluateIllness`, `IllnessSignalEngine`)

The live, app-side version of the baseline-comparison idea. It recomputes whenever the daily history changes (`repo.$days`) and only on today's row, with at least 14 days of history and `behavior.illnessWatch` on. The recent window is the **last 2 days**; the baseline is the **~28 days ending 3 days ago**, so the recent window does not contaminate its own baseline:

```swift
let recent = Array(days.suffix(2))
let base   = Array(days.suffix(31).dropLast(3))   // ~28 days ending 3 days ago
```

The earlier fixed-threshold rule (resting HR +5 bpm, HRV −20 %, skin temperature +0.6 °C, respiration +1.5 bpm, any two) is gone. `IllnessSignalEngine` replaced it with a score against the wearer's own baselines:

1. Each of four signals is z-scored (`Baselines.deviation`) against a baseline folded over the pre-recent history, oriented so that positive means illness-like: resting HR up, respiration up, skin-temperature deviation up (z against a zero-centred 0.3 °C spread), and HRV **down** (negated z). The two-night mean is used, and a signal counts only while the newest night also clears the same threshold (#2533).
2. A signal *fires* at `|z| ≥ signalZThreshold = 2.0`. Its sub-score is `min(perSignalCap = 40, kZToScore = 22 × (z − 2))`; the composite is their sum, capped at 100.
3. Nothing raises without a **trusted** baseline (at least 14 valid nights, not stale) and at least `minCorroboratingSignals = 2` firing signals; the composite must reach `mildThreshold = 25` to be heard at all and `raiseThreshold = 50` to be raised.
4. **Confounders** from the last two days' journal (alcohol, stress, a hard or late workout, travel; `sauna` exists in the engine) multiply the score by `confounderDampen = 0.45` and downgrade the level to *suppressed*. A logged "feeling unwell" turns the message into a plain "rest up" (`alreadyUnwell`) whatever the score.
5. Levels: quiet, mild (detail view only), raised (banner and notification), suppressed, alreadyUnwell.

A parallel Mahalanobis distance on the same z-vector (`IllnessDistance`, threshold 2.5, at least two deviating features) only supplies the "how strong" band on the Heads-Up card; it never gates the alert. On-device only; the copy is plain English and always ends in the not-a-diagnosis line.

---

## `HRVAnalyzer` — RMSSD / SDNN with cleaning

Source: `HRVAnalyzer.swift`. Reproduces the **Task Force (1996)** definitions over R-R / NN intervals (ms), with a deterministic cleaning pipeline.

### Formulas

```
RMSSD = sqrt( (1/(N-1)) · Σ (NN[i+1] − NN[i])² )    (Task Force 1996)
SDNN  = sample standard deviation of NN, ddof = 1     (Task Force 1996)
pNN50 = 100 · (count of |ΔNN| > 50 ms) / (N − 1)
```

`rmssdRaw(_:)` and `sdnnRaw(_:)` are the raw primitives (no filtering, return `nil` for fewer than 2 values).

### Cleaning pipeline (`cleanRR`)

1. **Range filter** — drop intervals outside `[rrMinMs, rrMaxMs] = [300, 2000]` ms (≈ 200 bpm to 30 bpm).
2. **Ectopic rejection (Malik-style)** — drop any beat deviating more than `ectopicThreshold = 0.20` (20%) from a **local median** over a centered window of `2·ectopicWindowRadius + 1 = 5` beats. Beats with too small a neighbourhood are kept.
3. **Sufficiency gate** — require at least `minBeats = 20` clean intervals before returning a trustworthy result; otherwise `HRVResult.empty(...)`.

> **Honest substitution.** The reference Python pipeline ran neurokit2's Kubios / Lipponen–Tarvainen (2019) artifact classifier, which isn't available on-device. NOOP substitutes the classical **Malik et al. (1989)** 20%-local-median rule — a simpler, fully deterministic approximation of the same intent (remove physiologically impossible beat-to-beat jumps before computing HRV). It does not model the missed/extra-beat insertion that Kubios does.

### API

```swift
HRVAnalyzer.analyze(_ rr: [RRInterval], windowStart: Int?, windowEnd: Int?) -> HRVResult
HRVAnalyzer.analyze(rawRR: [Double]) -> HRVResult
```

`HRVResult` carries `rmssd`, `sdnn`, `meanNN`, `pnn50`, plus `nInput` and `nClean` (counts before/after cleaning) for transparency.

---

## `RecoveryScorer` — the **Charge** score (transparent 0–100 recovery composite)

Source: `RecoveryScorer.swift`. Produces **Charge** — *"how recovered are you?"* A **z-score + logistic** composite, **led by your heart-rate variability (HRV) measured against your own personal baseline**, plus resting heart rate, last night's Rest, breathing rate, and a skin-temperature signal (an early illness / overreach flag). It is explicitly **approximate** and makes no claim to reproduce WHOOP's proprietary Recovery % model — same core idea (HRV-led recovery), but our weighting and baseline maths are our own and openly documented here.

### Weighting

Higher HRV versus your baseline means more Charge. Skin-temp folds in as a symmetric penalty: the further from baseline (in either direction), the less Charge, since a large deviation flags possible illness or overreach.

| Driver | Direction | Weight |
|---|---|---|
| HRV vs baseline | higher → more Charge | `wHRV = 0.55` (dominant) |
| Resting HR vs baseline | lower → more | `wRHR = 0.20` |
| Rest quality (sleep) | higher → more | `wSleep = 0.15` |
| Respiration vs baseline | lower → more | `wResp = 0.05` |
| Skin-temp deviation | further from baseline → less | `wSkinTemp = 0.05` |

The skin-temp term uses the deviation already computed as `DailyMetric.skinTempDevC` (±°C from the personal baseline), entered as a symmetric penalty `−|dev| / skinTempScaleC` (1 °C). SpO₂ folds in **only when real** (imported) as a small penalty below ~95%; it's never fabricated and never applied on a bare 5/MG day. HRV's weight dropped from `0.60` to `0.55` to make room for skin-temp; when skin-temp is absent the weights renormalize, so the score matches the older HRV-led composite.

Each metric is standardized to a **robust z-score** against the personal baseline (EWMA spread):

```
z = (value − mean) / (1.253 · spread)
```

The `1.253` converts an EWMA mean-absolute-deviation into an approximate Gaussian σ (`E[|X−μ|] = σ·√(2/π) ≈ σ/1.253`). For "lower is better" drivers (RHR, resp) the z is inverted by swapping value and mean. The sleep term is centered directly: `(sleepPerf − 0.85) / 0.12`.

Missing terms are dropped and weights renormalized (an optional baseline that is not yet usable, resting HR, respiration or Effort, is dropped the same way instead of entering with a synthetic midpoint). The weighted-mean z is squashed:

```
score = 100 / (1 + exp(−logisticK · (z − logisticZ0)))
        logisticK  = 1.6     (±2 z ≈ the full red–green band)
        logisticZ0 = −0.20   (anchors z = 0 → ~58 %)
```

The `58%` anchor matches WHOOP's published population-average recovery (`populationMean = 58.0`).

**Two further optional terms exist in `RecoveryScorer` and are not supplied by the app.** An overnight resting-HR decline slope (`recoveryIndexSlope`, weight `wRecoveryIndex = 0.05`, scale 2 bpm/h) and a previous-day-Effort term against its personal baseline (`priorDayEffort` with `effortBaseline`, weight `wActivityBalance = 0.05`) are tested library options; no production caller passes them, so the shipped Charge is the five-driver composite above.

**Parasympathetic-saturation guard: detected and logged, not applied.** A night whose HRV z and resting-HR z are both at least 0.5 personal SD on the low side (`satEnterZ`) is flagged in the Charge trace and the driver verdict, together with the easing it *would* apply (up to `satMaxDampFraction = 0.5` of the HRV penalty, full strength at 1.5 SD). `recovery(...)` ignores it, because low HRV with low resting HR is also a reported sign of parasympathetic overreaching and no real saturation night has been observed.

### Which nights a day is scored against (AI-35)

Each day is scored against the baselines of the nights **before** it: the wearer's own nights of the last
`ChargeBaselines.windowDays = 90` days up to the day before (`ChargeBaselines.anchorDay(forScoredDay:)`), with
imported vendor nights seeding only until the own nights alone are trusted (#2525). The night being scored and
every later night stay out, so a past day keeps its score when new nights arrive and a rebuild scores July
against July's normal, not November's. The Charge configs add a 3-night spread half-life while the baseline is
young (`ChargeBaselines.earlySpreadHalfLife`, `MetricCfg.earlyHalfLifeS`), so the spread reaches the wearer's real night-to-night spread instead of
staying near its floor. Every readout of a day's Charge (the driver rows, the calibration count, the confidence
tier, the vitals' usual value, the coach) resolves that day's baselines through the same rule
(`Repository.chargeBaselines(forDay:)`).

### Cold-start ("Calibrating")

HRV is the dominant driver, and NOOP needs a few nights to learn your personal baseline first. If that baseline isn't usable yet (`BaselineState.usable == false`, i.e. fewer than `minNightsSeed` valid nights), `recovery(...)` returns `nil` and the UI shows **"Calibrating"** — more honest than fabricating a number. Callers may fall back to `populationMean` but should flag it.

### Bands (`band(_:)`)

| Band | Range |
|---|---|
| red | `< 34` |
| yellow | `34 … 67` |
| green | `≥ 67` |

### Resting HR

`recovery(...)` takes the sleeping resting HR as an input; it does not compute one. The number the apps show comes from the sleep path — see [Per-session resting HR and HRV](#per-session-resting-hr-and-hrv).

---

## `StrainScorer` — the **Effort** score (0–100 cardiovascular load on a fitted curve)

Source: `StrainScorer.swift`. Produces **Effort** — *"how hard did your heart work?"* Your day's cardiovascular load: an **independent** implementation (WHOOP-*like*, not a reproduction). Every minute of heart rate weighs more the closer it sits to your maximum, measured on the heart-rate reserve (Karvonen), and the day's load lands on a 0–100 curve with a soft cap, so easy days sit low and 100 stays out of reach.

> **Analysis recipe AI-32 (13.0.0, #2438).** Until then Effort summed Edwards-*style* zone weights (or, behind a setting, Banister's exponential TRIMP) and compressed them as `100 · ln(TRIMP + 1) / ln(7201)`. Both are gone from Effort, and so is the Banister setting: one curve, fitted on WHOOP's own Strain for **3,760 workouts in 15 exports** people shared in #2438, replaces them, and the recipe bump scores the whole history again with it. The Training Load cardio lane keeps its Banister load (see below). `trimpToStrain`, `strainDenominator` and `fitStrainDenominator` remain in the source for that lane's legacy readers and their tests; they no longer produce Effort.

> **Scale (0–21 → 0–100).** Effort is the same cardiovascular-load idea as WHOOP's Day Strain (0–21). The curve is fitted and evaluated on the 0–21 axis (`effortScore21`) and its top is rescaled to 100 (`maxStrain 100.0`, `effortValue(fromWhoopStrain:)` for imported values) so all three NOOP scores share one scale.

### Pipeline

1. **Heart-Rate Reserve (Karvonen 1957):** `HRR = HRmax − RHR`, with HRmax from the resolver below and RHR the night's **Effort resting rate** (see below), not the shown resting heart rate.
2. **Per-sample intensity** as `x = %HRR = (HR − RHR) / HRR × 100`, clamped `[0, 100]` (`pctHRR`).
3. **Weight of one minute** (`effortWeight`):

   ```
   w(x) = e^(β · (x − 55) / 10) / (1 + e^(−(x − 20) / 3)),    β = 0.5646
   ```

   A minute at 55 %HRR (the middle of the old zone 1) weighs 1; each 10 %HRR more multiplies the weight by
   about 1.76; below 20 %HRR the logistic step fades it out.
4. **A day counts nothing below 50 %HRR, and never sits below its strongest workout.** A reading below
   **50 %HRR** (`effortOutsideWorkoutFloor`, where the old zone 1 began) adds nothing to a **day's** load,
   inside a workout or not (`StrainScorer.LowIntensity.day`), so hours of standing and walking around do not
   add up to a moderate day. A **workout's own** score counts every reading (`LowIntensity.counted`), and the
   day is lifted to the load of its strongest workout scored that way. WHOOP keeps workout Strain and Day
   Strain apart (a walk logged as a workout scores about 4 while a day of walking scores about 2, and a day
   sits below its strongest workout on 1 of 368 days in two exports), and summing each workout's low time into
   the day had overcounted. Dismissed detected workouts do not count. Each reading is credited with at most 2
   minutes (`maxSampleGapMin`), so a gap cannot invent load.
5. **Load → score** (`effortScore21`, `effortValue(load:)`):

   ```
   b      = a · ln(1 + load / k),                a = 5.4591, k = 12.2245
   score₂₁ = 21 · b / (b^p + 21^p)^(1/p),        p = 8   (soft cap: 21 is never reached)
   Effort = score₂₁ / 21 × 100, two decimals, at most 99.99
   ```

   `a`, `k` and `β` are fitted; the floor, the cap and the outside-workout threshold are set. On the fit, a
   brisk 30-minute walk lands around 32, an hour in zone 4 around 83 and a 3:30 marathon around 97.
6. **Lab: Strength in Effort** (off by default). A rated strength session adds `0.11 × session RPE ×
   minutes` to the load before the curve, on the day it starts (`strengthLoad`,
   `effortValue(_:addingStrengthLoad:)`). 0.11 is the median load WHOOP gave 419 strength sessions of nine
   contributors beyond heart rate, assuming RPE 7. No rating, no share.

### Two zone models — and why they disagree

NOOP has **two** notions of "zone". Confusing them is the root of a real user-reported defect, so they
are worth stating plainly:

| | Display zones (`HRZones`) | Effort zones (`StrainScorer`) |
|---|---|---|
| Measured against | **% of HRmax** | **% of heart-rate RESERVE** (`(HR − RHR) / (HRmax − RHR)`) |
| Boundaries | 50/60/70/80/90 by default, **user-definable** | none: a continuous weight `w(x)` over %HRR, with the fixed 50 %HRR floor for a day |
| Drives | the live readout, in-workout card, Health hero, workout time-in-zone, haptic coaching, what the coach prescribes | the Effort score, and nothing else |

They are not interchangeable, and the gap is large. With HRmax 190 and a resting HR of 50, the floor of
**display** Zone 2 (60 % HRmax = 114 bpm) is only 46 %HRR — *below* the 50 %HRR floor, so in the day's
score it earns nothing — while its top (70 % HRmax = 133 bpm) is 59 %HRR and weighs about 1.25.

Consequences that follow from this, both deliberate:

- **User-set bands never reach Effort.** They change what is displayed and what is prescribed; no stored
  score moves when a band is edited, so history stays comparable and the ported method stays faithful.
- **A session prescribed in display zones needs translating** before anyone can state what it is worth.
  `EffortFeasibility` does that translation — `effortWeight` × minutes through the same
  `effortValue(load:)` that scores the day — which is what stops the coach offering "20 min in Zone 2,
  effort 15" for a session worth something else. It reports a `typical` figure from the MEAN weight
  across the band rather than the weight at its midpoint, so a band that straddles the floor is not read
  as worth nothing.

### The resting heart rate Effort is scored against (`EffortRestingHR`)

The curve was fitted on WHOOP's Strain, which WHOOP computes from its own resting heart rate, a dynamic average
weighted towards the night's last deep sleep, so a value between the night's lowest stretch and its mean. NOOP
shows the night's lowest five minutes, which sits well below it (on one paired wearer WHOOP's value ran 4 to 6
bpm above NOOP's lowest bin, the main night's mean about 10 above it). Scored against the lowest bin every
reading sat higher in the reserve and light days were lifted most; against the mean, hard days fell about twice
as far as expected. A night's Effort resting rate is therefore **halfway** between its lowest five-minute bin
and its main-night mean (`towardsMean = 0.5`; both must lie in 30 to 130 bpm). The daily pass resolves each
day once and stores it as `rhr_effort`; without a night the median of up to the last 7 nights' values within
30 days stands in, then a device-supplied resting rate, then 60 bpm. Effort, its bouts and the workouts it is
scored from read it; the shown resting heart rate and every other model keep theirs. The aim is ranges
comparable with WHOOP's, not a copy of its number.

### 5/MG continuity

Effort reads `COALESCE(measured HR, ppg_hr)` via hrBuckets, so 5-series users get Effort from live + PPG
HR. The former steps / active-energy floor is gone with AI-32: Effort comes from heart rate alone.

### Maximum heart rate (`MaxHeartRate.swift`)

Live Effort, the stored day, heart-rate zones, AgeLess, energy and the coach read one resolved value:

1. **The wearer's own setting**, exactly as entered, always wins.
2. **The measured level:** the level held by five consecutive readings within a minute in workouts
   (`StrainScorer.sustainedPeak`), reached on **two different days** of the **last 90**. A day reads only the peaks of the days before it, so its own
   workouts cannot move its value. A peak more than **25 bpm** above the formula counts as an artefact,
   and after a quiet stretch the level falls slowly, with a slope set by age.
3. **Gellish et al. (2007):** `192 − 0.007 × age²`, rounded to a whole bpm, until a level is confirmed.
4. With neither a setting, a level nor an age: `StrainScorer.defaultMaxHR()` (220 − default age).

Settings shows which of these is in force. `StrainScorer.estimateHRmax` (observed 99.5th percentile with a
Tanaka floor) remains only for the workout-type classifier.

### Guards & gates

- Returns `nil` with fewer than `minReadings = 600` samples (≈ 10 min at 1 Hz), unless a sparse stream has at least `minSparseReadings = 20` readings spanning `minSpanSeconds = 600` s (a strap that reports standard HR only about every 30 s), or when `HRmax ≤ RHR` (invalid HRR).
- Per-sample duration is inferred from the first two timestamps, falling back to `1 s`.

### Denominator calibration (`fitStrainDenominator`, legacy)

Fits the old log map's `D` from `(TRIMP, reference_strain)` pairs: `ln(D) = maxStrain · Σx² / Σ(x·strain)`,
`x = ln(TRIMP+1)`. It belongs to the pre-AI-32 curve and no longer calibrates Effort; the fitted curve's
constants were derived offline from the #2438 exports.

---

## `SleepDebt` — actionable next-night sleep target

The displayed debt is a planning estimate, not an hour-for-hour bank of every
minute missed over the last fortnight. For each usable night, NOOP carries 55%
of the complete unmet need into the following night's target:

```text
currentNeed = personalizedBaseNeed + currentDebt
nextDebt    = 0.55 × max(0, currentNeed − creditedSleep)
```

`creditedSleep` is the main night's asleep time plus separately recorded nap
sleep. A calculated debt below 10 minutes is treated as balanced; exactly 10
minutes remains debt. Meeting the complete current need clears the displayed
debt, and extra sleep never creates a positive bank. The chart bars remain the
raw nightly difference from base need so the underlying nights stay visible.

The coefficient is an interoperability approximation, not a physiological
constant. It was selected against one contributor's 853 consecutive exported
WHOOP nights: the 0.55 recurrence was within 15 minutes of WHOOP's following-day
debt on 93.0% of pairs and within 20 minutes on 94.5%. That contributor also used
WHOOP's sleep-debt target for daily sleep planning for approximately 800 days.
This is useful longitudinal field evidence, but it is single-user validation,
not a population study or clinical claim.

A bounded, recency-weighted planning estimate is also more honest than treating
sleep loss as interchangeable hours. Controlled restriction studies find that
sleep physiology, subjective sleepiness, and cognitive performance accumulate
and recover on different timescales; recovery depends on sleep dose and intensity,
and some performance effects can remain after extended recovery sleep:

- Van Dongen et al. (2003), chronic restriction dose-response:
  <https://pubmed.ncbi.nlm.nih.gov/12683469/>
- Banks et al. (2010), recovery-sleep dose response:
  <https://pmc.ncbi.nlm.nih.gov/articles/PMC2910531/>
- Doty et al. (2020), differential recovery across neurobehavioral measures:
  <https://pubmed.ncbi.nlm.nih.gov/33274389/>

The estimate therefore answers the narrow product question “how much should I
add to tonight's base sleep target?”, not “have all physiological and cognitive
effects of prior sleep restriction disappeared?”. Swift and Kotlin implement the
same constants, recurrence, deadband, nap credit, and 14-usable-night bound.

## `SleepStager` — sleep/wake detection + approximate 4-class staging (feeds **Rest**)

Source: `SleepStager.swift`. Detects in-bed sessions from gravity/HR/RR/respiration and produces a 30-second hypnogram of `{wake, light, deep, rem}`. These stages and the AASM roll-up below are the raw material the **Rest** score composite consumes (see *The Rest score composite* immediately after this section).

> **Honest hedging.** These stages are **approximations**, not PSG-validated, not medical advice. **Light/deep separation is the weakest link — deep-minute estimates are the least reliable output.**
>
> **What the EEG-free literature actually measures, and why it flatters us (#2835).** This note used to read "the EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019)". Walch et al. (2019) report a **three-class** task — wake / NREM / REM, about 72% — alongside a separate **two-class** sleep/wake result near 90%. It attempts **no** light/deep separation, so it publishes no four-class ceiling, and the range was attributed to a task the paper did not run.
>
> The correction makes this hedge **stronger**, not weaker. The four classes NOOP outputs are a harder problem than the three Walch scored, so ~72% is an **upper bound from an easier task** rather than a ceiling for ours — and the sentence immediately above, that light/deep is the weakest link, is precisely about the class that literature never had to separate. No four-class figure is quoted here because the cited work has none to quote.

### Stage 0 — gravity-stillness sleep/wake spine (`detectSleep`)

- Per-record movement proxy = L2 magnitude of the gravity-vector change vs the previous record (`gravityDeltas`).
- A sample is "still" if its delta < `gravityStillThresholdG = 0.01 g`. A rolling window (`stillWindowMin = 15` min) calls its center "sleep" when ≥ `stillFraction = 0.70` of samples are still.
- Contiguous runs are built, breaking on a class change or a data gap > `maxGapMin = 20` min; runs shorter than `mergeMin = 15` min are absorbed into neighbours.
- A run must exceed `minSleepMin = 60` min to count, and is **HR-confirmed**: median HR over the run must be ≤ `hrSleepBaselineMult = 1.05 ×` the day's median HR, widened for deeply quiescent motion as described below (skipped when fewer than 30 HR samples — gravity is trusted alone).
- **V3 conservative onset after bridging (fork).** Onset evidence is rebuilt from raw stillness flags
  before permissive gap bridging or short-run absorption. Bare missing-motion gaps can join evidence
  runs within the existing gap bound only when both median and mean HR support them; the continuity
  path keeps its existing median guard. If a joined candidate contains an evidence run that already
  exceeds the existing 60-minute floor, and activity separates short leading bouts from that run,
  its onset moves to the first independently qualifying run. This deliberately prefers omitting
  uncertain initial rest over admitting a chain of short bouts as hours of sleep. A qualifying first
  run, a bare missing-data gap and a candidate with no independently qualifying run retain the previous
  behavior. Interior interruptions remain bridgeable; this is a boundary-selection rule and does not
  change the light/deep/REM formulas. Stillness does not prove sleep, so uninterrupted quiet wake can
  remain indistinguishable from sleep. V3 uses the existing V2 phase engine. The explicit V2 and V1
  pipelines retain the original detector. Legacy Boolean APIs still select V1/V2; the app resolves the
  default V3 preference separately and includes the method in detection and persisted-day cache keys.
- A citable **te Lindert 30 s Cole–Kripke** index (`SI = 0.001 · Σ wᵢ·Aᵢ`, sleep iff `SI < 1`, weights `[106, 54, 58, 76, 230, 74, 67]`) is computed per epoch as a cross-check and to find onset / final-wake.

- **Nap and stillness guards.** A window centred in the local daytime band (11:00 to 20:00) must run at least `daytimeMinSleepMin = 90` min and show a resting HR at or below `daytimeRestingHRMult = 0.95 ×` the day's baseline (#90), unless it resumes within `nightContinuationGapMin = 90` min of an overnight chain (the night's tail). A daytime block that begins within `morningStillnessWindowMin = 180` min after the night's wake is held to the stronger `morningReonsetRestingHRMult = 0.90` bar, or to the strap's own "asleep" band state in at least `morningReonsetBandAsleepFrac = 0.6` of its epochs (H7/H8, #531). The evening twin (H9, DX23876/noop#60) holds an evening block (centre from 20:00) that a longer sleep follows within `eveningStillnessWindowMin = 180` min to the same bar, so a still evening on the sofa is no longer a separate sleep; the first half of a genuinely split night dips far below the day's median and keeps its place. A single assembled run longer than `maxMainSleepSpanS` (16 h) is dropped as a clock artefact (H4), and off-wrist time inside a kept run is cut out of it (a run more than `maxOffWristSleepFraction = 0.5` off-wrist is refused).

### Stage 1 — per-epoch cardiorespiratory features (classic stager, V1)

Over a rolling 5-minute window per 30 s epoch:

- mean HR;
- **Walch difference-of-Gaussians HR variability** (`σ1 = 120 s` minus `σ2 = 600 s`, reflect-padded convolution; NaNs linearly interpolated);
- **RMSSD / SDNN** from range-filtered R-R (`HRVAnalyzer.rmssdRaw` / `sdnnRaw`);
- **respiration rate + RRV** from the raw 1 Hz resp channel via a simple peak detector (detrend → local-maxima peaks ≥ 2 s apart → breath intervals 1.5–12 s → rate = `60 / median interval`, RRV = std of intervals).

> Frequency-domain HRV (HF, LF/HF) is **omitted** — there is no neurokit2/scipy on-device — so the parasympathetic-tone signal is **RMSSD only**. The respiration peak-finder is a faithful port (the reference derived these "robustly ourselves" too, without neurokit).

### Stage 2 — percentile-band classifier (`classifyOne`)

Reference distributions are taken over the session's **sleep-period** epochs (Cole–Kripke = sleep). A motion fraction and the per-epoch features are compared against session-relative percentiles:

| Class | Rule |
|---|---|
| **wake** | sustained motion (`moveFrac ≥ 0.15`) **and** activated cardiac (high HR or high DoG-HR variability), or no HR to vet the motion |
| **deep** | still (`moveFrac ≤ 0.10`) **and** high parasympathetic tone (RMSSD ≥ 70th pct) **and** low HR (≤ 25th pct) **and** regular respiration |
| **rem** | still body **and** activated cardiac **and** irregular respiration (RRV ≥ 65th pct); a fallback requires both cardiac signals when respiration is unavailable |
| **light** | everything else (the default) |

### Stage 3 — smoothing + physiology re-imposition

- 5-epoch **median smoothing** of the label sequence (`smoothLabels`).
- **No REM in the first 15 min** after onset (`reimposePhysiology` → demote to light).
- **No deep after the first third** of the night (deep is biased early) → demote to light.
- Pre-onset and post-final-wake epochs are forced to `wake`.

Consecutive same-stage epochs are merged into `StageSegment`s tiling `[start, end]`.

### Outputs

- `SleepSession` — `start`, `end`, `efficiency` (AASM `asleep / in-bed`, where `asleep = in-bed − wake`), `stages`, per-session `restingHR` (lowest 5-min rolling-mean HR) and `avgHRV` (mean RMSSD over 5-min tumbling windows).
- `hypnogramMetrics(_:)` — AASM-style roll-up: TIB / TST / SPT / SOL / REM latency / WASO / efficiency / disturbances, plus deep/REM/light minutes and percentages.

### Default staging — `SleepStagerV2`, and the Lab recipes

`SleepStager.Method` selects the detection and staging pipeline: **V3** (the default; V2 stages with the conservative-onset detection described above), V2, or the classic V1 whose Stages 1 to 3 are described above. Detection always comes from `SleepStager`; the recipe only re-stages a window already decided to be sleep. `SleepStagerV2` became the default over V1 after a 44-subject leave-one-subject-out benchmark (kappa 0.35 against 0.03, deep recall 55 % against 1 %); its coefficients are fixed a priori from sleep physiology and population base rates, not fitted to labels. Each 30 s epoch is staged from:

1. per-night z-scored cardiorespiratory emissions (heart rate, heart-rate variability, movement);
2. a per-night **deep gate** on the 11-minute heart-rate flatness percentile (deep is eligible only in the lowest `deepGateThresh = 0.25` of epochs);
3. a soft sleep-cycle prior (deep concentrated early; REM rising through the night) with base log-priors light 0.50, REM 0.22, deep **0.15** (lowered from 0.18 against PSG hypnograms), awake 0.10, a **REM-latency guard** (3 log-odds at onset, decaying linearly to zero over 60 min) and a **deep-latency guard** (3 log-odds, decaying over 20 min, adopted from ayiskakov/noop);
4. a peak-motion wake gate thresholded against the night's own quiescent jerk floor (moving above floor × 38, gate above floor × 55);
5. an RR-derived respiration-regularity term (`respWeight = 0.6`: regular breathing to deep, irregular to REM);
6. Viterbi smoothing with a sticky transition matrix.

A motion-quiescent epoch cannot be called awake on raised heart rate alone (see *Motion-corroborated wake* below). The recipe is selectable in Settings › Lab (`SleepStager.StagingRecipe`, default `standard`, so a wearer who never touches it is staged exactly as before):

- **`restless`** adds the restless-movement term (#59): small movements too weak for the "moving" threshold but sustained for at least 5 s (a per-second jerk above 5 × the quiet floor, only in runs of at least `restlessMinRun = 5`, longer than a REM twitch) argue against REM (`rem −= 0.5 · z⁺`, averaged over ±5 epochs and z-scored within the night). Only the REM-only form passed the sleep-lab guard on all three open PSG sets; the forms that also argued for wake over-called wake and were dropped.
- **`trained`** (`SleepStagerTrained`, adopted from ayiskakov/noop) stages with two multinomial logistic-regression heads fitted to open polysomnography (Wearanize+, 88 nights; PhysioNet sleep-accel, 31 nights) plus a Viterbi pass, on night-relative features (and 5-minute HRV features when at least half the staged epochs have beat intervals). Agreement was measured on other wrist devices, not a WHOOP strap, and the stages remain approximations.

A switch re-keys every stored day and every edited night (`signatureSuffix`).

### Per-session resting HR and HRV

`sessionRestingHR` is the **minimum of 5-minute non-overlapping bin means** of the HR samples in `[start, end]` — "lowest sustained HR", which rejects single-beat dips while capturing the night's true floor. A bin qualifies to win only when it holds at least 5 samples and its mean is at least 25 bpm (#1943), so a one-sample bin at the edge of a wear gap or a dropout-driven sub-physiological dip cannot become the night's resting HR. When no bin qualifies, the floor falls back to the lowest of all bin means (ungated), then the all-sample mean, so a session with data never scores nil. `sessionHrvWindows` tumbles the same 5-minute grid over the RR series, cleans each bucket (range filter + Malik ectopic rejection, gap-aware) and emits one window per bin tagged with the stage at its center; `sessionAvgHRV` is the mean of those window RMSSDs. These two are the shipped source of the per-session `restingHR` / `avgHRV`, of the HRV nightly trace and of the last-deep-run comparator.

**Window endpoint rule.** The session window is closed at both ends, so the binning is too: bins are `[t, t + 300)` except the last one, which is `[t, end]`. A sample or beat sitting exactly on an aligned `end` passes the `[start, end]` prefilter, so it must land in a bin rather than be admitted and then dropped. A zero-length window (`start == end`) is that single closed bin. Bin start times, the stage-tagging center and the RMSSD math are unaffected.

Because these two functions are the shipped path, the rule can move a displayed number on a night whose session length is an exact multiple of 300 s with a sample on `end`: per-session `restingHR`/`avgHRV` and the HRV trace. Stored rows keep the old value until that night is re-scored (`MetricsCache` overwrites both on every recompute).

### Motion-corroborated wake — elevated-but-motionless HR is not wake (default ON)

Both stagers (`SleepStager` V1 and the default `SleepStagerV2`) and the HR-led session confirmation (`confirmSleepWithHR`) previously called **wake** primarily off HR / HR-variability with no motion or posture cross-check. On a night whose resting HR is held elevated **without the wearer getting up** — a supplement protocol, a fever, a hot room, alcohol — that logic scored hot-but-motionless sleep as wake, over-calling WASO, mis-placing onset, and tanking efficiency and Rest. Two confirmed nights required manual relabeling (2026-07-13: 194 min WAKE vs ~67; 2026-07-14: onset 1:41 vs ~1:29 plus a 44-min WAKE block).

The rule: **elevated HR alone is insufficient to call wake.** An epoch or run at the night's quiescent **motion** floor with **unchanged posture** cannot be scored WAKE on cardiac evidence alone; corroboration comes from the **gravity posture/jerk** signal both stagers already consume (always present), not step ticks. This acts where the mis-scoring is produced, and is **on by default** — distinct from the prior default-OFF post-pass over an already-staged hypnogram (upstream #402).

- **`SleepStagerV2` (default).** On a motion-quiescent epoch (no observed movement; peak jerk at/below the night-relative wake-gate floor) the AWAKE cardiac term is clamped to **≤ 0** — wake-*suppressing* (low, flat HR) evidence is kept, the wake-*promoting* half is dropped. A still low-HR epoch is byte-identical; genuine motion and the night-relative jerk gate still drive wake.
- **`confirmSleepWithHR` (V1 detection).** When a run is deeply motion-quiescent (≥ ~90% of its dense-gravity minutes posture-stable), the HR sleep band widens from **×1.05 → ×1.30** so a supplement-elevated but motionless run is not rejected. The band keeps a **floor** (genuine all-night in-bed wakefulness is still dropped); with no gravity evidence the strict ×1.05 band stands.
- **`adaptiveOvernightHRBaseline`.** A personalised sleep band derived from recent overnight medians (self-calibrating across a supplement/fitness era), with a floor. Threaded through `detectSleep` as an optional argument that defaults to `nil` (byte-identical when unset); live cross-night wiring in `IntelligenceEngine` is a follow-up.

Source: `SleepStager.swift` (`confirmSleepWithHR`, `adaptiveOvernightHRBaseline`) and
`SleepStagerV2.swift` (motion-quiescent clamp), both in `Packages/StrandAnalytics`. Filed upstream as
[ryanbr/noop#462](https://github.com/ryanbr/noop/issues/462). Any upstream Kotlin port is maintained
upstream; it is not part of this Apple-only fork.
### Displayed sleep onset — the headline "Asleep at" spans the whole bridged night

The Sleep screen headline ("Asleep at …") reports the onset of the **whole bridged night**, not the main session's start. A night stored as a short first-sleep fragment + a brief walk + the main session bridges into one group when the gap is under `gapBridgeMaxMin` (60 min). The display onset walk (`SleepView.nightOnsetTs` → `isPreOnsetAwakeStub`) previously mis-classified such a fragment as a spurious pre-onset lead through two stacked defects: (1) the #259 relative "minor lead" test compared the fragment's asleep minutes against 15% of the main block, so on a long main sleep a genuine short first sleep was skipped and the headline jumped forward to the main session's start; (2) the stub test read asleep minutes via the dict-only `decodeStages`, which returns nil for the segment-array `stagesJSON` an on-device **computed** night stores — so every fragment counted as 0 asleep minutes and tripped the "essentially sleepless stub" branch, bypassing defect (1)'s floor entirely.

Fix: an **absolute floor** `preOnsetStubMinorAsleepFloorMin = 20` (min) under the #259 relative test — a leading fragment carrying **≥ 20 asleep minutes** is never treated as a spurious lead, whatever the main block's size — plus a format-agnostic `decodedAsleepMinutes` (dict-of-minutes decode with a segment-array fallback) used at both onset call sites, so the floor's input is populated on computed nights too. The relaxation is strict (it can only un-skip a real first sleep, never newly skip one), so the displayed onset now equals the bridged night's first sleep and agrees with the Apple Health write-back span (bridged night groups, #294/#364). The #736 sleepless-stub skip and the #259 tiny-stray-lead (≤ 10 min) behavior are unchanged. The constant and decode seam live in `Strand/Screens/SleepView.swift`.

---

## The **Rest** score composite — *"how restorative was your sleep?"*

Source: assembled in `AnalyticsEngine` from the `SleepStager` outputs above. Rest is a 0–100 composite that **replaces the older bare-efficiency proxy** for the `sleep_performance` key. It blends four components:

| Component | Weight | What it measures |
|---|---|---|
| Duration vs personal need | 0.50 (biggest factor) | how long you slept against your own sleep need |
| Efficiency (asleep / in-bed) | 0.20 | how efficiently you slept |
| Restorative share (deep + REM) / asleep | 0.20 | how much of the night was restorative |
| Consistency (sleep/wake regularity) | 0.10 | how consistent your sleep and wake timing is |

- **Sub-scores** (each clamped to 0–1, the weighted sum scaled to 0–100): duration is `hours asleep ÷ need`;
  efficiency is `asleep / in-bed`; the restorative share is `(deep + REM) ÷ asleep` against a 50 % target
  (`restorativeTarget`), scaled by a **deep-adequacy factor**: full credit once deep is at least 13 % of
  asleep time (`deepShareTarget`), ramping down to 0.5 (`deepFloorFactor`, never zero) as deep approaches
  zero, so a night with normal REM and almost no deep cannot read near-full (a night with an unknown deep
  split gets factor 1); consistency is the regularity below, or 0.5 (`neutralConsistency`) when unknown.
- **Personal sleep need and regularity, per night (AI-35):** each night is scored with traits learned from the
  nights **before** it (`Rest.inputs(forDay:nights:age:)`): the need is the upper quartile of the last 90 days'
  nights (at least `minNeedNights = 7` of them, else the population default), floored at the age's population
  target (9 h under 18, 8 h otherwise) and capped at 9.5 h (`maxNeedHours`); the regularity is
  `1 − CV` of the last 28 nights' durations (`VitalityEngine.sleepConsistency`, at least 3 nights). Both are stored beside the score (`sleep_need_min` in minutes,
  `sleep_consistency` in percent), and every Rest rebuilt from a daily row and every sleep need on screen reads
  them (`RestTraitLookup`). A night not yet scored carries the newest earlier night's traits; with none stored it
  is 8 h and a neutral regularity. The hours-vs-need term clamps at 100.
- Rest consumes whatever stages each device provides (v25 motion on 4.0; PPG/IMU on 5/MG as it unlocks) — the sleep-staging algorithm itself is unchanged.
- The `sleep_performance` key now stores this 0–100 composite. The **Charge** "Rest quality" driver reads it (÷100) instead of raw efficiency.

This composite is similar *in spirit* to WHOOP's Sleep Performance %, but the blend is our own.

---

## `Baselines` — personal rolling baselines

Source: `Baselines.swift`. Per-metric personal baselines that `RecoveryScorer` consumes. Two interchangeable paths produce the same `BaselineState` shape.

### 1. Winsorized EWMA (production model — `update` / `foldHistory`)

A robust, recency-weighted center with an EWMA-of-absolute-deviation spread tracker:

- **Half-life → smoothing factor:** `λ = 1 − 0.5^(1/halfLife)`. Center half-life 14 nights; spread half-life 21 (slower). While young (fewer than `earlyAdaptNights = 8` valid nights) the center uses 3 nights, and a config with `earlyHalfLifeS` (only Charge's) uses it for the spread too.
- **Sanity gate:** values outside `[minVal, maxVal]` (per-metric) → skip-and-hold.
- **Hard outlier rejection:** once seeded (`minNightsSeed`) and no longer young, a value > `hardOutlierK = 5 ×` spread away is seen but not folded.
- **Winsor clamp:** fold only within `± winsorK = 3 ×` spread of the current baseline, so a single big night can't yank the center; the **spread** uses the unclamped deviation so real change is still tracked.

```swift
let clamped = max(lo, min(hi, value))                       // ±3·spread
let newBaseline = lb * clamped + (1 - lb) * state.baseline
let newSpread   = max(cfg.floorSpread, ls * abs(value - newBaseline) + (1 - ls) * state.spread)
```

### 2. Trailing-window mean/SD (`rollingMeanSD`)

The simple, maximally auditable path: plain mean and sample SD (ddof = 1) over the trailing N (default 30) valid nights, with the σ floor applied and converted back into abs-dev space (`÷ 1.253`) so `deviation()` recovers the intended Gaussian σ unchanged.

### Status lifecycle (`BaselineStatus`)

| Status | Condition |
|---|---|
| `calibrating` | fewer than `minNightsSeed = 4` valid nights (no score yet) |
| `provisional` | `4 … 13` valid nights (usable, higher uncertainty) |
| `trusted` | ≥ `minNightsTrust = 14` valid nights |
| `stale` | usable but no update for > `staleDays = 14` nights |

### Per-metric config (`metricCfg`)

| Metric | min | max | floor spread | center / spread half-life |
|---|---|---|---|---|
| `hrv` | 5 | 250 | 5.0 | 14 / 21 |
| `resting_hr` | 30 | 120 | 2.0 | 14 / 21 |
| `resp` | 4 | 40 | 0.5 | 14 / 21 |
| `skin_temp` | 20 | 42 | 0.3 | 14 / 21 |
| `strain` (Effort) | 0 | 100 | 5.0 | 14 / 21 |
| `readiness_hrv_ln` (ln ms, hard-outlier rejection off) | 2.079 | 5.521 | 0.08 | 14 / 21 |
| `daytime_hr` | 35 | 160 | 3.0 | 14 / 21 |
| `daytime_rmssd` | 5 | 250 | 7.0 | 14 / 21 |

`skinTempDeviationCfg` folds the nightly skin-temperature *deviation* (±5 °C bounds, floor 0.3, 14 / 21) for the cycle phases. The Charge baselines add the 3-night spread half-life while young (see *Which nights a day is scored against*). The `strain` config backs only the tested-but-unwired Activity-Balance Charge term, and the two `daytime_*` configs the baseline-relative stress mode (see *Stress*).

### Deviation

`deviation(_:state:)` returns a robust z-score, a signed physical-units delta, a fractional ratio (`value/baseline − 1`), and an `inNormalRange` flag (`|z| ≤ 1`).

---

## Stress — a daily proxy, an hourly read and a check-in nudge

Stress is an autonomic **proxy** (resting heart rate up and HRV down against the wearer's own baseline), never a diagnosis; no figure on this page is a measure of psychological stress. Four pieces exist, on one 0 to 3 scale where under 1 is low, under 2 medium and 2 or more high (`StressBand`).

- **Daily proxy** (`StressMath`, `StressView`, stored under `stress`). `raw = (RHR − mean) / sd + (mean − HRV) / sd` over the **30 daily rows before the scored day**, using only nights after a manual "Recalibrate baseline" (HRV on its own epoch, resting HR on the recovery epoch, as Charge folds them), and `stress = 3 / (1 + e^(−raw))`, so a day on its baseline reads 1.5. A term with no spread (sd below 0.0001) drops out. The stored rows are written by the daily pass and rebuilt by the full rebuild (`proxyRebuild`, imported WHOOP days left alone); the chart and the live screen read one function, so they cannot disagree.
- **Hourly read** (`DaytimeStress`). The same logistic at hour grain over waking hours 06:00 to 22:00, each hour needing at least `minHourHRSamples = 300` samples. Default mode is **day-relative**: the day's own calm reference is the lower quartile of hourly mean heart rate and the upper quartile of hourly RMSSD, and the day is its own baseline. A **baseline-relative** mode scores daytime heart rate against a personal cross-day baseline (`daytime_hr`, the 10th percentile of each day's daytime heart rate) with a validated margin of `baselineRelativeHighMarginBPM = 15` bpm over it (26-day Oura-reference correlation, heart rate only, r about 0.6); its daytime-RMSSD half exists and is tested but is switched off (`daytimeRMSSDScoringEnabled = false`) because daytime RMSSD off the wrist is artefact-dominated. **Motion gate:** an hour whose gravity shows ambulatory movement for at least `activityMaskFraction = 0.30` of its records is exertion, not stress, and is masked rather than scored; the single hour after one is masked too while its mean heart rate is still more than `postActivityShadowBPM = 8` above the calm reference. The display timeline slides the hour every `timelineStepSeconds = 1,800`. **Sustained high stress** needs the last `sustainedHours = 3` covered hours all at 2.0 or above and only drives a passive suggestion to breathe, never a notification. `calmShare` is the share of scored, unmasked hours under 1.0, counted once for both phones (the two-column Today tile).
- **Baevsky Stress Index** (`StressIndex`, a descriptive lens with no baseline): `SI = AMo / (2 · Mo · MxDMn)` from the R-R histogram on the canonical 50 ms grid (Mo the modal bin in seconds, AMo its share in percent, MxDMn the range in seconds), at least 20 clean beats, nil when the range is degenerate. Frequency-domain HRV (`HRVFreqDomain`) sits beside it on the Advanced HRV card.
- **Check-in nudge** (`StressOnsetDetector`): a fast RMSSD over the latest `fastWindowBeats = 60` beats against a slow baseline (EMA weight 0.98) dropping below `dropRatio = 0.6` of it, resting heart rate in 55 to 100 bpm and no recent motion, edge-triggered, and only once the dip has held for `sustainSeconds = 60` (the bare edge fired about 8.4 times a day on 40 days of real data, 13 % still low a minute later; the hold cuts that to about once). At most one nudge per `minSecondsBetweenFires = 900` s, a single confirming buzz and a passive card.

---

## `WorkoutDetector` + `Calories` — retroactive workout detection

Source: `WorkoutDetector.swift`. Finds workouts in the stored 1 Hz HR + gravity streams (no manual logging).

A workout is a **sustained window** (≥ `minExerciseMin = 5` min) where **both** gates hold per sample:

- **Elevated HR** — above `RHR + hrMarginBPM (15 bpm)`. RHR defaults to the day's 10th-percentile HR.
- **Sustained motion** — gravity-derived intensity (10-second trailing mean) above `motionThreshold = 0.20`.

Active samples are grouped into runs (merging gaps < `mergeGapS = 150 s`), then qualified by intensity: ≥ `minIntensityZ2Plus = 0.50` of the bout in Edwards zone 2+. Per bout it reports avg/peak HR, duration, Edwards zone-time %, mean `%HRR`, strain (via `StrainScorer`), and calories.

### Calories (`Calories.estimateBoutCalories`)

Per-second blend of **Keytel (2005)** active expenditure and **revised Harris–Benedict** BMR (resting), with sex-specific coefficients (`male` / `female` / `nonbinary`). Below a `RHR + 0.30 × HRR` threshold the resting rate is used; above it, the HR-driven active rate. Returns `(kcal, kJ)`. **Approximate** — not laboratory calorimetry. **Not used for lifting:** every figure NOOP stores for a session it scored itself — a live session at save (`AppModel.endWorkout`) and the post-sync rescore of an under-scored manual row (`ManualWorkoutRescore`) — goes through `WorkoutEnergyEstimate.boutKcal`, which integrates a resistance sport sample by sample on `WhoopEnergyModel.exerciseMET` (resistance share) plus basal and returns this Keytel integration for every other sport. Keytel was fitted on steady endurance exercise and reads lifting's pressor response as oxygen uptake. Figures already stored are left as they are: the manual sheet lets the wearer type kcal, so a stored value cannot be told apart from one NOOP computed.

### `AutoWorkoutDetector` — the opt-in "did you just work out?" suggestion

Source: `AutoWorkoutDetector.swift`. Separate from `WorkoutDetector`: it only ever *suggests* a workout through a dismissible Today card and never writes a row. A candidate is a contiguous span where HR stays at or above `RHR + elevatedMarginBPM (30)` for at least `minSustainedMin = 12` min, with dips of up to `maxDipS = 90` s tolerated and windows less than `mergeGapS = 5 min` apart merged. When a motion series is available the window must also show a mean per-second intensity of at least `motionConfirmMean = 0.05`; without one it runs HR-only. Resting HR falls back to 60 bpm. The 10- and 15-minute durations exist only as Test Centre shadow policies and drive nothing.

---

## Training Load — three separate observations

Source: `TrainingLoad.swift`, `StrengthSession.swift` and `CardioSession.swift`. The dedicated Training
Load screen does not convert strength work, cardiovascular work and perceived demand into one score:
there is no measured exchange rate between those units. Each lane instead shows its rolling seven-day
total and compares its daily average with the wearer's preceding level, using up to 28 days that do
not contain the seven days being judged. Rest days are explicit zeroes;
averaging training days alone would hide the difference between training twice and training six times.
A comparison is withheld until seven recent days plus at least 14 preceding calendar days and a
non-zero personal baseline exist.

- **Strength Load** is the sum of completed working sets after the existing
  `MuscleStimulus.proximityFactor` has weighted each set by its logged RPE/RIR proximity to failure.
  That weighting is a CONTINUOUS ramp from 0.2 at RPE 5 to 1.0 at RPE 10; it used to step from 0.2 to
  0.3 across RPE 5, so half a point of perceived effort — well inside the noise of the scale — moved a
  set's weight by half. An unrated set takes the MEDIAN weight of the sets this athlete did rate, and
  only falls back to the fixed neutral default when nothing in the pool carries a rating: with a fixed
  default near a hard set, a change in rating habit moved the weekly figure on its own, so starting to
  log easy sets made the load appear to fall. Tonnage stays visible as a descriptive lifting statistic,
  but is not used as load: high-rep volume can outweigh substantially harder low-rep work in kilograms
  without representing greater training demand.
- **Cardio Load** sums each qualifying cardio session's Banister TRIMP (Banister 1991, analysis recipe
  AI-9): every reading contributes its minutes × ΔHRR × k × e^(b·ΔHRR), where ΔHRR is the reading's
  share of heart-rate reserve and the resting rate is the median of the recorded days within three of the
  session (then, for a week with no band or WHOOP reading, the Apple Watch's resting rate; widening to a month,
  then to every day read, then 60 bpm). The published pair is used together: k = 0.64 with b = 1.92 for a male
  profile (Morton, Fitz-Clarke and Banister 1990), k = 0.86 with b = 1.67 for a female one, and k = 0.75 with
  b = 1.795 for any other — NOOP's choice (2026-10-30), the mean of each half of the two pairs. A gap longer
  than two minutes contributes nothing. Unlike the Edwards
  zones used until AI-8 it is continuous: one beat across a zone edge no longer moves a whole weight
  step. Daily Effort is unchanged and keeps its own recipe. Moving time, distance and pace remain
  separate descriptive metrics. A day holding real training that could
  not be priced at all — no usable trace, and no other session that day to cover it — is **not** a rest
  day: it leaves both comparison windows (`TrainingLoad.trend(daily:)` accepts a series with unknown
  days) rather than being scored zero, because scoring a gap in measurement as zero reports the
  wearer's training as having fallen. Sessions too short to have been priced, and duplicates whose twin
  already described the same minutes, are ordinary days rather than gaps. When the whole recent window
  is unmeasurable the comparison is withheld entirely instead of being made from the days that remain.
- **Session Load** is the athlete's deliberately entered whole-session RPE multiplied by session minutes
  (`sRPE × duration`, arbitrary units). It is an independent observation of how the complete session
  felt. Missing ratings are reported as missing and are never inferred from set RPE or heart rate.

The percentage is presented as “above / about / below your usual” rather than exposing ACWR as a new
score. Readiness reads the same lanes (see *Readiness reads the lanes* below). Recovery interaction is
shown through Charge, HRV, resting HR and Rest rather than an invented combined-load total.

**The shape of a week, beside its size.** A seven-day mean throws away how the week was distributed. Two figures per lane are reported next to it,
and neither is a verdict:

- **Monotony and strain** (Foster 1998): the week's mean daily load over its standard deviation, and the
  week's total multiplied by that monotony. 600 units in one session is not 100 units on six days.
  Withheld below five KNOWN days in the window, and when every known day carried exactly the same load
  — a zero standard deviation makes monotony infinite, which is a division artefact, not a flat week.
  (The sports-science review proposed seven known days; five is used because unmeasurable days now leave
  the series, and a 7-of-7 rule would hide the figure for anyone with a single unpriced session.)
- **Week over week**: this week's total against the previous week's, as a signed percentage. The plain
  comparison a training plan is written in — no threshold to look up, and, unlike the ratio, no overlap
  between the two windows being compared. Withheld when either week has no known day, or when the
  earlier week was empty.

**Coverage travels with the verdict.** How much of a lane's figure was actually measured is stated at
the ring itself, not only in the coverage card further down the page — but only when coverage is poor
(below half the sets rated, or a cardio window resting on stored Effort instead of a measured trace).
A warning shown always is a warning nobody reads.

**Weekly working sets against a qualified research reference** (`StrengthVolume`, Strength screen). The rest of that
screen compares a muscle with the wearer's own recent habit, which is honest and also circular: four
sets a week forever looks normal to someone who always does four. The one external reference the
literature supports is roughly 10–20 challenging sets per muscle per week (Schoenfeld, Ogborn & Krieger
2017; Baz-Valle et al. 2022). NOOP counts logged working sets with warm-ups excluded; when RPE is missing
it cannot verify that a set was close enough to failure to match the studies. The screen therefore calls
the range rough context. It appears for COMPLETE weeks only (on a Tuesday every muscle is below ten), and
only for muscles the week actually trained — an untrained muscle is untrained, not underdosed. It is not
a target, a safety limit in either direction, or the range for strength or power work, which is trained
heavier with fewer sets.

**Intensity distribution** (`Repository.sessionZoneMinutes`, Cardio screen). Time in each heart-rate
zone across the displayed week: five hours of cardio is a different week depending on whether it was
all easy or half of it hard. Zones come from the wearer's own `ProfileStore.hrZoneSet` — the app has one
zone resolver, and a second would let the same heart rate read Zone 2 on one screen and Zone 3 on the
next. The source rule is the one pricing uses: the band's own samples where they cover the session,
HealthKit's minute buckets only otherwise, never stitched — a seam here would move minutes between
zones rather than merely blur a total. The card says how many of the week's sessions it could read, and
says when part of the split rests on Apple Health's one-value-per-minute averages, which cannot resolve
intervals shorter than a minute. No ideal distribution is implied: the polarised and threshold models
disagree, and which applies depends on the sport, the phase and the athlete.

### Readiness reads the lanes

Source: `ReadinessEngine.swift` (`ReadinessLoadContext`, the load and monotony signals),
`TrainingLoadLanes.readinessContext`, `Repository.readinessLoadContext`; tests in
`ReadinessEngineTests.swift`, `ReadinessMonotonyTests.swift` and `StrandTests/ReadinessLoadContextTests.swift`.

Today's Readiness card used to carry its own load signal: an acute:chronic ratio of daily Effort, over
coupled 7/28-day windows, with missing days closed up by `compactMap`. Effort is logarithmic, so the
signal barely moved — halved training read 0.89, doubled 1.10, tripled 1.16 — and stood on *good* for
almost any week, which in turn helped push most reads towards *primed*. The Coach only ever saw that
ratio.

Readiness now reads the Strength and Cardio lanes of this screen. `TrainingLoadLanes.readinessContext`
takes each lane's `LaneEngine` reading through the same reading day the screen uses, and the Repository
publishes it after every refresh; Today, Heute, Coupled and the Coach all evaluate with it, so the load
signal and the Training Load hero cannot name different bands. Session Load stays out: it has no guards
and a rating quota decides how much of it exists.

| Lane state | Signal |
|---|---|
| Strength **or** Cardio well above usual | `.watch` — keeps the read off *primed*; with a recovery signal down, *run down* |
| Above usual / about usual / below usual | described, no flag |
| No band (too few sessions, no comparison yet) | no signal |

A usual week is never `.good`: it is not evidence of readiness. The low-volume guard has already capped a
sparse baseline at "above usual", so a return to training cannot raise the watch. Without a context —
before the first lane read, or in a caller that has none — there is no load signal at all, rather than a
guessed one.

**Monotony has one definition.** Readiness used to divide the mean of daily Effort by its sample standard
deviation; this screen divides each lane's daily load by its population standard deviation over seven
days with at least five known (`TrainingLoad.distribution`). Readiness now reports that same figure — the
highest lane's — and warns at 2.0 only in a lane whose band is at least *about usual*. A week of walks
has a tiny spread and a large quotient; it sits below usual and does not warn.

### Room today, settling, muscle groups and the alert

Source: `LaneOutlook.swift` (`LaneOutlook`, `MuscleGroupLoad`); tests in `LaneOutlookTests.swift`,
`StrandTests/TrainingLoadNotifierTests.swift` and `StrandTests/ReadinessLoadContextTests.swift`.

- **Room today.** How much more load today keeps the last seven days at or under the edge of "above
  usual", and of "well above usual" — in each lane's own unit, rounded down. Solved by bisection on today's
  total against `TrainingLoad.relativeLoad` and `LaneEngine.thresholds`, because the personal edges move
  with the week being judged; at the figure the week still reads inside the edge, one step past it it does
  not. No room while the lane has no band; no "well above" room while the low-volume guard caps the lane.
- **Settling.** For a lane above or well above usual: the first day within 21 on which `LaneEngine` —
  hysteresis included — reads it about usual again if every day from its reading day is rest.
- **Muscle groups.** The Strength screen marks each muscle group with the strength lane's band, read by
  `LaneEngine` on that group's own hard sets per day (each set once, on its primary group — the list's own
  counting).
- **Coach.** `get_training_load` carries room and settling per lane; `estimate_session_effort` prices a
  planned zone and duration as Banister TRIMP between the zone's heart-rate bounds (the average-heart-rate
  form) and says whether it fits inside the usual week, would take it above, or well above.
- **Alert.** Default off (Automations). One notification when a lane moves into well above usual, and
  none again until that lane has left the band; the phase is tracked while the alert is off, so switching
  it on in a high week does not post for a week already under way.

None of these is a verdict: they locate the edges of the usual week, not whether to reach them.

### Training history — months and years of each lane

Source: `TrainingHistory.swift` (periods, gaps, level line, bands per period, lift and VO₂max series),
`TrainingHistoryModel.swift` and `TrainingHistoryView.swift`; tests in `TrainingHistoryTests.swift` and
`StrandTests/TrainingHistoryModelTests.swift`. It replaced the Trends card "Effort over time" (CTL/ATL/TSB
of log-scaled daily Effort) and opens from Training Load, Trends, Strength and Cardio, filtered to the
matching lane.

- **Spans and resolution.** 3 months, 1 year, 5 years or the whole history, plus a jump to any date (the
  span is then centred on it, never running past today). Up to 92 days a bar is a day, up to two years a
  week (Monday to Sunday), beyond that a calendar month. The first bar starts on its period's first day.
- **Same series, same bands.** Strength, Cardio and Session Load are the Training Load screen's own daily
  series (`TrainingLoadLanes`, `TrainingLoadModel.sessionSeries`). Each period's band strip is
  `LaneEngine`'s reading on the period's last recorded day — the band the screen showed that day. Session
  Load has no band.
- **Three kinds of day.** A known day counts, zero on a rest day. An unknown day — training the data could
  not price, or an unrated session — is left out of the total and hatched. Days before a lane's first
  record, or after its reading day, are unrecorded: neither rest nor a gap. Cardio sessions the ledger has
  not priced yet are unknown until the backfill reaches them.
- **Level line.** The mean known daily load of the 42 days ending on the period's last recorded day, times
  the period's recorded days — the wearer's usual for a period that long at that time. It needs 21 known
  days of the 42.
- **What the training did.** Above strength: the session-best e1RM per period of three lifts, the most
  trained in the span unless the wearer picked others (stored locally). Above cardio: NOOP's VO₂max
  estimate as the line, Apple Watch readings as points, each averaged per period.
- **Session Load** shows its rating quota for the span: rated sessions of the sessions there were.

### Training status — is it too much, too little, or about right?

Source: `LaneEngine.swift` (the band and the verdict table), `TrainingStatus.swift`
(`TrainingStatusModel`: the evidence, the statement, the history strip and the lasting-overload
warning); tests in `LaneEngineTests.swift`, `TrainingStatusTests.swift` and `TrainingStatementTests.swift`.

**Where the cardio load comes from.** Each canonical session's TRIMP is computed once from its heart
rate — the band's trace where it covers the session, the watch's minute buckets otherwise, never both —
and kept in `trainingSessionLoad` (WhoopStore v70) with the method and version that produced it, the HR
maximum it used and a fingerprint of its window and components. A row answers instead of the heart rate
once it was computed at least seven days after the session ended (strap offload and watch sync can
still add heart rate before then); newer sessions are recomputed on read as before. Rows of the whole
history are filled newest first in portions, when Training Load or Cardio opens and in the background
processing window, so a multi-year history no longer depends on a per-pass budget of 300 raw reads, and
a load survives a future pruning of raw heart rate. A changed HR maximum never rewrites stored loads on
its own; Training Load offers "Recalculate cardio history" when rows were priced with another one, and
a session whose raw heart rate is gone keeps its stored load.

Each row also keeps the resting rate it was priced with. Recipe AI-9 changed the method from
`edwards-hrmax` to `banister-hrr`; its migration fills the ledger with the new method over the whole
history, newest first and resumable, and re-scores no daily row. Rows of the old method stay in the table
but are never read: the two methods have different scales, and one lane may not mix them. A session with
no usable trace but a recorded average heart rate gets an estimate in Banister's original form (minutes ×
ΔHRR of the average), stored as `avg_hr`. Only the history view shows it — marked, beside the measured
bar — and no band, comparison, level or Readiness signal reads it.

**One band, shown everywhere.** Every surface — the hero pill, the eight-week strip, the ratio chart,
the statement and the warning — reads the same `LaneReading` from `LaneEngine`. The axis is the lane's
own `LoadTrend.ratio`: the seven-day mean over the mean of the days immediately before it (14 while the
history is short, then 28). The windows do not overlap, avoiding the coupled ratio's built-in
correlation. A day the data could not price is not a rest day: it leaves both windows
(`ComparisonCoverage.lane`) while at least five of the seven recent days and three quarters of the
baseline are known, and the means are taken over the known days; past that the comparison is withheld.
A gap in the measurement is therefore never reported as a drop in training, and one session without a
usable heart-rate trace no longer blanks the lane for five weeks, as an all-or-nothing window did.
Session Load keeps the all-or-nothing rule: an unrated session is missing the athlete's own answer.

| Band | Until eight complete weeks | From eight complete weeks |
|---|---|---|
| Below usual | ratio < 0.75 | under the robust weekly range (median − 1.4826 × MAD of the seven preceding weeks) |
| Usual | 0.75 – 1.15 | within that range |
| Above usual | 1.15 – 1.44 | above it, up to median + 2 × 1.4826 × MAD |
| Well above usual | > 1.44 | beyond that — but never later than 1.44 and never earlier than 1.15 |

0.75 and 1.44 are Polar's 0.8 and 1.3 (Training Load Pro white paper, 2019/2025) on NOOP's windows:
Polar's 28-day *tolerance* contains the acute week, so its coupled ratio is `4u / (u + 3)` of the
uncoupled `u` used here. Keeping 0.8 / 1.3 after decoupling (2026-09-13) had silently moved "well above"
from +44 % to +30 %. 1.15 is NOOP's own: Polar calls anything over 1.0 progression, which would make an
ordinary +3 % week "above usual". The personal range is held between limits: "well above" may never
start past 1.44, so a wearer who trains irregularly does not have a large jump read as normal, nor
before 1.15, and "below usual" never before 0.90 — a very regular history has so small a weekly spread
that +13 % would otherwise read "well above".

Three guards sit on the edges:

- **Too few sessions.** Fewer than three sessions in the baseline window: no band (Polar requires the
  same three in 28 days). The percentage is still shown.
- **Low volume.** While the baseline sits under the WHO weekly minimum — 150 cardio minutes, or two
  strength days — a lane reads at most *above usual*. Polar likewise shows "productive" instead of
  "overreaching" below the WHO level: one easy session a week becoming two is a return to training.
- **Hysteresis.** A band is left only once the ratio clears the edge by five percentage points. Each
  day's band replays a fixed fourteen-day warm-up, so a reading depends on a bounded window
  (`LaneEngine.dependencyDays`) and history older than that can never move it.

**The reading day.** A current reading runs through today once something was logged today, otherwise
through yesterday: a day that has not happened yet is not a rest day. For daily training that removes
a −14 % every morning. Training every other day still puts three or four sessions into any seven days,
so the percentage alternates by about ±14 %; the band does not, because the usual range and the
hysteresis absorb it.

**Verdicts need performance evidence.** A band describes the load; a judgement about what the load is
doing needs a measured performance trend. No wearable publishes a validated strength status, and the
2025 ACWR meta-analysis (22 studies) contains no resistance-training study and does not call any ratio
band reliably safe. Following the established idea that "productive" needs load *and* an improving
marker, both lanes read their own evidence — the lifts' e1RM for strength, VO₂max for cardio — plus
recovery:

- **Response.** Each lift trained in the last 42 days gets the exercise card's own e1RM line
  (`StrengthProgress.e1rmTrend`, Theil–Sen over session bests) through the in-window sessions only. It
  *rises* when the middle half of its pairwise slopes is entirely above zero, *falls* when entirely below,
  and is *unclear* otherwise — a direction is claimed only when the sessions agree, with no added
  threshold. Lifts with fewer than four estimable sessions in the window, and movements without an e1RM,
  are left out. The block rises when at least a third of the evaluated lifts rise and more rise than fall
  (falling likewise); fewer than two evaluable lifts is *unknown*.
- **Recovery.** `ReadinessEngine.evaluate` for each of the last SEVEN nights, reading only HRV, resting
  HR and respiratory rate (its load signal is itself a heart-rate ratio and would double-count the
  cardio lane). A night is strained on one `.bad` or two `.watch` signals; recovery is *strained* when
  half of the nights actually READ are strained, with a floor of two, *unknown* with fewer than two
  nights of data, otherwise *holding*. The window was three nights, where one poor night beside one
  mediocre one already read as strained — and this reading is not decorative: it decides between
  *productive* and *overreaching* in the top band. Seven nights is also the window every other acute
  figure on the screen uses, and the bar is proportional so a thin week is not judged more harshly.

`LaneEngine.verdict` — the same table for both lanes:

| Band | rising | unclear | falling | no evidence |
|---|---|---|---|---|
| Below usual | Maintaining | Maintaining → Detraining† | Detraining | "less than usual" → Detraining† |
| Usual | Productive | Maintaining | Unproductive | "as usual" |
| Above usual | Productive | Maintaining | Unproductive | "more than usual" |
| Well above usual | Productive if recovery holds, else Overreaching | Unproductive if recovery holds, else Overreaching | Overreaching | Overreaching if recovery is strained, else "much more than usual" |

† once the lane has been below usual for 21 days (strength; Bosquet et al. 2013, meta-analysis of
training cessation: maximal force significantly lower only from the third week) or 14 days (cardio;
Mujika & Padilla 2000: aerobic capacity largely held through about the first fortnight). Below usual
straight after a high phase — above or well above usual on at least half of the 14 days before — is
**Recovering** whatever the evidence says (NOOP's rule). Without evidence the verdict is a description
(`LaneVerdict.loadOnly`), never "productive", "maintaining" or "unproductive". "Unclear" at the usual
load is *Maintaining*: an advanced lifter gaining a fraction of a per cent a week is progressing below
what six weeks of e1RM can resolve. Falling performance at the usual load or above is *Unproductive* —
load without return — rather than detraining, which would blame too little training.

The session lane (sRPE × minutes) keeps its comparison with the usual level and gets no band or
verdict: a perceived-effort total has no published scale to borrow.

What a verdict is not: a measurement or an injury prediction. The edges are conventions with a stated
source, the verdict table and the recovering rule are NOOP's. Supporting
evidence for the strength inputs: weekly set volume raises both hypertrophy and strength with
diminishing returns, more pronounced for strength (Pelland et al., 67 studies); proximity to failure
raises hypertrophy with the slope flattening past about 2 RIR but barely changes strength gains
(Robinson et al. 2024) — which is why the load is effort-weighted sets but "productive" is judged on the
lifts themselves.

**Cardio evidence — never NOOP's own VO₂max estimate.** Source: `CardioEvidence.swift`. The card shows
NOOP's weekly `vo2max_est` as the VO₂max headline — always current while the band is worn, one
unbroken line — and Apple Watch's latest measured reading beneath it *with its date*, so a reading from
weeks ago never passes as today's value. It used to prefer Apple whenever there were four readings in
eight weeks, however old the latest was. The estimate is not evidence, though: Nes 2011 is built from a
physical-activity index NOOP derives from Effort, so more training raises it by construction (three
days at Effort 45 → five days at Effort 75 is +2.0 ml/kg/min at an unchanged resting HR), and Uth 2004
is resting heart rate alone, which the recovery reading already uses. The cardio verdict therefore
reads, in order:

1. **Apple's measured VO₂max while fresh** — at least four readings in the last 56 days and the latest
   no more than 14 days old. Theil–Sen line within one segment, the agreement rule, and at least
   1.5 ml/kg/min of change across the window (an estimate's error is around a point).
2. **Heart-rate efficiency** — beats per kilometre in the main endurance sport (the exact stored label
   with the most sessions carrying the figure in 56 days), the same Theil–Sen line and agreement rule as
   a lift over at least four sessions, and a change of at least 3 % of the typical value (NOOP's own
   floor: beats per kilometre moves with heat, hills and pace). Fewer beats per kilometre is improving.
3. **Nothing** — the statement describes the load.

The chat context and goal feasibility quote the same headline and Apple reading
(`AICoachEngine.vo2maxDisplay`); they used to recompute Nes themselves, which gave the coach no value at
all without a waist measurement while every screen showed the Uth estimate.

**NOOP's weekly VO₂max estimate (`vo2max_est`).** Written once a week beside Fitness Age (`DailyAnalysis.fitnessAgeRows`): the Nes 2011 estimate from age, sex, resting heart rate, waist and a physical-activity index derived from the week's Effort, or, with no waist measurement, the Uth 2004 heart-rate ratio `15.3 × HRmax / RHR` (`Calories.vo2maxFor`, the maximum heart rate being the resolved one). Both are non-exercise estimates, which is why neither counts as performance evidence below.

**Training-based VO₂max — an experimental instrument.** Source: `ExerciseVO2max.swift`, `TrainingVO2max.swift`, behind a
default-off switch (Settings › Lab, "Training-based VO₂max"). It estimates VO₂max from what the wearer did: the ACSM
metabolic equations turn a session's average speed into an oxygen cost (walking 0.1·S + 1.8·S·G + 3.5
for 50–100 m/min, running 0.2·S + 0.9·S·G + 3.5 above 134 m/min; between the two the gait decides and
NOOP cannot see it, so those sessions are left out), and %HRR = %VO₂R (Swain & Leutholtz 1997)
extrapolates it to maximum. Sessions qualify on foot, ≥ 20 minutes, with distance, a measured heart-rate
trace and an average of 40–85 % of heart-rate reserve; a week is the median of its sessions. **One
departure from the published method:** a session's average speed over its whole duration stands in for a
steady pace, so stops read low and warm-up reads high. **Grade** enters only when the climb is known
(NOOP's barometer, Apple Health's ascent or an imported file; AI-25): the uphill term is applied as the
equations write it with descents counted as level, which makes it the metres climbed per minute (walking
`0.1·S + 1.8·ascent/min + 3.5`, running `0.2·S + 0.9·ascent/min + 3.5`). Without a known climb grade is
taken as zero, hills read low, and the surface says "grade assumed flat". It is shown beside the weekly estimate and never used as evidence until
`ExerciseVO2max.validate` passes the rule fixed before looking at any data: at least 8 weeks paired with
an Apple Watch reading within 7 days, a mean absolute difference of at most 3.5 ml/kg/min, and the
direction of week-to-week change agreeing in at least 70 % of the steps where Apple moved by 0.5 or more.
Tests recover five injected VO₂max values across speeds, gaits and wearers, not one.

**Lasting overload — a warning, not another verdict.** The ECSS/ACSM consensus (Meeusen et al. 2013)
separates functional overreaching (a planned hard block, recovered from in days, followed by better
performance) from non-functional overreaching (a performance decrement taking weeks to months to
recover from) and the overtraining syndrome, which it says can only be diagnosed clinically, over
months and by excluding other causes, with no single marker qualifying.
`TrainingStatusModel.sustainedOverreaching` therefore raises a warning only when a lane has been *well
above usual* at three consecutive week-ends of the history strip, that lane's performance evidence is
falling **and** recovery is strained now. Missing evidence never raises it. The screen recommends
several easy or rest days and says outright that it is not a diagnosis of overtraining and to see a
doctor if performance and wellbeing stay down for weeks.

**Considered and not adopted.**

- *EWMA instead of rolling means* (Williams et al. 2017). EWMA-based ratios associate somewhat more
  closely with health problems in team-sport data, but Polar's edges were set on rolling 7- and 28-day
  means. Swapping the averaging while keeping the converted edges would silently change what they mean.
- *A coupled ratio.* Rejected because putting the acute week inside its own baseline creates a built-in
  mathematical relationship (Lolli et al. 2017). Polar's coupled edges are converted instead.

**RIR-adjusted e1RM.** `OneRepMax` applies Epley to completed reps plus `10 − RPE` when a valid RPE
(or an RIR entry converted to RPE at capture) exists. Without a rating it uses completed reps exactly as
before; no reserve is guessed. Completed plus remaining reps must stay at or below 12, preserving the
formula's existing validity guard. This improves comparisons between equally weighted sets stopped at
different distances from failure while keeping the estimate explicitly labelled as a projection.
- *Weight-dependent 1RM equation* (arXiv 2603.17495, 2026; fitted on 303,494 near-failure app sets).
  A preprint with no directly measured maxima in its data; not a basis for replacing a published
  formula.

**One statement for both lanes.** `TrainingStatusModel.statement(strength:cardio:recovery:)` maps a PAIR
of verdicts onto the page's single sentence. Each verdict first reduces to a tendency — *behind*
(detraining, recovering, less than usual), *holding* (maintaining, as usual), *building* (productive,
more than usual), *spinning* (unproductive), *excessive* (overreaching, much more than usual) — so a
split is decided by the rules that already priced each lane rather than by a second threshold. Both
lanes can be *spinning*, so the table is symmetric:

| strength ↓ / cardio → | behind | holding | building | spinning | excessive | unmeasured |
|---|---|---|---|---|---|---|
| **behind** | `aligned` | `oneBehind(strength)` | `split` (mild) | `split` (mild) | `split` (sharp) | `laneOnly` |
| **holding** | `oneBehind(cardio)` | `aligned` | `aligned` | `spinning(cardio)` | `excessive(cardio)` | `laneOnly` |
| **building** | `split` (mild) | `aligned` | `aligned` | `spinning(cardio)` | `excessive(cardio)` | `laneOnly` |
| **spinning** | `split` (mild) | `spinning(strength)` | `spinning(strength)` | `bothSpinning` | `spinning(strength, otherAlsoHigh)` | `laneOnly` |
| **excessive** | `split` (sharp) | `excessive(strength)` | `excessive(strength)` | `spinning(cardio, otherAlsoHigh)` | `bothExcessive` | `laneOnly` |
| **unmeasured** | `laneOnly` | `laneOnly` | `laneOnly` | `laneOnly` | `laneOnly` | `noHistory` |

A `split` always names the lane that is behind and the one that is ahead — including beside a spinning
lane, which the previous matrix dropped — and the card is painted from the first colour to the second.
An `aligned` statement is *productive* only when a building lane has the evidence for it, otherwise it
describes the load. Strained recovery is applied AFTER the pair resolves: it sharpens an overload
statement and displaces a quiet one, but never overrides a split or a lane that is falling behind.
Where one lane is spinning while the other runs high, the sentence names both facts and does **not**
claim that one costs the other its progress: plausible, unmeasured. Contract tests pin totality over
every pair, the split invariants, symmetry and the no-productive-without-evidence rule.

**Analysis migration required: no** for the single band, the guards, the reading day and the verdict
table (2026-09-24): everything here is computed at read time and nothing stored changes.

Earlier, 2026-09-13 — **analysis migration required: yes.** The non-overlapping comparison changes the aggregation window,
and RIR-adjusted e1RM changes the meaning of the lift-response input used by Training Status. Both land
inside the same unreleased analysis recipe 5 as canonical-session fusion; its existing resumable 21-day
maintenance refreshes affected workout-derived outputs before committing the cursor. Raw workouts,
sets, ratings and heart-rate samples are retained.

### Training Load phase 2 — what the training is for, whether it was enough, and the morning advice

Source: `TrainingGuidance.swift`, `MorningAdvice.swift` and `FitnessInstruments.swift` (decisions in
`docs/fork/TRAINING_LOAD_PLAN.md` §8). All pure; every input is passed in and nothing reads a clock. The
earlier lane bands and verdicts are unchanged; this adds the three questions they cannot answer alone.

- **What for** (`TrainingFocusResolver`). Each lane is measured against a focus: lose weight, fitness, strength
  or health. The wearer's choice wins; otherwise the diet plan's direction (lose, gain or recomposition, maintain),
  else the weight goal's; a training goal speaks only for its own lane (endurance, running and fitness goals for
  cardio, strength and hard-set goals for strength, consistency and activity goals for cardio as health).
  Several candidates are settled by the nearest target date, then plan before weight goal before training goals;
  with nothing to go by the focus is *health*, measured by the guideline. A goal younger than
  `graceDays = 14` is only described. A goal paused for illness or pain rests the verdict.
- **Enough?** The weekly floor is the WHO 2020 guideline: 150 to 300 moderate-equivalent minutes (vigorous
  minutes count double) and two muscle-strengthening days; a *lose weight* focus asks 250 to 300 minutes (ACSM
  2009), *strength* two to three strength days, and a weekly-minutes goal the wearer set wins. Under 18 there is
  no adult target, and from 65 a balance-work hint is added. A week reached the minutes when its total hits the
  low end; a goal is *carried* when at least `carriedWeeks = 3` of the last `windowWeeks = 4` complete weeks reached it.
- **Active minutes** (`ActiveMinutes.day`, stored per day in AI-39 as four `active_min_*` series under the computed
  id). A minute counts when its mean heart rate (at least `minimumSamplesPerMinute = 10` samples) is at 40 to 59 %
  of heart-rate reserve (moderate) or from 60 % (vigorous), after ACSM. Inside a workout or recorded session heart
  rate alone decides; outside one a minute counts only if the strap also counted at least
  `movementTicksPerMinute = 30` step ticks in it, so a raised pulse at a desk (stress, heat, fever) never counts.
  A session the heart rate cannot speak for counts by the wearer's rating: moderate from 4 of 10, vigorous from 7,
  nothing when unrated or easier.
- **Verdict against the goal** (`GoalOutcome`). For *lose weight* the cardio lane reads as carrying the loss when
  the minutes were carried and recovery is not strained, and the strength lane as strength held when the main
  lifts changed by no worse than `strengthHeldDrop = −5 %` over six weeks (a rising lane keeps its own, stronger
  verdict); strength falling while weight falls faster than `fastLossPercentPerWeek = 1 %` a week and recovery is
  strained asks the wearer to look at the load or the deficit. For *health* the cardio lane is met when the
  guideline was carried. Overreaching and detraining are never overridden by a goal note.
- **One morning advice** (`MorningAdvice.resolve`), the same on Today, the Effort target, the Training tab, the
  coach and the morning notification, and without a language model. The first rule that applies decides: unwell,
  rest; recovery strained while a lane is well above usual, rest; Charge under `lowCharge = 34`, easy; one lane
  well above usual, easy for that lane; both, easy; a planned session, steady (shorter or lighter below Charge 67);
  behind the goal with Charge from `highCharge = 67`, recovery not strained and not having eaten too little, push;
  otherwise steady (without a measured night, never push). The first ready advice holds for the rest of the day;
  only a raised illness signal or the night arriving afterwards may replace it. The Effort target is Charge's band
  on WHOOP's 0 to 21 scale (14 to 18 from Charge 67, 10 to 14 from 34, else 4 to 10), capped by the advice (rest
  4 to 10, easy at most 10 to 14) and shown on the stored 0 to 100 axis.
- **Offers** (`TrainingOffers`): at most three, the plan's own session first, then cardio and strength sized to the
  room left (minutes of the wearer's typical session of that sport, rounded down to 5, at least 10; 30 minutes of
  brisk walking with no history; a rest day offers easy movement only).
- **Lab instruments** (`FitnessInstruments`), never evidence until `InstrumentCheck.passes`: *pulse at the same
  cadence* (strap step ticks per minute binned by 10, the wearer's most common bin, at least 5 minutes in it),
  *pulse recovery* in the minute after a session that ended hard, and *pulse at the same pace* from the kilometre
  splits of a NOOP GPS recording, flat ones only. Each reads a Theil–Sen line over a 56-day window, at least 4
  sessions and a change of 3 bpm. The check, fixed before any real data: at least 8 week-on-week comparisons with
  at least 70 % pointing the same way as an independent reference.

**Analysis migration required:** yes for the stored active minutes (AI-39, written by the full rebuild); no for
the focus, enough, verdict and advice rules, which are computed at read time.

---

## Daily energy — `EnergyEngine`, `WhoopEnergyModel`, Watch calibration, adaptive TDEE

Source: `Packages/StrandAnalytics/Sources/StrandAnalytics/{EnergyEngine,WhoopEnergyModel,CardioFitness,EnergyCalibrationEngine,EnergyValidation,Digestion,ScaleBurn,EnergyDensity,EnergyRange,BasalFormula}.swift` (and the superseded `AdaptiveExpenditureEngine.swift`), all pure and DB-free. Together they answer "how much did I burn today?" (the **ENERGY** card in Control Center / Today, `Strand/Screens/EnergyCard.swift`) without ever silently adding two devices' measurements for the same body.

### Basal rate — one formula for the whole history

Every energy path (the day total, the strap bucket model, the day's timeline, the reference curves, a session's tile) reads basal through `Calories.bmrKcalPerDay(profile:)`, which evaluates `UserProfile.basalFormula` via `BasalRate`. `Repository.analyticsProfile` fills it from `BmrFormulaLog.current`: the wearer's choice on the Energy Plan, **Mifflin–St Jeor** until they choose (more accurate than revised Harris–Benedict for height/weight alone; earlier versions used Harris–Benedict). The choice applies to **every day**, past ones included, because it is a method rather than a change in the body — a formula that changed at a date would put a step into trends, 30-day means and the intake/weight comparison that reads as a metabolic change. Weight and body fat are still resolved per day from their own history. Katch–McArdle uses the body fat in force on each day (`Repository.bodyFatResolver`); days before the first reading use Mifflin–St Jeor, so the curve steps where the first reading begins. No wearable NOOP supports measures resting metabolism (that takes gas exchange); these are population regressions. A fourth choice, **measured**, takes a resting rate the wearer had measured (indirect calorimetry): it is stored as its ratio to Mifflin–St Jeor for the body on the measurement day, so it follows the weight afterwards, it applies to the whole history like every formula choice, a value more than 40 % from the equation is asked about once, and a measurement older than a year is named as old but still used. The reason it exists: prediction equations miss a single body with a BMI over 50 by up to about 700 kcal either way.

A strap day's active energy is the model's own stored figure (`DayInputs.strapActiveKcal`, the sum of the hourly rows written beside the buckets), not `strap total − basal`, so a formula change moves basal and total only. A switch re-prices the strap model's stored basal over its 120-day window (`scheduleEnergyRefresh`).

### `EnergyEngine` — one day's total, sources never summed

`EnergyEngine.summarize(_:profile:context:)` selects **one** source per day and, where possible, tops it up with the *modelled remainder* — it never adds two measured sources together:

1. **`strapWornTime`** — the WHOOP total (from `whoopDailyEnergy`, or the legacy `DailyMetric.activeKcalEst`) whenever present. The total and its coverage denominator are always taken from the **same** model — `(rawTotalKcal, representedSeconds)` for v4 or `(activeKcalEst, energyCoverageSeconds)` for the legacy path, never crossed. `representedSeconds` is wall time whose basal share is already inside the bucket total; HR evidence remains separately available as `observedSeconds`. This is canonical: an optional Watch calibration factor may scale it, but Apple never replaces it. The worn-time total is topped up with `profile BMR × unrepresented seconds`, never a full day's BMR (that would double-count every represented second — the trap the file's header exists to prevent). The Watch factor scales **active energy only** — see "Calibrating active energy only" under `EnergyCalibrationEngine` below. Since model v10 the strap total is the sum of three shares that add up to it again on every screen: **basal** (the profile rate for the elapsed time), the **everyday share** (awake still time above lying basal, plus digestion, never calibrated) and **active** (what the strap measured, times the Watch factor). Digestion and the scale's correction are described below.
2. **`appleSplit`** — Apple's own `active_kcal` + `basal_kcal`, used only on a day with no WHOOP estimate.
3. **`mixed`** — Apple active energy with no basal figure; basal is modelled from BMR × elapsed fraction.
4. **`loggedActivity`** — no device measured the day, but sessions were logged. Each `ActivityContribution` carries a window and a source: the window places it (a session across midnight is split by time, and one beyond the elapsed edge is not counted yet), the source says whether its kcal still contains the bout's resting energy. Apple writes energy above resting; every other lane — and anything NOOP itself modelled — is gross, and has `BMR-rate × window` removed before it is added. Sessions and the step estimate describe overlapping time, so the step estimate is charged only for the hours `appleStepHour` shows steps in and no session covered; where the hourly stream is missing, the larger of the two stands alone rather than the sum. The share that came from sessions is reported as `loggedActivityKcal` so a screen can answer "were my workouts counted?" without arithmetic.
5. **`stepsEstimate`** — no energy measurement and no sessions: steps become a speed through the wearer's own measured step length (`StepLengthTimeline`, population average 0.75 m otherwise) at an assumed 100 steps/min, priced on the **same** `WhoopEnergyModel.metForSpeed` Compendium curve the bucket model uses, less 1 MET so the result is energy *above* resting. It replaced a flat `0.0005 kcal/step/kg`, which could not tell two people's strides apart.
6. **`profileOnly`** — nothing measured and nothing logged; only the modelled 24 h BMR is reported, and `totalBurnedSoFar` stays `nil` (never `0`).

Where a session arrived without energy of its own, the app prices it strongest-evidence-first before handing it over: its recorded kcal, else `Calories.estimateBoutCalories(averageHR:)` on the average the workout list already reconciled, else `ActivityMETCatalog` (Compendium values for the sports `WorkoutCatalog` offers, 3.5 MET for anything else). Anything modelled is flagged `isEstimated`, which both marks it on screen and tells the engine the figure is gross. The list itself comes from `repo.workoutRows`, so cross-source twins are collapsed by the same `WorkoutSource.dedupCrossSource` rule the Workouts screen uses — energy never applies a second, divergent idea of which session was real.

`.loggedActivity` and `.stepsEstimate` are both `.calibrating`: a logged session measures an hour, not a day.

**Digestion** (`Digestion`, the thermic effect of food) is part of the everyday share on strap days. Doubly-labelled-water measurements contain it and the bucket model does not: about a tenth of the day on a mixed diet (Westerterp 2004). A day the wearer marked as completely logged prices its own food: 25 % of protein energy, 7.5 % of carbohydrate, 2 % of fat and 10 % of the rest; every other day takes the standard tenth of the day (`standardShareOfRest = 1/9` of basal plus everyday plus active, because half a logged day would price only the half). An Apple day stays as Apple gives it. `EnergyPlanning.thermicEffect` (25 % / 8 % / 4 %, else 10 %) remains the planning page's own figure beside intake and is not what the day total uses.

**The scale's correction** (`ScaleBurn`, `BurnCorrection`, `EnergyDensity`). Once eaten, weighed and burned have been logged long enough, the scale says what the body really burned and the Energy page offers to adjust the strap to it. The one scale estimate (`ScaleBurn`, read by the Energy page, the diet plan's expenditure and the nutrition page's adaptive estimate) takes eight weeks (`windowDays = 56`), only days marked as completely logged and only weigh-ins without a water mark, and a Theil–Sen weight slope over weigh-ins at least 7 days apart after a gate against the smoothed series. A figure is offered only when the data span 42 days with at least 21 completely logged days in 6 distinct weeks and 10 weigh-ins, and its own uncertainty is under 10 % of the burn (`maximumRelativeError`). What a kilogram of weight change holds follows the body (`EnergyDensity`: fat 9,440 and fat-free mass 1,816 kcal/kg after Hall 2008, the fat-free share of a change `10.4 / (10.4 + fat mass in kg)` after Forbes; body fat from a measurement, the tape method, else CUN-BAE, Gómez-Ambrosi et al. 2012), clamped to 4,500 to 9,300, in place of 7,700. A correction is only proposed past 3 %, only applied after the wearer agrees, from that day on, moves by at most 3 % a week and stays within 0.8 to 1.2; with a measured resting rate it leaves basal alone, and it is never applied to an Apple day. The scale always compares against the strap's figure before any correction. It holds still while the water balance settles (three weeks after a plan starts or its way of eating changes, four weeks after a weigh-in marked "creatine started", three weeks after strength training returns after a month off). After three weeks with twelve completely logged days and six weigh-ins (`ScaleBurn.Gates.early`) the Energy page shows only the direction the scale points, in words; it is never proposed and never applied.

**A likely range for a finished day** (`EnergyRange`): the strap model's own error (`uncertaintyFraction`) and the basal formula's miss for one body (`formulaError = 0.10`, Frankenfield 2005) added in quadrature, at most 30 %; narrowed to the scale's 5 % once the wearer adjusted the strap to it. Today keeps its forecast range.

Coverage (`EnergyCoverage.energy`) is the fraction of the elapsed local day the day's *actual* source represented: v4 context-bucket wall seconds, or — for an `appleSplit` day — `healthEnergyBucket.coverageSeconds` (max per bucket across sources, never summed; iOS only, see below). Confidence (`ScoreConfidence`) is `.solid` at ≥80% coverage (`solidCoverage`), `.building` at ≥40% (`buildingCoverage`), `.calibrating` below. Reporting both active and basal energy is not proof Apple covered the whole elapsed day, only that it covered whatever it saw. Where no coverage signal exists at all, `.appleSplit` keeps its previous `.solid`: an *absent* signal is not evidence of a *thin* one. Local-day seconds are calendar-derived (`Repository.energyDayContext`), not a fixed 86,400, so DST transitions don't skew basal accrual.

### The day forecast — `projectedTotalBurn` / `projectedRangeKcal`

    projected = spent so far + basal for the hours left + the activity still expected

Since v10 the awake hours still to come add their everyday share, and digestion and the scale's correction are priced the way the hours so far were. Computed only for *today*, and only once ≥10 % of the day has elapsed (before that the rate is too noisy and a wild morning figure reads as a malfunction).

The last term used to be `active / elapsedFraction` — a linear extrapolation assuming activity arrives at a constant rate. It does not: an 08:00 workout made the forecast shoot far too high (a whole day extrapolated from the one hour containing all of it), and a quiet morning before an evening session made it read far too low. Dividing by a small personal-shape fraction had the same flaw, so the current form adds the person's own **historical median activity still expected in the remaining hours** (`ActivityShape.expectedActivity`, the median per local hour of their recent days), with a same-day adjustment only once enough of the routine has elapsed:

    expected remaining activity = expected.remaining × adjustment
    adjustment = clamp(activeSoFar / expected.toNow, 0.5 … 1.5)   when ≥ 25 % of the day has elapsed and the curve expects ≥ 20 % of the day's activity by now, else 1

Without a personal curve there is **no forecast** (`nil`); the old linear fallback is gone. The magnitude cap of 6.0 (`maxRemainingActivityMultiplier`) went with it.

### `ActivityShapeEngine` — the personal time-of-day curve

Source: `ActivityShapeEngine.swift` (pure). Fits `f(t) ∈ [0,1]` — the cumulative fraction of a typical day's **active** energy burned by hour *t*, and the typical active kcal in each hour (`expectedActiveByHour`, which keeps magnitude) — from `whoopEnergyHourly` (migration v48), which the same bucket pass that writes `whoopDailyEnergy` populates for free. Basal is excluded: it is flat by construction and would flatten the very shape this measures.

- **Each day is normalized to its own total *before* the days are combined.** The curve is a shape, not a magnitude, so one colossal day cannot redefine what a normal afternoon looks like.
- **Per-hour combination is a median**, not a mean — the same robustness applied to the other axis.
- Needs ≥`minimumDays` (7) usable days inside a `maximumWindowDays` (28) window; a day below `minimumDailyActiveKcal` (50) is skipped, because dividing by a near-zero total manufactures a shape out of rounding. Below the threshold the engine returns `nil` and there is no forecast.
- Fitted from complete days only — today is still accruing, and including it would teach the curve that this person stops being active at whatever time it currently is.
- Deliberately **not** split weekday/weekend yet: a real effect, but splitting doubles the history each arm needs, and the fallback is honest linear behaviour rather than a worse curve.

### The adaptive TDEE stays separate from the wearable forecast

`summarize(adaptivePriorKcal:)` keeps the parameter for source compatibility but deliberately does
not blend it into today's wearable estimate. The retrospective intake/weight model answers a
different question and remains a separate card. Today's projection is available only once at least
seven sufficiently complete v5 days provide both a personal time-of-day shape and typical hourly
activity magnitude; until then the UI says that the forecast is learning.

### The forecast interval

`projectedRangeKcal` is present whenever a forecast is. A bare `~2,650 kcal` claims a precision the model does not have; `2,400–2,900` says the same thing honestly and carries extra information. Two independent widths add: what the model already publishes about the energy it *has* measured (`uncertaintyFraction`, itself weighted by the observed/inferred/modeled evidence mix; without one, `0.10 + 0.20 × (1 − coverage)`, else 0.20), plus `0.20 × (1 − elapsed fraction)` for the hours not yet lived — no coverage figure can speak for hours that have not happened. The half-width is clamped to 4 % to 50 % of the projection.

### `WhoopEnergyModel` — WHOOP-first bucket estimate

A pure, Apple-Health-free model over five-minute `WhoopEnergyBucket`s (HR, motion intensity, steps, distance, stride, the strap's `activity_class`, and workout/sleep/off-wrist flags), producing a `WhoopDailyEnergyEstimate` with an explicit **evidence mix** per bucket:

- **`observed`** — HR contributes inside an independently established workout or locomotion context. A workout uses `WhoopEnergyModel.exerciseMET`: ACSM's %HRR ≈ %VO2R relation (Swain & Leutholtz 1997), `MET = 1 + share · HRR · (peakMET − 1)`, with `peakMET` the aerobic ceiling for the day from `PeakMETResolver` (since v8, in this order: a VO2max the wearer entered, for 183 days; a fresh Apple Watch reading, at most 183 days old since v9; else the Jurca et al. 2005 non-exercise estimate from sex, age, BMI, resting heart rate and a measured four-week activity category, bounded 3.5–16 MET against 3.5–25 for a measured value; a measured value is rescaled by the weight then over the weight now) and `share` 1.0 endurance / 0.8 other / 0.6 resistance (heart rate runs ahead of oxygen uptake while lifting; Hurley et al. 1984), capped at 14.5 MET. Until v7 this was `1 + c·HRR²` (c = 11 / 9.5 / 8), which had no source and priced a 108-bpm lifting session at ~2 MET. The ceiling had been Uth–Sørensen (15.3 · HRmax / HRrest, bounded 7–16 MET) until v8, which has no body term and is validated in trained men only: for a 212 kg wearer measured at 19 ml/kg/min it read 47 and priced walks at three times what the Watch and the ACSM walking equation give. A session on foot with movement evidence is priced by pace, and a workout with no ceiling yet from the sport's Compendium MET. Locomotion is movement-primary and HR may add at most 1.5 MET as a secondary correction; that nudge deliberately keeps the pre-v7 quadratic, because it applies to every walking minute of the day.
- **`inferred`** — movement covers time without HR. Speed/cadence/activity class supplies the locomotion MET and basal is added underneath.
- **`physiological`** — HR was observed but neither movement nor a trusted workout proves activity. It is retained as provenance (`unresolvedElevatedHR`) but contributes **zero active kcal**. Heart rate can grade confirmed activity; it cannot prove activity by itself.
- **`modeled`** — off-wrist, sleep, sedentary-without-HR, or unknown signal: pure basal fill (`BMR/86,400 × seconds`).

**The everyday share (model v10, 2026-11-27).** Awake still time used to be priced at lying basal, so the owner's days came to 1.25 times basal, below the 1.40 to 1.69 that doubly-labelled-water studies find for sedentary lives. It now costs `awakeStillFactor = 1.35` times the wearer's own basal rate (Mansoubi 2015: sitting 1.33 to 1.45, standing 1.59 times the measured resting rate; the strap cannot tell sitting from standing, so one value at the low edge of sitting, the smallest that passes six reference personas), relative to basal rather than to weight (a weight-based MET overstates a heavy body at rest, Byrne 2005). Sleep, heart-rate workouts and still time inside the wearer's usual sleep window earn none (`UsualSleepWindow`: the median bed and wake time of the last 14 main nights that ended by the day, 23:00 to 07:00 with fewer than three), so a night without the strap is not counted as sitting up; a walk's still seconds do count. The share is kept apart from basal and active energy and never reaches the Watch calibration.

Context is selected **before** any calorie equation, in precedence order: off-wrist → sleep → confirmed workout → locomotion → sedentary/unresolved elevated HR → unknown. A high heart rate cannot promote its own bucket into a workout. Active kcal in every active branch is `max(0, met−1) × 3.5 × weightKg / 200 × minutes`.

#### Why HR alone cannot define activity *(historical v2/v4 defect, resolved by v5)*

Both energy paths used to gate active energy on heart-rate reserve alone, and both went blind at ordinary walking intensity:

- The legacy whole-day path (`Calories.estimateDayCalories`) credits every second below `restingHR + 0.50 × HRR` the **bare resting rate** — and `restingKcalPerS` is *exactly* `bmrKcalPerDay / 86,400`, the same number `EnergyEngine` subtracts as its basal top-up. The two cancel, so a 30-minute walk at ~37 % HRR was worth **bit-exactly zero** active kcal. (The 50 % gate was a deliberate over-correction against a "calories too high" report; it fixed over-counting by making low-intensity movement invisible.)
- The bucket model's low-intensity curve returns ~1.9 MET at that same reserve, where a brisk walk really costs 3.0–4.3 MET.

v2 fixed the missing walk by taking `max(hrMET, movementMET)`, but retained the mirror-image error: high HR with a quiet wrist kept the full exercise curve even when stress, caffeine, heat, illness or sensor error was the more plausible explanation. v4 made locomotion movement-primary but still granted quiet elevated HR up to 0.5 MET. At high body weight that small per-minute allowance accumulated into a large false activity total. v5 removes that allowance entirely and charges locomotion only for seconds where the movement stream actually changed, rather than charging an entire five-minute bucket for a brief event. The strap's own **`activity_class@63`** (0 still / 1 walk / 2 run, WHOOP 5/MG only) still sets a floor (walk ≥ 3.0, run ≥ 7.0). WHOOP 4.0 has neither `@57` nor `@63`; without phone movement or a trusted workout it therefore takes the conservative physiological path, not an HR-only exercise path.

#### One MET curve, not two *(model v3, 2026-08-26)*

`movementMET`'s GPS-distance branch and step-cadence branch used to carry **independently hand-tuned** breakpoint tables. At the same real walking pace they could disagree by up to 2.7 MET — 100 steps/min read 4.0 MET on the cadence table against ~3.3 on an external reference at the same implied speed, and 130 steps/min read 7.0 against ~4.5. Since `refreshWhoopEnergyModel` populates `steps`/`activityClass` but not `distanceM`, the cadence table was the one that actually ran in practice, and it ran high.

Both branches now resolve to a **speed in km/h** and look it up in one shared, cited curve — `speedMETTable`, piecewise-linear between reference points from Ainsworth et al.'s *2011 Compendium of Physical Activities*, the standard external reference for activity METs (walking 3.2→16.1 km/h through running paces, up to 14.5 MET at 16.1 km/h — the elite-pace ceiling, up from the old hand-picked 12). The cadence branch uses the wearer's robust daily median `walkingStepLength` from Apple Health when one was measured on the iPhone on or before that day (`StrideLength`, maximum 30-day carry). It never carries a future value backwards and never assumes an Apple Watch. Without enough plausible samples it retains the documented 0.75 m population fallback. Walking stride is not extrapolated to running.

#### Context before intensity and movement duration *(model v5, 2026-08-29)*

The production assembler now supplies real sleep, off-wrist, workout, movement-coverage and workout-kind inputs; v3 declared these fields but built buckets from HR alone, leaving most branches unreachable. Workout trust is deliberately independent of the calorie equation: imported/manual workouts qualify, as do NOOP workouts produced by the existing detector only after **both** sustained HR and sustained motion passed. Since v7 the workout context is read through `Repository.rawWorkoutRows` (then `WorkoutSource.dedupCrossSource`) — the same union the Workouts list and the burn-rate bands read — so native logger sessions, FitNotes/Strong history imports, Hevy API sessions and every retained strap's rows count, and a dismissed detector bout does not. The sport label maps to endurance / resistance / other through `EnergyWorkoutKind.forSport`. Oura cloud workouts (`oura-api`) are part of that union; their stored `source` holds Oura's own origin enum and their sport Oura's activity token, so `Repository.rawWorkoutRows` rewrites both on read (`WorkoutSource.normalizedOuraRow`). Endurance and resistance use different continuous coefficients, removing the old discontinuity at 50% HR reserve.

`restingHR` is causal: each day uses the median of up to 14 prior daily resting-HR values, never the current day's eventual answer. The maximum heart rate is the resolved value described under [Effort](#maximum-heart-rate-maxheartrateswift) (your setting, then the measured level, then Gellish). Quiet elevated HR is exposed as `unresolvedElevatedHR` time in the Energy detail screen instead of being silently called activity, and contributes zero active kcal.

Bucket movement is assembled in `Repository.stepMovementByBucket` (`Strand/Data/EnergySeries.swift`), which reuses three existing rules rather than re-deriving them: **one device id, never merged** (`@57` is cumulative — interleaving two straps fabricates huge deltas), the shared **`StepsCounter`** wrap-aware kernel, and the **`stepTicksPerStep`** tick→step calibration (#139). It reads one day at a time, because `stepSample` is a ~1 Hz stream. The bucketing itself is the pure `Repository.bucketStepMovement`, split out (like `latestActivityClass`) so its delta and gap rules are unit-testable without a store.

Each bucket carries the **previous** sample as well, because `stepsInWindow` needs a predecessor to form a delta and a slice starting cold silently drops the ticks accrued across every boundary — 288 small losses a day, all in the same direction. That predecessor is accepted only from within one bucket-width, though: `@57` is cumulative, so a sample from before a data gap (a charge break, a not-yet-offloaded stretch) carries every tick of that whole gap, `StepsCounter` accepts any delta below 512, and crediting it to the first bucket after the gap renders hours of absence as five minutes of brisk walking — which then feeds `movementMET` a cadence that never happened.

`uncertaintyFraction` is duration-weighted from context-specific provisional widths (18% confirmed workout; 20–28% locomotion; 35% unresolved/sedentary physiological; 40–45% unknown; 20% sleep; 30% off-wrist), capped at 60%. These widths are engineering priors, not validated confidence intervals; the calorimetry gate below explicitly tests their coverage. Body weight is resolved **per day**, not from today's profile, via `CausalWeightResolver` — a 10-day EWMA (`α = 2/11`) over `bodyWeightEntry` + imported Health weights, decaying **per calendar day** between weigh-ins (AI-38; applied once per weigh-in it moved the value by only 18 % after six weeks without one), manual entries winning ties on the same local day, valid for at most 90 days before falling back to the profile default. This prevents a new weigh-in from silently rewriting historical calorie totals.

`AppModel.refreshWhoopEnergyModel` runs this after every completed strap offload (`Strand/App/AppModel.swift`) and recomputes 120 whole local days (the window starts at midnight; a mid-day start used to rewrite its oldest day from the afternoon alone). A saved, edited, merged, deleted or imported workout, and a Hevy sync that changed sessions, re-prices the days it touched through `Repository.scheduleEnergyRefresh` (coalesced, capped at the same 120 days), because the workout list is an input to this model and not only a display. Daily totals, hourly activity-shape rows and auditable five-minute timeline buckets are assembled first, then published in **one SQLite transaction** by `replaceWhoopEnergyWindow`; cancellation cannot expose mixed generations. Rows are keyed by `WhoopDailyEnergyEstimate.modelVersion` (currently `"whoop-bucket-v10"`), and reads filter to that exact version.

**A session's own energy tile** (`WorkoutEnergyEstimate.resolve`, shared by the Workouts list, the workout detail and the coach through `WorkoutEnergyDisplay`) takes, strongest first: the figure the session recorded; the strap model's figure for its window (`Repository.strapSessionEnergy` → `WorkoutEnergyEstimate.strapWindowKcal`: basal + active of the stored buckets, prorated at the edges, Watch factor on active only, answered only at ≥ 80 % coverage with ≥ 50 % of the covered time priced as `confirmedWorkout`); the average heart rate — Keytel, except for a resistance session, which is priced on `exerciseMET` with the resistance share plus the profile's basal rate, the arithmetic its buckets would use; the activity's MET value (`ActivityMETCatalog`, which now also knows the labels strength sessions actually arrive with — "Strength Training", Apple's two strength types — instead of pricing them at the unknown-sport default). All estimated steps are gross. The day's "Training" line is the active share of the same buckets, so the two differ by the window's basal energy and nothing else.

### `EnergyCalibrationEngine` — opt-in, bounded Apple Watch reference factor

Off by default (Settings toggle inside the Energy detail screen, `EnergyCalibrationPreferences.enabled`). When enabled, NOOP compares time-aligned WHOOP bucket output against Apple Health reference buckets **from an Apple Watch source only** (`HealthEnergySourceKind.calibrationEligible`; iPhone/third-party/NOOP's-own writes are never eligible) and fits a single multiplier:

- Requires **≥7 distinct days** (`minimumDays`) and **≥84 buckets** (`minimumBuckets`) at `overlapQuality ≥ 0.70`.
- Uses only `locomotion` and `confirmedWorkout` buckets, trims ratio outliers beyond 3×MAD (or ±0.001 when MAD is zero), then fits a robust Huber slope through the origin. Apple zero-active rows are retained, so a WHOOP false positive can pull the factor down instead of disappearing from training.
- Rejects the fit outright if the trimmed sample's coefficient of variation exceeds `0.20` (`maximumCV`) — an unstable ratio is not a calibration.
- Clamps the result to **`0.80...1.20`** (`factorRange`): calibration can only ever nudge the WHOOP number, never dominate it.

`Repository.refreshWhoopEnergyModel` picks the single Watch source with the most eligible buckets in-window (never blends multiple watches) before fitting. State surfaces as `EnergyCalibrationStatus`: `off` → `learning` (opted in, no fit yet) → `active` (fit applied) → `paused` (opted out, fit retained for a later re-enable without re-fitting from scratch).

#### Calibrating active energy only *(fit v3, 2026-08-28)*

Both sides of the fit are now **active-only kcal, never totals**:

- Apple already reports `activeKcal` separately from `basalKcal`, so no subtraction is needed there.
- WHOOP's side is the bucket's stored `activeKcal` — the same active-only figure written to `whoopEnergyHourly`, reused rather than recomputed. It is normalized by wall-bucket duration, never sparse HR seconds. Apple is normalized by its own `coverageSeconds`.

Fitting on totals (v1) baked resting metabolism into the ratio and diluted it: at a typical 70% basal share, a real active-energy ratio of 1.5 shows up as a total-based ratio of only ~1.15. Applying THAT diluted factor to active energy alone — which is what `EnergyEngine.burn` has always done — systematically under-corrected. The fix therefore touches both ends together: the fit's inputs (here) and where the factor is applied (`EnergyEngine.burn`, above — `rawActive = strapTotal − observedBasal`, then `active = rawActive × factor`; **never** a straight multiplier on the raw WHOOP total, and never applied to the legacy branch that has no coverage denominator to isolate basal from).

`EnergyCalibrationFit.modelVersion` is `"watch-reference-v3"`. `Repository.energyCalibrationState` treats a stored fit as `.active` only when its version matches, so older fits read as `.learning` rather than being applied under changed inclusion rules. Calibration remains opt-in and is not ground truth.

### `EnergyValidation` / `Tools/EnergyBench` — external release gate

Algorithm tests prove invariants (monotonicity, no 50%-HRR jump, the 0.5-MET quiet-HR ceiling, context precedence); they do **not** prove calorie accuracy. That claim requires an external study. `EnergyBench` consumes interval labels from indirect calorimetry, evaluates only rows explicitly marked `holdout`, and uses a simultaneously worn Apple Watch as the secondary non-inferiority comparator — never as training truth.

The pre-registered gate requires ≥20 held-out participants; ≥20 intervals each for sedentary, unresolved elevated HR, locomotion and confirmed workout; ≤15% overall WAPE; ≤10% absolute bias; ≤25% WAPE per required context; NOOP no more than three percentage points worse than Apple; and 80–99% empirical coverage of the published uncertainty intervals. The CLI exits non-zero while any condition is missing or fails. **No repository test or Watch calibration satisfies this gate, and v4 must not be described as “Apple-Watch-accurate” until a real held-out calorimetry dataset passes it.**

### `AdaptiveExpenditureEngine` — retrospective TDEE from intake + weight trend *(superseded by `ScaleBurn`)*

**Superseded (2026-11-27).** The Energy page's food-and-weight figure and the coach's adaptive comparison are now computed by `ScaleBurn` (see *The scale's correction* above): eight weeks, only completely logged days and unmarked weigh-ins, and an energy density that follows the body instead of 7,700 kcal/kg. `NutritionReads.adaptiveEstimate` keeps this engine's result type (`AdaptiveExpenditureEstimate`) as the shape the screens read, with a 95 % interval of 1.96 standard errors and confidence *high* at a relative error of 5 % or less, else *moderate*. The 28-day rules below are no longer called; `AdaptiveExpenditureEngine.estimate` remains in the package with its tests. What follows describes that earlier method.

A **separate, retrospective** estimate — deliberately not an `EnergyEngine` input, and never used to calibrate or replace a wearable's daily total. Shown on the Energy detail screen only once it has enough data (`Repository.adaptiveExpenditureEstimate`).

Energy balance: `expenditure = intake − Δstored-energy`, using the conventional **7,700 kcal/kg** conversion (`energyPerKgKcal`) — a weeks-scale constant, not something meant to explain single days.

- **Window:** 21–42 days (`minimumWindowDays`/`maximumWindowDays`), requiring ≥14 days of logged intake (`minimumIntakeDays`), ≥6 weight readings (`minimumWeightReadings`), and ≥70% intake coverage of the window (`minimumIntakeCoverage`). One value per metric per day (latest timestamp wins for duplicate imports).
- **Weight slope:** raw weight readings are first gated against the app's existing smoothed weight series (`WeightTrendSummary.smoothedSeries`, ±max(3, 4% of centre)) to drop outliers, then a **Theil-Sen** median-of-pairwise-slopes is fit over pairs at least 7 days apart (`pairSlopes`) — robust to a single bad weigh-in, and the 7-day separation keeps normal water-weight noise from becoming an implausible kcal/day correction.
- **Intake:** a trimmed mean (drops the top/bottom 10% once ≥20 points exist).
- **Interval:** `estimate = trimmedIntake − weightSlope × 7,700`, with a 95%-ish half-width from `1.96 × √(intakeSEM² + (robustSlopeSE × 7,700)²)` plus a missing-coverage penalty, clamped to `[150, 1200]` kcal.
- **Confidence:** `.high` (≥28-day window, ≥85% coverage, ≥10 weight readings, half-width ≤350), `.moderate` (≥78% coverage, half-width ≤600), else `.building`.

### The compact provenance line

`EnergyDetailView.compactProvenanceLine` (`Strand/Screens/EnergyCard.swift`) reads "WHOOP · 87 % captured · ±8 %" above the Data Quality row breakdown — a terse "who / how much / how sure" lead-in, deliberately confined to the detail screen rather than the compact card, which keeps its own progressive-disclosure split ("the card answers 'how much?', this answers 'how do you know?'"). It renders only when `coverage.energy` is non-nil — the compact form has nothing honest to say about a steps- or profile-only day, which has no wear-duration signal at all; the existing row breakdown covers those unaided. "WHOOP" / "Apple Health" are brand names, rendered `verbatim` (never translated), matching the "Model" row's existing "WHOOP · N kcal" treatment; the ± term appears only where `uncertaintyFraction` is populated, which today means a WHOOP day only.

### Coach and widget surfaces

`AICoachEngine.energyBalanceTool()` (`get_energy_balance`) reports today's total, source, coverage, calibration status/factor, model uncertainty, the basal, everyday, digestion and active shares so far, the forecast range ("likely by tonight"), the scale correction when the wearer agreed to one, and — when available — the scale comparison range, with a note that it is not today's measurement. The tool reports expenditure only: what the user ate comes from `get_food_log`, and intake is never inferred from these estimates. The iOS energy widget (`WidgetEnergySnapshot`) additionally carries the raw pre-calibration WHOOP figure, the uncertainty percentage, and the calibration factor (stored as an integer permille to keep snapshot-diffing exact).

---

## Interactive engines (wired into screens)

These are the **live** data-interrogation engines, used by `InsightsView`, `CompareView`, and `MetricExplorerView`.

### `CorrelationEngine`

Source: `CorrelationEngine.swift`. Pearson r, OLS regression, and an approximate two-sided p-value between two daily series.

```
r         = Σ(x−x̄)(y−ȳ) / sqrt( Σ(x−x̄)² · Σ(y−ȳ)² )
slope     = Σ(x−x̄)(y−ȳ) / Σ(x−x̄)²          (OLS, y on x)
intercept = ȳ − slope·x̄
t         = r · sqrt( (n−2) / (1−r²) )
p         = 2·(1 − Φ(|t|))                  (normal approximation)
```

- Returns `nil` for fewer than 3 pairs or zero variance in either variable.
- Φ uses the Abramowitz & Stegun 7.1.26 `erf` approximation. The normal approximation slightly **understates** p for small n (true Student-t tails are heavier) but is fully deterministic with no special-function tables.
- `alignByDay(...)` inner-joins two `yyyy-MM-dd`-keyed series; `lagged(x:y:lagDays:)` shifts y forward by `lagDays` (UTC day arithmetic) to probe directional/delayed effects — e.g. *today's strain vs tomorrow's recovery*.

### `BehaviorInsights`

Source: `BehaviorInsights.swift`. The headline "does this behavior move an outcome?" feature. Splits days where a behavior was logged (e.g. *Alcohol*, *Late meal*, *Meditation*) from days it was not, and compares an outcome metric between the groups.

For each behavior/outcome it reports group means, signed `delta`, `pctChange`, **Cohen's d** (pooled SD), and a **Welch t-test** p-value (unequal variances, Welch–Satterthwaite df, normal-approx tail):

```
sp = sqrt( ((n1−1)·s1² + (n2−1)·s2²) / (n1+n2−2) )     d = (m1 − m2) / sp
t  = (m1 − m2) / sqrt(s1²/n1 + s2²/n2)
```

- `significant` requires `p < 0.05` **and** `min(nWith, nWithout) ≥ 5` (guards against spurious "significance" from a handful of days).
- `rank(...)` orders effects by `|d|` descending, significant first.
- `sentence(_:)` renders plain English, e.g. *"On days you logged 'Alcohol', Charge was 12% lower (avg 61 vs 69, n=140 vs 498)."*

### `ComparisonEngine`

Source: `ComparisonEngine.swift`. Period-over-period comparison of one daily metric.

- `stat(_:)` → `SeriesStat`: mean, median, min, max, sample SD (ddof = 1), n, and least-squares slope-per-day (OLS against the 0-based index).
- `compare(current:previous:)` → `PeriodComparison`: signed `delta` on the means, `pctChange` (nil when the previous mean is 0/empty), and a coarse `direction` (`-1/0/+1`).
- `monthOverMonth(byDay:referenceDay:)` splits a `yyyy-MM-dd` series on the `yyyy-MM` prefix (locale/timezone-free) into the reference month vs the immediately preceding calendar month.

---

## The library orchestrator: `AnalyticsEngine`

Source: `AnalyticsEngine.swift`. A pure function that ties the recompute engines together for one day, producing the three daily scores — **Charge** (recovery), **Effort** (strain), **Rest** (sleep). **Live:** `analyzeDay` is wired in via `Strand/Data/IntelligenceEngine.swift` — it runs every ~15 minutes while connected and on demand from the Intelligence screen, persisting the computed Charge/Effort/Rest/workouts under the `"<deviceId>-noop"` source and **merged under** imports. Where a WHOOP export covers a day, its own per-day numbers still win; the recompute fills in the days the strap offloaded but no export covers.

`analyzeDay(day:hr:rr:resp:gravity:profile:baselines:maxHROverride:)` runs, in order:

1. `SleepStager.detectSleep` → keep sessions whose `end` falls on `day` (UTC) — a night ending that morning.
2. Daily sleep aggregates (in-bed-weighted efficiency; deep/REM/light minutes; disturbances) via `hypnogramMetrics`.
3. Daily resting HR = the **primary** (longest) session's lowest 5-minute bin, so a nap never replaces the main night (AI-10/AI-11; the session's plain mean is kept as the `rhr_primary_session` shadow metric, and Effort reads `rhr_effort`, see *Effort*); daily avg HRV = in-bed-weighted mean of per-session HRV.
4. **Rest** — the four-component sleep composite (duration vs need / efficiency / restorative share / consistency), with the night's own need and regularity, stored under `sleep_performance`.
5. **Charge** — `RecoveryScorer.recovery(...)` with the personal HRV/RHR/resp baselines, the skin-temperature deviation and the Rest score as the sleep input, stored under `recovery`.
6. **Effort** — `StrainScorer.strain(...)` over the full day's HR window (HRmax from the resolver: your setting, the measured level, then Gellish; resting rate from `EffortRestingHR`; the day rule with that day's workouts), on the 0–100 scale, stored under `strain`.
7. `WorkoutDetector.detect(...)`.

Each score is also tagged with its **confidence tier** (`ScoreConfidence`: Solid / Building / Calibrating — see below). It assembles a `DailyMetric` (the `WhoopStore` cache shape) plus rich `SleepSession`s and `CachedSleepSession` cache rows. Every derived value is **approximate** by construction.

### Score confidence (`ScoreConfidence`)

Each score carries a small honesty label so a sparse day reads truthfully:

| Tier | Meaning |
|---|---|
| **Calibrating** | NOOP is still learning your baseline, or doesn't have enough data yet (baseline not usable for Charge; no in-bed data for Rest; no HR window for Effort). |
| **Building** | Enough to show, but thin (e.g. fewer than ~7 nights of baseline, or a 5/MG day backed mostly by PPG-derived HR). |
| **Solid** | Full inputs present. |

When NOOP can't compute a score honestly it shows **nothing** rather than a fake number.

### Imported-strain rescale

Imported WHOOP "Day Strain" is on WHOOP's 0–21 scale. To keep the Effort axis consistent, the importer (`WhoopExportImporter`) **rescales at import**: an imported Day Strain is multiplied by `100/21` when writing the `strain` metric series, so everything stored under `strain` is on the 0–100 Effort scale (a lossless round-trip — the CSV export down-converts back to 0–21).

---

## Data flow summary

```
WHOOP strap (BLE) ─┐
                   ├─► WhoopProtocol (frame decode) ─► WhoopStore (SQLite, 1 Hz streams)
WHOOP CSV export ──┤                                         │
Apple Health XML ──┘                                         │
                                                             ▼
   importers copy per-day recovery / strain / sleep ──► DailyMetric (metrics cache)
                                                             │
                          ┌──────────────────────────────────┤
                          ▼                                   ▼
   IntelligenceEngine ─► AnalyticsEngine.analyzeDay   Repository.days ─► TodayView,
   (live recompute: HRV + Charge/Effort/Rest +        InsightsView (CorrelationEngine,
   workouts from raw streams, every ~15 min +         BehaviorInsights), CompareView,
   Intelligence screen; persisted under the           MetricExplorerView (ComparisonEngine)
   "<deviceId>-noop" source, merged UNDER imports)

   live BLE stream ─► AppModel: HR smoothing · RMSSD · zone coaching ·
                       illness early-warning · resting-stress nudge
```

---

## Conventions & honesty notes

- **Approximate by design.** Charge, Effort, Rest (and sleep stages, workout intensity, calories) are transparent approximations of published methods — not reproductions of any proprietary algorithm. They're **independent approximations from a consumer strap, built on open science — not medical advice, and not WHOOP's official scores.** Each engine's source header states exactly where it approximates (e.g. Malik instead of Kubios; RMSSD-only parasympathetic tone; normal-approx p-values).
- **One scale, honest about certainty.** All three scores are 0–100 and each rides a Solid / Building / Calibrating confidence tier; a score that can't be computed honestly shows nothing rather than a number.
- **Deterministic.** No randomness, no wall-clock dependence inside the math, no DB/network access. Same inputs → same outputs, which makes the package unit-testable against fixed vectors.
- **Robust statistics.** z-scores use EWMA mean-absolute-deviation (`× 1.253` to a Gaussian σ); resting HR uses 5-minute bin minima; HR display uses windowed medians — all chosen to resist single-sample outliers.
- **Cold-start honesty.** When a baseline isn't trustworthy yet, the recovery scorer returns `nil` rather than a fabricated number.
- **Not a medical device.** None of this is diagnostic or medical advice. The illness early-warning is a wellness nudge from your own baselines, not a clinical screen.
- **Not affiliated with WHOOP.** NOOP interoperates with hardware and exports you already own, entirely on-device. Protocol decoding builds on community reverse-engineering of the WHOOP 4.0 (project *my-whoop*, `johnmiddleton12/my-whoop`) and WHOOP 5.0 (project *goose*, `b-nnett/goose`) protocols.
