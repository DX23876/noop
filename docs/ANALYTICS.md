# NOOP Analytics

On-device analytics for **NOOP** — an offline-first companion app for WHOOP straps (4.0 and 5.0/MG). NOOP talks to *your own* strap over Bluetooth, stores its biometric history locally in SQLite, and computes its three daily scores plus HRV and sleep staging on-device. No cloud or account participates in any of the math described here.

## NOOP's three daily scores — Charge / Effort / Rest

NOOP gives you **three daily scores, each on a 0–100 scale**:

| Score | Answers | Engine | Internal key | Was called |
|---|---|---|---|---|
| **Charge** | How recovered are you? | `RecoveryScorer` | `recovery` | Recovery |
| **Effort** | How hard did your heart work? | `StrainScorer` | `strain` | Strain (0–21) |
| **Rest** | How restorative was your sleep? | Rest composite (`AnalyticsEngine`) | `sleep_performance` | Sleep Performance |

Each score is built from your strap's raw signals using **published, peer-reviewed sport science** (Task Force 1996 HRV, Karvonen %HRR, Edwards/Banister TRIMP, Tanaka HRmax — all cited in full below) and computed **entirely on your device**.

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
| `HRVAnalyzer` | `HRVAnalyzer.swift` | **Library-only** as a type. Live stress check-ins use the dedicated `StressOnsetDetector`. |
| `RecoveryScorer` | `RecoveryScorer.swift` | **Live.** Computes the **Charge** score. Runs inside `AnalyticsEngine.analyzeDay` via `Strand/Data/IntelligenceEngine.swift`; computed values are persisted under the `"<deviceId>-noop"` source and merged **under** any imported `recovery_score_pct` (imports always win). APPROXIMATE. |
| `StrainScorer` | `StrainScorer.swift` | **Live.** Computes the **Effort** score (0–100). Day load is computed on-device for nights the strap offloaded; the imported `day_strain` column still wins for imported days. APPROXIMATE. |
| `SleepStager` | `SleepStager.swift` | **Live.** Stages each offloaded night inside `analyzeDay`; the per-night stages feed the **Rest** composite. Computed sessions are persisted under the `"-noop"` source, with imported sleeps taking precedence. APPROXIMATE. |
| `Baselines` | `Baselines.swift` | **Live.** Seeds the recovery baseline in `IntelligenceEngine.analyzeRecent` (two-pass cold-start). The illness early-warning in `AppModel` still uses its own trailing-window baseline math inline (see below). |
| `WorkoutDetector` / `Calories` | `WorkoutDetector.swift` | **Live.** Runs inside `AnalyticsEngine.analyzeDay`; detected bouts are persisted as `workout` rows under the computed `"<deviceId>-noop"` source (sport `"detected"`), de-duplicated against imported WHOOP workouts. All intensity/calorie fields are APPROXIMATE. Not yet surfaced in the Workouts screen. |
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

### 4. Illness / strain early-warning (`evaluateIllness`)

This is the live, app-side version of the baseline-comparison idea. It recomputes whenever the daily history changes (`repo.$days`). It compares the **last ~2 days** against a **~28-day baseline ending 3 days ago** (so the recent window doesn't contaminate its own baseline):

```swift
let recent = Array(days.suffix(2))
let base   = Array(days.suffix(31).dropLast(3))   // ~28 days ending 3 days ago
```

It then flags anomalies against simple, explainable thresholds using `DailyMetric` fields:

| Signal | Field(s) | Anomaly condition |
|---|---|---|
| Resting HR ↑ | `restingHr` | recent mean ≥ baseline mean **+ 5 bpm** |
| HRV ↓ | `avgHrv` | recent mean ≤ baseline mean **× 0.80** (−20%) |
| Skin temp ↑ | `skinTempDevC` | recent mean deviation **≥ +0.6 °C** |
| Respiration ↑ | `respRateBpm` | recent mean ≥ baseline mean **+ 1.5 bpm** |

A banner appears only when **two or more** anomalies fire together — the classic early-illness signature is *RHR up + HRV down + skin-temp up*. Requires `behavior.illnessWatch` on and at least 14 days of history. On-device only; the message is a plain-English summary like *"Your body looks strained — resting HR +6 bpm, HRV −22%. Consider taking it easy."*

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

The skin-temp term uses the absolute deviation already computed as `DailyMetric.skinTempDevC` (a z-like ±°C), entered as a symmetric penalty `−|dev|/scale`. SpO₂ folds in **only when real** (imported) as a small penalty below ~95%; it's never fabricated and never applied on a bare 5/MG day. HRV's weight dropped from `0.60` to `0.55` to make room for skin-temp; when skin-temp is absent the weights renormalize, so the score matches the older HRV-led composite.

Each metric is standardized to a **robust z-score** against the personal baseline (EWMA spread):

```
z = (value − mean) / (1.253 · spread)
```

The `1.253` converts an EWMA mean-absolute-deviation into an approximate Gaussian σ (`E[|X−μ|] = σ·√(2/π) ≈ σ/1.253`). For "lower is better" drivers (RHR, resp) the z is inverted by swapping value and mean. The sleep term is centered directly: `(sleepPerf − 0.85) / 0.12`.

Missing terms are dropped and weights renormalized. The weighted-mean z is squashed:

```
score = 100 / (1 + exp(−logisticK · (z − logisticZ0)))
        logisticK  = 1.6     (±2 z ≈ the full red–green band)
        logisticZ0 = −0.20   (anchors z = 0 → ~58 %)
```

The `58%` anchor matches WHOOP's published population-average recovery (`populationMean = 58.0`).

### Cold-start ("Calibrating")

HRV is the dominant driver, and NOOP needs a few nights to learn your personal baseline first. If that baseline isn't usable yet (`BaselineState.usable == false`, i.e. fewer than `minNightsSeed` valid nights), `recovery(...)` returns `nil` and the UI shows **"Calibrating"** — more honest than fabricating a number. Callers may fall back to `populationMean` but should flag it.

### Bands (`band(_:)`)

| Band | Range |
|---|---|
| red | `< 34` |
| yellow | `34 … 67` |
| green | `≥ 67` |

### Resting HR (`restingHR`)

"Lowest sustained HR" during the in-bed window = the **minimum of 5-minute non-overlapping bin means** of HR samples in `[start, end]`. This rejects single-beat dips while capturing the night's true floor.

---

## `StrainScorer` — the **Effort** score (0–100 logarithmic cardiovascular load)

Source: `StrainScorer.swift`. Produces **Effort** — *"how hard did your heart work?"* Your day's cardiovascular load: an **independent** implementation of published exercise-physiology methods (WHOOP-*like*, not a reproduction). NOOP turns every second of heart rate into a training-impulse using heart-rate-reserve zones (Karvonen), weights time in harder zones more heavily (Edwards / Banister), and places it on a logarithmic 0–100 scale — so easy days sit low and an all-out day approaches 100, which stays genuinely rare.

> **Scale change (0–21 → 0–100).** Effort is the same cardiovascular-load idea as WHOOP's Day Strain (0–21). We rescaled the **top of the ladder** from 21 to 100 (`maxStrain 21.0 → 100.0`) so all three NOOP scores share one 0–100 scale. The denominator `D = 7201` is **unchanged**, so the log curve and its saturation point are preserved — the rungs didn't move, a 100 is as rare as a 21.0 was.

### Pipeline

1. **Heart-Rate Reserve (Karvonen 1957):** `HRR = HRmax − RHR`.
2. **Per-sample intensity** as `%HRR = (HR − RHR) / HRR × 100`, clamped `[0, 100]`.
3. **TRIMP accumulation** over the window, by one of two methods:
   - **Edwards (1993) 5-zone summation (default):** each sample contributes its zone weight (`1…5` at the `50 / 60 / 70 / 80 / 90 %HRR` cut-offs) × duration.
   - **Banister (1991) exponential:** each sample contributes `duration × x × 0.64 × e^(b·x)`, where `x = %HRR/100` and `b = 1.92` (men) / `1.67` (women).
4. **Logarithmic compression** onto `[0, 100]`:

```
Effort = 100 · ln(TRIMP + 1) / ln(D),    D = strainDenominator = 7201
```

`D = 7201` is calibrated so the Edwards daily ceiling — top zone weight 5 sustained for 24 h = `5 × 1440 = 7200` — maps to exactly the maximum (`ln(7201)/ln(7201) = 1`, so `Effort = 100`). The old 0–21 scale used the identical denominator and curve; only the `maxStrain` multiplier changed from `21.0` to `100.0`.

### Two zone models — and why they disagree

NOOP has **two** notions of "zone". Confusing them is the root of a real user-reported defect, so they
are worth stating plainly:

| | Display zones (`HRZones`) | Effort zones (`StrainScorer`) |
|---|---|---|
| Measured against | **% of HRmax** | **% of heart-rate RESERVE** (`(HR − RHR) / (HRmax − RHR)`) |
| Boundaries | 50/60/70/80/90 by default, **user-definable** | 50/60/70/80/90 %HRR, **fixed** — they are part of the Edwards method |
| Drives | the live readout, in-workout card, Health hero, workout time-in-zone, haptic coaching, what the coach prescribes | the Effort score, and nothing else |

They are not interchangeable, and the gap is large. With HRmax 190 and a resting HR of 50, the floor of
**display** Zone 2 (60 % HRmax = 114 bpm) is only 46 %HRR — *below* Edwards' 50 % cut-off, so it earns
weight 0 — while its top (70 % HRmax = 133 bpm) is 59 %HRR and earns weight 1.

Consequences that follow from this, both deliberate:

- **User-set bands never reach Effort.** They change what is displayed and what is prescribed; no stored
  score moves when a band is edited, so history stays comparable and the ported method stays faithful.
- **A session prescribed in display zones needs translating** before anyone can state what it is worth.
  `EffortFeasibility` does that translation — Edwards weight × minutes through the same
  `trimpToStrain` — which is what stops the coach offering "20 min in Zone 2, effort 15" for a session
  worth about 30. It reports a `typical` figure from the MEAN weight across the band rather than the
  weight at its midpoint, because a band that straddles a threshold otherwise reads as worth nothing.

### Steps / active-energy floor

A long walk with little cardio still counts: when cardio TRIMP is low but step / active-kcal load is high, Effort is raised to a movement-derived floor so non-cardio activity still registers. (5/MG continuity: Effort already reads `COALESCE(measured HR, ppg_hr)` via hrBuckets, so 5-series users get Effort from live + PPG HR.)

### HRmax estimation (`estimateHRmax`)

- With ≥ `hrmaxMinSamples = 600` HR samples, use the observed `99.5th` percentile (`"observed"`), unless a Tanaka estimate is higher.
- **Tanaka (2001):** `HRmax = 208 − 0.7 × age` (gender-independent), used as the floor / fallback (`"tanaka"`).
- No data and no age → `(0, "unknown")`.

### Guards & gates

- Returns `nil` with fewer than `minReadings = 600` samples (≈ 10 min at 1 Hz) or when `HRmax ≤ RHR` (invalid HRR).
- Per-sample duration is inferred from the first two timestamps, falling back to `1 s`.

### Denominator calibration (`fitStrainDenominator`)

Given `(TRIMP, reference_strain)` pairs, fits `D` via a through-origin least-squares line in log-space: `ln(D) = maxStrain · Σx² / Σ(x·strain)`, `x = ln(TRIMP+1)`, where `maxStrain` is the full-scale value (now `100`, formerly `21`). Throws on fewer than 2 usable pairs.

---

## `SleepStager` — sleep/wake detection + approximate 4-class staging (feeds **Rest**)

Source: `SleepStager.swift`. Detects in-bed sessions from gravity/HR/RR/respiration and produces a 30-second hypnogram of `{wake, light, deep, rem}`. These stages and the AASM roll-up below are the raw material the **Rest** score composite consumes (see *The Rest score composite* immediately after this section).

> **Honest hedging.** These stages are **approximations**, not PSG-validated, not medical advice. The EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019). **Light/deep separation is the weakest link — deep-minute estimates are the least reliable output.**

### Stage 0 — gravity-stillness sleep/wake spine (`detectSleep`)

- Per-record movement proxy = L2 magnitude of the gravity-vector change vs the previous record (`gravityDeltas`).
- A sample is "still" if its delta < `gravityStillThresholdG = 0.01 g`. A rolling window (`stillWindowMin = 15` min) calls its center "sleep" when ≥ `stillFraction = 0.70` of samples are still.
- Contiguous runs are built, breaking on a class change or a data gap > `maxGapMin = 20` min; runs shorter than `mergeMin = 15` min are absorbed into neighbours.
- A run must exceed `minSleepMin = 60` min to count, and is **HR-confirmed**: mean HR over the run must be ≤ `hrSleepBaselineMult = 1.05 ×` the day's median HR (skipped when fewer than 30 HR samples — gravity is trusted alone).
- A citable **te Lindert 30 s Cole–Kripke** index (`SI = 0.001 · Σ wᵢ·Aᵢ`, sleep iff `SI < 1`, weights `[106, 54, 58, 76, 230, 74, 67]`) is computed per epoch as a cross-check and to find onset / final-wake.

### Stage 1 — per-epoch cardiorespiratory features

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

- **Personal sleep need:** 8 h default, refined by your recent average; the hours-vs-need term clamps at 100.
- Rest consumes whatever stages each device provides (v25 motion on 4.0; PPG/IMU on 5/MG as it unlocks) — the sleep-staging algorithm itself is unchanged.
- The `sleep_performance` key now stores this 0–100 composite. The **Charge** "Rest quality" driver reads it (÷100) instead of raw efficiency.

This composite is similar *in spirit* to WHOOP's Sleep Performance %, but the blend is our own.

---

## `Baselines` — personal rolling baselines

Source: `Baselines.swift`. Per-metric personal baselines that `RecoveryScorer` consumes. Two interchangeable paths produce the same `BaselineState` shape.

### 1. Winsorized EWMA (production model — `update` / `foldHistory`)

A robust, recency-weighted center with an EWMA-of-absolute-deviation spread tracker:

- **Half-life → smoothing factor:** `λ = 1 − 0.5^(1/halfLife)`. Center half-life 14 nights; spread half-life 21 (slower).
- **Sanity gate:** values outside `[minVal, maxVal]` (per-metric) → skip-and-hold.
- **Hard outlier rejection:** once seeded, a value > `hardOutlierK = 5 ×` spread away is seen but not folded.
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

### Deviation

`deviation(_:state:)` returns a robust z-score, a signed physical-units delta, a fractional ratio (`value/baseline − 1`), and an `inNormalRange` flag (`|z| ≤ 1`).

---

## `WorkoutDetector` + `Calories` — retroactive workout detection

Source: `WorkoutDetector.swift`. Finds workouts in the stored 1 Hz HR + gravity streams (no manual logging).

A workout is a **sustained window** (≥ `minExerciseMin = 5` min) where **both** gates hold per sample:

- **Elevated HR** — above `RHR + hrMarginBPM (15 bpm)`. RHR defaults to the day's 10th-percentile HR.
- **Sustained motion** — gravity-derived intensity (10-second trailing mean) above `motionThreshold = 0.20`.

Active samples are grouped into runs (merging gaps < `mergeGapS = 150 s`), then qualified by intensity: ≥ `minIntensityZ2Plus = 0.50` of the bout in Edwards zone 2+. Per bout it reports avg/peak HR, duration, Edwards zone-time %, mean `%HRR`, strain (via `StrainScorer`), and calories.

### Calories (`Calories.estimateBoutCalories`)

Per-second blend of **Keytel (2005)** active expenditure and **revised Harris–Benedict** BMR (resting), with sex-specific coefficients (`male` / `female` / `nonbinary`). Below a `RHR + 0.30 × HRR` threshold the resting rate is used; above it, the HR-driven active rate. Returns `(kcal, kJ)`. **Approximate** — not laboratory calorimetry.

---

## Daily energy — `EnergyEngine`, `WhoopEnergyModel`, Watch calibration, adaptive TDEE

Source: `Packages/StrandAnalytics/Sources/StrandAnalytics/{EnergyEngine,WhoopEnergyModel,EnergyCalibrationEngine,AdaptiveExpenditureEngine}.swift`, all pure and DB-free. Together they answer "how much did I burn today?" (the **ENERGY** card in Control Center / Today, `Strand/Screens/EnergyCard.swift`) without ever silently adding two devices' measurements for the same body.

### `EnergyEngine` — one day's total, sources never summed

`EnergyEngine.summarize(_:profile:context:)` selects **one** source per day and, where possible, tops it up with the *modelled remainder* — it never adds two measured sources together:

1. **`strapWornTime`** — the WHOOP total (from `whoopDailyEnergy`, or the legacy `DailyMetric.activeKcalEst`) whenever present. The total and its coverage denominator are always taken from the **same** model — `(rawTotalKcal, observedSeconds)` or `(activeKcalEst, energyCoverageSeconds)`, never crossed. Crossing them lets the engine divide one model's kcal by another's seconds, and where the legacy denominator is the larger the implied basal top-up eats the day's active energy through `max(0, total − basal)`. This is canonical: an optional Watch calibration factor may scale it, but Apple never replaces it. The worn-time total is topped up with `profile BMR × unworn seconds`, never a full day's BMR (that would double-count every worn second — the trap the file's header exists to prevent). The Watch factor scales **active energy only** — see "Calibrating active energy only" under `EnergyCalibrationEngine` below.
2. **`appleSplit`** — Apple's own `active_kcal` + `basal_kcal`, used only on a day with no WHOOP estimate.
3. **`mixed`** — Apple active energy with no basal figure; basal is modelled from BMR × elapsed fraction.
4. **`stepsEstimate`** — no energy measurement anywhere: `steps × 0.0005 kcal/step/kg × bodyWeightKg`, calibrated so 10,000 steps ≈ 400 kcal for an 80 kg adult.
5. **`profileOnly`** — nothing measured; only the modelled 24 h BMR is reported, and `totalBurnedSoFar` stays `nil` (never `0`).

Coverage (`EnergyCoverage.energy`) is the fraction of the elapsed local day the day's *actual* source reported for: real strap HR seconds, or — for an `appleSplit` day, since 2026-08-25 — `healthEnergyBucket.coverageSeconds` (max per bucket across sources, never summed; iOS only, see below). Confidence (`ScoreConfidence`) is `.solid` at ≥80% coverage (`solidCoverage`), `.building` at ≥40% (`buildingCoverage`), `.calibrating` below — a modelled day is never `.solid` however complete it looks. **`appleSplit` runs this exact same ladder once a coverage signal exists.** Reporting both active and basal energy is not proof Apple covered the whole elapsed day, only that it covered whatever it saw — the same principle already applied to the strap. Where no coverage signal exists at all (a macOS import, or any day before `healthEnergyBucket` existed — the bridge that populates it is iOS-only), `.appleSplit` keeps its previous `.solid` rather than being marked down for a platform gap it didn't create: an *absent* signal is not evidence of a *thin* one. Local-day seconds are calendar-derived (`Repository.energyDayContext`), not a fixed 86,400, so DST transitions don't skew basal accrual.

### The day forecast — `projectedTotalBurn` / `projectedRangeKcal`

    projected = spent so far + basal for the hours left + the activity still expected

Computed only for *today*, and only once ≥10 % of the day has elapsed (before that the rate is too noisy and a wild morning figure reads as a malfunction).

The last term used to be `active / elapsedFraction` — a linear extrapolation assuming activity arrives at a constant rate. It does not: an 08:00 workout made the forecast shoot far too high (a whole day extrapolated from the one hour containing all of it), and a quiet morning before an evening session made it read far too low. The divisor is now the fraction of a *typical* day's activity this person has normally banked by now:

    expected remaining activity = activeSoFar × (1 − f) / f

**With `shape == nil` the expected fraction IS `elapsedFraction`, and the formula collapses to exactly the previous arithmetic** — algebraically identical, not merely close, so a user without enough history keeps the old behaviour rather than a worse curve. `(1 − f)/f` is capped at `maxRemainingActivityMultiplier` (6.0). A curve legitimately reading *zero* is clamped **up** to `minimumShapeFraction` rather than discarded: "this person has normally done nothing by now" is the strongest signal the curve ever carries — it is what stops an evening routine being forecast as a quiet day — so the multiplier ceiling, not the floor, bounds the magnitude.

### `ActivityShapeEngine` — the personal time-of-day curve

Source: `ActivityShapeEngine.swift` (pure). Fits `f(t) ∈ [0,1]` — the cumulative fraction of a typical day's **active** energy burned by hour *t* — from `whoopEnergyHourly` (migration v48), which the same bucket pass that writes `whoopDailyEnergy` populates for free. Basal is excluded: it is flat by construction and would flatten the very shape this measures.

- **Each day is normalized to its own total *before* the days are combined.** The curve is a shape, not a magnitude, so one colossal day cannot redefine what a normal afternoon looks like.
- **Per-hour combination is a median**, not a mean — the same robustness applied to the other axis.
- Needs ≥`minimumDays` (14) usable days inside a 42-day window; a day below `minimumDailyActiveKcal` (50) is skipped, because dividing by a near-zero total manufactures a shape out of rounding. Below the threshold the engine returns `nil` and the projection stays linear.
- Fitted from complete days only — today is still accruing, and including it would teach the curve that this person stops being active at whatever time it currently is.
- Deliberately **not** split weekday/weekend yet: a real effect, but splitting doubles the history each arm needs, and the fallback is honest linear behaviour rather than a worse curve.

### The adaptive TDEE as a forecast prior

`summarize(adaptivePriorKcal:)` blends the long-horizon retrospective TDEE into the **forecast only**:

    final = w × sensorForecast + (1 − w) × prior,   w rises with coverage

The case it exists for: an 11:00 workout on a day the strap has barely seen can project 3,700 kcal for someone whose measured six-week maintenance is 2,750. The sensors are not wrong about the workout — they are wrong about the thirteen hours they did not observe, and the prior is the only thing in the app that knows what those hours usually cost. The sensor keeps at least `minimumSensorWeight` (0.5), so the prior can temper a forecast but never replace it with an average of the person's past; at `priorFullTrustCoverage` (0.90) the prior drops out entirely. **`totalBurnedSoFar` is never touched** — an energy-balance model must not rewrite a measurement (`fork/decisions.md`, 2026-08-25).

An **unknown** coverage signal does not shrink anything. Only a *measured* thin day is tempered, because this has to read that nil exactly the way `confidence(...)` does — that ladder calls an unknown-coverage day `.solid` (a macOS import didn't create the platform gap), and halving the same day's forecast toward a long-horizon average would put two contradictory readings of one nil in one file: "High" on the badge, half-trusted in the number beneath it.

### The forecast interval

`projectedRangeKcal` is present whenever a forecast is. A bare `~2,650 kcal` claims a precision the model does not have; `2,400–2,900` says the same thing honestly and carries extra information. Two independent widths compose it: what the model already publishes about the energy it *has* measured (`uncertaintyFraction`, itself weighted by the observed/inferred/modeled evidence mix), plus a term for how much of the day is still unlived — no coverage figure can speak for hours that have not happened.

### `WhoopEnergyModel` — WHOOP-first bucket estimate

A pure, Apple-Health-free model over five-minute `WhoopEnergyBucket`s (HR, motion intensity, steps, distance, stride, the strap's `activity_class`, and workout/sleep/off-wrist flags), producing a `WhoopDailyEnergyEstimate` with an explicit **evidence mix** per bucket:

- **`observed`** — a valid HR sample (30–240 bpm) drives an HR-reserve MET curve: `met = 1 + 11·reserve²` (capped 14) for workout/high-reserve buckets (`reserve ≥ 0.50`), else the conservative `met = 1 + 2.5·reserve`, where `reserve = (hr − restingHR) / (maxHR − restingHR)`. **When the same bucket also carries a movement signal, the model takes `max(hrMET, movementMET)`** (see "Why HR alone cannot see a walk" below). Active kcal: `max(0, met−1) × 3.5 × weightKg / 200 × minutes`.
- **`inferred`** — no HR, but steps/distance/motion/activity-class indicate movement: a coarse MET from walking/running speed (km/h) or step cadence, same active-kcal formula, basal added underneath.
- **`modeled`** — off-wrist or sleep, or no signal at all: pure basal fill (`BMR/86,400 × seconds`).

#### Why HR alone cannot see a walk *(model v2, 2026-08-25)*

Both energy paths used to gate active energy on heart-rate reserve alone, and both went blind at ordinary walking intensity:

- The legacy whole-day path (`Calories.estimateDayCalories`) credits every second below `restingHR + 0.50 × HRR` the **bare resting rate** — and `restingKcalPerS` is *exactly* `bmrKcalPerDay / 86,400`, the same number `EnergyEngine` subtracts as its basal top-up. The two cancel, so a 30-minute walk at ~37 % HRR was worth **bit-exactly zero** active kcal. (The 50 % gate was a deliberate over-correction against a "calories too high" report; it fixed over-counting by making low-intensity movement invisible.)
- The bucket model's low-intensity curve returns ~1.9 MET at that same reserve, where a brisk walk really costs 3.0–4.3 MET.

v2 therefore lets **movement corroborate** the HR reading: `max()`, never a replacement or an average. Movement can only ever *raise* the estimate, and only when a real steps / distance / motion / activity-class signal exists for that bucket — a high-HR, quiet-wrist bucket (cycling, lifting) keeps the HR curve untouched. The guard matters: `movementMET` floors at 1.5, so calling it for a bucket with no movement signal would invent half a MET on every still, awake second. Evidence stays `observed`, because HR *was* measured; the movement channel corroborates it rather than standing in for it.

The strap's own **`activity_class@63`** (0 still / 1 walk / 2 run, WHOOP 5/MG only) sets a MET **floor** (walk ≥ 3.0, run ≥ 7.0) rather than being averaged in — it is a direct classification, not something inferred from a tick counter. It never lowers a faster reading, so a run misreported as a walk keeps the run's energy. A WHOOP 4.0 carries no `@57` counter and no `@63` class, so it keeps exactly the HR-only behaviour.

#### One MET curve, not two *(model v3, 2026-08-26)*

`movementMET`'s GPS-distance branch and step-cadence branch used to carry **independently hand-tuned** breakpoint tables. At the same real walking pace they could disagree by up to 2.7 MET — 100 steps/min read 4.0 MET on the cadence table against ~3.3 on an external reference at the same implied speed, and 130 steps/min read 7.0 against ~4.5. Since `refreshWhoopEnergyModel` populates `steps`/`activityClass` but not `distanceM`, the cadence table was the one that actually ran in practice, and it ran high.

Both branches now resolve to a **speed in km/h** and look it up in one shared, cited curve — `speedMETTable`, piecewise-linear between reference points from Ainsworth et al.'s *2011 Compendium of Physical Activities*, the standard external reference for activity METs (walking 3.2→16.1 km/h through running paces, up to 14.5 MET at 16.1 km/h — the elite-pace ceiling, up from the old hand-picked 12). The cadence branch has no measured stride yet — `strideM` already exists on `healthEnergyBucket` from Apple's calibrated walking-step-length reading, but nothing reads it into this model — so cadence is converted to speed with a population-average 0.75 m stride as a documented placeholder, pending that wiring.

Bucket movement is assembled in `Repository.stepMovementByBucket` (`Strand/Data/EnergySeries.swift`), which reuses three existing rules rather than re-deriving them: **one device id, never merged** (`@57` is cumulative — interleaving two straps fabricates huge deltas), the shared **`StepsCounter`** wrap-aware kernel, and the **`stepTicksPerStep`** tick→step calibration (#139). It reads one day at a time, because `stepSample` is a ~1 Hz stream. The bucketing itself is the pure `Repository.bucketStepMovement`, split out (like `latestActivityClass`) so its delta and gap rules are unit-testable without a store.

Each bucket carries the **previous** sample as well, because `stepsInWindow` needs a predecessor to form a delta and a slice starting cold silently drops the ticks accrued across every boundary — 288 small losses a day, all in the same direction. That predecessor is accepted only from within one bucket-width, though: `@57` is cumulative, so a sample from before a data gap (a charge break, a not-yet-offloaded stretch) carries every tick of that whole gap, `StepsCounter` accepts any delta below 512, and crediting it to the first bucket after the gap renders hours of absence as five minutes of brisk walking — which then feeds `movementMET` a cadence that never happened.

`uncertaintyFraction` blends per-second weights `0.10·observed + 0.22·inferred + 0.35·modeled`, capped at 0.50 — deliberately conservative and monotonic in evidence quality. Body weight is resolved **per day**, not from today's profile, via `CausalWeightResolver` — a 10-day EWMA (`α = 2/11`) over `bodyWeightEntry` + imported Health weights, manual entries winning ties on the same local day, valid for at most 90 days before falling back to the profile default. This prevents a new weigh-in from silently rewriting historical calorie totals.

`AppModel.refreshWhoopEnergyModel` runs this after every completed strap offload (`Strand/App/AppModel.swift`) and persists one `whoopDailyEnergy` row per day (`WhoopStore`), keyed by `WhoopDailyEnergyEstimate.modelVersion` (currently `"whoop-bucket-v3"`). `Repository.energySummaries` **filters rows to the current version**, so a formula change genuinely invalidates old rows instead of drawing two model generations as one trend line — a superseded row falls back to the legacy whole-day estimate until the next refresh overwrites it.

### `EnergyCalibrationEngine` — opt-in, bounded Apple Watch reference factor

Off by default (Settings toggle inside the Energy detail screen, `EnergyCalibrationPreferences.enabled`). When enabled, NOOP compares time-aligned WHOOP bucket output against Apple Health reference buckets **from an Apple Watch source only** (`HealthEnergySourceKind.calibrationEligible`; iPhone/third-party/NOOP's-own writes are never eligible) and fits a single multiplier:

- Requires **≥7 distinct days** (`minimumDays`) and **≥84 buckets** (`minimumBuckets`) at `overlapQuality ≥ 0.70`.
- Takes the **median** ratio `appleWatchKcal / whoopKcal`, trims outliers beyond 3×MAD (or ±0.001 when MAD is zero), and refits the median over the trimmed set.
- Rejects the fit outright if the trimmed sample's coefficient of variation exceeds `0.20` (`maximumCV`) — an unstable ratio is not a calibration.
- Clamps the result to **`0.80...1.20`** (`factorRange`): calibration can only ever nudge the WHOOP number, never dominate it.

`Repository.refreshWhoopEnergyModel` picks the single Watch source with the most eligible buckets in-window (never blends multiple watches) before fitting. State surfaces as `EnergyCalibrationStatus`: `off` → `learning` (opted in, no fit yet) → `active` (fit applied) → `paused` (opted out, fit retained for a later re-enable without re-fitting from scratch).

#### Calibrating active energy only *(fit v2, 2026-08-25)*

Both sides of the fit are now **active-only kcal, never totals**:

- Apple already reports `activeKcal` separately from `basalKcal`, so no subtraction is needed there.
- WHOOP's side is `bucket.kcal − basalPerSecond × bucketSeconds` — the same active-only figure written to `whoopEnergyHourly` (see `ActivityShapeEngine` above), reused rather than recomputed so the two copies of the basal-subtraction arithmetic cannot drift apart.

Fitting on totals (v1) baked resting metabolism into the ratio and diluted it: at a typical 70% basal share, a real active-energy ratio of 1.5 shows up as a total-based ratio of only ~1.15. Applying THAT diluted factor to active energy alone — which is what `EnergyEngine.burn` has always done — systematically under-corrected. The fix therefore touches both ends together: the fit's inputs (here) and where the factor is applied (`EnergyEngine.burn`, above — `rawActive = strapTotal − observedBasal`, then `active = rawActive × factor`; **never** a straight multiplier on the raw WHOOP total, and never applied to the legacy branch that has no coverage denominator to isolate basal from).

`EnergyCalibrationFit.modelVersion` moved to `"watch-reference-v2"` for exactly this reason: `Repository.energyCalibrationState` treats a stored fit as `.active` only when its version matches, so a v1 (total-based) fit reads as absent — back to `.learning` — rather than being applied as though it had been fitted on active-only energy. No migration needed; the version check does the invalidation.

### `AdaptiveExpenditureEngine` — retrospective TDEE from intake + weight trend

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

`AICoachEngine.energyBalanceTool()` (`get_energy_balance`) reports today's total, source, coverage, calibration status/factor, model uncertainty, and — when available — the adaptive comparison range, with an explicit instruction never to turn either figure into diet/intake advice (NOOP holds no nutrition-recommendation logic). The iOS energy widget (`WidgetEnergySnapshot`) additionally carries the raw pre-calibration WHOOP figure, the uncertainty percentage, and the calibration factor (stored as an integer permille to keep snapshot-diffing exact).

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
3. Daily resting HR = lowest per-session resting HR; daily avg HRV = in-bed-weighted mean of per-session HRV.
4. **Rest** — the four-component sleep composite (duration vs need / efficiency / restorative share / consistency), stored under `sleep_performance`.
5. **Charge** — `RecoveryScorer.recovery(...)` with the personal HRV/RHR/resp/skin-temp baselines and the Rest score as the sleep input, stored under `recovery`.
6. **Effort** — `StrainScorer.strain(...)` over the full day's HR window (Tanaka HRmax from age unless overridden), on the 0–100 scale, stored under `strain`.
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
