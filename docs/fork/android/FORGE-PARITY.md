# Forge parity: the new iOS design on Android

Goal (owner, 2026-11-09): when the new design is done, iOS and Android show the same screens in the same
design. This file lists what Android has, what it lacks, and the order of work. Started 2026-11-09.

iOS source: `StrandiOS/Forge/*`, `Strand/Forge/*` (timeline, coach notes, weekly), `StrandiOS/App/RootTabView.swift`.
Android source: `android/app/src/main/java/com/noop/ui/forge/*`.

## Shell

| | iOS (new design) | Android (Forge) | Gap |
|---|---|---|---|
| Tabs | Today, Training, Sleep, Health, Coach (search-role tab, only with the coach on) | Today, Trends, Training, Sleep, More | Health tab missing (Android reaches Health through More); Trends and More are tabs of their own; no Coach tab |
| Settings | the profile picture in each tab's header | More tab and the profile button on Today | same entry, different place |
| Search | magnifier in each tab's header (`ForgeSearchView`) | none in the header | missing |

## Today

| Part | iOS | Android | Gap |
|---|---|---|---|
| Header | "Today" with the date, strap, plus, profile | header with profile and quick actions | close |
| Rings | three organic rings in one chamber with the day's answer under them | `Hero` with organic rings | answer line under the rings missing |
| Hint | one most-pressing hint (`ForgeTodayHint`) | status pills plus the Momentum card | different structure |
| Tiles | a free grid of measure and picture tiles, three sizes, moved by drag in edit mode (`ForgeTodayWidgets`) | Key metrics section, arranged in a separate editor | sizes and drag missing |
| Timeline | the day as a time rail: coach notes, workouts, wake, naps, weigh-ins, logs, with a "Now" marker (`ForgeTimeline`) | none | missing; the largest gap |
| Scene | painted day-cycle scene at the top, scrolls away with the rings | scene backdrop | check the fade and the scroll |
| Cards | fully clear by default in the new design (Card transparency 0) | glass cards | follow the transparency setting |

## Other tabs

| Screen | iOS | Android | Gap |
|---|---|---|---|
| Training | week strip, quick actions, Your week, Routines, Recent activities, Key metrics, Tools | `ForgeTraining*` with history, reports, muscles, lift logger | close; check the order and the headings |
| Sleep | night navigator, Rest and duration tiles, Tonight, Last night stages, Highlights, This night, History, Alarm and naps | `ForgeSleep`, `ForgeSleepCards` | compare card by card |
| Health | Vitals in range, Vitals tiles, Focus areas, Heart and stress, Body and energy, Long term and patterns | spread across More, Trends and dashboards | the tab itself is missing |
| Coach | the coach inside its tab | `ForgeCoach` behind More | tab missing |

## Order of work

1. Tabs as on iOS: Today, Training, Sleep, Health, Coach. Trends and More move into Health and Settings.
2. Today: answer line under the rings, the single hint, tiles in three sizes, then the timeline.
3. Health tab from the pieces Android already has (vitals, focus areas, trends entry).
4. Card by card on Training and Sleep.

Each step is checked side by side with iOS screenshots of the same demo data.
