# Forge parity: the new iOS design on Android

Goal (owner, 2026-11-09): when the new design is done, iOS and Android show the same screens in the same
design. This file lists what Android has, what it lacks, and the order of work. Started 2026-11-09.

Since 2026-11-10 the new design sits behind the same Lab switch as on iOS, "New design (preview)" (`noop.forgeDesign.preview`,
`ForgeDesign.kt`), off by default. Off, Android shows the shipped Forge tabs; on, everything below.

iOS source: `StrandiOS/Forge/*`, `Strand/Forge/*` (timeline, coach notes, weekly), `StrandiOS/App/RootTabView.swift`.
Android source: `android/app/src/main/java/com/noop/ui/forge/*`.

## Shell

| | iOS (new design) | Android (Forge) | Gap |
|---|---|---|---|
| Tabs | Today, Training, Sleep, Health, Coach (search-role tab, only with the coach on) | the same, behind the Lab switch (`ForgeDesign.tabs`), with iOS's symbols (2026-11-11); the coach as a round button beside the bar | Android's bar floats as a capsule, iOS's spans the width |
| Settings | the profile picture in each tab's header | the profile in the Today, Training, Sleep and Health headers opens the More page over the tabs, with Settings, the strap and every page | iOS opens a profile hub, Android the More page |
| Search | magnifier in each tab's header (`ForgeSearchView`) | a magnifier in the Training, Sleep and Health headers opens the More page with its search focused (2026-11-11) | iOS's search is a sheet of its own; Android's is the More page's field |

## Today

| Part | iOS | Android | Gap |
|---|---|---|---|
| Header | "Today" with the date, strap, plus, profile | in the new design "Today" and its date on one line, profile and quick actions, no wordmark (2026-11-11) | no strap button of its own (the battery sits in the quick actions) |
| Rings | three organic rings in one chamber with the day's answer under them; holding them arranges the tiles | `Hero` with organic rings; holding a ring arranges the tiles (2026-11-10) | the answer line, which iOS shows only while Charge is carried from an earlier day; Android's Forge hero has no carried state yet |
| Hint | one most-pressing hint (`ForgeTodayHint`) | the activity prompt and the morning suggestion; pills and Momentum are gone from the new Today (Momentum is a tile) | the hint card, which needs the timeline's notices and coach notes |
| Tiles | a free grid of measure and picture tiles, three sizes, moved by drag in edit mode, two or three to a row (`ForgeTodayWidgets`) | `ForgeTodayWidgets.kt` (2026-11-10; tiles per row and iOS's tile look 2026-11-11): measures from the Key Metrics reading, sleep from the latest night, and the cards Training load, Goals, Energy, Latest workout, Cycle, Momentum, Live heart rate; three sizes, moved by drag in edit mode (2026-11-11), by arrows and accessibility actions, gallery | no water, last night, week plan, coach note, AgeLess, tonight, next session, what changed, what works, breathe, strap or stress tiles |
| Timeline | the day as a time rail: coach notes, workouts, walks bundled, wake, naps, weigh-ins, logs, ECG, notices, the day's close, with a "Now" marker (`ForgeTimeline`) | time rail with Now, workouts, waking up with stages, naps, Yesterday (2026-11-09, `ForgeTodayTimeline`); naps come from the core's `SleepNight.naps`, the same rule iOS reads (2026-11-10) | coach notes, walk bundles, weigh-ins, logs, ECG, notices, the day's close and "Show all" missing |
| Scene | painted day-cycle scene at the top, scrolls away with the rings | scene backdrop | check the fade and the scroll |
| Cards | 78 % glass until a Card transparency is chosen, down to fully clear (`ForgeCardModifier`) | the new design draws iOS's card: 78 % glass until a transparency is chosen, no rim, 14 dp corners | close |

## Other tabs

| Screen | iOS | Android | Gap |
|---|---|---|---|
| Training | This week, Start, Planned today, Your week (goals, routines), Recent activities, Key metrics, Tools | `ForgeTraining*`: start, goals, This week, Routines, Recent, Consistency, Muscle analytics, the analysis list, and in the new design the Tools group with the interval timer and Breathe, Key metrics (Effort this week, VO₂max, last 30 days) (2026-11-10) | the week summary hero, Planned today and the pace tile missing; Android keeps Consistency and Muscle analytics, which iOS shows deeper |
| Sleep | night navigator (weekdays and clock span), Rest and duration tiles, the coach button, Tonight, This night, Naps, stages, goals, Highlights, night facts, History | `ForgeSleep`, `ForgeSleepCards`: in the new design the night navigator as on iOS, the Rest and duration tiles and the coach button (2026-11-11), in the shipped design the Rest ring, times, Alarms, goals, the arrangeable cards; in the new design the day's naps from the core (2026-11-10) | the Rest ring is the shipped hero, iOS shows tiles; Tonight, Highlights, night facts and History missing |
| Health | Vitals in range, the off-range card, editable Vitals tiles, Focus areas, Heart and stress, Body and energy, Long term and patterns | `ForgeHealthTab` (2026-11-09): vitals in range, tiles with their range badge (2026-11-11), the three groups, Trends | the off-range card is in (2026-11-10, not seen on screen: the demo data has every vital in range); tile editing and Focus areas missing; a vital tile opens the Health page because Android has no single-metric page yet (iOS opens `TabRoute.metric`) |
| Coach | the coach inside its tab | own tab button (2026-11-09) | close |

## Order of work

1. Tabs as on iOS: Today, Training, Sleep, Health, Coach. Trends and More move into Health and Settings.
2. Today: answer line under the rings, the single hint, tiles in three sizes, then the timeline.
3. Health tab from the pieces Android already has (vitals, focus areas, trends entry).
4. Card by card on Training and Sleep.

Each step is checked side by side with iOS screenshots of the same demo data.

## Emulator review 2026-11-10

The new design checked on the `noop-spike` emulator (demo data, light and dark), then the code read again.

Fixed:
- (2026-11-11, from the Health tab of 2026-11-09) Trends opened from Health had no backdrop, insets or back
  arrow: the Health tab and the tab bar showed through it. Now a page of its own; seen on the emulator.
- The updates inbox (Trends and Overview dashboards, shipped design) had the same bare overlay: Today showed
  through it and its title sat under the clock. Fixed the same way; seen on the emulator.
- (2026-11-11, from yesterday's own change) The More page over the tabs was an overlay page itself; opening
  Analysis, Health & Body, Tools or Settings from it closed both and left the profile dead until a restart.
  More is a layer of its own now; seen on the emulator.
- The More page opened from a profile drew its title under the status bar (empty insets).
- The Timeline and Naps headings used the scene's white ink on the light canvas and all but vanished.
- Holding the rings opened Effort instead of arranging the tiles: each ring's click claimed the press first.
- The tile edit controls covered each tile's name and were 32 dp; they sit in the corners at 44 dp now.
- The timeline and the sleep tile never read again after a sync while Today stayed open, and "Now" kept the
  minute the page opened.
- The same one-time read on Today's Energy ("so far" never grew), Training load and coach cards, and on the
  Training tab: all read again on the core's data revision now. These were in the shipped design too.
- The older nights' line in Sleep's navigator ran past the width; it names the wake day only.
- With the Classic dashboard style chosen the new design drew the classic Today, whose battery and devices
  jumps went to the More tab the new design lacks. The new design keeps its own Today and any jump to More
  opens the More page (read in the code and compiled, not run on screen).
- The emulator launch extra wrote the switch in every build; it is now a debug-only override, as on iOS.
- The coach page's arrow went back to Today but the system Back closed the app; Back now does what the arrow does.
- The workout list was loaded only when the Workouts page, Insights or Data Sources opened, so Today's timeline,
  its latest-workout card, the dashboards and Training's count showed no workout until then (both designs).
  Forge loads it at start and after each analysis pass.
- Forge's Today (both designs) took the calendar date: opened between midnight and four it showed an empty new
  day, and kept open past midnight its title fell to the weekday (#144, solved long ago on the classic Today).
  Today and every part of it read the logical day now; seen on the emulator at 00:04.
- Trend charts (metric pages, Trends cards) broke five-digit axis values in their fixed 32 dp column
  (steps' 10940 as "1094" over "0"); the column sizes to its labels now. Both designs.

Seen, not changed:
- Today's measure tiles: iOS shows each measure's latest value (`ForgeMeasureWidget`, the series' last point),
  Android the day's value as Key Metrics reads it. After the 4:00 rollover, before the night is synced, Android's
  tiles read "No data yet" where iOS still shows yesterday's figure; the Charge ring likewise, where iOS carries
  Charge with its answer line. Seen on the emulator at 04:14. Which reading both should take is the owner's call.
- Demo build: a run added by hand on the Workouts page did not appear in its list, even after reopening it.
  The save mirrors to the core and the list reads the core; whether only the demo strap's id is at fault could
  not be told on the emulator. To check on a phone: add a workout, then look at Workouts and Today.
- Both platforms: Customize Sleep reuses Today's editor hint, "Move an item to Hidden to remove it from Today",
  on the Sleep page (iOS `SleepCustomizationSheet` through `EditableLayoutList`, Android `ForgeEditableLayoutList`).
  The fix needs a page-neutral sentence in nine languages, which on iOS comes through the Xcode catalog build.
- Rest's word differs between the platforms: iOS says Good, Fair or Low at 80 and 60 (`ForgeToday.restWord`),
  Android Poor, Fair, Good or Optimal at 50, 70 and 85 (`RestWord`); 94 reads "Good" on iOS, "Optimal" on
  Android. The owner's call which words and thresholds both should use.
- iOS (simulator, demo data): the new design's Today header named the calendar day past midnight while its
  values and Liquid Today's header follow the logical day. Fixed 2026-11-11 (Today passes the logical day to
  `ForgeLargeHeader`). The empty steps tile and Effort dash seen at 00:09 came with the demo's analysis still
  running and are not counted as a bug.
- iOS Sleep lists every block outside the main night as a nap, the timeline only those with 10 min asleep
  (`SleepNight.naps`). Hiding the short ones on Sleep would also hide their delete button, and the classic
  Sleep view counts them in the day's total, so the rule for that list is the owner's call.
- The demo app answered slowly at first start on the emulator (an ANR while WorkManager waited). The main
  thread was waiting for the render thread and spent most of the minute waiting for the CPU, in both designs,
  with software rendering and also with the host GPU and 4 GB. No NOOP code was on the stack; the first
  start's load is worth measuring on a real low-end phone.
- Optimisation done (2026-11-11): the score rings redrew sixty times a second when scrolled away or covered
  by a page; they pause there now, as iOS's rings pause by `dashboardAnimationVisibility`. Main and render
  threads over 10 s: scrolled away 1389 to 0 jiffies, More open 1280 to 11, a metric page over Today 13.
- Optimisation, measured on the debug build: a cold start takes about 10.5 s to the first frame on this
  emulator. A simpleperf profile shows no single hotspot (the scene picture decode and loading the Swift
  library about 1 % each, the rest ordinary composition, which a debug build runs interpreted). With the rings on screen
  their animation is the cost, as on iOS. Worth a release-build measurement on a phone before changing anything.

## Screen comparison 2026-11-11 (iOS simulator `--demo-anchor`, Android emulator, demo data)

Card by card where Android's new design still differs from iOS's. The rule: Android rebuilds each card as iOS
draws it, reading the same core data; the shipped Android cards are not reused in the new design.

Whole app
- Done 2026-11-11: Sleep on the plain canvas; section titles bold in sentence case.
- iOS's tab bar spans the width at the bottom; Android's floats as a capsule.

Today
- Done 2026-11-11: tiles show the latest value, curves whole with an end dot, rings carry Charge and Rest,
  edit controls in the corners.
- The hint card under the rings ("You slept less today", "1 more").
- Done 2026-11-11: Energy, Momentum and Training load drawn as iOS's; the cycle card only while tracking is on.
- Done 2026-11-11: Latest workout, Last night, Tonight (bedtime from the phone alarm's wake time and the
  wind-down sleep need), This week's plan (agreed coach sessions ringed), Next session, Breathe and Strap.
  `--ez demo_widgets true` seeds every card in a debug build, as iOS's `--demo-widgets`.
- Strap opens Settings (Android has no battery page) and leaves out iOS's "Off the wrist" line, since Android's
  live state keeps only the latest strap event of any kind.
- Still to draw as iOS's: What changed (better and worse), What helps your Charge (bars), Goals (journeys).
- The timeline's head "Tagesverlauf" with "Show all".

Training
- Done 2026-11-11: the week head; the start capsules; the year grid and the muscle map off the tab (both still
  reachable).
- "Your week" card with the week's goals as progress bars.
- Routines as a sideways row of cards.
- Recent activities as one grouped list with Effort on the right.
- Key metrics with the pace tile, then the grouped rows (Training load, Strength, Cardio, Goals).
- Tools: This week's plan and Plan and library besides Intervals and Breathe.

Sleep
- Phases as bars against the typical night; "What shaped the night" with three rings, Regularity and
  Breathing; Sleep debt with its bars; Inner clock dial; this week's sleep goal; Highlights; "This night"
  tiles with 14 nights' bars; the history chart with Week, Month, Year; Alarms rows; Sleep marks last.

Health
- Done 2026-11-11: the Long term group with Trends, What works and All metrics.
- Still missing: Focus areas as six tiles (iOS opens focus pages Android lacks, so the Heart and Body groups
  stay until those pages exist); "Your week in rings"; Weekly report; Vitals with "Edit".
