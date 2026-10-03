# Liquid Today redesign

Status: product decisions approved on 2026-10-02. Implemented on branch `codex/liquid-today-redesign`
on 2026-10-02: stages 2 to 8 (rings, motion, accessibility, hero, Today composition and surfaces,
Energy, Explore). Open: the stage 9 QA matrix (screenshot set, accessibility sizes, physical iPhone
for motion, frame pacing and energy impact) and the shared Classic fixes listed under Key Metrics.

Tuning decided with the user after the first device look (2026-10-02): the rings follow the approved
reference more literally (eight soft lobes, band of crossing filaments, bloom, interior particles
rising with the value), plus small wandering local swells; Effort gains extra glow and breath depth
from Moderate (6/21) up, never extra tempo; the breath is gentle (brightness about ±22 %). Later the same day the rings grew with the phone: each is drawn
1.08 times its third of the hero row (clamped 100 to 150 pt, about 127 pt on a 17 Pro, 141 pt on a 17 Pro
Max) instead of a fixed 108 pt, while its layout and tap target stay inside its own third.

This document is the canonical implementation specification for the Liquid Today redesign. It
replaces the earlier session plan under `docs/superpowers/specs/`. When code, chat history, or a
handoff disagrees with this specification, verify current behaviour in source and then preserve the
approved product decisions here unless the user explicitly changes them.

`Analysis migration required: no`

The work changes UI, motion, navigation, and display preferences. It does not change scoring,
stored metric meaning, source precedence, aggregation windows, or
`IntelligenceEngine.currentAnalysisRecipeVersion`. The checkout is Apple-only; no Android twin is
required.

## Outcome

Replace Liquid Today's filled liquid vessels with a single prominent hero containing three organic
waveform rings for Charge, Effort, and Rest. Complete the surrounding Today cleanup so the rest of
the dashboard reads as one restrained system rather than a stack of strongly outlined widgets.

The new hero replaces the old one directly. Do not ship a user-facing preview switch, experimental
toggle, or hidden renderer fallback. Remove obsolete hero rendering code after the replacement is
integrated and verified. Classic Today, Trends, and Overview remain available dashboard fallbacks.

Generated concept art is a style reference only. Acceptance uses screenshots and interaction tests
from the built app at real iPhone aspect ratios.

## Visual references

- **Approved hero direction:**
  [`design/references/liquid-today-organic-rings.jpg`](design/references/liquid-today-organic-rings.jpg).
  Use its organic waveform contours, fine internal particles, smoke, glow, delayed echoes, and clear
  value hierarchy as the target language. Adapt its example values and scales to NOOP's real data and
  the rules in this document.
- **Current-app evidence:** the sixteen local QA screenshots taken on
  2026-10-02 (kept outside the repository; paths in the local handoff) cover the real Liquid Today scroll,
  Energy, Last Workouts, Recovery Vitals, Your Cards, Key Metrics, Explore/Show All Metrics, Light,
  Dark, transparency, tab-bar overlap, and the original filled vessels. Inspect the full series before
  changing layout; do not judge only the top of the dashboard.
- **Rejected intermediate mockups:**
  (two local generated images, kept outside the repository) are context, not targets. Their four-phone presentation made the iPhone screens too narrow, they did
  not supply an acceptable Light variant, the light attempt lacked text contrast (especially its first
  screen), and their ordinary arc rings lost the liquid concept. Do not reproduce those mistakes.

## Approved visual behaviour

### Stable geometry

- The three rings are equal peers inside one hero surface. Their hit targets are independent and
  route to the existing Charge, Effort, and Rest destinations.
- Mean diameter and centre never translate, rotate, or drift. Only the radial contour deforms.
- The value stays crisp, neutral-coloured, and above every visual layer.
- Each ring leaves a quiet central zone around its value. Particles remain contained inside the ring.
- Use time-coherent seeded noise. Do not create unrelated random geometry on each frame and do not
  use Swift `hashValue` for deterministic seeds.
- Particles drift slowly through small local currents. They do not orbit as a group and never read as
  confetti.
- Smoke and one to three delayed echo contours add depth outside the principal contour.
- The three rings share one render clock but use de-phased deterministic seeds so they do not pulse
  in lockstep.
- A normal value change morphs over roughly one second. With Reduce Motion, the new number and static
  visual state appear without count-up or morphing.

### Value-to-intensity mapping

Interpolate smoothly between these anchors rather than jumping between five discrete presets:

| Normalised value | Particles | Wave and pulse | Echoes |
| --- | --- | --- | --- |
| 0-20% | very sparse | nearly smooth | 0-1 |
| 20-50% | sparse | gentle | 1 |
| 50-80% | clearly present | lively but calm | 1-2 |
| 80-90% | dense | strong in several local zones | 2 |
| 90-100% | very dense and fine | strongest soft pulse | 2-3 |

The final decile is a nonlinear visual peak. A value of 94 must be substantially fuller, brighter,
and more active than 82 without flashing or becoming frantic. Higher values increase fine-particle
density, glow, smoke presence, echo strength, and local radial amplitude; they do not increase global
translation.

Effort geometry is scale-independent. Normalise from the stored `0...100` value, then format the
number according to the existing `0...21` or `0...100` preference. `8.4/21` and `40/100` therefore
produce the same visual intensity.

### Colour semantics

Charge uses the existing canonical `ChargeBand` and `StrandPalette.chargeRingColor`:

| Charge | Colour family |
| --- | --- |
| `<25` | red |
| `25..<50` | orange |
| `50..<70` | yellow |
| `70..<88` | yellow-green |
| `>=88` | green |

Apply the resolved Charge colour to contour, particles, smoke, echoes, and glow. Semantic Peak begins
at 88; the extra animation peak begins at 90. Effort remains orange and Rest remains violet/indigo;
their colours do not imply good or bad. Text remains neutral. Values, units, accessibility labels,
and detail content carry meaning independently of colour.

### Missing and loading states

All three positions remain stable while data loads or is absent. A missing value shows `-` inside a
neutral, almost motionless contour. It is neither removed nor rendered as a low or bad score. On first
load, show the neutral state immediately and morph to real data when available; do not introduce a
competing shimmer.

## Device motion and animation ownership

Extend the existing ref-counted `LiquidMotion` owner. Do not add a second sensor owner.

- Add a lock-protected two-dimensional gravity/attitude snapshot and a smoothed movement impulse while
  preserving the scalar tilt API used by existing liquid primitives.
- Slow tilt biases particle drift, smoke, and echo distribution in the real gravity direction.
- Faster movement creates a clamped, damped counter-impulse at the contour and then settles.
- All rings observe the same physical direction while their seeded local response remains distinct.
- Motion never moves the number, centre, average diameter, or hit target.
- Add a display-only `React to device movement` preference, default on. It affects only the new hero;
  autonomous breathing continues when it is off.
- `NOOP Quiet Motion` remains the global animation control. Reduce Motion, Quiet Motion, Low Power
  Mode, backgrounding, an inactive tab, or an off-screen hero stops sensor updates and live frames.
- On macOS the rings keep their quiet autonomous animation but have no phone-motion response.
- Motion samples remain ephemeral and on-device; do not persist or export them.

Target a stable 60 frames per second while the hero is visible and active. Use one hero clock rather
than three independent 60 Hz loops. Under pressure, reduce smoke resolution, particle count, and echo
quality before compromising the number, primary contour, or interaction. Do not target 120 Hz.

`OrganicScorePreparation` prepares fixed seeded phases, swell parameters, filament attributes and
particle attributes once per ring seed. Each rendered frame prepares its breathing, active swells
and motion quantities once; lagged filament and echo frames reuse these quantities across their
sampled points. The Canvas also reuses fixed angle/sine/cosine grids. Full quality uses 256 contour
points rather than 192 for finer edges; radius, particle count, brightness and animation timing stay
the same. Scalar geometry is compared with the original model across values, motion and morphs.

`Tools/organic-ring-benchmark.swift` compares the original 192-point geometry, prepared 192-point
geometry, and prepared full-quality geometry over 180 frames of all three rings. Compile with
`swiftc -O` alongside `ChargeBand.swift`, `OrganicScoreMotion.swift`, `OrganicScoreVisualModel.swift`
and `OrganicScorePreparation.swift` from `Packages/StrandDesign/Sources/StrandDesign/`. Its timings
exclude Canvas drawing, GPU blur/compositing and SwiftUI updates; they are not iPhone CPU or battery
measurements. Analysis migration required: no — presentation only.

The local macOS `-O` comparison on 2026-10-03 (median of five interleaved runs, three rings at
20/94/100, 180 frames, fixed tilt/impulse) measured 41–50% less geometry time at 192 points and
25–40% less at the shipped 256 points, compared with the original 192-point path. These are
geometry-only measurements; full renderer cost and iPhone energy use require device profiling.

## Surfaces, themes, and system fallbacks

- Keep one visually dominant hero. Other sections use restrained tonal fills, spacing, and dividers;
  remove repeated strong blue rims.
- In Light Mode the hero is a light card like the rest of the page, with dark numbers and labels
  (changed on 2026-10-02 after the final mockups; the earlier rule was a dark optical chamber in Light
  too). Dark and graphite keep the dark optical chamber for the luminous rings.
- The hero always retains an adaptive minimum contrast layer. A card-opacity setting of 0% may soften
  the surface (the light fill never drops below 72%) but may not make values, smoke, or controls
  illegible on light or custom backgrounds.
- Support the existing Light and graphite Dark appearances plus black/plain backgrounds. Do not add a
  fourth global True Black appearance in this project.
- Restrict native iOS 26 Liquid Glass to appropriate container, navigation, control, and search
  surfaces. Ring geometry and particles remain identical on iOS 17 and later. Reuse the existing
  material and opaque fallbacks, including Reduce Transparency and Increased Contrast.
- Keep the native tab bar. Replace Today's fixed bottom spacer with system-aware content margins so
  every final control scrolls above normal and minimised tab bars.

## Today content and defaults

The new default order contains:

1. Hero.
2. Momentum when it has content.
3. Goals when they have content.
4. Key Metrics.
5. Compact Energy summary.
6. Last Workouts when history exists.
7. Your Cards.

Recovery Vitals remains a supported, editable section with HRV, resting heart rate, and respiration,
but is hidden for new or otherwise untouched layouts. Preserve the visibility and order of every
layout the user has explicitly customised. Live Heart Rate appears only as a compact temporary section
while a live connection actually exists. Remove Data Sources from Today; its existing management
route remains available elsewhere.

Optional sections with no content are not rendered. For automatic Key Metrics, hide entries without
values. A metric the user explicitly selected or pinned remains visible with `-`. The three fixed hero
positions are always visible regardless of data.

### Key Metrics

- Use two columns by default in Liquid Today, keep three as an option, and use one column for
  accessibility sizes.
- Prevent clipped labels and keep explicitly selected empty metrics after populated metrics.
- Remove Calories from Liquid Today's fresh default because Energy already presents it, and (2026-10-03)
  Charge, Effort and Rest because the hero rings show them directly above. All stay available in the
  editor; an explicit selection is never rewritten.
- (2026-10-03) Tiles rest on a neutral surface with the metric colour on the icon and bar. Vitals with
  no 0…max scale (HRV, resting HR, SpO₂, respiration) draw no bar; the scores and steps keep theirs.
- Apply shared component bug fixes, accessibility improvements, safe-area fixes, missing-Effort
  behaviour, and performance improvements to Classic where appropriate. Keep Liquid-specific defaults,
  composition, surfaces, columns, and ring animation out of Classic.

### Energy

Use a compact Today summary for total, basal, active, projected, and confidence. Restyle the existing
Energy detail without changing its source, estimation, calculation, provenance, or no-minute-curve
fallback. Shared Energy components may receive neutral correctness and accessibility improvements;
the compact Liquid composition remains specific to Liquid Today.

### Last Workouts

Use one grouped card with dividers and the five newest workouts. Each row opens its workout detail;
`All` opens the complete chronological workout history. Missing Effort is shown as unavailable and
does not draw a fake zero-length progress bar.

### Recovery Vitals and Your Cards

Recovery Vitals remains available but uses the default-hidden rule above. A fresh/default Your Cards
selection contains Stress, Fitness Age, and Vitality. Preserve every explicit existing card selection.

### Explore / Show All Metrics

- Preserve Deep Timeline as the leading action and keep it visible during search and filtering.
- Add search and an `All` / `With Data` filter. Default to `All` and remember the user's last filter.
- Add collapsible categories. They start expanded, then persist each category's state.
- Searching temporarily expands matching categories; clearing search restores their prior states.
- Keep compact grouped rows, source chips, and existing metric navigation.
- Continue using the cheap `nonEmptyMetricIDs` probe. Filtering must not load every time series.

## Preference compatibility

Treat the current saved configuration as user-owned:

- New defaults apply only when the corresponding Liquid layout or selection has never been customised.
- Never rewrite an explicit section order, visibility choice, Key Metrics selection, column selection,
  or Your Cards selection.
- Shared preference types currently serve Classic and Liquid. Introduce the smallest style-specific
  default distinction needed; do not silently migrate Classic to Liquid's layout.
- The motion-response preference is independent of Quiet Motion and changes display only.

## Accessibility contract

- Each ring is one VoiceOver element and action with metric name, formatted value and unit, state,
  provenance when applicable, and its existing destination. Avoid duplicate announcements from the
  ring and its visible label.
- Charge state must remain understandable with Differentiate Without Color.
- Reduce Motion produces a static contour and immediate value updates. Reduce Transparency and
  Increased Contrast preserve legibility.
- Search, filters, collapsible categories, and their expanded states expose the correct traits and
  maintain useful focus when results change.
- Verify Bold Text, accessibility Dynamic Type, narrow devices, and sufficient independent hit areas
  for all three rings.

## Implementation map

Primary files and seams to verify before editing:

- `Strand/Liquid/LiquidTodayView.swift`
- `Strand/Liquid/LiquidCore.swift`
- new `Strand/Liquid/OrganicScoreRing.swift`
- new `Packages/StrandDesign/Sources/StrandDesign/OrganicScoreVisualModel.swift`
- `Packages/StrandDesign/Sources/StrandDesign/TodayComponents.swift`
- `Strand/Data/TodayLayoutPrefs.swift`
- `Strand/Data/KeyMetricPrefs.swift`
- `Strand/Screens/DashboardCards.swift`
- `Strand/Screens/EnergyCard.swift`
- `Strand/Screens/EnergyDetailView.swift`
- `Strand/Screens/EnergyHeroCard.swift`
- `Strand/Screens/EnergyBurnRateCard.swift`
- `Strand/Screens/EnergyCalculationView.swift`
- `Strand/Screens/MetricExplorerView.swift`
- `Strand/Screens/SettingsView.swift`
- `StrandiOS/App/RootTabView.swift` only if shell-level safe-area work is necessary

Reuse the existing hero routing, provenance resolution, Effort formatting, `ChargeBand`, Glass
fallbacks, `nonEmptyMetricIDs`, energy model, workout history route, `TodayLayoutPrefs`, and
`LiquidMotion`. Current source is authoritative; update this map if names or ownership have moved.

## Execution sequence

Work on one feature branch and one coherent redesign PR, using logical commits and the checkpoints in
the next section. Every numbered stage ends in a compiling or testable state even though full app
verification is intentionally batched.

1. **Document and baseline.** Confirm the current layouts, saved-preference semantics, routes, shared
   Classic consumers, and existing relevant tests. Record baseline screenshots from the current app.
   Completion: every touched shared preference/component has an explicit Liquid-versus-Classic rule.
2. **Pure visual model.** Add clamping, intensity interpolation, deterministic seeds, Charge colours,
   Effort scale equivalence, no-data state, motion inputs, and quality levels without SwiftUI frame
   ownership. Completion: focused StrandDesign tests pass.
3. **Renderer.** Build the organic contour, particles, quiet centre, smoke, echoes, static fallback,
   and one shared timeline. Completion: preview/test harness covers `nil`, 20, 50, 80, 90, 94, 100 and
   contains particles without overlapping the value.
4. **Motion and accessibility.** Extend `LiquidMotion`, add the preference and gates, wire Reduce
   Motion/Transparency/Contrast, and supply complete semantics. Completion: deterministic motion tests
   pass and inactive states stop both frames and sensor ownership.
5. **Hero replacement.** Integrate all three rings while preserving routing, formatting, provenance,
   state resolution, and day behaviour; then remove obsolete hero renderer code. Completion: focused
   `StrandTests` pass and an incremental `NOOPiOS` build succeeds.
6. **Today composition.** Apply surfaces, defaults, Key Metrics rules, section inventory, five-row
   workouts, Recovery/Your Cards behaviour, live-HR condition, and safe area. Completion: saved custom
   layouts remain byte-for-byte semantically equivalent after decode and both Liquid and Classic tests
   pass.
7. **Energy.** Add the compact Liquid summary and restyle the detail without changing any values or
   data-selection logic. Completion: existing Energy tests remain output-identical.
8. **Explore.** Add search, remembered filter, persisted collapse state, and compact grouped rows while
   keeping Deep Timeline and cheap availability probing. Completion: pure filtering/state tests pass.
9. **Current-app QA.** Run the full grouped verification and capture the required screenshots on the
   built app. Completion: the Definition of Done below is satisfied with no generated mockup used as
   evidence.

New visible strings must be added to the String Catalogs and translated according to
`docs/FORK_GUIDE.md` before their checkpoint is considered complete.

## Batched verification strategy

Commits are logical savepoints, not full-build boundaries. Do not clean and rebuild after every commit.
Reuse DerivedData and run the smallest relevant checks while developing.

1. After the pure visual model: run its focused StrandDesign tests only.
2. After renderer plus hero integration: run focused package/app tests and one incremental `NOOPiOS`
   build.
3. After the full Today composition: run relevant `StrandTests` and incremental builds for both
   `NOOPiOS` and shared macOS `Strand`.
4. After Energy plus Explore: run the complete affected automated suites, the localization audit, and
   both app builds.
5. At the end: perform the full visual/accessibility/device matrix once.

Use a clean build only to diagnose a suspected cache problem or for the final release gate. App-target
Swift must be built locally before push; package tests alone do not compile these views. Ensure enough
free disk space exists before starting Xcode builds.

## Automated coverage

Add focused tests for:

- clamping and monotonic visual intensity;
- a distinct nonlinear `90...100` tier;
- deterministic, platform-stable particle seeds;
- particle containment and the quiet centre;
- motion smoothing, clamps, damping, and shared direction;
- all static gates, including Reduce Motion and Low Power Mode;
- Effort scale equivalence;
- Charge band boundaries, leaving existing `ChargeBandTests` authoritative;
- new preference defaults without rewriting customised layouts;
- empty automatic versus explicitly selected metrics;
- five-workout grouping and missing-Effort presentation;
- Explore filtering, remembered filter, collapse restoration, and cheap availability reads;
- accessibility labels/actions and no duplicated ring announcements where practical.

Protect existing `KeyMetricPrefsDecodeTests`, `LiquidChargeCarryTests`, `TodayLayoutPrefsTests`,
`TodayHeroRingLayoutTests`, `QuietMotionCoverageTests`, Charge tests, and contrast/chrome/legible-text
tests. Update exact test names if source inspection shows they have moved.

## Manual acceptance matrix

Test the built app, not only previews:

- Hero values: `nil`, 0, 20, 50, 80, 89, 90, 94, 100.
- Both Effort scales and every Charge band boundary.
- Light with the light hero card, graphite Dark, and black/plain background.
- Card opacity 0/30/70/100%, plain/sky/custom backgrounds.
- Reduce Transparency, Increased Contrast, Differentiate Without Color, Bold Text, Reduce Motion,
  Quiet Motion, and accessibility Dynamic Type.
- Narrow and wide iPhones; normal and minimised tab bar; complete scrolling through Today and Explore.
- No strap, unsynced, estimated, carried, partial, and complete data.
- Search, `All`/`With Data`, category restoration, Deep Timeline, workout `All`, and every ring tap.
- At least one physical iPhone for gravity response, impulse settling, scroll interaction, Low Power
  Mode, background/foreground transitions, frame pacing, and energy impact.
- macOS compilation and quiet autonomous fallback.

Capture a final screenshot set from the real app for narrow and wide iPhones across Light, graphite,
black/plain, and opacity 0/30/70/100. Capture close views of `nil`, 20, 50, 80, 90, 94, and 100. A
single device need not contain all values simultaneously; use controlled debug fixtures that exercise
the real renderer and layout.

## Definition of Done

- The old Liquid hero is gone and the new hero is the default without a feature flag.
- Every approved Today, Energy, workout, and Explore behaviour above is implemented.
- Saved user customisations survive unchanged; fresh defaults match this specification.
- Static and accessibility fallbacks convey the same data without relying on motion or colour.
- The renderer meets the visibility/lifecycle gates and remains smooth on a physical iPhone.
- Focused and full checkpoint tests, localization audit, `NOOPiOS`, and `Strand` builds succeed.
- The real-app screenshot set is reviewed against the supplied concept and original QA screenshots.
- Related current-behaviour documentation and `docs/fork/decisions.md` are consistent with the shipped
  result.
- The PR/release note says `Analysis migration required: no`.

## Out of scope

- Scoring or analysis changes, recipe migrations, database migrations, source precedence, or energy
  estimation changes.
- Rewriting explicit user customisations.
- A global True Black appearance.
- Android, widgets, complications, watch surfaces, or expensive background animation.
- A permanent selector between old and new Liquid heroes.

### Today control and empty-state follow-up (2026-10-03)

The plus remains the quick-action symbol and sits outside the profile button. “Customize home” is a
separated final menu item on iOS and opens the existing draft editor after dismissal. The macOS bottom
entry remains because the iOS quick-action shell is not available there. Populated Momentum keeps its
normal card-opacity behavior; the all-dismissed fallback is only an unfilled text link. The broad
“Show all metrics” row uses the shared card opacity and muted text.

Effort uses one day-gated readout for its hero, tile and tapped detail; explicitly missing values cannot
fall back to the last historical series point. Live scoring is read independently of the full dashboard,
with one supplied timestamp and a two-minute foreground retry for raw-HR arrivals that do not change a
cached daily row. The duplicate temporary scoring window was removed; the existing canonical LiveEffort
window and scoring remain unchanged. Missing Effort draws a static faint orange contour/bloom, weaker than
the first computed band, with the same "–" centre every empty ring uses (2026-10-03). Analysis migration required: no.

### Key Metric notes, settled ring numbers and the Training Load card (2026-10-03)

Score rings remember the number they last showed for the life of the process (`OrganicScoreShownMemo`),
so scrolling back or returning to the tab no longer replays the count-up; it plays once per launch and
then only when a value changes. The Sleep screen's ring keeps its own memory.

Key Metric notes, all without a caption except weight: Charge (own scored day only), Rest, HRV, resting HR
and respiratory rate show their delta against the 30-day personal normal, coloured only beyond one
standard deviation. Effort, steps and calories build through the day, so today shows the neutral 30-day
average ("Ø 8.400") and only finished days get a delta (steps coloured, Effort and calories neutral).
Weight shows its change over 30 days, always neutral. SpO₂ lost its note (it read "±0" nearly always) and
skin temperature keeps its own deviation reading. In three columns the chip leads the caption line
instead of squeezing beside the number; VoiceOver reads the chip through the tile's value.

The Training Load card (`TodaySection.trainingLoad`, under Key Metrics by default, also in classic Today)
shows strength and cardio as one four-segment scale each (below, usual, higher, well above usual), only
the current segment tinted, a dot at the lane's position on its personal edges, the lane's verdict word,
and one recovery line. It reads `TrainingLoadModel.snapshot`, the read the Training Load screen and the
Coach use, caches it for five minutes, leaves out lanes with nothing logged, and opens Training Load.
Analysis migration required: no.
