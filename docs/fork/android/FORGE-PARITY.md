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
| Settings | the profile picture in each tab's header | the profile in the Today, Training, Sleep and Health headers opens Settings laid out as `ForgeSettingsView`: profile, search field, You, Strap and devices, Alerts, App, Data and help, Lab and About (2026-11-12) | Android keeps Battery & Recording and Strap Actions as rows of their own and "All settings" last |
| Search | magnifier in each tab's header and in Settings (`ForgeSearchView`) | the magnifiers and the Settings search field open the More page with its search focused; results list metrics (opening Explore), screens and settings pages, and the last eight searches stay as chips (2026-11-12) | iOS's search is a page of its own; Android's is the More page's field |

## Today

| Part | iOS | Android | Gap |
|---|---|---|---|
| Header | "Today" with the date, strap, plus, profile | in the new design "Today" and its date on one line, profile and plus; the plus is iOS's menu (Start or Back to workout, Add entry, Customize Today), Add entry opens the Log sheet after `ForgeLogSheet` (2026-11-12) | no strap button of its own; the Log sheet has no Photo button, since the Android coach cannot read a photo |
| Rings | three organic rings in one chamber with the day's answer under them; holding them arranges the tiles | `Hero` with organic rings; holding a ring arranges the tiles (2026-11-10) | the answer line, which iOS shows only while Charge is carried from an earlier day; Android's Forge hero has no carried state yet |
| Hint | one most-pressing hint (`ForgeTodayHint`) | the activity prompt and the morning suggestion; pills and Momentum are gone from the new Today (Momentum is a tile) | the hint card, which needs the timeline's notices and coach notes |
| Tiles | a free grid of measure and picture tiles, three sizes, moved by drag in edit mode, two or three to a row (`ForgeTodayWidgets`) | `ForgeTodayWidgets.kt` (2026-11-10; tiles per row and iOS's tile look 2026-11-11): measures from the Key Metrics reading, sleep from the latest night, and the cards Training load, Goals, Energy, Latest workout, Cycle, Momentum, Live heart rate; three sizes, moved by drag in edit mode (2026-11-11), by arrows and accessibility actions, gallery | 2026-11-11: tiles drawn as iOS's `TodayMetricTile` (equal row heights, one-line names, change chip from the shared `MeasureTileReading`), editor as iOS (hold a tile, one editor card with tiles per row, timeline shown and where tiles start, tiles trade places while carried); water, coach note and AgeLess added. Done 2026-11-11 later: the diet goal card (shared `DietProgress`, core call `food.planProgress`, also on the plan page), AgeLess across the row, the gallery in iOS's order and sizes; on both phones a tile over two columns shows more (a measure's usual and 30-day range from `MeasureTileReading.summary`, water's share of the goal, the strap's state with its sync, AgeLess's years against the calendar age) |
| Timeline | the day as a time rail: coach notes, workouts, walks bundled, wake, naps, weigh-ins, logs, ECG, notices, the day's close, with a "Now" marker (`ForgeTimeline`) | time rail with Now, workouts, waking up with stages, naps, Yesterday (2026-11-09, `ForgeTodayTimeline`); naps come from the core's `SleepNight.naps`, the same rule iOS reads (2026-11-10) | done: coach notes with the Why sheet, walk bundles, timed weigh-ins, meals, ECG, notices, the day's close, "Show all" |
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
- (2026-11-12) The water tile, its Your cards row and the Log sheet's Drink opened the journal, which cannot log
  water; the drink log (`HydrationScreen`) was out of reach in the new design. A search-only More destination
  opens it now, as iOS's `TabRoute.hydration`; seen on the emulator.
- (2026-11-12) The vital page said "as of 2026-11-10" (the stored day) and named itself twice under a storage
  subtitle; in the new design it reads "as of Tue 10 Nov" and names itself once.
- Not changed, for a decision: the readings table names the imported strap source "Whoop", as iOS's
  `MetricCatalog.sourceLabel` does.
- Not an app fault found: the cold-start "isn't responding" on the emulator is "No response to onStartJob"
  while the main thread waits on the emulated render thread; the system's Bluetooth service timed out in the
  same minutes.
- (2026-11-12) The drink log's "x% of today's goal" was fixed white on the white hero card in light mode; it takes
  the secondary text colour now; seen on the emulator.
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
- Tab bar: iOS uses the system tab bar, which on iOS 26 floats as a glass capsule with the coach apart, as Android
  draws it; on iOS 17 and 18 it spans the width. Android keeps the iOS 26 look.

Today
- Done 2026-11-11: tiles show the latest value, curves whole with an end dot, rings carry Charge and Rest,
  edit controls in the corners.
- Done 2026-11-11: the hint card under the rings (`ForgeTodayHint`): Momentum's notices through the shared
  `TimelineFeed.admit` (core call `timeline.admit`), ranked as iOS ranks them, dismissed for the day, "n more". Not
  among Android's candidates: the coach note and a plan waiting for an answer.
- Done 2026-11-11: Energy, Momentum and Training load drawn as iOS's; the cycle card only while tracking is on.
- Done 2026-11-11: Latest workout, Last night, Tonight (bedtime from the phone alarm's wake time and the
  wind-down sleep need), This week's plan (agreed coach sessions ringed), Next session, Breathe and Strap.
  `--ez demo_widgets true` seeds every card in a debug build, as iOS's `--demo-widgets`.
- Strap opens Settings (Android has no battery page) and leaves out iOS's "Off the wrist" line, since Android's
  live state keeps only the latest strap event of any kind.
- Done 2026-11-11: What works for your Charge, from the Insights ranking. Its bars are unchecked on screen: the
  demo has no journal answers. Every row carries the journal symbol, since Android has no per-habit symbols.
- Done 2026-11-11: What changed, the rule of iOS's `TrendsChangeSummary.rows` with a test; it opens Health's
  Trends. Android reads seven of iOS's ten measures (no sleep regularity, stress or weight on the core path yet),
  so its counts can be smaller for the same data.
- Done 2026-11-11: a goal on Today's card opens its own page or journey.
- Done 2026-11-11: the timeline's head with "Show all" (closed: today's latest three), walks bundled, meals, ECG
  readings and notices on the rail; coach notes, timed weigh-ins and the day's close are on it too.

Training
- Done 2026-11-11: the week head; the start capsules; the year grid and the muscle map off the tab (both still
  reachable).
- Done 2026-11-11: Planned today with Start; "Your week" over the training goals with a Goals link (Goals open over
  the tab); routines as a sideways row of cards (tap starts, long press edits); recent activities of every kind as
  one grouped list with Effort; the Training load, Strength, Cardio and Goals rows under Key metrics; Tools with
  This week's plan, Plan and library, Intervals and Breathe. The week strip and the Understand list left the tab;
  muscles, past sessions and lifting imports sit under Tools.
- Done 2026-11-11: the pace tile; "Plan and library" as a page of its own (plan, routines, starters, Hevy, library,
  past sessions, muscles, imports). Unseen on screen: the routine row and the recent list with data.

Sleep
- Done 2026-11-11 (`ForgeSleepNewDesign`): Tonight, the night with stage lanes, make-up bar and totals, naps,
  stages against the typical night, what shaped the night (rings with the usual as a tick, steadiness from the
  stored AI-35 regularity, breathing), sleep debt, body clock, the week's sleep goal, highlights as pages, "This
  night" with 14 nights' bars, history with Week, Month and Year, the alarms and the sleep marks. The need is the
  stored Rest trait, as on iOS. A night stored only as stage minutes keeps its breakdown without lanes.
- Done 2026-11-11: the night editor (bed and wake times, delete) with Undo, nap delete, the deleted sleep windows
  with Recompute and Hide. The body clock was not on screen (the demo's rhythm is unreadable).

Health
- Done 2026-11-11: the Long term group with Trends, What works and All metrics.
- Done 2026-11-11: the food log card; Focus areas as six tiles, each opening a list of that area's Android pages
  (Sleep opens the Sleep tab), which replaces the Heart and Body groups; "Your week in rings" opening Trends.
- Done 2026-11-11: the Weekly report row and page, the cycle card while tracking is on, Vitals with "Edit" (hide,
  bring back, two or three per row).
- Done 2026-11-11: the focus pages with their measure tiles; a focus or vital tile opens Explore on its measure
  (Android's stand-in for iOS's single-metric page); vital tiles swap with measures and reorder by drag.

## Inventory 2026-11-11: every iOS page of the new design against Android

Read from iOS's `MoreDestination`, `ForgeRoute`, `ForgeSettingsRoute` and the `StrandiOS/Forge` files. "Has" means
Android reaches the same function; "missing" pages are the build list.

| iOS page | iOS file | Android |
|---|---|---|
| More destinations (Momentum, Insights, Explore, Compare, Fused record, Body, Food, Energy plan, Health, AgeLess, Rhythm age, Lab book, Stress, Beat rhythm, ECG, Live, Breathe, Intervals, Workouts, Strength, Cardio, Training load, Alarms, Coach, Goals) | `RootTabView` | has (`MoreDest`) |
| Settings, Data sources, Backup, Mi Band, Automations, Test Centre, Limitations, Power saving | `ForgeSettingsView`, hubs | has (`ForgeSettings`, hosted screens) |
| Apple Health, Siri and Shortcuts export | | not applicable (Health Connect in Data sources) |
| Search sheet | `ForgeSearchView` | has as the More page's search |
| Charge page | `ForgeChargeDetailView` | has (`ForgeChargeBreakdown`) |
| Effort page, Rest page | `ForgeScoreDetailViews` | has (`ForgeScorePages`) |
| Weekly report page | `ForgeWeeklyReportView` | has (`ForgeWeeklyReport`) |
| This week's plan page | `ForgeWeekPlanView` | has (`ForgeWeekPlan`) |
| Focus pages, six | `ForgeFocusView` | has (`FocusAreaPage`) |
| Cycle page, guide, fertile band | `ForgeCycleView`, `ForgeCycleGuide`, `ForgeCycleFertile` | done 2026-11-11 (`ForgeCycle.kt`, `ForgeCycleModel.kt`): dial, fertile line and page, log sheet (flow, symptoms, mood, ovulation test under `noop-cycle`), phase cards and topic pages, temperature card, calendar, history, settings with the fertile reminder; fertile estimate and training pattern from the shared core (`cycle.fertile`, `cycle.pattern`) |
| Coach notes on the timeline, "Why" sheet | `ForgeTodayView`, `ForgeCoachWhySheet` | has |
| Vital tile editor (swap, reorder, up to nine) | `ForgeHealthTiles` | has (drag to reorder 2026-11-11) |
| AgeLess page | `ForgeAgeLessView` | has, rebuilt 2026-11-11 (age line, domains, over time) |
| Single-metric page | `MetricDetailView` | has (2026-11-12): every vital tile, the steps tile and the measures on the focus pages open `VitalDetailScreen`, laid out as iOS: four windows (W, M, 6M, ALL), chart, Average with its trend line, Min, Max, Change against the window before, Latest, Ask coach, What correlates and the readings. Statistics, change and correlations come from the shared `MetricDetailInsights` in the core, which iOS calls too; steps follow the chosen steps source |
| Effort of an imported workout from its heart rate | `WorkoutHeartRateFills.fillApple` (AI-16) | has (2026-11-12): `fillHealthConnect` from the strap trace or the minute heart rate the import files, on AI-35 |
| Where steps come from | Devices and data sources, `StepsSource` | has (2026-11-12): Data and backup; one steps reader (`MetricResolver.resolvedSteps`) for tiles, steps page and AgeLess |
| Energy page | `ForgeEnergyView` | has, rebuilt 2026-11-11 (ring against a usual day, parts, 30-day bars) |
| Workouts page | `ForgeWorkoutsView` | has, rebuilt 2026-11-12 (13 weeks, this week, sessions by week); a recent session opens itself |
| Workouts list, Strength, Muscles | `ForgeWorkoutsView`, `ForgeStrengthView` | has; Strength opens an overview after `ForgeStrengthView` (next routine with Start, eight weeks of volume from the shared `StrengthWeeklyVolume`, latest sessions, plan, muscles and the full report) since 2026-11-12 |

## Round 2026-11-12: page by page against iOS

Each page below was read against its iOS file section by section; "open" lists what is still missing there.

| Page | Done | Open |
|---|---|---|
| Training tab | coach quick asks (shorter, other routine, plan today, create a routine), Routines heading whose All opens the plan and library, each sport's own colour (`forgeSportTint`, iOS `AppleInspiredColors.role(forSport:)`) in Training, Workouts and Today, distance in the recent rows | routine pictures (`CoachPicture`) |
| Cardio | iOS forge order: chart under the hero, one week-figures card with the kcal line, sessions per family as tile rows, history link last | bests as tile rows with icons |
| Training load | one standing card with both lanes against their usual range (core `usualLow`, `usualHigh`), the verdict sentence, Last 8 weeks inline, Development rows (adaptation, recovery, session load), no subtitle | duplicate-session review card |
| Section headings in the training reports | no kicker, headline size in the new design | |
| Food | the plan's day from the shared `DietDayResolver` (core `food.planDay`): phase, training or rest day, active-day extra, goals per day; other-source note; completely-logged row (`food.planDayComplete`, `food.planSetDayComplete`) | week strip goals per day; iOS's `ForgeFoodModel` still computes the day itself and should adopt the resolver |
| Diet plan page | burn card (real burn against the strap, base the plan on it), active-days switch | change card, advice card |
| Diet plan data | Kotlin `Plan` keeps iOS's seven newer fields on save (it dropped them before) | planner steps for training weekdays, experience and recomposition deficit |
| Body | iOS forge order: today's three figures, Measure, What changed (3 windows, tape against scale, diverging bars), body fat with Navy and sources, change since first reading chart, sites with sparklines, photos, weekly and daily reminders (`BodyMeasurementReminder`, new on Android) | a site's detail page |
| Appearance | colour profiles (Colorful default, Stone, Slate, Sage) with iOS's values; the new design no longer wears the shipped bluish chrome; Motion card with Reduce motion and Living or Classic score rings (`ClassicScoreRing`) | accent colour choice, chart style rows, Motion effect, Coach animation, Coloured icons |
| Lab | personal stress baseline switch | Continuous HRV "Nights only" (BLE, needs a strap) |
| Log sheet | coach Photo while the provider reads images (`coach.acceptsPhotos`, `coach.sendPhoto`, PNG at most 1024 px) | Speak starts no dictation yet, it opens the chat |
| Live workout | | voice feedback, zone and pace warnings, auto-pause (iOS `WorkoutFeedbackSettingsView`) |
