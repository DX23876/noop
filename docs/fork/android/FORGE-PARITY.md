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
| Tabs | Today, Training, Sleep, Health, Coach (search-role tab, only with the coach on) | the same, behind the Lab switch (`ForgeDesign.tabs`); the coach as a round button beside the bar | close |
| Settings | the profile picture in each tab's header | the profile in the Today, Training, Sleep and Health headers opens the More page over the tabs, with Settings, the strap and every page | iOS opens a profile hub, Android the More page |
| Search | magnifier in each tab's header (`ForgeSearchView`) | the More page's search, behind the profile | no magnifier in the header |

## Today

| Part | iOS | Android | Gap |
|---|---|---|---|
| Header | "Today" with the date, strap, plus, profile | header with profile and quick actions | close |
| Rings | three organic rings in one chamber with the day's answer under them | `Hero` with organic rings | answer line under the rings missing |
| Hint | one most-pressing hint (`ForgeTodayHint`) | the activity prompt and the morning suggestion; pills and Momentum are gone from the new Today (Momentum is a tile) | the hint card, which needs the timeline's notices and coach notes |
| Tiles | a free grid of measure and picture tiles, three sizes, moved by drag in edit mode (`ForgeTodayWidgets`) | `ForgeTodayWidgets.kt` (2026-11-10): measures from the Key Metrics reading, sleep from the latest night, and the cards Training load, Goals, Energy, Latest workout, Cycle, Momentum, Live heart rate; three sizes, moved by arrows and accessibility actions, gallery | no drag; no water, last night, week plan, coach note, AgeLess, tonight, next session, what changed, what works, breathe, strap or stress tiles |
| Timeline | the day as a time rail: coach notes, workouts, walks bundled, wake, naps, weigh-ins, logs, ECG, notices, the day's close, with a "Now" marker (`ForgeTimeline`) | time rail with Now, workouts, waking up with stages, naps, Yesterday (2026-11-09, `ForgeTodayTimeline`); naps come from the core's `SleepNight.naps`, the same rule iOS reads (2026-11-10) | coach notes, walk bundles, weigh-ins, logs, ECG, notices, the day's close and "Show all" missing |
| Scene | painted day-cycle scene at the top, scrolls away with the rings | scene backdrop | check the fade and the scroll |
| Cards | 78 % glass until a Card transparency is chosen, down to fully clear (`ForgeCardModifier`) | the new design draws iOS's card: 78 % glass until a transparency is chosen, no rim, 14 dp corners | close |

## Other tabs

| Screen | iOS | Android | Gap |
|---|---|---|---|
| Training | week strip, quick actions, Your week, Routines, Recent activities, Key metrics, Tools | `ForgeTraining*` with history, reports, muscles, lift logger | close; check the order and the headings |
| Sleep | night navigator, Rest and duration tiles, Tonight, Last night stages, Highlights, This night, History, Alarm and naps | `ForgeSleep`, `ForgeSleepCards` | compare card by card |
| Health | Vitals in range, the off-range card, editable Vitals tiles, Focus areas, Heart and stress, Body and energy, Long term and patterns | `ForgeHealthTab` (2026-11-09): vitals in range, tiles, the three groups, Trends | off-range card, tile editing and Focus areas missing; a vital tile opens the Health page because Android has no single-metric page yet (iOS opens `TabRoute.metric`) |
| Coach | the coach inside its tab | own tab button (2026-11-09) | close |

## Order of work

1. Tabs as on iOS: Today, Training, Sleep, Health, Coach. Trends and More move into Health and Settings.
2. Today: answer line under the rings, the single hint, tiles in three sizes, then the timeline.
3. Health tab from the pieces Android already has (vitals, focus areas, trends entry).
4. Card by card on Training and Sleep.

Each step is checked side by side with iOS screenshots of the same demo data.
