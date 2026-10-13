# AgeLess

**Status:** fork feature, experimental, off by default (Settings → Experimental → AgeLess). While on, it
takes Body Age's place on Health.

## What it is

AgeLess is an age built from habits: how old your body seems, judged by six months of sleep, movement and
fitness. Meeting every health recommendation reads exactly at your age; doing better reads younger,
falling short reads older. Next to it, **Aging speed** says where the last 30 days are taking you.

It is computed **on-device**, weekly, from data NOOP already has. It is a motivation tool, not a medical
or biological age and not a prediction of lifespan.

## The nine measures

Each measure maps its value to the all-cause mortality hazard ratio a large study found, relative to a
health-optimised target (the published recommendation, not the population average).

| Measure (screen name) | Value | From | Study |
|---|---|---|---|
| Hours of sleep | mean nightly sleep | daily rows | Saint-Maurice et al., Sleep 2024 |
| Sleep consistency | timing regularity, 0–100 | sleep sessions | Windred et al., Sleep 2024 |
| Daily steps | mean per day | daily rows | Paluch et al., Lancet Public Health 2022 |
| Moderate activity | min/week at 40–80 % of heart-rate reserve | workouts + raw HR | Lee et al., Circulation 2022 |
| Vigorous activity | min/week above 80 % of heart-rate reserve | workouts + raw HR | Ahmadi et al., Eur Heart J 2022 |
| Strength activity | min/week | workouts | Momma et al., Br J Sports Med 2022 |
| VO₂max | ml/kg/min | see below | Kodama et al., JAMA 2009 |
| Average sleeping heart rate | whole-sleep mean | `rhr_primary_session` | Zhang et al., CMAJ 2016 |
| Lean body mass | 100 − body fat % | body measurements | Jayedi et al., Int J Obes 2022 |

Targets taper between ages 50 and 70 where the studies show a lower optimum. Curves are piecewise linear
in ln(HR) between the studies' anchor points and hold their end value outside the studied range.

## From risk to years

The method is the **effective age** of Spiegelhalter (BMC Med Inform Decis Mak 2016): with roughly 10 %
more risk per year of age, each measure adds or removes `10 · (ln HR(value) − ln HR(target))` years. The
sum is scaled by one factor, k = 0.64, which stands in for the overlap between correlated measures
(resting heart rate and VO₂max, steps and activity minutes). k is fitted on four published reference
profiles of 30-year-olds; they are effectively two profiles in two sexes, so that test guards the curves
against regressions rather than validating the age.

## Windows and gates

- **Age:** the last 182 days. **Aging speed:** the last 30 days carried forward six months, compared with
  the age: `(projected − current) / 0.5`, held to −1.0×…3.0×.
- No age before **30 nights** of sleep data, and none without the four measures the band always supplies:
  sleep duration, sleep consistency, steps and average sleeping heart rate. Any other gap stays visible
  ("Based on 8 of 9 measures"); a missing measure never counts as a met recommendation.
- Aging speed needs 14 nights in its window; activity rates need 7 days of banked raw heart rate.

## Where each value comes from

- **VO₂max**, newer measurements beat older ones (AI-24): (1) a value entered in Settings, until two
  newer measurements arrive and for a year at most; from then on only measurements after the entry count;
  (2) Apple Watch's Cardio Fitness from Apple Health, while it measured in the last 30 days; (3) the
  training-based estimate from walks and runs, the same estimator Training Load reads
  (`Repository.trainingVO2maxEstimates`: fused sessions on foot, a trace the cardio load could price, ACSM
  oxygen cost at the session's speed, extrapolated over the heart-rate reserve against the week's median
  resting HR; grade assumed flat); (4) older Apple Health readings when there are no walks or runs either.
  Two readings rather than one replace an entry because a single walk can be off by a few ml/kg/min and the
  mean of two halves such an outlier. The age takes the six-month median, Aging speed the 30-day median from
  two readings on. The weekly non-exercise estimate (Fitness Age's VO₂max) is never used. The VO₂max goal
  follows the same readings (`HealthspanVO2.goalReadings`).
- **Lean mass:** the latest body-fat reading of the past year, entered on the Body page or from Apple
  Health.
- **Activity minutes:** time in logged and detected workouts, from the band's raw heart rate against the
  heart-rate reserve between the average sleeping heart rate and the maximum heart rate. Raw heart rate is
  kept about five weeks, so minutes are banked per day while it exists (`hs_zone13_min`, `hs_zone45_min`);
  a first run banks the whole retention.
- **Sleep consistency:** the 24 h before each wake time compared minute by minute with the same 24 h on
  the four days before, on the Sleep Regularity Index scale (200·a − 100, floored at 0); naps count, and
  only nights with all four prior nights recorded are scored.
- **Average sleeping heart rate** is deliberately not the app's resting heart rate (the night's lowest
  five minutes, used by Charge, Effort and Training Load): the age's reference profiles use an average at
  rest, which sat 6.5 to 11 bpm above the nadir on real data.

## Screens

- **Health card:** the age on a half-circle gauge spanning ten years either side of the actual age, the
  years younger or older, and Aging speed.
- **AgeLess screen:** week switcher, Aging speed on its scale (leaf for slow, flame for fast), a status
  line, the biggest levers ranked with what all of them together would take off, and each measure on a
  ticked bar with its years and a trend arrow for the last 30 days, grouped as sleep, activity and fitness.
  Under each bar a line says what the measure stands on ("Nights: 152 of 182 · 6 months", "Days measured",
  "Sessions", "Walks and runs", "Entered", "Apple Health" or "Body fat from" with the reading's day) and, in
  coral, "thin data" when that is too little to lean on: a daily measure on fewer than 60 % of the days the
  window covers, zone minutes on fewer than four weeks of banked days, a training VO₂max on fewer than three
  walks and runs, or body fat older than 90 days at the week's end. Strength is never thin; no sessions is a
  fact. The thresholds are reasoned starting values in `HealthspanBasis`.
- **Levers as goals:** a lever whose number has a goal template carries a **Set as goal** button that opens
  the goal setup on its value step: sleep duration (sleep goal), daily steps (**More steps a day**, mean over
  28 days), average sleeping heart rate (**Lower sleeping heart rate**, 28 nights like resting heart rate),
  VO₂max, and lean mass (a **body-fat** goal: lean mass is 100 % minus body fat). The target is the further of
  the lever's value and the goal's own current value plus the lever's step, so it is never reached on the day
  it is set. An open goal on the same number replaces the button with **Goal running**. A goal on one of these
  numbers shows on its page what reaching its target would take off the AgeLess age (from 0.1 years, while
  AgeLess is on), from the same rule the levers use (`HealthspanEngine.years(reaching:on:from:)`). A lean-mass
  goal is kept in kilograms and is not priced.
  An info button opens **About AgeLess**: the idea in plain words, each study linked, the calculation one
  level down.
- Colours are AgeLess's own: cyan to indigo for younger, coral for older.

## Stored values and migrations

Weekly rows under the computed source, keyed to the Saturday on or before: `healthspan_age`,
`healthspan_pace`, `healthspan_covered_days`, `hs_vo2_source`, `hs_vo2_day` and `hs_fat_day` (newest
VO₂max and body-fat reading behind the week, as yyyymmdd), and per measure `hs_in_*` (six months),
`hs_in30_*` (30 days) and `hs_n_*` (days, sessions or readings behind the six-month value). Each pass
rewrites its weeks as one window and writes nothing when a read fails. Recipes **AI-21** to **AI-24**
rebuild every week (see `docs/fork/decisions.md`).

## Limits

- An estimate in years built from population studies; it says nothing about any one person's health.
- The calibration rests on four reference profiles; no independent validation exists.
- VO₂max from walks and runs assumes flat ground; hills read low.
- Steps and sleep come from a wrist band's own estimates.

## References

- Spiegelhalter D. *How old are you, really? Communicating chronic risk through 'effective age'.*
  BMC Med Inform Decis Mak 2016;16:104. doi:10.1186/s12911-016-0342-z
- Windred DP et al. Sleep 2024;47(1):zsad253. doi:10.1093/sleep/zsad253
- Saint-Maurice PF et al. Sleep 2024;47(3):zsad312. doi:10.1093/sleep/zsad312
- Paluch AE et al. Lancet Public Health 2022;7:e219. doi:10.1016/S2468-2667(21)00302-9
- Lee DH et al. Circulation 2022;146:523. doi:10.1161/CIRCULATIONAHA.121.058162
- Ahmadi MN et al. Eur Heart J 2022;43:4801. doi:10.1093/eurheartj/ehac572
- Momma H et al. Br J Sports Med 2022;56:755. doi:10.1136/bjsports-2021-105061
- Kodama S et al. JAMA 2009;301:2024. doi:10.1001/jama.2009.681
- Zhang D et al. CMAJ 2016;188:E53. doi:10.1503/cmaj.150535
- Jayedi A et al. Int J Obes 2022;46:1573. doi:10.1038/s41366-022-01165-5
