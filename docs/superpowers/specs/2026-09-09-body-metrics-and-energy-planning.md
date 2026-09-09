# Body metrics and energy planning — design

**Date:** 2026-09-09
**Scope:** Apple only. A new Body page and two energy pages, a `BodyMetrics` resolver that ends the
duplicate storage of body data, and a dated basal-formula log. Pure work lands in
`Packages/StrandAnalytics` and `Packages/WhoopStore`; the pages are app-target Swift, which no
default CI job builds — see "Verification".

## Problem

Three separate ones, which is why this is one spec rather than three.

**Body data has up to three homes.** Weight lives as an undated scalar in `ProfileStore.weightKg`,
as a dated series in `BodyWeightStore`, and in Apple Health. Waist lives in `ProfileStore.waistCm`,
as a `LabMarkerRow` under the `waist` key, and in HealthKit. Height the same. The scalar and the
series are kept in step by a VIEW: `WeightDetailView` writes the newest weigh-in back into
`profile.weightKg` because "HR zones and the calorie model read" it. Meanwhile `EnergySeries`
deliberately refuses that scalar and resolves body mass per day, with the comment that using
today's weight for history "leaks future information backwards and can rewrite old calorie totals".
Two parts of the app already disagree about where the truth is.

**There is no way to log a body measurement.** Circumferences have no capture surface at all. Body
fat can only arrive from Apple Health; a DEXA result or a caliper reading has nowhere to go.

**There is no way to plan intake, and no way to check the number the app produces.** For a
strap-only setup (the target here) the daily burn is `strapWornTime`: measured heart rate converted
by two population formulas — Keytel above the activity gate, the basal rate below it. Since a WHOOP
is worn continuously, most of the day sits below that gate, so the basal formula IS most of the
number. `EnergyCalibrationEngine` exists to correct the level, but it fits a bounded multiplier
against an **Apple Watch reference**; with no Apple Watch it stays in `.learning` forever and the
bias stands uncorrected.

## Step 1 — `BodyMetrics`: one home, one read path

No body value remains an undated scalar. Weight stays in `BodyWeightStore`; every other measurement
becomes a `LabMarkerRow` (which already carries day, instant, value, unit, source and note).

A resolver answers every read, in two shapes because callers ask two different questions:

| | Question | Callers |
|---|---|---|
| `latest` | what is true now | HR zones, the planner, the profile row in Settings |
| `asOf(day:)` | what was true on that day | `EnergyEngine`, Fitness Age, the Navy series, anything historical |

`asOf` generalises what `EnergySeries` already does for weight alone. `latest` is held in memory:
it sits on the Today launch path and must stay as cheap as the UserDefaults read it replaces.

**What moves, and what does not.**

| Stays in the profile | Moves to the measurement store |
|---|---|
| Date of birth, sex, name, avatar | Weight, height, waist |
| HRmax override, zone configuration | (and everything new below) |
| Step calibration | |

The line is: date of birth and sex are identity, weight and circumferences are measurements. That
distinction is the whole reason for the move.

**Migration.** On first launch, a typed `weightKg` / `heightCm` / `waistCm` with no corresponding
reading is written into the store as a dated reading with source `profile`, stamped at the date it
was last known — never at "today", which would claim a measurement that was not taken. Only then is
the scalar retired. The user typed those numbers; they do not disappear because the architecture is
being tidied.

**Settings keeps the fields as a way in.** Where the editable fields are today, the row shows the
current value with its date and navigates to the Body page. Removing them outright loses everyone
who knows where they are.

**Blast radius.** 39 files read `ProfileStore`. Three need care:

- The Today launch path (HR zones, calorie model) — hence the in-memory `latest`.
- `DashboardPresentation`'s cache key is built from `weightKg`/`heightCm`; it must be rebuilt from
  resolved values or the dashboard stops invalidating after a weigh-in.
- Widgets and the Watch read no body data at all — the radius ends in the app targets.

Step 1 ships with **no behaviour change**: every caller receives the value it receives today.

## Step 2 — the Body page

**Data model: no new table.** `MarkerCatalog` gains circumference keys under the existing
`bodyMeasurement` category: `neck`, `shoulders`, `chest`, `hips`, `thigh_l`, `thigh_r`, `calf_l`,
`calf_r`, `biceps_l`, `biceps_r`, `forearm_l`, `forearm_r` (`waist`, `height`, `weight` and
`body_fat` already exist). They inherit CSV import, backup, Explore and the marker detail screen
for free.

**Capture** is one sheet for a whole session — one timestamp, n values, one optional note. That is
how people actually measure, and it is what Hevy does.

**Measurement guidance per site**, shown at the point of entry. Circumference data is almost
entirely method noise when the method varies; without this the chart is a random walk drawn
beautifully.

**Left/right readout.** Where both sides exist the difference is a measured number — the
circumference counterpart to the Strength screen's balance card.

## Step 3 — body fat, from three sources kept apart

1. **Navy method** (Hodgdon & Beckett) from neck/waist/(hip)/height — a published formula, citable
   the way Epley is. Labelled an ESTIMATE wherever it appears, with its real error band against DEXA
   (roughly ±3–4 percentage points, and individually biased rather than randomly wrong). It is good
   at TREND and poor at ABSOLUTE level; the wording says so.
2. **Entered manually** with its source recorded — DEXA, BIA scale, caliper, InBody. The source
   rides on `LabMarkerRow.source` and is distinguished in the chart: DEXA and caliper are not the
   same measurement and must not sit on one line.
3. **Read from Apple Health** (exists today).

**A Navy estimate is never written back to Apple Health.** `HealthKitBridge` keeps body fat
read-only today because there is "no reliable NOOP-computed source" for it; a circumference formula
does not change that. A manually entered DEXA value may be written back, default off.

## Step 4 — progress

Reuses `TrendChart`, the EWMA smoothing behind `WeightTrendSummary`, and `TypicalRangeBar`.

- Smoothed line over the raw points: circumferences vary day to day by more than they change month
  to month.
- A multi-series view — weight against waist against body fat on one time axis. That comparison is
  the actual question ("am I losing fat or water?") and it needs three series, not one.
- Windows as on the Strength screen: 3 months / 1 year / all.
- Source markers on the points (Navy vs DEXA vs scale).

## Step 5 — reminders

`WindDownNudge` is the template: a local `UNCalendarNotificationTrigger`, opt-in, with a switch in
the notification settings. A weekly measurement reminder, optionally a daily weigh-in one. **Default
off**, like every other notification in the project.

## Step 6 — Apple Health scope

- **Read:** weight, body fat, lean mass, BMI (exists). Add `waistCircumference` — the ONLY
  circumference HealthKit models. Chest, thigh and the rest have no HK type and stay NOOP-local; the
  page says so, or their absence reads as a sync fault.
- **Write:** weight (exists), waist (new, opt-in), body fat only when manually entered from a
  measured source and explicitly enabled.
- Conflicts use the same arbitration weight already uses. Nothing new is invented.

## Step 7 — the basal formula becomes a dated log

Once a body-fat value exists, Katch-McArdle (which works from lean mass) is the better formula. It
must not change history.

**`BmrFormulaEpoch`** — an append-only list of `(effectiveFrom: day, formula)`, seeded with one
entry at the beginning of time carrying the current **revised Harris-Benedict**. Switching APPENDS;
entries are never edited. The energy path asks "which formula applied on day X". Days before the
switch keep what they had.

This does not violate `Calories`' own rule that "NOOP must have ONE basal rate" — one formula per
day is still one rate per body per day, as long as the selection is deterministic and comes from
stored data rather than from whatever the settings currently say.

**Two surfaces behave differently, and only one needs the log:**

| | Where the basal rate enters | Effect of a switch |
|---|---|---|
| Stored | `DailyMetric.activeKcalEst`, baked in at scoring time | already behaves correctly: old days keep their value |
| Computed at read | `EnergyEngine.summarize` reads the profile on every build | without the log, yesterday's displayed history silently changes |

**Katch-McArdle uses the body-fat reading in force on that day**, through `asOf` — so the basal rate
keeps tracking new measurements going forward without ever reaching backwards.

**The step in the line is labelled.** A formula change moves the basal rate by roughly 50–200
kcal/day; an unexplained step reads as a bug. A marker at the switch date on the chart, and a line
in the provenance sheet naming both formulas and the date. Comparisons that span the boundary
("last 30 days vs the 30 before") are either restricted to one epoch or annotated — otherwise a
formula change is read as a change in behaviour.

**Quality caveat, stated at the switch.** Katch-McArdle only beats Harris-Benedict when the body-fat
number is good. On a Navy estimate the resulting error can be comparable. The switch is offered as
soon as any value exists, and the sheet names **what it rests on** — DEXA, scale or circumference
estimate.

**Retroactive stays possible, never automatic.** Settings already carries a confirmation-gated
manual 21-day reanalysis. That is the only way history is recomputed under a new formula.

**The epoch log belongs in the `.noopbak` whitelist** (a JSON string; the whitelist carries
Int/Double/String). Without it a restore silently reverts to Harris-Benedict and the curve steps a
second time, with nobody having changed anything.

## Steps 8 and 9 — the two energy pages

**Three rules, in order of importance.**

1. **The planner owns no calorie model.** `EnergyEngine`'s third rule is that sources are CHOSEN per
   day and never summed — two devices on one wrist measure the same body, and adding them invents a
   person who burned twice. A planner deriving its own burn from heart rate or steps would be
   exactly that second computation. It consumes `energySummaries` and `AdaptiveExpenditureEngine`,
   and nothing else. Its only own arithmetic is the formula page, which answers a different question:
   what a population formula PREDICTS, not what was measured.
2. **A measured TDEE is source-weighted, not blindly averaged.** A 30-day mean of which 22 days are
   `stepsEstimate` is a formula calculation with extra steps. The page shows how many days came from
   which `EnergySource` and at what `coverage`, and refuses to call a mostly-modelled average
   "measured".
3. **What the basal formula actually touches.** On `appleSplit` days NOOP supplies no basal rate at
   all. On a strap-only setup — the target here — the basal term dominates the day. The switch is
   therefore consequential for exactly this configuration, which the sheet states.

**Page A — "Calculated".** Named published formulas: revised Harris-Benedict today, Mifflin-St Jeor
and Katch-McArdle as the alternatives, times a PAL factor. The PAL steps are **conventions**, not
measurements, and are labelled as such — the same treatment the Strength screen's stimulus anchors
get.

**Page B — "From your data"**, two tiers:

- **Measured burn:** `EnergyEngine` per day, averaged over covered days, with provenance. Needs no
  food log.
- **Energy balance:** `AdaptiveExpenditureEngine` back-calculates expenditure from intake and weight
  change over weeks, with its confidence band. It is the only figure that does NOT inherit the
  strap's conversion error, which makes it the check value rather than a second opinion.

**The comparison is the product.** Three numbers side by side — formula, wearable, balance — and the
spread between them. Because nobody can say how accurately a wearable measures, the honest output is
a corridor with named sources, not a single figure.

**From TDEE to a plan.** Goal (hold / lose / gain) → deficit or surplus → predicted rate, with two
honesty rules: the 7 700 kcal/kg figure is the **Wishnofsky convention** and demonstrably optimistic
over longer horizons, so once enough data exists NOOP shows the wearer's **own observed** kcal-per-kg
beside it; and the rate is checked against `GoalSafetyGate`, which already carries
percent-of-body-weight-per-week thresholds. Neither is re-invented here.

## Step 10 — intake

A **manual daily entry**: one number per day, no food database. `calories_in` already exists as a
metric key; today it can only arrive through the nutrition CSV import. The balance tier needs
nothing more than one value per day, and for a strap-only setup it is the ONLY remaining way to
validate the level at all, since the Apple Watch calibration reference is gone.

## Step 11 — onboarding

A guided flow that asks exactly what the calculation needs — sex, height, age, activity, goal — and
explains at each stop why it is being asked. It ends not on "your requirement is 2 480 kcal" but on
the corridor, the provenance of each number, and which input moves it most.
`CoachGoalOnboardingFlow` is the pattern.

## Deliberately excluded

- **A food diary with a food database.** That is a separate app and would need a server this project
  does not have. The balance tier therefore rests on manual entry or CSV import.
- **Progress photos.** Moderate value, large privacy surface.
- **Reference ranges for body fat.** The Lab Book ships none for exactly this reason; a "normal
  range" is a medical claim.
- **Feeding the balance estimate into `EnergyCalibrationEngine`** as a replacement for the Apple
  Watch reference. Tempting, but `EnergyEngine.summarize` explicitly refuses to let an energy-balance
  model rewrite a measurement (`fork/decisions.md`, 2026-08-25). A bounded multiplier is not a
  rewrite, but it changes what the factor means, and that deserves its own decision entry rather
  than arriving inside a calorie feature.

## Analysis migration required: **no**

Nothing stored is rewritten. Step 1 hands every caller the value it already receives. The formula
switch is DATA (a dated log), not code, and applies forward only. The moment any caller is changed
from "today's scalar" to `asOf` in a way that alters historical stored values, that specific change
answers **yes** and carries a recipe bump — a deliberate per-caller decision, never a side effect of
the move.

## Verification

- Pure work (`BodyMetrics` resolution, Navy, BMR formulas and epoch selection, PAL, the corridor)
  gets `swift test` coverage in `Packages/StrandAnalytics`, which `swift-packages.yml` runs.
- New marker keys and the profile migration need a versioned migration plus a test that pins the
  resulting schema and the migrated rows.
- Everything under `Strand/Screens` and `StrandiOS` is app-target Swift that **no default CI job
  builds** — `app-build.yml` is disabled. Each PR states that the app was built locally.
- New UI strings only enter the catalog through an Xcode.app build; translations follow through
  `Tools/translations/*.json` and `Tools/fill-missing-translations.py`.

## PR order

1. `BodyMetrics` resolver + profile migration, no behaviour change
2. Settings rows show value + date and navigate to the Body page
3. `MarkerCatalog` circumference keys + migration
4. Navy estimate as a pure function
5. Body page: capture, list, guidance
6. Progress charts
7. Reminders
8. Apple Health scope extension
9. `BmrFormulaEpoch` + the provenance sheet
10. Energy analytics (formulas, PAL, corridor)
11. Page A
12. Page B + manual intake entry
13. Onboarding
14. Coach access + i18n

## Open

- Whether a manually entered DEXA body-fat value should be written back to Apple Health by default
  (this spec says no).
- Whether the Body page and the energy pages sit side by side in the Body group, or the energy pages
  hang off the Body page.
