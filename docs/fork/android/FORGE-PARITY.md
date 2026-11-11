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
| Tiles | a free grid of measure and picture tiles, three sizes, moved by drag in edit mode, two or three to a row (`ForgeTodayWidgets`) | `ForgeTodayWidgets.kt` (2026-11-10; tiles per row and iOS's tile look 2026-11-11): measures from the Key Metrics reading, sleep from the latest night, and the cards Training load, Goals, Energy, Latest workout, Cycle, Momentum, Live heart rate; three sizes, moved by arrows and accessibility actions, gallery | no drag; no water, last night, week plan, coach note, AgeLess, tonight, next session, what changed, what works, breathe, strap or stress tiles |
| Timeline | the day as a time rail: coach notes, workouts, walks bundled, wake, naps, weigh-ins, logs, ECG, notices, the day's close, with a "Now" marker (`ForgeTimeline`) | time rail with Now, workouts, waking up with stages, naps, Yesterday (2026-11-09, `ForgeTodayTimeline`); naps come from the core's `SleepNight.naps`, the same rule iOS reads (2026-11-10) | coach notes, walk bundles, weigh-ins, logs, ECG, notices, the day's close and "Show all" missing |
| Scene | painted day-cycle scene at the top, scrolls away with the rings | scene backdrop | check the fade and the scroll |
| Cards | 78 % glass until a Card transparency is chosen, down to fully clear (`ForgeCardModifier`) | the new design draws iOS's card: 78 % glass until a transparency is chosen, no rim, 14 dp corners | close |

## Other tabs

| Screen | iOS | Android | Gap |
|---|---|---|---|
| Training | This week, Start, Planned today, Your week (goals, routines), Recent activities, Key metrics, Tools | `ForgeTraining*`: start, goals, This week, Routines, Recent, Consistency, Muscle analytics, the analysis list, and in the new design the Tools group with the interval timer and Breathe, Key metrics (Effort this week, VO₂max, last 30 days) (2026-11-10) | the week summary hero, Planned today and the pace tile missing; Android keeps Consistency and Muscle analytics, which iOS shows deeper |
| Sleep | night navigator (weekdays and clock span), Rest and duration tiles, the coach button, Tonight, This night, Naps, stages, goals, Highlights, night facts, History | `ForgeSleep`, `ForgeSleepCards`: in the new design the night navigator as on iOS and the Rest and duration tiles (2026-11-11), in the shipped design the Rest ring, times, Alarms, goals, the arrangeable cards; in the new design the day's naps from the core (2026-11-10) | the Rest ring is the shipped hero, iOS shows tiles; Tonight, Highlights, night facts and History missing |
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
- Forge's Today (both designs) took the calendar date: opened between midnight and four it showed an empty new
  day, and kept open past midnight its title fell to the weekday (#144, solved long ago on the classic Today).
  Today and every part of it read the logical day now; seen on the emulator at 00:04.
- Trend charts (metric pages, Trends cards) broke five-digit axis values in their fixed 32 dp column
  (steps' 10940 as "1094" over "0"); the column sizes to its labels now. Both designs.

Seen, not changed:
- Rest's word differs between the platforms: iOS says Good, Fair or Low at 80 and 60 (`ForgeToday.restWord`),
  Android Poor, Fair, Good or Optimal at 50, 70 and 85 (`RestWord`); 94 reads "Good" on iOS, "Optimal" on
  Android. The owner's call which words and thresholds both should use.
- iOS at 00:09 (simulator, demo data): the Today header names the calendar day ("Wed, Nov 11") while the
  values follow the logical day until four; Effort showed a dash and steps "No data yet". The header date
  comes from `ForgeLargeHeader` (`Date()`), the values from `logicalDayKey`, partly through `repo.today`.
  Not changed on iOS without a closer look; Android shows the logical day in its header too.
- iOS Sleep lists every block outside the main night as a nap, the timeline only those with 10 min asleep
  (`SleepNight.naps`). Hiding the short ones on Sleep would also hide their delete button, and the classic
  Sleep view counts them in the day's total, so the rule for that list is the owner's call.
- The demo app answered slowly at first start on the emulator (an ANR while WorkManager waited). The main
  thread was waiting for the render thread and spent most of the minute waiting for the CPU, in both designs,
  with software rendering and also with the host GPU and 4 GB. No NOOP code was on the stack; the first
  start's load is worth measuring on a real low-end phone.
- Optimisation, measured on the debug build: a cold start takes about 10.5 s to the first frame on this
  emulator. A simpleperf profile shows no single hotspot (the scene picture decode and loading the Swift
  library about 1 % each, the rest ordinary composition, which a debug build runs interpreted). Idle on Today
  the main thread still uses about a third of a core and the render thread a sixth, from the rings' constant
  animation, in both designs. Worth a release-build measurement on a phone before changing anything.
