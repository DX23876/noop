
# NOOP — Feature Guide

NOOP is an **offline-first** companion app for WHOOP straps (4.0 and 5.0/MG). It pairs
directly with the strap over Bluetooth Low Energy — **no WHOOP account, no
cloud** — stores everything on-device in SQLite, imports your WHOOP and Apple Health exports,
and computes its own daily scores locally — **Charge** (recovery), **Effort** (strain) and **Rest**
(sleep), an energy economy you wake with, spend, and rebuild — alongside HRV and the raw signals.
These are honest approximations from published methods, **not WHOOP's scores**. macOS and iOS/iPadOS
ship from this fork and share the same store and analysis implementations; iOS is distributed as an
unsigned AltStore/SideStore IPA or built with Xcode. The optional Watch companion is part of the Full
IPA. Android is maintained in [RyanBR's upstream project](https://github.com/ryanbr/noop), not here.

> **Not affiliated with WHOOP.** NOOP is independent interoperability software for *your own*
> device and *your own* data. "WHOOP" is used only to identify the hardware NOOP talks to.
> **NOOP is not a medical device** — every metric (HR, HRV, Charge, Effort, Rest, SpO₂,
> respiration, skin temperature) is an approximation, not a clinical reading, and must not be
> used to diagnose, treat or make health decisions.

NOOP is built on community interoperability and protocol-documentation work, with thanks to:

| Project | Contribution |
| --- | --- |
| [`johnmiddleton12/my-whoop`](https://github.com/johnmiddleton12/my-whoop) | WHOOP 4.0 BLE protocol — framing, commands, decoding |
| [`b-nnett/goose`](https://github.com/b-nnett/goose) | WHOOP 5.0 / MG BLE protocol |
| [`groue/GRDB.swift`](https://github.com/groue/GRDB.swift) | On-device SQLite persistence |

---

## At a glance

NOOP is a `NavigationSplitView`: a left sidebar of screens, a live connection status pill
pinned to the sidebar's bottom (bonded / connecting / disconnected, with battery %), and a
detail pane. A menu-bar item gives a glanceable live heart rate from anywhere. The whole UI is
dark, and a first-run wizard walks you through pairing.

The sidebar itself is five collapsible groups (macOS `RootView.swift`; the exact mapping is in
[docs/ARCHITECTURE.md](ARCHITECTURE.md) §10) — **Today**, **Sleep**, **Body** (Workouts, Live,
Health, Stress, Intervals, Breathe), **Insights** (Intelligence, What Moves You, Coach, Goal &
Journey, Explore, Compare, Insights, Lab Book, Rhythm, Trends), and **Data & App** (Devices, NOOP
Limitations, Data Sources, Apple Health, Mi Band, Backup & Sync, Your Data Fused, Notifications,
Automations, Alarms, Power saving, Settings, Test Centre) — and auto-expands whichever group owns
the destination you're on. iOS reaches the same destinations through the tab bar's **More** tab
instead of a sidebar.

Screens are grouped below by whether they need a connected strap:

| Needs a connected strap (live BLE) | Works from imported/local data alone |
| --- | --- |
| Live, Breathe (for haptics), Intervals (for haptics), Health Monitor (live HR), Automations (to act), Notifications (to buzz), Alarms (to arm the strap wake-buzz — the wind-down nudge itself doesn't), Power saving (levers a connected strap's sync cadence) | Control Center, Intelligence, Explore, Compare, Insights, What Moves You, Coach, Goal & Journey, Lab Book, Rhythm, Sleep, Trends, Workouts, Stress, Mind, Devices (pairing itself needs Bluetooth, but the screen and history don't), NOOP Limitations, Apple Health, Mi Band, Data Sources, Backup & Sync, Your Data Fused |

Most of NOOP works the moment you import an export. The strap adds the *live* layer — real-time
heart rate, haptic cues, and physical-input automations.

---

## Connection states

Throughout the app the strap reports one of three states:

- **Disconnected** — no strap found (critical / red dot).
- **Connecting** — found and connecting, finishing the secure pairing handshake (warning / amber).
- **Bonded** — paired and streaming; haptics and live HR are available (positive / green).

> WHOOP straps do **not** appear in *System Settings → Bluetooth*. They advertise on a custom
> profile that only apps like NOOP can find — so there's nothing to pair in System Settings.

Commands that drive the strap motor (any wrist buzz) and the live realtime stream require a
**bonded** connection. Where a feature needs this, it is noted below and the button is disabled
until you bond.

---

## First-run onboarding

The onboarding wizard (`OnboardingWizard.swift`) appears on first launch and runs once
(tracked by the `noop.onboarded` preference). It is a calm, paged flow with a progress
"thread" along the bottom and a Back button always available:

1. **Welcome** — "all your data, none of the cloud".
2. **What NOOP does** — three value slides: the Charge ring, live heart, offline ownership.
3. **Bluetooth priming** — explains *before* the macOS Bluetooth prompt that nothing leaves
   your Mac; the connection is local BLE with no server in the middle.
4. **Wear & wake** — put the strap on (snug, sensor on skin), charge it, keep it within ~1 m.
5. **Scan** — a radar sweep; tapping **Scan** calls the BLE engine. If it hasn't bonded after
   ~12 seconds, a reassurance card appears explaining the strap won't show in System Settings,
   that only one host can hold it at a time (close the WHOOP phone app), etc.
6. **Bonded celebration** — a Charge ring blooms in when the strap bonds, with battery %.
7. **Profile** — age, sex, weight, height (feeds zones, calories and baselines). Shows your
   estimated max heart rate.
8. **Import (optional)** — points you to Data Sources; fully skippable.
9. **Done** — "Your thread starts here."

You can revisit pairing and profile any time from **Settings**.

---

## Control Center

**Sidebar: Today · works from imported data; live status shown in the sidebar.**

The home dashboard (`TodayView.swift`, titled "Control Center"). A tight, gapless grid:

- **Health alert banner** — the illness early-warning banner appears here when triggered (see
  [Illness early-warning](#illness-early-warning)).
- **Today's Synthesis** — the signature **Charge Ring** (HRV and resting HR underneath) beside
  a plain-English read-out ("Charge is strong and sleep was consistent.") and a state
  word (Depleted / Low / Steady / Primed / Peak). NOOP frames the day as an energy economy: you
  **wake with Charge**, **spend it as Effort**, and **rebuild it with Rest**.
- **Key Metrics** — a uniform tile grid, each with a 14-day sparkline: Charge, Effort
  (of 100), Rest (hours + efficiency), HRV, Resting HR, Blood Oxygen, Respiratory,
  Steps (on-device only for WHOOP 5/MG; on a 4.0, NOOP shows your imported Apple Health /
  Health Connect steps, because it can't yet read steps off the 4.0 strap over Bluetooth —
  the 4.0 itself does count steps in the official WHOOP app — and approximate),
  Weight, Calories. WHOOP metrics come from the `my-whoop` source; Steps/Weight/Calories/
  Respiratory pull from `apple-health`. Sparse series (e.g. weight) fall back to all history so
  a tile never shows empty when data exists.
- **Last Workouts** — up to six recent sessions as tiles (duration, date, avg HR, kcal).
- **Data Sources** — a footer showing whether WHOOP and Apple Health data are present, with day/
  session counts.

---

## Energy

**Reached via the ENERGY card in Control Center / Today (all three presentations) · works from
imported and strap data, no live connection needed.**

`EnergyCard.swift` / `EnergyDetailView`. One card, not several tiles — basal and active energy
would otherwise become two more Key Metric tiles that only ever move together.

- **The card** — total burned so far, and (once ≥10% of today has elapsed) a `~`-prefixed
  *projected* total extrapolated from the day's rate so far. Basal and active render as **shares of
  the total** (a bar each) once something has actually measured the day; with nothing measured yet,
  the card falls back to plain figures and a caption explaining that the basal number is your
  estimated resting rate, not a measurement. A quality caption appears whenever the day is only
  partly or mostly modelled — it stays silent on a solidly measured day so people don't learn to
  ignore it.
- **Everyday movement counts, not just workouts.** A walk sits well below the heart-rate threshold
  that used to be the only thing NOOP looked at, so an ordinary half-hour walk contributed *nothing*
  to your active energy. NOOP now also reads the strap's own step counter and its walk/run
  classification, and takes whichever reading is higher — so walking, stairs and errands show up,
  while a quiet-wrist effort like cycling or lifting still scores on heart rate as before. (Requires a
  WHOOP 5/MG, the only generation whose records carry a step counter; a 4.0 is unchanged.)
- **Where the number comes from — one source, never summed.** NOOP's own WHOOP-first estimate is
  canonical whenever it exists, topped up only with modelled basal for the hours the strap wasn't
  worn (never a full day's BMR, which would double-count worn time). Without a WHOOP estimate, it
  falls back to Apple Health's active+basal split, then Apple active energy with a modelled basal
  half, then a steps × body-weight estimate, and finally — with no measurement at all — your
  estimated basal rate alone. Two devices measuring the same body are **never added together**.
- **Energy detail screen** (tap the card) — the same card, plus:
  - **Data quality** — a terse lead-in ("WHOOP · 87 % captured · ±8 %") on a day with a real
    coverage figure to report, then the full breakdown: source, energy coverage % of the elapsed
    day, hours-with-movement %, estimated basal rate, the raw WHOOP model figure and its
    approximate uncertainty (±%), and calibration status.
  - **Calibration** — an **off-by-default** toggle. When enabled, NOOP compares your WHOOP estimate
    against time-aligned Apple Watch energy (Apple Watch only — never an iPhone or third-party app)
    and, once there is enough stable overlap (about a week of high-quality five-minute buckets),
    learns a small, bounded correction factor (×0.80–×1.20) applied to your **active** energy — your
    resting rate is never rescaled by it. WHOOP stays the measurement; Apple is a reference. Status
    reads **Off / Learning / Active / Paused**, with a **Reset** to discard a learned fit and start over.
  - **Adaptive expenditure** — a separate, retrospective average-kcal/day range computed from your
    imported calorie logs and weight trend (shown only once you have several weeks of reasonably
    complete intake logging and enough weigh-ins). This is explicitly **not** today's measurement
    and never calibrates or replaces the WHOOP figure — it's a second, independent way to sanity-check
    maintenance calories over time.
  - **Daily burn chart** — last 30 days of completed-day totals (today is excluded — it's still
    "so far", not a finished number).
- **Coach** — `get_energy_balance` (see [docs/fork/COACH.md](fork/COACH.md)) reports the same
  figures, including the adaptive comparison when available, and is explicitly told never to turn
  either number into diet or intake advice — NOOP holds no nutrition-recommendation logic.
- **Widget** — the iOS energy widget also carries the raw pre-calibration WHOOP figure, its
  uncertainty %, and the calibration factor, so the same honesty travels to the home screen.
- **Privacy** — the Apple Watch reference data used for calibration is a bounded, on-device,
  five-minute aggregate (kcal/HR/steps/distance/stride/workout flag per source) — never raw
  HealthKit samples, and never anything that leaves the device.

---

## Today (iOS)

**Tab bar: Today (first tab) · works from imported data; live status/battery in the header.**

iOS uses a bottom tab bar (`RootTabView.swift`: Today, Trends, Sleep, More) instead of macOS's
sidebar. The Today tab hosts one of three interchangeable home-screen presentations, picked under
**Settings → Appearance → Experimental**:

- **Liquid Today** (default, `LiquidTodayView.swift`) — a sky-gradient hero with three fluid,
  count-up "vessel" circles for Charge / Effort / Rest, a synthesis line ("Charge is strong and
  sleep was consistent") with day-scoped readiness pills, a scrubbable live/banked heart-rate
  thread, "Your Cards" (swipeable coach training suggestions), Key Metrics, Recovery Vitals, Last
  Workouts and Data Sources — the same content as Control Center, restyled.
- **Classic Today** (`TodayView.swift`) — the same screen macOS shows as Control Center (tight
  tile grid, no hero animation), reused verbatim as an iOS fallback. As of 2026-07-25 it has full
  functional parity with Liquid Today (design stays its own): reorderable/hideable sections over a
  shared saved order, a live heart-rate badge over the HR trend chart with a one-tap **Full day**
  link into the Deep Timeline, and Recovery Vitals as its own movable section instead of being fixed
  inside Synthesis.
- **Customize Today** (`TodayCustomizationSheet.swift`) — one editor behind every Today layout
  affordance on both Today screens, replacing the separate Arrange / Key Metrics / Your Cards sheets
  (upstream #940, adopted 2026-07-31). A **Shown / Hidden** list with drag-to-reorder, Cancel/Save
  over a draft so nothing is half-applied, and "Edit" rows that deep-link to the Key Metrics and
  Your Cards child pages. Every section is a row, the Coach banner included — drag it anywhere or
  move it to Hidden. The Key Metrics page also carries **Tiles per row** (2 or 3), **Detailed
  tiles**, and the trend window.
- **Heute** (`StrandiOS/Redesign/HeuteRedesignView.swift` and friends) — a from-scratch redesign on
  its own fixed green/blue/violet token set (`HeuteRedesignPalette`, independent of the selected
  chart style). **Its Settings toggle was removed (2026-07-25)** — the prototype never got past
  off-by-default/untested-on-a-real-strap, so `RootTabView` no longer reads its flag at all and the
  screen is unreachable. The code is left in place, not deleted, in case it's revisited later:
  - **Header** — a greeting + tappable date (opens day navigation; swiping the screen
    left/right also changes the day) and three status chips: **Activity status** (Active / Sick /
    Injured / On break, each with a duration — Today / 3 days / This week / Custom date / Until
    changed), strap **battery**, and **coach** entry.
  - **Rings** — Charge / Effort / Rest as three glow rings. **Charge is tappable** — even while
    calibrating or empty — and opens a breakdown sheet naming which drivers (HRV, resting HR,
    respiration, sleep quality, skin temperature) pulled the score up or down versus your personal
    baseline, with the same confidence tier (Calibrating / Est. / Reliable) the ring itself shows.
    Effort and Rest stay display-only.
  - **Card zone** — a fixed base card (today's readiness statement, or the current activity-status
    exception) behind a swipeable stack of the coach's real pending training-plan proposals; a
    swipe hides a card locally without declining the proposal, tapping one opens the full
    accept/modify/decline sheet.
  - **Vitals grid** — HRV, resting heart rate, blood oxygen, respiratory rate, Fitness Age, steps,
    and the day's workout as a tappable tile.
  - **Heart rate** — a live beat-by-beat trace (when connected) over the day's banked 5-minute
    trace, scrubbable by dragging along it.
  - **Journal reminder + Data Sources footer** — shown only on today, not on a navigated past day.

All three presentations read the SAME carry-over rules: an unscored today shows the last scored
night's Charge (labelled whose it is), a mid-calibration baseline shows "Learning your baseline,
N of 4 nights" instead of a stale number, and each vital falls back per-field to the freshest
prior reading independent of whether that night scored a Charge — so switching between the three
never changes what number you see for the same day.

---

## Updates inbox

**The bell, top of Today (Classic and Liquid alike) · `UpdateStore.swift` / `UpdatesInboxView.swift`.**

A calm, newest-first log of what's new — tap the bell (badged with the unread count) to open it. Three
kinds of row, each behaving differently rather than all looking like the same generic notification:

- **Needs a decision** — a session the coach proposed (see [docs/fork/COACH.md](fork/COACH.md) §11a), with
  **Accept / Change / Decline** right there. Once it's decided elsewhere (e.g. from the Today card
  first), the row shows the outcome instead of stale buttons.
- **A hint, nothing to decide** — release notes, "new data arrived" readings, and the coach's proactive
  nudges (a body signal worth knowing about, a small win) — tap to mark read, nothing else expected of
  you. Proactive hints used to be chat-only; they now show up here too, without needing to open Coach.
- **Status & reminders** — a Today info-card you swiped away, restorable with one tap ("Restore to
  Today"); everything else in this bucket is read-only history.

Old rows are deduped and capped so a background recompute loop can't spam the same "new data" row; items
still awaiting a decision sort to the top of their unread/read section. Everything here is local —
nothing about the bell's contents leaves the device.

---

## Live

**Sidebar: Live · needs a bonded strap for HR; the hardware-test surface.**

`LiveView.swift` is the real-time heart-rate screen and the pairing/diagnostics surface:

- A large **smoothed heart rate** (BPM) — NOOP shows a spike-filtered median over a ~10 s
  window, not the raw per-beat value, so it's stable. Recent **R-R intervals** (ms) are listed
  beneath.
- **Status grid** — battery %, last decoded frame type, last decoded event.
- **Controls**:
  - **Scan & Connect / Re-scan** — start or restart BLE scanning.
  - **Buzz strap** — fire a test haptic buzz (requires a **bonded** connection).
  - **Disconnect** — drop the connection.
- A scrolling **BLE log** of frames, events and actions — useful for confirming the strap is
  streaming.

Opening Live starts the realtime HR stream and requests a fresh battery reading; leaving it
stops the realtime stream (the lightweight standard HR keeps recording).

---

## Breathe

**Sidebar: Breathe · works visually without a strap; needs a bonded strap for haptic cues.**

`BreathingView.swift` / `BreatheScreen.kt` / `WatchBreatheView.swift` — an **HRV haptic breathing
biofeedback** trainer (NOOP's flagship novel feature), now also a **content-driven protocol
catalog**. Because the strap both *measures* HRV (from R-R intervals) and *buzzes*, NOOP can pace
your breath with a felt cue and watch your HRV respond in real time.

- **Pick a pace** from the in-place pill row:
  - Built-in: Relax 4-6, Coherence 5.5, plus a **catalog** of ANS protocols (Deep, Box 4-4-4-4 with
    holds, Diaphragmatic, Alternate Nostril, 4-7-8, Buteyko, Tummo, Ujjayi, Bhastrika, Qi Gong,
    Soma, Coherent 6-6, …) and **Presence Process** tempos (Regular / Mid / Punching Through —
    consciously connected breathing, no holds).
  - **Guided** entries (Kapalabhati, Holotropic, Wim Hof, Shamanic) give education + a session timer
    without an aggressive auto-pacer.
  - Locked **Resonance** pill still appears after a Resonance sweep.
- **Session length**: Open (until Stop) or **5 / 10 / 15 min** with auto-stop; defaults follow each
  protocol's recommended duration (e.g. Presence → 15 min).
- **ⓘ Protocol info** — background, session hint, and cautions (localized; non-clinical). Presence
  paces include a short Presence Process / CCB intro.
- **Start a session** — liquid vessel fills on inhale, holds steady on hold, drains on exhale; live
  BPM in the centre. Bonded strap: **one pulse on inhale, two on exhale** (holds are silent).
  Without a strap it's visual-only ("Visual only" pill).
- **Live readouts**: heart rate, rolling **HRV (RMSSD)**, and stage timing.
- **Coherence estimate** and **pre/post RMSSD outcome** unchanged (estimates, not clinical).
- Modes **Resonance** and **Calm me** stay on the existing mode strip.

Pure schedule math lives in `Packages/StrandAnalytics` (`BreathProtocol` / `BreathProtocolCatalog` /
`BreathProtocolPlayer`) with a Kotlin twin under `com.noop.analytics` — golden-vector tested.

Technique list and timing hints are inspired by publicly documented ANS breath protocols (including
[Ultrahuman's ANS breath protocols blog](https://www.ultrahuman.com/blog/harness-the-power-of-breath-protocols-for-your-autonomic-nervous-system/));
NOOP is not affiliated with Ultrahuman. Education copy is original. Presence tempos were measured
from public Presence Process guide audio.

A "Test buzz" button fires a single pulse (bonded only).

---

## Intervals

**Sidebar: Intervals · works visually without a strap; needs a bonded strap for haptic cues.**

`IntervalTimerView.swift` — a **silent haptic HIIT interval timer**. Train hands-free: the strap
buzzes every transition so you never look at the screen.

- **Configure** Work seconds (5–600), Rest seconds (5–600) and Rounds (1–30).
- A big glanceable **stage face**: WORK / REST / DONE, the current round, a countdown ring, and a
  total-session progress bar (elapsed / planned).
- **Haptic cues** (bonded strap): a strong triple-buzz into each WORK block, a short single buzz
  into REST, a 3-2-1 tick on the last seconds of each phase, and a long 5-loop buzz when the
  session finishes.
- **Start / Pause / Restart** and **Reset**.

With no strap bonded it still works as a large visual timer (without haptics), prompting you to
bond on the Live screen.

---

## Intelligence

**Sidebar: Intelligence · works from raw strap streams — live-collected or backfilled, no cloud.**

`IntelligenceView.swift` — NOOP's own Charge/Effort/Rest, computed on-device from the strap's raw
HR/HRV/motion streams using the WHOOP model shape, independent of WHOOP's own cloud scoring. Works
for any day NOOP holds raw streams for, not just days WHOOP itself scored.

- **Tomorrow's Charge** (evening only) — an *estimate*, not a measurement, from today's effort,
  your typical sleep, and your recovery baseline: "You'll likely wake around N ± band Charge if you
  sleep about H tonight." Explicitly labelled as a forecast; your real Charge is still scored from
  tomorrow's HRV when you wake.
- **How this works** — a plain explanation of the Charge weighting (HRV ~55%, resting HR ~20%, rest
  quality ~15%, respiration ~5%, skin-temperature deviation ~5%), Effort as a 0–21 (or rescaled)
  cardiovascular load from HR-zone time, and Rest staged from motion + heart rate.
- **By Day** — a lazily-rendered list of every recomputed day in the selected window, so an 800+
  day imported history stays responsive.

---

## Explore (Metric Explorer)

**Sidebar: Explore · works from imported data.**

`MetricExplorerView.swift` — a catalog of every signal, one tap deep. The root is a grouped list
(by `MetricCatalog` category); a faint trailing dot marks metrics with no recorded data. Tapping a
metric opens its **detail dossier**:

- A **W / M / 3M / 6M / 1Y / ALL** range control.
- A hero **trend chart** with the latest value and "as of *date*".
- A uniform stat row: **Average, Min, Max, Latest, and Δ vs the previous equal-length window**
  (tinted by whether the change is the "good" direction for that metric).
- **What correlates** — a cross-catalog Pearson scan over the visible window (|r| ≥ 0.30,
  n ≥ 10), top 6, each with an r-bar.

Sparse metrics (weight, body fat) auto-widen the window when the selected range holds no points,
and flag that they did, so you always see real data instead of an empty state.

---

## Compare

**Sidebar: Compare · works from imported data.**

`CompareView.swift` — overlay **2–4 metrics** from the catalog and read how they move together:

- Pick metrics from a grouped menu; selected metrics show as removable colored chips.
- A **W / M / 3M / 6M / 1Y / ALL** range control.
- A **normalized overlay chart** — each line min–max scaled to 0–1 within the window so different
  units share an axis. Hovering shows a crosshair and a tooltip with every series' **real** value
  on the nearest day; the legend lists each series' true min–max range.
- **How They Move Together** — every selected pair gets a live **Pearson r** with a plain-English
  conclusion ("When weight rises, Charge tends to fall — a moderate negative link.").

Sparse series auto-widen so they still overlay against dense ones.

---

## Insights

**Sidebar: Insights · works from imported data (needs WHOOP journal answers for behaviour effects).**

`InsightsView.swift` — "interrogate what affects what", in two halves:

1. **Behaviour Effects** — splits your logged WHOOP **journal** answers (Alcohol, Caffeine, Late
   meal, Meditation…) into days each behaviour *was* vs *was not* logged, then compares a chosen
   outcome (Charge / HRV / Rest / RHR) between the two groups. Each effect card shows a
   plain-English sentence, the with/without means and group counts, a **SIGNIFICANT / EXPLORATORY**
   pill, and an effect size (**Cohen's d**) with a magnitude word. Tint is sign-aware: a behaviour
   that moves the outcome the "good" way reads positive/green, the "bad" way reads red. Without
   journal data, NOOP explains how to start logging.
2. **Metric Relationships** — a curated set of **Pearson** correlations: Rest ↔
   Charge, HRV ↔ Charge, Resting HR ↔ Charge, and Charge → next-day Charge (1-day lag).
   Each is a one-line insight with r, a significance pill, an r-bar, and a strength/direction reading.

---

## What Moves You

**Sidebar: What Moves You (`insightsHub`) · works from imported data + your own journal/mood log.**

`InsightsHubView.swift` — the more advanced, personal sibling of [Insights](#insights): pure
association on *your own* logged days, explicitly never advice, diagnosis, or cause.

- **What moves your Charge / HRV / Rest / RHR** — a unified, **lag-aware** effect feed. For each
  logged behaviour it keeps the strongest honest lag (same day, +1, or +2 days), so a card reads
  "shows up the next morning" instead of pretending everything is same-day. Each card carries a
  sign-aware sentence, with/without means, a lead/lag chip, an effect-size word, and a **Solid /
  Building / Calibrating** confidence pill — never a bare "significant" stamp.
- **Dose-response** — a personal alcohol/caffeine curve (per drink/dose → Δ next-day Charge) that
  **shrinks toward a documented population prior** until enough of your own nights accrue, so it
  never overclaims from a handful of logged nights. States the current per-unit effect plainly
  (honest whether it's still prior-dominated or your own data has taken over), plus an evening
  "damage forecast" preview ("a 2nd drink tonight ≈ −N Charge tomorrow").

---

## Coach

**Sidebar: Coach · needs a configured AI provider (own API key or local model); everything else it
reads stays on-device. Fork-only — see [docs/fork/COACH.md](fork/COACH.md) for the full design.**

A chat coach that can see your NOOP data through a bounded set of read tools (biometrics, sleep,
workouts, stress, energy, goals…) and propose — never silently apply — training sessions and goal
setups for you to accept, change, or decline. Runs against a provider you configure yourself
(cloud API key or a fully local model); nothing about your data leaves the device unless you've
pointed the coach at a cloud provider and it's actively answering you. Persona/voice, memory,
safety gates around goal pacing, and the full tool list are documented in `fork/COACH.md`.

---

## Goal & Journey

**Sidebar: Goal & Journey · works from your own logged data; also reachable from the goal card on
Today. Fork-only — see [docs/fork/COACH.md](fork/COACH.md) §4/§6 for the full design.**

Set up to **five active goals** (run / consistency / sleep / strength / weight / custom) — entirely
optional, with a guided step-by-step first-run flow or a one-page quick editor, both saving through
the same store so neither can diverge. The **Journey** page tracks progress honestly: **no invented
percentages** — a measured percentage shows only when both a baseline and a target exist, otherwise
the page falls back to what's actually known (sessions completed, consistency, recovery trend), and
a five-minute-old goal correctly shows "nothing achieved yet" as a normal state. Milestones are
**facts, not a streak counter** (first week in, longest run, a real recovery uptrend) — nothing here
rewards a daily habit loop or penalizes a gap, since a streak mechanic would shame exactly the people
who get sick or travel.

---

## Lab Book

**Sidebar: Lab Book · your own manually entered readings; works fully offline.**

`LabBookView.swift` — a private logbook for the numbers you already get from a doctor or pharmacy
(bloods, blood pressure, body measurements), kept next to your wearable signals on this device.

- Add a reading by hand, or locally extract recognizable text from a selected PDF or photo of a lab
  report — extraction runs on-device.
- **Trend** — your own readings over time for a marker.
- **Compare with a signal** — the same restrained Pearson idiom as [Compare](#compare), showing the
  marker beside a NOOP signal in the days before each reading.
- **History** — every reading you've entered, editable.

**Explicitly non-clinical.** NOOP never asserts a clinical judgement — it never labels a reading
"abnormal/high/low/normal" itself; any reference range shown is exactly what you typed from your
own report, and correlation copy says "association, not a medical finding." A full disclaimer is on
the screen itself.

---

## Rhythm

**Sidebar: Rhythm · works from your most recent banked night; experimental, off by default.**

`RhythmView.swift` / `RhythmHost` — an experimental beat-to-beat visualization of your R-R
intervals during still, resting windows from your last banked night. Gated behind an explicit,
un-pre-checked consent screen naming exactly what it is before it shows anything.

**Explicitly not a medical device.** The standing, non-dismissible disclaimer on the screen itself:
*"Experimental wellness visualization: not a diagnosis, not an ECG, and not a medical device. It
cannot detect any heart condition. Beat-to-beat variation has many ordinary, benign causes."* Every
window is windowed into ~5-minute still, resting slices and scored descriptively — never as a
verdict — and the disclaimer points anyone worried toward a qualified professional, or emergency
services for an emergency. Everything is computed on-device.

---

## Sleep

**Sidebar: Sleep · works from imported WHOOP data.**

`SleepView.swift` — last night, read in two seconds — and **browse back through past nights**, not
just the most recent (step through earlier nights to compare):

- **Stage breakdown hero** — a **hypnogram** (reconstructed from stage durations) or, if intervals
  can't be reconstructed, a proportional stacked stage bar. Footer shows REM / Deep / Light / Awake
  each as "Xh Ym · NN%", with time-in-bed, efficiency, and onset–wake times.
- **Night detail** — a uniform tile grid, each with a sparkline and a "vs typical" caption: Sleep
  Performance, Efficiency, Consistency, Hours vs Needed, Restorative (deep + REM share),
  Respiratory, and Sleep Debt. Debt is 55% of the current unmet personalized need, carried into the
  next night's target; values below 10 minutes read as balanced instead of stacking into an
  unrepayable 14-night hours bank.
- **Stages vs typical** — Deep / REM / Light as horizontal bars, last-night minutes with a marker
  at your personal mean, so highs and lows pop.
- **Asleep duration** — a trailing-30-night hours trend with avg / min / max.

If no sleep sessions are imported, NOOP points you to Data Sources.

---

## Trends

**Sidebar: Trends · works from imported WHOOP data.**

`TrendsView.swift` — the longitudinal view ("the thread of you over time"):

- A **W / M / 3M / 6M / 1Y / ALL** range control (default 3M).
- A hero **Charge** chart with avg / peak / low / day-count.
- **Daily signals** — small multiples for **HRV**, **Resting HR** and **Effort**, each with
  mean / min / max.
- A **Charge year heat-strip** — a calendar of Charge scores across the past year (or all
  history on ALL), with a depleted→peaked legend.

Windows are taken relative to your latest recorded day and auto-widen on sparse data.

---

## Workouts

**Sidebar: Workouts · works from imported WHOOP and Apple Health data.**

`WorkoutsView.swift` — the activity log, threaded together:

- A **7D / 30D / 90D / 1Y / All** range control (auto-picks the tightest range with ≥2 sessions).
- **Summary tiles** — Total Workouts, Total Time, Total Calories, Total Distance, Most Active sport.
- **Activity Breakdown** — per-sport cards (sessions, time, kcal, avg per session), sport-specific
  icons.
- **All Sessions** — a uniform table: date/time, sport, duration, avg HR, kcal, distance, and a
  **source badge** (WHOOP or Apple) per row.

---

## Health Monitor

**Sidebar: Health · live HR needs a bonded strap; vitals come from imported WHOOP data.**

`HealthView.swift` — live vitals:

- **Live heart rate hero** — a streaming HR sparkline tinted by zone, with a zone pill, "% Max",
  your Max HR (from Settings) and a streaming/idle state. When the strap reports HR as 0, NOOP
  derives it from the latest R-R interval and notes "from R-R".
- **Vital Signs** — a tile grid from your most recent imported day: Respiratory Rate, Blood O₂,
  Resting HR, HRV and Skin Temp, each colored by whether it sits in a healthy range ("In range" /
  "Out of range").

With no live HR and no imported day, NOOP prompts you to connect or import.

---

## Stress

**Sidebar: Stress · works from imported WHOOP data.**

`StressView.swift` — a clear, single-number **Stress Monitor** (0–3) with a LOW / MEDIUM / HIGH
band and one plain-English line on *why*:

- Today's value is your **recorded daily stress score** if one exists; otherwise NOOP **derives**
  it transparently — comparing today's resting HR and HRV to your own 30-day baseline (higher RHR
  and lower HRV both push stress up), combining two z-scores and squashing onto 0–3 with a logistic
  curve (0 calm · 1.5 baseline · 3 high).
- A semicircular **gauge** (its own blue → mint → amber ramp, deliberately not the Charge traffic
  light), the band, and an explanation tuned to your RHR/HRV shifts.
- **Today's markers** — the stress value (with sparkline), Resting HR and HRV vs baseline (tinted
  toward stress or Charge), and "Calm time" (share of recent days in the LOW band).
- A multi-range **trend** chart.
- A **"How this is computed"** card laying out the exact method and band legend.

---

## Mind

**Sidebar: Mind · works from imported data; logs your own daily check-in.**

A quick **daily mood check-in** and a place to see how it tracks against your body's signals over
time:

- **Daily mood check-in** — log how you feel each day in a few taps. Stored on-device alongside
  the rest of your history.
- **Correlations** — once you've logged enough days, NOOP lines your mood up against your own
  **Charge, Rest, HRV** and other metrics, so you can see what actually moves it (e.g. "lower
  HRV days tend to read lower mood").
- **Non-clinical by design** — this is a personal self-reflection log, **not** a mental-health
  assessment, diagnosis or therapy. It never leaves your device.

---

## Devices

**Sidebar: Devices · pairing itself needs Bluetooth; the screen and paired-device list work without one.**

`DevicesView.swift` — pair and manage the bands NOOP reads from. **WHOOP-first**: the WHOOP is the
primary, fully-supported device; generic heart-rate straps (Polar / Wahoo / Coospo / Garmin HRM…)
are an early, in-development addition that streams live heart rate and HRV but not WHOOP's deeper
sleep/recovery data.

- **Add / manage devices** — an add-device wizard, and — with more than one paired band — a picker
  for which one supplies live data. Removing a device deletes its recorded data locally; re-pairing
  a strap pulls its recent history back.
- **Oura ring** (experimental, see [docs/OURA_PROTOCOL.md](OURA_PROTOCOL.md)) — paired locally; NOOP
  owns the ring while it holds the pairing key, and re-setting it up in the official Oura app hands
  ownership back.
- **Protocol-research probes** (advanced, WHOOP only) — read-only, user-triggered diagnostics for
  reverse-engineering unconfirmed BLE opcodes: an extended-battery-info probe, a body-location probe,
  a feature-flag lister, a device-config-value reader, a reboot-frame test (4.0 only, non-destructive),
  and an MG ECG-subsystem capture. Every probe sends nothing but the documented read-only command and
  logs the strap's raw reply; the reboot probe never risks data loss. **The ECG capture is explicit
  unvalidated instrumentation, not a medical measurement or a diagnosis** — the screen says so before
  it runs. See [docs/PROTOCOL.md](PROTOCOL.md) and [docs/BLE_REVERSE_ENGINEERING.md](BLE_REVERSE_ENGINEERING.md)
  for what each probe is investigating.

---

## NOOP Limitations

**Sidebar: NOOP Limitations · static reference, no data or connection needed.**

`NoopLimitationsView.swift` — a plain, honest capability grid: every metric NOOP surfaces, and
whether it's read **live** off a WHOOP 4.0 vs a 5.0/MG (full / partial-estimate-or-experimental /
not available). For example, skin temperature and steps are full on 5.0/MG but only a partial
estimate on 4.0; SpO₂% and blood pressure aren't available live on either generation. A legend
carries the three-state meaning so the table doesn't need per-row prose.

---

## Apple Health

**Sidebar: Apple Health · works from imported Apple Health data.**

`AppleHealthView.swift` — the per-source page for everything imported from the `apple-health`
source, read locally on this Mac:

- A **W / M / 3M / 6M / 1Y / ALL** range control.
- **Tiles**: Steps, Resting HR, HRV, VO₂ Max, Weight, Body Fat, Lean Mass, Asleep avg, Workouts.
- **Chart sections** — Heart & Vitals (resting HR, HRV, blood oxygen, respiratory rate), Activity
  & Energy (steps, active energy), Body Composition (weight, body fat, lean mass, BMI), and Sleep
  (asleep). Each chart has an avg / min / max / point-count footer.

Sparse weekly series (weight, body fat) auto-widen to all history so a short window is never empty;
a single reading is shown as a "Latest reading" value rather than an empty chart.

On iPhone, the same page also controls the live two-way HealthKit bridge. NOOP writes the strap's
24/7 heart rate as one measured minute mean per sample, associates those saved samples with matching
NOOP-authored workouts, and writes sleep stages plus nightly vitals. Apple Health's HRV type is
**SDNN**, so the bridge computes a separately cleaned/trust-gated SDNN from the night's R-R stream;
NOOP's own HRV tiles and Charge continue to use RMSSD. An on-device export diagnostic reports each
category's authorization, count and last result. Its reversible A/B check can compare 60-second HR
intervals with point-in-time minute samples on a physical iPhone when Apple's merged graph omits a
source even though Health's raw-data list contains it. The selected representation is applied to the
latest 14 days immediately and older exported history is migrated in resumable 14-day chunks on later
syncs. The diagnostic never changes source priority, which HealthKit does not expose to apps.

**Water and caffeine import themselves** (upstream #949, adopted 2026-07-31). A drink logged in
Apple Health — by a hydration app, a smart bottle, or by hand — lands in NOOP's hydration and
caffeine logs without being typed in twice. Both are **read-only**: imported entries keep their own
row and never overwrite what you entered yourself, and NOOP never writes either back. iPhone asks
permission once for the two new data types, including for users who granted Health access before
this version existed. The Coach's own `log_caffeine` tool writes through the same store, so a
chat-logged intake and an imported one appear side by side.

---

## Mi Band

**Sidebar: Mi Band · works from an imported Mi Fitness export.**

`XiaomiBandView.swift` — the per-source page for everything imported from the `xiaomi-band`
source, mirroring [Apple Health](#apple-health)'s layout: a range control, a tile grid, and chart
sections (including a last-sleep hypnogram), all windowed client-side against the newest imported
point rather than "now." See the import mechanics under [Data Sources](#data-sources) below and
[docs/DEVICE_SUPPORT_ROADMAP.md](DEVICE_SUPPORT_ROADMAP.md) for how the export is read (no
Bluetooth, no Xiaomi account, no cloud — NOOP reads the Mi Fitness iOS app's own on-device export).

---

## Data Sources

**Sidebar: Data Sources · the import hub. Everything stays on this Mac.**

`DataSourcesView.swift` — bring your history in once, then it's yours:

### WHOOP Export (CSV)
Import your full WHOOP history — recovery, strain, sleep, workouts — from a WHOOP data export
(`.zip` or unzipped folder). Works for WHOOP 4.0, 5.0 and MG. Get one from
*app.whoop.com → Data Management*. NOOP reports the records imported and the date span, and shows
how many days and sleeps are stored.

### Apple Health
Import an Apple Health export (`export.zip`) from *Health app → profile → Export All Health Data*.
NOOP **streams and aggregates** it locally — years of HR, HRV, sleep, SpO₂, steps, body
composition and more. Large exports take a minute or two.

### Nutrition (CSV)
Import a daily-nutrition CSV exported from **Cronometer** or **MacroFactor** to bring calories and
macros onto the same timeline as your Charge, Rest and HRV — so you can explore and correlate
food against how you feel. Parsed locally; nothing is uploaded.

### Xiaomi Smart Band (CSV)
Import a Mi Band's full history — no Bluetooth, no Xiaomi account, no cloud — by bringing NOOP a
zipped copy of the **Mi Fitness iOS app's own on-device export** (*Files → On My iPhone → Mi
Fitness → compress → share to NOOP*). Lands under its own `xiaomi-band` source, viewable on the
[Mi Band](#mi-band) page above. See [docs/DEVICE_SUPPORT_ROADMAP.md](DEVICE_SUPPORT_ROADMAP.md) for
what's decoded and the (researched, not yet built) live-BLE path.

### WHOOP Strap (Live BLE)
Shows whether the strap is bonded and streaming. Pairs directly over Bluetooth — no WHOOP app,
no cloud. Open **Live** to pair if it isn't connected.

All imports run on-device; nothing is uploaded. WHOOP data is stored under the `my-whoop` source
and Apple Health under `apple-health`, so per-source pages and cross-source consensus stay distinct.

---

## Backup & Sync

**Sidebar: Backup & Sync · works from a folder you choose; no in-app cloud account, ever.**

`BackupSyncView.swift` — the Apple mirror of Android's own backup screen: back up NOOP's whole
on-device database to a **folder you pick**, and restore from a snapshot in that folder. Point the
folder at an already-syncing Google Drive / iCloud Drive / Dropbox location for off-device sync
with zero in-app account. Backups are the existing `.noopbak` whole-database snapshot format.

- **Choose a folder**, or (iOS-only fallback, #52 — for the rare device where the system folder
  picker's Select button won't respond) use NOOP's own Files-visible folder instead.
- **Daily auto-backup** — runs on next launch (there's no background daemon), keeps a configurable
  number of the newest snapshots, prunes older ones, and warns if it hasn't run in a few days (a
  moved or disconnected cloud folder stops it silently otherwise).
- **Restore** — pick a snapshot from the folder (newest first) and confirm an explicit, destructive
  "Replace all data" prompt before anything is overwritten.
- **Honest about the format**: the screen states plainly that `.noopbak` snapshots are an
  **unencrypted** ZIP — if the chosen folder syncs to a cloud service, that readable file goes there
  too, so only point it at a service you trust.

---

## Your Data, Fused

**Sidebar: Your Data, Fused (`fusedRecord`) · works from whatever sources you already have; read-only.**

`FusedRecordView.swift` — the day's best-sourced value for each core metric, one screen. For every
metric it shows which source NOOP is using, a plain published reason ("counts directly" / "best
stager" — the same `MetricArbitrationPolicy` every screen already uses), and whether every
contributing source agrees, shows a minor delta, or conflicts. On a real disagreement, a
conflict-compare sheet lists **every** source's value side by side and which one NOOP picked and
why — **NOOP never silently merges or averages** two sources' readings for the same metric. With
only one contributing source, the screen shows a plain record with no provenance clutter. Wellness
framing throughout: a source is "higher-trust for this metric," never "correct" or "accurate."

---

## Notifications

**Sidebar: Notifications · needs a bonded strap to buzz; settings save without one.**

`NotificationSettingsView.swift` — choose which Mac apps tap your wrist, and how. Everything runs
on this Mac.

- **Wrist alerts** master switch (opt-in, **off** by default). A test buzz fires immediately
  (bonded only). Strap status mirrors the connection state.
- **Per-app control** — NOOP discovers installed, notification-capable apps via macOS
  (LaunchServices) and groups them: **Email** (Outlook, Mail), **Messaging** (WhatsApp, Messenger,
  Messages, Discord, Slack, Telegram, Signal), **Meetings & Calls** (Teams, Zoom, FaceTime), and
  **Calendar & Reminders**. Each app shows its real icon, an on/off switch, and a **buzz pattern**
  picker — **Single / Double / Triple / Long** — with a per-app test button.
- **Behaviour** — "Only buzz when worn", and **Quiet hours** (mute wrist alerts overnight, with
  a from/to time picker; default 22:00–07:00).

> Wrist *delivery* of macOS notifications is not live yet — it needs a small on-device watcher
> (coming in an update). Your per-app choices and patterns are saved now and apply automatically
> once delivery ships. Everything stays on this Mac.

---

## Automations

**Sidebar: Automations · needs a bonded strap to act/buzz; settings save without one.**

`AutomationsView.swift` — turn the strap's physical inputs and live biometrics into Mac actions
and haptic coaching, all on-device.

### Double-tap → Mac action
Double-tap the strap to trigger an action on this Mac. Pick one of:

| Action | What it does |
| --- | --- |
| Nothing | No action |
| Lock the Mac | Locks the screen immediately (falls back to a "Lock Screen" Shortcut) |
| Buzz back (confirm) | Fires a confirming wrist buzz |
| Mark a moment | Records a timestamped "moment" (with a confirming buzz) |
| Run a Shortcut… | Runs any macOS Shortcut by name |

A **Test action** button runs it without the strap. Recent moments are listed and can be cleared.

### Wear & presence
React when the strap comes off or goes on:

- **Lock the Mac when I take the strap off** — fires the moment the strap leaves your wrist.
- **Run a Shortcut when taken off** — presence automation (set a Focus, pause media, set away…).
- **Run a Shortcut when put back on** — reverse it when you return.

> macOS reserves true auto-*unlock* for Apple Watch, so this can **lock**, not unlock.

### Haptic coaching
- **Heart-rate ceiling** — choose either the highest allowed profile zone or a fixed bpm value, then
  monitor always while worn or only during a workout NOOP records. Profile-zone mode uses the exact
  automatic / custom-percent / custom-bpm bands entered under Settings, and shows the resolved bpm
  boundary before it is armed. The first smoothed sample at or above the boundary buzzes immediately;
  continuing breaches can use bounded standard reminders or one buzz every two seconds, and recovery is
  confirmed after a stable drop below it.
  It needs current live HR and a bonded, worn strap; it is a training aid, not medical monitoring.
- **Target-zone coach** — optionally choose Zone 1–5 when starting a recorded workout or Live Session.
  The picker shows the exact current profile BPM band. After eight stable seconds, one tap confirms the
  target, two light taps ask for more intensity, and three heavy taps ask you to ease off; outside reminders
  are capped at one every 30 seconds. The last selection is proposed next time, while new installs default
  to no coach. A configured heart-rate ceiling always has haptic priority.
- **Stress check-ins (haptic)** — offer a guided breathing check-in after a fresh HRV dip while
  you are still. Off by default, with optional auto-nudges, quiet hours, and your resonance pace.

### Smart alarm
Wake to a wrist buzz and an evening wind-down reminder — moved into its own **Alarms** sidebar
destination (#766) so it's one tap away instead of buried in this list. See [Alarms](#alarms) below.

---

## Alarms

**Sidebar: Alarms (`smartAlarm`, screen titled "Alarms") · the wake-alarm needs a bonded strap; the
wind-down nudge is a local notification and doesn't.**

`SmartAlarmView.swift` — one surface for both the strap's silent wake-buzz and an evening wind-down
reminder, after user reports conflated the two when they lived apart (#766).

- **Strap wake-alarm** — arms the strap's own firmware alarm to buzz your wrist at a chosen time
  (with a Monday-first weekday picker), even if your phone is asleep or NOOP is closed. Sends the
  exact command the official WHOOP app sends; confirmed buzzing on a real WHOOP 4.0 (community wire
  capture + on-device test, #535). On a WHOOP 5/MG it only arms with **Experimental mode** on
  (Settings), and even then a strap-driven wake on 5/MG is unconfirmed — the screen says so plainly
  rather than promising a wake it can't yet confirm.
- **Honesty card** — states up front that this is a **silent wrist buzz, not a sound**: a sideloaded
  build has no critical-alert entitlement, so it can't guarantee a loud wake — Focus or silent mode
  can still mute the backup notification NOOP also schedules. Keep your phone's own Clock alarm as a
  real backup; phone-based smart wake with light-sleep detection is an Android-only capability.
- **Strap-rejected warning** — appears only if the strap keeps reporting back a different alarm time
  than NOOP sent (usually a strap whose clock/alarm register has reset), with a concrete fix (reset
  in the official WHOOP app, or fully charge and reconnect).
- **Wind-down nudge** — a calm evening notification timed from your wake time and usual sleep need
  ("a suggestion, not an alarm"). If notifications are denied at the OS level, NOOP reverts the
  toggle instead of silently scheduling something that can never fire, and offers a direct link to
  Settings.

---

## Power saving

**Sidebar: Power saving · levers a connected strap's own sync cadence; the screen itself needs no live connection.**

`PowerSavingView.swift` — lifted out of Settings into its own destination so the strap-battery
levers are one tap away (#477); the controls and their behavior are unchanged, only their location.
The strap keeps recording regardless — these settings only change how often NOOP talks to it.

- **Power saving mode** (master toggle) — slows background strap-sync from every 15 minutes to every
  45 while the strap's battery is low (10–35%, adjustable). No data loss: the strap banks everything
  and sync just batches into larger, less frequent pulls.
- **Pause HRV capture** (sub-option, on by default once the master is on) — stops the always-on
  background HRV stream, the strap's single biggest continuous drain, while its battery is low. Live
  screen HR keeps working; HRV re-arms automatically once the strap is charged.
- **Low refresh** (sub-option, applies at *any* charge level) — background-syncs hourly instead of
  every 15 minutes. The single biggest saving on a WHOOP 4.0, since reconnections cost more than the
  sync itself. Pull-to-sync and live heart rate are unaffected.

---

## Illness early-warning

NOOP watches for the classic early-illness/strain signature on-device. It compares your last ~2
days against a ~28-day baseline (ending 3 days ago) for resting HR, HRV, skin-temperature
deviation and respiration. When **two or more** anomalies appear — e.g. resting HR up ≥5 bpm,
HRV down ≥20%, skin temp up ≥0.6 °C, respiration up — a banner appears on **Control Center**:
*"Your body looks strained — … Consider taking it easy."*

On a banner transition from clear to raised, NOOP also posts a **system notification** (at most
once per local day) so the warning reaches you when the window is closed. The toggle lives in
**Automations → Illness early-warning**. It is opt-in; enabling it can trigger the platform's
notification-permission prompt. It needs at least 14 days of history. On-device and approximate —
informational only, **not** a diagnosis.

---

## Settings

**Sidebar: Settings · always available.**

`SettingsView.swift`:

- **Profile** — age, sex, weight, height, and max heart rate (auto-estimated via Tanaka, or a
  manual override). These power your zones, calorie estimates and Charge baselines.
- **Heart-rate zones** — set where each of your five zones starts, instead of accepting the standard
  50/60/70/80/90 % of maximum. Two ways to say it: **% of max**, which moves with your maximum when
  it is re-estimated, or **beats**, the absolute heart rates a threshold or lactate test gives you,
  which stay put. Both keep whatever you typed in the other, so trying one costs nothing.
  Your bands change what you see — the live zone readout, a workout's zone split, the haptic "ease
  off" buzz — and the zones your coach prescribes in. They do **not** change your Effort score, which
  is measured against your heart-rate reserve on a published method with its own fixed thresholds, so
  your history stays comparable; nor zone bars that arrived inside a WHOOP export, which carry
  WHOOP's own bands.
- **Step calibration** — tune the stride/step estimate to your own walking so step and distance
  figures read closer to reality.
- **Units** — choose your preferred measurement units (metric / imperial) across the app.
- **Appearance** — card transparency, whether the coach tile pulses on Today, and **App icon
  colors** (on by default): recolors the leading icons across the app — the More tab, Chat and its
  submenus (Coach Settings, Coach Info, Goal & Journey), Journey, and Settings' own section headers —
  to an Apple Health-style palette instead of plain blue. Purely cosmetic — chevrons, checkmarks and
  state icons (e.g. bell vs. bell with a badge) are unaffected either way. Also here: chart colours
  (Apple Health palette by default) and the day-cycle sky backdrop / "sky behind cards" (both off by
  default).
- **Strap** — connection status, battery, and Re-scan / Disconnect controls.
- **Export for Shortcuts (iOS)** — a **HealthKit-free** path that hands your NOOP metrics to Apple
  Health via the Shortcuts app, so an anonymous build (with no HealthKit entitlement) can still get
  data into Health on your terms.
- **About** — version, the "all your data, none of the cloud" note, a **medical disclaimer**, and
  attribution to the community protocols NOOP is built on.

---

## Menu-bar item

NOOP lives in the macOS menu bar (`MenuBarContent.swift`). The label is a zone-tinted heart dot
plus the live HR (or "—" when not streaming). Clicking it opens a compact popover: a Charge
ring, the live heart rate, battery / resting HR / HRV, and quick actions to start/stop the live
feed, refresh battery, scan/reconnect, or disconnect.

---

## Support

**Sidebar: Support · always available. NOOP is free and always will be.**

`SupportView.swift`:

- **Built on** — credit to the community interoperability projects NOOP stands on.
- A reminder: **not affiliated with WHOOP; interoperability software for your own device and
  data; not a medical device.**

---

## Privacy & data ownership

- **Offline by design.** NOOP talks to your strap directly over Bluetooth Low Energy — there is
  no server in the middle. No account, no sync, no cloud.
- **On-device storage.** All history (imported and live-captured) is stored locally in SQLite
  via GRDB.
- **Your data is yours.** Imports happen once and stay on this Mac; nothing is uploaded.
