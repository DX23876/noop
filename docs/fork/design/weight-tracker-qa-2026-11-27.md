# Weight tracker: design QA and platform comparison (2026-11-27)

Scope: the weight page (Overview, History, Reports), its settings and date editor, the four home-screen widgets
and the weight tile on Today, on iOS (simulator, `--demo-seed`) and Android (emulator, Demo flavour). Both
platforms were checked side by side, section by section, and each widget was placed on a real home screen.
The two demo seeds carry different weights (iOS about 93 kg, Android about 76 kg), so figures differ while
layout, wording and behaviour are compared.

## Assessment

| Heuristic | Result |
|---|---|
| Visibility of state | Hero shows the last weigh-in, its age and the trend side by side; the trend line is labelled as such everywhere. |
| Match with the wearer's words | Neutral wording, no BMI, no judging colours on the scale itself; green/orange only on direction of change against the goal. |
| Consistency | One pink weight tint (`systemPink`) for the page, the ring, the trend line and the trend widget; the settings sheet keeps the app accent, as every other Forge sheet. |
| Recognition over recall | Each figure carries its unit and its label; reports say how many weigh-ins they rest on. |
| Error prevention | Reports with fewer than four weigh-ins say so instead of drawing a line; editors refuse values outside 25 to 400 kg. |
| Aesthetic and minimal | Cards without rims, roomy gaps, one chart per section; the widgets each say one thing. |

Strengths: the forecast states its basis ("from the trend, 76.3 kg") under every sentence, so the number is
never unexplained; milestones and dates turn a long goal into near steps; the logbook pairs each weigh-in with
the trend and the week's change, which is the core idea of the page.

## Issues found and fixed

| # | Platform | Issue | Fix |
|---|---|---|---|
| 1 | Android | A newly placed weight widget stayed empty: the app only wrote the widget data while a widget was already placed. | The widget words the data itself on its first draw. |
| 2 | Android | A colour change or a new weigh-in did not reach a widget whose Glance session was still running. | Every redraw bumps a value in the widget's Glance state, which recomposes the running session; verified by switching purple to green live. |
| 3 | Android | Trend widget showed text only; iOS draws the 30-day trend line. | The line is drawn to a bitmap, with the latest weigh-in as fallback when there is too little to draw. |
| 4 | Android | Widget picker showed no descriptions. | Descriptions added in all locales, taken from the iOS widget catalogue. |
| 5 | Android | Empty widgets were a bare sentence; iOS shows a mark above it. | Scale and calendar marks added. |
| 6 | iOS | Trend, month and figures widgets all started pink; the decision was one colour each. | Start colours pink, orange, indigo, teal on both platforms. |
| 7 | iOS | Figures widget said "Latest" ("Aktuellste"); everywhere else it is "Last" ("Zuletzt"). | Shared "Last" label. |
| 8 | Android | History chart had one axis label and no months; labels sat on top of the dots. | Label gutter on the left, month rules and names along the bottom, goal named on the left as on iOS. |
| 9 | Android | Report cards had no dates under their line; figures were not bold. | Four dates under each report line; figures bold, titles semibold. |
| 10 | Android | Logbook values had no unit; iOS shows "kg" on every value. | Units and the iOS column widths. |
| 11 | Android | "Letzte Messung Vor 6 Tagen": the platform capitalises the relative phrase. | Lower-cased mid-sentence. |
| 12 | Both | Forecast heading read "Prognose" on Android and "Vorhersage" on iOS; iOS French and Polish carried a stray full stop. | One wording from the iOS catalogue; full stops removed. |
| 13 | Both | Week card said "Tief" on Android and "Niedrig" on iOS. | iOS wording. |
| 14 | Android | "Add" date action had no plus mark. | Plus mark, as iOS. |
| 15 | Both | Today's small weight tile on iOS showed the weekly rate beside the week's change chip, cut short; Android showed nothing. | The forecast line only on the two-column tile, on both platforms. |
| 16 | Android | Tapping a weight widget opened Today; iOS opens the weight page. | The tap carries a flag that moves the shell to Today and pushes the weight page, once. |

## Open, not changed

- Today's weight tile is amber on both platforms while the weight page is pink. The tile colours are the
  app-wide metric palette; changing one tile is the owner's call.
- Android's Today change chips print a decimal point in German ("−1.2" where iOS says "−1,2"). The text comes
  from the shared core's `CoreTile.delta`, so it is a core localisation issue for every chip, not the weight tile.
- The iOS simulator never finished loading the widget's colour editor (spinner); the same configuration
  intent is exercised by the gallery, which shows each widget in its start colour. Check on the iPhone.
