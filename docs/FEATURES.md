# NOOP Forge: Feature Guide

NOOP Forge is an offline-first companion app for WHOOP 4.0 and WHOOP 5.0/MG straps. It pairs directly with
the strap over Bluetooth, needs no WHOOP account and no cloud, keeps everything in one database on your
device, and works out its own daily scores from the strap's raw data: **Charge** (recovery), **Effort**
(strain) and **Rest** (sleep). Imports from other apps and wearables fill in history; an optional AI coach,
which you switch on yourself, can talk about your data.

It runs on iPhone and iPad, Mac, Apple Watch (as a companion) and Android. Android has been a released
platform since 13.0 (28 November 2026) and runs the same shared core as the Apple apps. This guide says
where a feature differs between platforms.

> **Not affiliated with WHOOP.** NOOP is independent interoperability software for your own device and your
> own data. "WHOOP" is used only to name the hardware NOOP talks to.
> **NOOP is not a medical device.** Every figure (heart rate, HRV, Charge, Effort, Rest, SpO₂, breathing,
> skin temperature, stress, ECG) is an approximation from published methods, not a clinical reading, and must
> not be used to diagnose, treat or make health decisions.

NOOP builds on community interoperability and protocol work, with thanks to:

| Project | Contribution |
| --- | --- |
| [`johnmiddleton12/my-whoop`](https://github.com/johnmiddleton12/my-whoop) | WHOOP 4.0 Bluetooth protocol: framing, commands, decoding |
| [`b-nnett/goose`](https://github.com/b-nnett/goose) | WHOOP 5.0 / MG Bluetooth protocol |
| [`groue/GRDB.swift`](https://github.com/groue/GRDB.swift) | On-device SQLite storage |

## Contents

1. [How to read this guide](#how-to-read-this-guide)
2. [Platform matrix](#platform-matrix)
3. [Today](#today)
4. [Training](#training)
5. [Nutrition](#nutrition)
6. [Sleep](#sleep)
7. [Health](#health)
8. [Body and energy](#body-and-energy)
9. [Goals](#goals)
10. [Coach](#coach)
11. [Devices and the strap](#devices-and-the-strap)
12. [Widgets, Live Activities, Siri and Shortcuts](#widgets-live-activities-siri-and-shortcuts)
13. [Apple Watch](#apple-watch)
14. [Mac](#mac)
15. [Android](#android)
16. [Data in and out](#data-in-and-out)
17. [Settings, Lab and Experimental](#settings-lab-and-experimental)
18. [Privacy-relevant network features](#privacy-relevant-network-features)
19. [For developers](#for-developers)

## How to read this guide

- **iPhone** means iPhone and iPad. The iPad runs the same layout as the iPhone.
- **Where** lines name the place in the app. Settings pages are named as they appear in the Settings hub.
- Status tags in brackets: *(optional, off by default)* means a switch you turn on. *(Settings › Lab)* is an
  early feature behind the Lab page. *(Experimental)* is labelled that way in the app. *(Test Centre)* is
  for bug reports and diagnostics only (Settings › Help and diagnostics › Test Centre). Anything without a
  tag is on and visible without a switch.
- **Two designs on Apple.** Since 20 November 2026 the iPhone has one design, called Forge: five tabs (Today,
  Training, Nutrition, Sleep, Health), tiles you arrange, and the drawn Alps, Coast or Meadow scenery. There
  is no switch to go back. The Mac keeps the classic design with a sidebar. Android uses Forge by default and
  has a "Classic screens" row in About that turns it off.
- Several screens appear on more than one platform under the same name. Where a feature is missing on a
  platform, the platform matrix and the section say so.

## Platform matrix

| Feature | iPhone / iPad | Mac | Apple Watch | Android |
| --- | --- | --- | --- | --- |
| Charge, Effort, Rest scores and pages | yes | yes | glance and face | yes |
| Today as arrangeable tiles with timeline | yes | no (classic Today with four layouts) | no | yes |
| Sleep tab, editing nights, naps, alarms | yes | yes (classic) | no | yes |
| Strap wake alarm | yes | yes | no | yes |
| Phone smart alarm with wake window | no | no | no | yes |
| Training: logging, routines, plans, library | yes | yes | strength workout only | yes (some gaps, see Android) |
| GPS workouts, voice feedback, auto-pause | yes | yes | no | yes (fewer pages) |
| Barometer elevation, laps, run plans, pacer | yes | partial (stored elevation) | no | no |
| Muscle map, Strength, Cardio, Training Load | yes | yes | no | yes |
| Nutrition tab, food database, barcode, diet plan | yes | no | no | yes |
| Body page, weight tracker, progress photos | yes | partial | no | yes (photo picker) |
| Energy and three burn estimates | yes | yes | no | yes |
| Health records (lab book) | yes | yes | no | yes (no PDF or photo reading) |
| Stress, Breathe, Intervals | yes | yes | Breathe and Intervals | yes |
| ECG with WHOOP MG (Experimental) | yes | yes | no | yes |
| Cycle awareness (optional) | yes | yes | no | yes |
| Fitness Age, Vitality, Trends, What works, Journal | yes | yes | no | yes |
| AgeLess and Daily rhythm (Settings › Lab) | yes | yes | no | yes |
| Goals (daily, weekly, monthly, long-term) | yes | yes | complication | yes |
| AI coach | yes (5 providers) | yes (5 providers) | no | yes (4 providers, see Coach) |
| Coach on-device semantic memory | yes | partial | no | no |
| Home Screen widgets | yes | no | n/a | yes |
| Lock Screen widgets, Live Activities, Dynamic Island | yes | no | no | no (ongoing notification) |
| Siri, Shortcuts, Home Screen quick actions | yes | partial (3 intents) | no | no |
| Apple Health connection | yes | file import only | n/a | no |
| Health Connect connection | no | no | n/a | yes |
| Strong, FitNotes, OpenGym import | yes | yes | no | no |
| Self-hosted push (Experimental) | no | no | no | yes |
| Wrist alerts for other apps, calls and timers | no | not live yet | no | yes |
| Demo data for users | no | no | no | yes (Demo flavor) |

## Today

Today is the first tab on iPhone and Android and the first sidebar entry on the Mac.

**Score rings.** Three glowing rings show today's Charge, Effort and Rest. Tap a ring to open its page.
Charge takes the colour of its band. While today is not scored yet, the last scored night's Charge is shown
with a caption saying whose it is, and a baseline that is still learning shows a "calibrating" countdown
instead of a stale number.

**Pinned score bar.** When the rings scroll off screen, a small capsule keeps the three values at the top;
tap it to jump back. (iPhone)

**Hold the rings to customise.** Holding the rings, or choosing Customize Today in the + menu, starts the tile
editor. (iPhone, Android)

**Header.** The + menu offers Start workout (or Back to workout), Add entry and Customize Today. A coach
button sits beside it when the coach is switched on.

**Add entry (Log).** One sheet logs a workout, weight, status, journal answers, drink, food, sleep, blood
pressure, mood, health records, medication, a breathing session or live heart rate. With the coach on it
also accepts writing, speaking or a photo.

**Activity status.** Tell the app you are ill, injured or on a break, for today, three days, this week, a
custom date or until changed. A line at the top of Today says the status holds and that training suggestions
are paused. The classic Mac Today has the same chip.

**Illness early-warning banner** *(optional, off by default)*. When two or more of resting heart rate, HRV,
skin temperature and breathing drift together from your own 28-day baseline, a banner appears on Today and
at most one notification a day. It is not a diagnosis. Switch: Settings › Alerts and reminders.

**First-run connection card.** On a fresh install a card shows the connection state and the one next step.

**Today's advice.** A card next to the rings says how hard to train today (Push, Steady, Easy or Rest today)
with an Effort target, from your Charge, recent load and plan.

**Detected activity prompt.** When the app finds a walk or workout you did not start, a prompt asks whether to
log it. See [Training](#training) for the switch.

**Morning suggestion** *(optional, needs the AI coach)*. Each morning the coach proposes today's session with
Accept, Change or Decline; after your decision it becomes the plan card.

**The day's hint.** One line under the rings for the most pressing thing: a raised warning, a plan waiting
for an answer, the newest coach note, other notices or "No weigh-in for a week". Dismissed ones stay hidden.

**Timeline.** A rail of today and yesterday: workouts, walks (two or more bundled), the night's wake-up, naps,
weigh-ins, drinks, food, journal answers, saved ECGs, coach notes (morning brief, check-in, nudge, weekly
review, after-workout, evening), notices and an end-of-day summary. A calm day says so. Notices (for example
"the night may not be fully synced") speak at most once in a few days unless the situation gets clearly worse.
(iPhone, Android; the Mac's classic Today has no rail)

**Tiles.** Today is a board of tiles. Remove with the minus, drag to reorder, switch small, medium or wide
where a card allows, and add from a gallery. VoiceOver can move and resize tiles by action. Three layout
choices: show or hide the timeline, whether tiles start under the rings or after the timeline, and two or
three tiles per row.

| Tile group | What is in it |
| --- | --- |
| Measures (26) | Charge, Rest, sleep duration, sleep debt, Effort, steps, active energy, heart-rate zone minutes (two tiles), HRV, resting heart rate, SpO₂, breathing rate, VO₂max estimate, stress, weight, body fat, lean mass, skin temperature, Fitness Age, Vitality, Body Age, calories in, protein, mood. Each shows the latest value with a change chip; some have a wide 30-day form. |
| Cards | Training load, Goals, Energy, Nutrition, Latest workout, AgeLess *(Settings › Lab)*, Last night, This week's plan, Way to your goal, Coach note, Tonight, Next session, What changed, What works, Breathe, Strap, Cycle *(optional)*, Momentum, Hydration, Live heart rate, Heart rate through the day, Stress through the day. |

**Heart rate through the day** shows the whole day's heart rate with last night's sleep band and a sport symbol
per workout, and opens the Deep Timeline. It was adopted from `DX23876/noop#58` by @sondrealf.

**Strap tile and battery page.** Battery, charging or off-wrist state and the last sync; the battery page adds
estimated runtime, Refresh battery and Manage devices. (iPhone, Mac; Android shows the battery in its header
and the Strap tile.)

**Momentum.** A ranked feed of what is worth saying right now: a missed planned workout, sessions still owed
this week, milestones, a needed rest day, recovery read, step goal, sleep catch-up, streak, HRV trend, health
alert, bedtime target, a strap battery that will not last the night, cycle phase and goal check-ins. It
appears as a tile, a hint and its own page.

**Updates inbox.** A bell on Today opens a calm, newest-first log of release notes, "new data arrived"
readings, strap heads-ups, activity-detection suggestions and dismissed cards you can restore.

**Search.** The Sleep and Health headers search across screens (workouts, plan, goals, stress, ECG, weight,
energy, journal and more).

**Look of Today.** Settings › Appearance sets the scene motif (Alps, Coast, Meadow), an optional time-of-day
sky, a custom background photo kept on the device, and how see-through cards and Today's tiles are. See
[Settings](#settings-lab-and-experimental).

### Today on Mac and Android differences

- **Mac** has four Today layouts, chosen in Settings › Appearance: Liquid (default), Classic, Trends Dashboard
  (four configurable metric slots and an Arrange dashboard editor) and Overview Dashboard. It also has the
  classic Customize Today sheet (section order and visibility), Key Metrics, Your Cards, a journal reminder
  strip and hosted cards (Sleep marks, Consistency, Sleep-debt ledger).
- **Android** adds a day header with a date picker and horizontal swipe to browse earlier days. The iPhone
  Forge Today shows today only.

## Training

The Training tab holds everything about exercise: this week's sessions, buttons to start or add a workout,
today's planned session, your routines, recent activities, key figures and the deeper pages (Strength,
Cardio, Training load, All workouts, Goals, Interval timer, This week's plan). The Mac has the same content as
a classic hub.

### Starting and recording

**One start screen.** Today's plan, a freestyle strength session, a routine or any activity starts from the
same screen: search, recent sports, a Strength section and about 107 activities (running, walking, hiking,
cycling, swimming, rowing, strength, HIIT, yoga, pilates, team and racket sports, snow sports, climbing, golf,
CrossFit, rucking, meditation, wheelchair and more). Distance sports default to recording a route; indoor
ones never ask for location. A Home Screen quick action also starts a workout (iPhone).

**Resume banner.** A running session survives closing the screen; the Training tab and a bar on other tabs
take you back.

**Planned today.** Shows the routine planned for today with Start, "Shorter, please" and "Other routine".
With the coach on, chips ask the coach to plan today or build a routine.

**Add workout and Log past workout.** Add a workout by hand with sport, start and end or duration, optional
distance, average heart rate and calories. Strength sessions can also be logged after the fact with a date,
optional routine and heart-rate source. (Android has the manual workout; a separate past-strength entry was
not found.)

**Heart-rate source.** A strap, an Apple Watch, an external tracker or none can be the heart-rate provider
for a workout; trackers are never averaged. (iPhone, Mac)

**Live workout screen.** Time, heart rate, Effort, distance, current and average pace, with pages for
Metrics, Zones, Elevation and Sections; pause, resume and end with confirmation. Recordings under a minute
offer save or discard. Android has fewer pages.

**Guided training** *(Settings › Training, Beta)*. A silent-guardian session: the strap buzzes only when your
heart rate leaves your range.

**Haptic zone coach.** Pick a target heart-rate zone before starting; the strap buzzes "faster" or "slower"
when you stay outside it.

**Interval timer.** A hands-free HIIT timer with presets (Tabata 20/10, 4 x 4 min, EMOM 10, 30/30 x 10) and
custom work, rest and rounds. The strap buzzes at every change: triple buzz to work, single to rest, 3-2-1
ticks, a long buzz at the end. It also works as a visual timer without a strap. The Watch has its own version.

### GPS and distance activities

| Feature | What it does |
| --- | --- |
| Route recording | Outdoor activities record a GPS route, drawn live and afterwards. A card with Open Settings appears if location is denied. |
| Honest GPS filter | Distance counts only when the phone is sure you move; weak or jumpy points are dropped and a signal gap shows as a gap, so it may record slightly too little, never too much. |
| Voice feedback *(optional)* | Spoken updates every 0.5, 1 or 2 km (or miles), or every 5, 10 or 15 minutes, with split pace and heart rate; offline, in the app language, through headphones by default. |
| Target-zone warnings *(optional)* | Phone and strap tell you when you stay outside your chosen zone. |
| Pace or speed warnings *(optional)* | A range for running pace or cycling speed; warns after ten seconds outside it, at most once a minute. |
| Auto-pause *(optional)* | GPS running and cycling pause after five seconds stopped and resume after three moving. |
| Run plan with phases *(optional)* | Warm-up, work, recovery and cool-down by time or distance; templates; skip or edit upcoming phases. (iPhone, Mac) |
| Pacer *(optional)* | A goal time for a distance with ahead or behind shown. (iPhone, Mac) |
| Laps and splits | Mark a lap by hand; GPS adds distance splits with pace, gaps, flat-equivalent pace and heart rate. (iPhone, Mac) |
| Elevation | Climbed, descended, steepest grade and an on-the-flat pace from the iPhone barometer, Apple Health or an imported file; without a barometer the app shows none rather than guessing. (iPhone; Mac reads stored elevation; Android no) |
| Sensor readout | A connected footpod, cycling speed and cadence or power sensor shows on the live screen. (iPhone, Mac) |
| New best split | After saving, the app says when you ran your fastest split of that distance so far. (iPhone, Mac) |
| Unsaved recording protection | If saving fails, the recording stays on the device and "Try saving again" appears. (iPhone, Mac) |

Cadence warnings are not offered.

### Strength logging

A native in-gym logger: each exercise with last time's numbers beside each set, number-pad entry, a set tick
that copies last session's values, time, volume, sets done, and live heart rate and Effort. It works offline.

- **Layouts:** One exercise, All exercises or Compact.
- **Measurement types:** weight and reps, bodyweight reps, added weight, assisted bodyweight, reps only,
  duration, distance and duration, weight and duration, distance and weight. Timed sets have a start button
  (iPhone, Mac).
- **Rest timer:** ticking a set starts a countdown with -15 s, +15 s and Skip; a notification, sound,
  vibration and a triple strap buzz five seconds early announce the end.
- **Lock Screen and Dynamic Island controls:** next set, rest countdown, -15, +15, Skip and a Set done button;
  cardio workouts get Pause and End. (iPhone only)
- **Strap double-tap** *(optional)* logs the next prepared set; one buzz confirms.
- **Plate calculator** shows plates per side for a target weight, with equipment profiles.
- **Supersets, warm-up sets** (added by hand or suggested as a ramp, kept out of volume and records), **set
  types** (working, warm-up, drop, rest-pause, AMRAP, to failure) and **one-arm or one-leg exercises** with
  left and right logged separately.
- **Set effort** *(optional)*: rate each set by RIR or RPE, or switch off.
- **Progression hints:** each exercise shows last time and a hint for today. Policies per routine or exercise:
  Off, Linear, Double progression, Greyskull LP, Time progression.
- **Session rating** *(optional)*: rate the whole session 1 to 10; NOOP multiplies by duration for a separate
  session load.
- **In-session options:** move, swap, remove, skip remaining sets, history, notes, add exercise or a whole
  routine.
- **Summary:** volume, warm-up count, muscles trained, new records and "Update your routine".
- **Keep this session as a routine** turns what you did into a routine.
- **Training settings** *(Settings › Training)*: weight unit (kg or lb, display only), weight step, available
  equipment, sets for a new exercise, exercise media size, keep screen on, rest weekdays, week start.

Android has the logger, rest timer, plate calculator, warm-ups, set effort, progression and left-right sets.
Timed sets and creating supersets mid-session were not found there.

### Routines, plans and programs

- **Routines:** saved workouts with exercises, sets, repetitions, rests, weights and notes; scheduled
  weekdays; estimated duration.
- **Weekly schedule and day override:** choose which routine falls on which weekday and change a single date.
- **This week's plan:** a day-by-day view of done and planned sessions with Effort per day.
- **Build a plan:** a generator from your answers (sessions per week 2 to 6, minutes, experience, lean,
  your equipment, optional fixed block). Works offline, no coach needed.
- **Ready-made plans:** Full body (3 days), Upper and lower (4), Push-pull-legs (6), Body weight only (3),
  5x5 and Greyskull LP.
- **Following a plan:** Strength, Conditioning or Mobility plans; one strength plan at a time plus one other
  kind. Plans can run in blocks with a lighter week and a block report, and a plan review lists findings
  about balance and load.
- **Share and export a plan** as a file or PDF, and import it back (iPhone, Mac).
- **Spreadsheet import** of a program from a template (.xlsx or CSV) (iPhone, Mac).

### Exercise library

1,324 exercises searchable by name, muscle or equipment, with favourites, "Done before", filters by body
region, muscle and type, descriptions, your own records and history. **Find by muscle** uses a body picture.
**Create your own exercise** stays on the device. Each exercise shows an estimated one-rep max (labelled a
projection) and best volume.

**Exercise media pack** *(optional download)* adds exercise animations from an external source, with a
disclosure of source, size and rights. It is stored privately, left out of backups, and can be deleted,
disabled or downloaded again. Everything works without it. An advanced option loads exercises from your own
ExerciseDB-style provider key, or imports a licensed catalogue file.

### Detected workouts

**Detect activities** *(Settings › Training, Beta, off by default)* looks after a sync for walks and stretches
of raised heart rate and asks what they were; nothing is saved until you answer. Options: Detect walks (from
the step track, not available on WHOOP 4.0, which sends no steps), How often to ask (Detect more, Balanced,
Only clear ones) and Notify me (at most two a day, never at night). Candidates appear on Today and in the
Updates inbox with "Other kind", "Not training" and "Later".

**Workouts list.** Strap-detected, imported and your own workouts in one list with a menu: Edit details,
Dismiss, Duplicate as manual, Delete. Edited averages are marked and the graph stays from the recording.

**Help teach the app** *(optional)* records short raw motion stretches during chosen sports so a sport
detector can be built; nothing is ticked by default and sending is a separate step. See
[Privacy](#privacy-relevant-network-features).

### History and analytics

| Page | What it shows |
| --- | --- |
| All workouts | All sessions with scope picker, typical Effort, a 13-week active-calorie heatmap, activity breakdown, zone share and heart-rate recovery trend. |
| Workout detail | Heart-rate graph, zones, Effort contribution, route, elevation, splits, first-minute heart-rate recovery, session rating, export and edit. |
| Strength | Planned today, tonnes lifted per week, working sets per muscle against your usual, exercise progress, recent personal records and sessions. |
| Muscle map | One body (front and back) showing balance, fatigue and strength trend per muscle, with a "right now" and a weekly view and a four-option recovery answer (iPhone, Mac). |
| Cardio | The week's cardio load, time in zones, per-sport progress, your bests per distance band and session lists. |
| Training Load | Strength and cardio in two lanes against your own history, with "Room today", the shape of the week, an overload note, recovery of the last seven nights and an eight-week status history. |
| Training history | Strength, Cardio and Session load over 3 months to all time with a Jump to date picker, e1RM lines and a VO₂max line. |
| Consistency grid | A year of training days as darker squares by time logged. |
| Same session | When strap and watch recorded the same activity, the app asks to Merge or Keep separate. |

**Today's advice, Enough this week, Focus.** Advice cards come from Charge, load and plan. "Enough this week"
counts active minutes and strength days against a weekly target. The Training Load settings set a focus
(Automatic, Lose weight, Fitness, Strength, Health), a switch for pulse-altering medication or a pacemaker
(minutes then count by duration and rating), an optional Morning advice notification and *(optional, off by
default)* new fitness markers: pulse at your usual walking pace, pulse drop after hard sessions, pulse at
your usual pace on flat ground.

**VO₂max.** A weekly estimate from profile and resting heart rate, an entered value or an Apple Watch reading
(counted for six months), used for workout calories. **Training-based VO₂max** *(Settings › Lab)* estimates it
from runs and walks with distance and heart rate and is shown on Training Load only.

### Training imports and Hevy

- **Hevy API sync** *(optional)*: your own Hevy API key brings sets, reps, weight, RPE and exercises, with
  optional automatic sync (6 h, 12 h or daily) and Remove data. Lifting volume never becomes cardio Effort.
- **Import Hevy routines**, **Hevy CSV and Liftosaur JSON history**.
- **FitNotes and Strong CSV history** and **OpenGym plan import** (iPhone, Mac; not on Android).
- **Coach drafts to Hevy:** the coach can draft a routine or workout; nothing is written to your Hevy account
  until you review it and press the send button.

## Nutrition

The Nutrition tab (iPhone) and Food page (Android: More › Health and body › Food) log what you eat. There is
no Food page on the Mac.

**Day view.** A plate figure with the day's calories and macronutrients, day arrows and a calendar, a
sentence for what is left, meals grouped by meal and a week strip.

**Add food.** Search with recents, favourites and a cart: add several foods, choose meal and time, add all
at once. A warning appears when a losing day would clearly go over its goal.

**Food database.** The German Bundeslebensmittelschlüssel 4.0 plus your own foods, always offline.

**Branded products** *(optional, nothing goes online until you choose)*. First-run choice: Off, Search online
(words and barcodes go to Open Food Facts, no account) or Download for offline (public country files from the
project's GitHub release, searched on the device). An extra switch looks up unknown barcodes online.

| Way to add | How it works |
| --- | --- |
| Barcode scan | Camera or typed number; an unknown product can be entered from its label. |
| Label reading | Photograph a nutrition label; it is read on the device and shown for checking before saving as your own food. |
| Quick calories | Calories only, optionally protein, carbs and fat. |
| Describe *(needs the coach)* | Write or photograph a meal; the coach's model names foods and amounts, and every nutrient comes from the database, shown as a list to check. The text or photo goes to your coach provider. |
| Copy and repeat | Copy a meal to chosen days or every ticked weekday up to a date. |
| Favourites, saved meals, recipes | Star foods, keep a meal, build a meal, turn a logged meal into a recipe. |
| As usual | A meal eaten on several recent days is offered again at its usual time. |

**Portions and entries.** Pick grams, ml or a portion; edit amount, time and meal; correct a product's values
and save the correction as your own food.

**Complete day.** Mark a day as completely logged; only complete days count when the app works out your real
burn from food and weight.

**Nutrients.** A nutrient card and a full Nutrients page with day and 7-day views, recommended amounts
(protein, fibre, fats, salt, vitamins, minerals), the foods each came from, and hold-to-pin.

**Nutrition score.** A 0 to 100 score for how healthy the week's eating was, with day, week and month notes
and a trend. No score below five logged days of seven; nothing is stored.

**Badges and streak.** For staying with logging and eating well, with a streak that bridges one missed day a
week. It never rewards weight loss or a larger deficit.

**Food goals.** Calories and macros come from the diet plan; Android also offers a fixed calorie and macro
goal. Training and rest days differ.

**Reminders** *(optional)*. A morning look back, an evening reminder only when one meal can still close a gap,
and a warning while logging.

**Meal pictures** *(optional, default on)*: your photo or a drawing of the main food. **Fill in missing
nutrients** *(optional)*: the coach finds the most similar database food and marks the values as estimated.

**Write meals to Apple Health or Health Connect** *(optional)*. Each meal goes with its nutrients; NOOP does
not read its own meals back. Health Connect nutrition is also imported on Android.

**Nutrition widget** and Today tile show calories left with protein, carbs and fat.

### Diet plan

A planner inside Nutrition that sets calories and macros and adjusts them weekly. Simple asks a few questions;
Advanced exposes every dial. Goals: lose, maintain, gain or recomposition, with a goal weight (floored at the
lowest healthy weight for your height), a pace (gentle, normal, ambitious) and a pregnancy or nursing check.

- **Twelve ways of eating:** balanced, Mediterranean, DASH, high protein, flexitarian, low fat, low carb,
  keto, 16:8, 5:2, alternate day, alternate day full fast. Keto and fasting forms are Advanced only. Foods
  that suit the plan carry a small leaf; nothing is forbidden.
- **Weekly steering, diet breaks and phases:** the goal follows the weight trend each week with an Adjust
  prompt, or calories only, or only you.
- **More on active days** *(optional)*: more carbohydrate on training days and half of the extra strap-measured
  burn added on active days.
- **Forecast chart:** where the weight is heading, "a band, not a promise".
- **Protein helper** (iPhone): last week's average against the goal and everyday portions that would close
  the gap.
- **Hide weight and numbers** and a **burn source** choice (strap or scale) *(optional)*.
- **Ask the coach** about the plan; the coach can propose a change for you to accept.

## Sleep

The Sleep tab shows one night at a time. The Mac has the classic Sleep page with an Arrange sheet; the iPhone
Sleep tab has a fixed card order.

**Night navigator and cards.** Step through nights. The night card shows bed and wake times, the stage bar
(Deep, REM, Light, Awake), time in bed and efficiency, with a note when stages are approximate. The chart
style is Classic, Filled or Ribbon (Settings › Appearance). While last night is not in yet, a card says why
(syncing, failed sync, no night found).

**Stages against your typical night.** Deep, REM, Light and Awake minutes with a mark for your usual from the
last 30 nights.

**What shaped the night.** Rings for hours against need, efficiency, steadiness, restorative sleep and
breathing rate, each against usual. **This night: signals** lists wake-ups, night resting heart rate, HRV,
skin temperature and breaths per minute.

**Sleep need and debt.** The need that Rest and the debt are measured against comes from your own history and
age. The debt ledger estimates sleep owed over the last fortnight with per-night bars; small debts read as
balanced.

**History and highlights.** Hours asleep per night over a week, month or year with the need line, and a
highlights carousel of what stood out.

**Body clock dial.** A 24-hour dial comparing when you slept with when your body clock wanted the night,
from your nightly temperature.

**Tonight.** The planned bedtime for a full night from your need and wake time.

### Editing

- **Edit a night's times** with the pencil; the day is re-scored and sleep outside the new times is removed.
  A short Undo strip follows every change.
- **Delete a night or a nap.** The app stops re-detecting a deleted window. **Deleted nights** lists them with
  Recompute and Hide.
- **Add a sleep by hand** for a night the strap missed or a nap; it refuses overlap and warns when the strap
  recorded nothing for those hours.
- **Naps** are listed under the night. **Sleep marks** ("Going to sleep", "I'm awake") log a timestamp without
  changing detected sleep.

### Alarms

| Feature | Description |
| --- | --- |
| Strap wake alarm *(off until armed)* | Arms the strap's own silent alarm at your wake time so it buzzes even with the app closed. Needs a bonded strap; works on many 5.0 and MG straps, not certain yet. A "Check what the strap has stored" read-back and reset guidance are included. |
| Different wake time per day *(optional)* | Weekday overrides move both the strap alarm and the evening reminder. |
| Wind-down reminder *(optional, off by default)* | A calm evening reminder timed back from your wake time and sleep need. |
| Next alarm countdown | Shown only when something will actually fire. |
| Phone smart alarm *(optional, Android only)* | An earliest wake time and a window; if a lighter sleep phase is seen inside it the phone wakes you then, with an exact alarm at the end of the window. |

The iPhone app is sideloaded and cannot sound a dependable loud alarm. It says so on the Alarms page and
schedules a backup notification at wake time. Alarms: Sleep tab rows, More, or the Mac sidebar.

**Coach and goals on Sleep.** A button sends a prepared question about last night to the coach *(needs the
coach)*; a goals card shows sleep goals.

**Customize Sleep** reorders or hides cards (Mac, Android).

## Health

On iPhone the Health tab is the hub for vitals, focus areas and long-term patterns; the Mac has a classic
Health page (Vital Signs, Heart Rate, Skin temperature, Fitness Age, Vitality, Contributors).

### Vitals and focus areas

**In range.** A hero shows "N of M in range" for last night's vitals (HRV, resting heart rate, SpO₂,
breathing, skin temperature). An out-of-range vital gets a card with one sentence and coach chips.

**Vitals tiles.** Up to nine editable tiles (HRV, resting HR, blood oxygen, breathing rate, skin temperature,
SpO₂ estimate, AgeLess, VO₂ Max, weight, stress, steps). Hold to edit; two or three per row. Badges say In
range, Estimated or off.

**Focus areas.** Six hubs: Fitness, Sleep, Heart and vitals, Body and nutrition, Mind and stress, More. Each
lists its tiles and a list of pages in that area.

**Long term and patterns.** Rows to the Weekly report, Trends, What works and All metrics, plus "Your week in
rings".

**Metric pages.** Resting heart rate, HRV, breathing and skin temperature each show the value, a trend range
from a week to all time, delta, readings and "What correlates". Skin temperature shows the deviation from
your baseline in your unit. **SpO₂** is an on-device estimate always shown and marked "Estimated".

**Explore** lists about 55 measures across Heart, Charge, Rest, Effort, Health, Nutrition and Mind from WHOOP,
Apple Health, Mi Band and logged sources. **Deep Timeline** is a zoomable whole-day line for one metric down
to the raw per-second signal, with the sleep band and a symbol at each workout.

**HRV snapshot.** A 60-second seated capture from live beat-to-beat intervals shows RMSSD, SDNN, mean heart
rate and beats used, and can be saved beside other HRV sources. It needs a connected strap.

**Fitness Age, Vitality, Body Age.** Weekly figures as tiles and pages. Fitness Age compares your cardio
fitness with typical people of other ages (a fitness comparison, not a biological age).

**Health records.** A private notebook for blood tests, blood pressure, body numbers, imaging and notes, with
a trend per marker. The app never judges a value as normal, high or low. Add readings by hand, import a
markers CSV, or read a lab report from a PDF or photo (text is read on the device and shown for review;
nothing is uploaded; not on Android). A marker can be compared with resting heart rate, HRV, sleep, Charge
or weight over the 7, 14 or 30 days before each reading.

### Stress and mind

**Stress.** A page with today's 0 to 3 stress (Low, Medium, High) and a one-line reason, the day by the hour
(waking hours only; hours with too little heart rate are masked; activity is masked rather than scored), a
Calm, Moderate and High totals bar, a 30-day trend and markers. A long high run shows a warning with a
Breathe button. **Advanced HRV** adds extra measures on request and does not change the stress score.

**Personal stress baseline** *(Settings › Lab)* scores hourly stress against how your days usually run. It
never feeds Charge or illness.

**Stress check-in** *(optional, off by default, Settings › Strap actions)*. After a fresh HRV dip while you
are still, a one-minute breathing offer with a confirming buzz. Options: auto-nudge, respect quiet hours, use
my resonance pace.

**Mood.** Five faces for today (editable for the day); after seven check-ins, up to three lines about what
tracks your mood. Self-tracking, not clinical.

**Breathe.** Guided haptic breathing with 22 patterns and Open, 5, 10 or 15 minute sessions. A bonded strap
buzzes once on inhale and twice on exhale; without a strap it is visual only. It shows live heart rate and
HRV, audio cues and a before and after HRV outcome.

| Group | Patterns |
| --- | --- |
| Everyday | Relax 4-6, Coherence 5.5, Box, Deep, Diaphragmatic, Coherent 6-6, Presence tempos |
| Traditional | Alternate Nostril, 4-7-8, Buteyko, Tummo, Ujjayi, Bhastrika, Qi Gong, Soma |
| Guided only | Kapalabhati, Holotropic, Wim Hof, Shamanic |

**Find your resonance pace.** A quick (about 7 minutes) or full (about 13 minutes) sweep measures your heart
response and locks your personal breathing pace. **Calm me** is a three-minute felt rhythm on the wrist just
below your heart rate; it never paces below a safe rate and is not cardiac control.

### Trends, insights and journal

**Trends.** Range from a week to all, a Charge chart, daily signals (HRV, resting HR, Effort), a Charge year
heat strip and a weekly digest with week-over-week changes. **Export trends report** makes a one-page PDF on
the device. **Weekly report** (Health › Weekly report) shows the week in figures against last week,
highlights, Charge per day, sleep against need, load and goals, plus the coach's weekly review if the coach
is on.

**Compare.** Overlay up to four metrics, each on its own scale, with "How they move together".

**What works.** A ranked, lag-aware list of which logged habits move your Charge, with with and without
averages, an effect size in words, and dose response for alcohol and caffeine timing. It needs journal
history. **What changed** compares this week with last in a word.

**Journal.** Yes/no and numeric habit questions in groups (Nutrition, Supplements, Lifestyle, Health,
Behaviour, Other), your own questions, rename, regroup, reorder, hide, and a duplicate finder *(needs the
coach)*. Imported WHOOP journal history joins the same questions. Also on the Journal screen: behaviour
effects, metric relationships, the personal recovery cost of tagged activities, and a personal experiment.

**Caffeine window.** Log a coffee, tea or energy drink; a rough "still active" estimate from a 5 to 6 hour
half-life; an optional warning when logged too close to bedtime *(optional)*.

**Values by source.** The best-sourced value per core metric with a note when several sources report it.

### ECG and heart rhythm

**ECG with WHOOP MG** *(Experimental)*. Sit still and hold the clasp indents for about 40 seconds. You see the
trace on a paper-style grid, an average beat with intervals and irregular beats, and can save it. Needs a
WHOOP MG and the ECG switch under Settings › Experimental WHOOP 5/MG. It is not a medical device and is not
clinically validated. **Apple Watch ECG comparison** reads Apple Watch ECGs from Apple Health beside the
nearest strap reading (iPhone, read-only).

**Heart rhythm** *(Experimental, off by default)*. A scatter picture of last night's beat timing with neutral
wording and descriptive numbers; you must read and accept an experimental notice. It is not a screening.

### Cycle awareness

*(optional, off by default; only offered to profiles it applies to)*. Log period starts, symptoms and mood;
NOOP reads the nightly temperature rise to show the phase (Period, Follicular, Mid-cycle shift, Luteal), the
cycle day, a next-period window, a skin-temperature chart and a calendar. Short cards per phase (Mind,
Exercise, Body) name their sources. **Likely fertile days** shows a rough window after three cycles with a
clear rise or a positive ovulation test, with an optional reminder and a discreet Lock Screen mode. **Learn
from my training** compares how sessions felt per phase *(optional)*. It is awareness only, not contraception.

### Healthspan ages (Settings › Lab)

- **AgeLess** *(Settings › Lab, beta)*. A health age from nine measures over six months with an aging speed, a
  six-month projection and the steps that would help most. Needs 30 nights; replaces Body Age; a lever can
  become a goal. Not a medical age.
- **Daily rhythm** *(Settings › Lab, beta)*. A rhythm age from how your day's movement over a week compares
  with a large study. Needs a WHOOP 5.0 or MG worn day and night for three days.

## Body and energy

### Body

One page for weight, body fat and tape measurements, each with its date and source so a DEXA scan and a tape
estimate never share a line. (iPhone, Mac, Android)

- **Measure.** One sheet records any mix of body fat and 15 tape sites (neck, shoulders, chest, waist,
  abdomen, hips, thigh, calf, biceps, forearm); only filled fields are saved.
- **Measured body fat with its source:** DEXA, caliper, BIA scale or InBody.
- **Tape body-fat estimate** with the Navy equations, on its own line with an error band.
- **What changed** compares each site now with 3 weeks, 6 weeks or 3 months ago, counting only changes larger
  than your own tape scatter; **change since the first reading** draws weight, waist and body fat as percent
  change.
- **Per-site history** with edit and delete, and **how to measure it** guides.
- **Progress photos:** front, side and back, one per pose per day, compared then and now. Photos stay on the
  device, are not written to the photo library and are not in a backup. The iPhone uses the camera with a
  placement frame; Android uses the photo picker; the Mac shows stored photos.
- **Reminders** *(optional)*: a weekly measurement and a daily weigh-in.

### Weight

A weight tracker that shows the trend behind daily ups and downs. Overview: latest weigh-in, trend, goal
progress as a route of stops, forecast and change figures. History: dots for the scale and a line for the
trend with a table. Reports: months or years with lowest, average, trend change and per-week change.

- **Log, edit and delete** weigh-ins. An optional **water mark** (creatine, period, salty food or a party,
  new medicine) leaves a weigh-in out of the scale-based burn estimate. Weigh-ins from Apple Health or Health
  Connect appear too.
- **Forecast and plan rate:** when the trend reaches the goal at the current, overall or plan rate, with
  honest messages when data is too thin or the goal is over three years away.
- **Weight dates:** add a date such as a holiday; the app shows the expected weight, counts down and compares
  afterwards.
- **Settings:** trend basis, rate mode and window, plan rate, and a weigh-in reminder that stays quiet on a day
  already weighed.
- **Widgets:** four tracker widgets (trend, this month, figures, on a date) and a simple Weight widget.

The Mac compiles the weight page but a Mac entry point was not found.

### Energy

**Energy page.** Today's energy by tonight as a range, split into resting, everyday (sitting, standing,
digesting), daily movement, training and eaten, with a day picker, a 30-day chart switchable between Burned,
Eaten and Balance and a usual-day reference. Read the balance over a week.

- **Three estimates of daily burn,** never averaged: what a formula predicts from height, weight and age, what
  the strap measured, and what food and scale imply. The spread is printed rather than one number.
- **Burn rate through the day** in kilocalories per minute, compared with the previous day or the median of
  the last 7 or 30 days.
- **Basal formula:** Mifflin-St Jeor (default), revised Harris-Benedict, Katch-McArdle (needs a body-fat
  reading) or a measured resting rate you enter.
- **Activity level and onboarding,** and a target rate (hold, lose or gain per week) with an energy density
  tuned to the body.
- **Food and scale balance check:** maintenance from logged intake and weigh-ins after about two weeks of
  logs, with a warning that most people under-log.
- **Digestion:** about a tenth of what you eat, shown against food.
- **Your scale:** after about six weeks of fully logged days the app proposes a correction of the strap's burn
  to agree with the scale; it is never applied without your Adjust (iPhone, Android).
- **Apple Watch calibration** *(optional)*: a bounded factor (0.80 to 1.20) corrects the strap's active
  energy against time-aligned Apple Watch energy. Apple stays a reference (iPhone, Mac).
- **Data quality and calculation page** explains how the day was calculated. On Android it is reduced.
- **Calories in without a diary:** type a day or let Apple Health nutrition supply it; a typed day wins over
  Food meals, and Food meals win over Apple Health.
- **Energy widget** with total, active and basal calories.

## Goals

**Goals hub.** Overview of daily, weekly and monthly, long-term, paused and ended goals, with a filter, "How
goals work" and Goal settings. Found in the Training tab and More, with goal cards on Today, Training and
Sleep.

- **Daily goals** (steps, active calories, sleep, workout, tick box, journal habit): up to three show as
  rings on Today; schedules by day or weekday; some tick themselves from steps, sleep or workouts.
- **"Done yesterday?"** asks the next day for boxes the app cannot see; "Still open from the last days" lists
  unanswered ones.
- **Weekly and monthly goals:** set up in steps with easy, recommended and ambitious levels from your own last
  weeks. Metrics: workouts, training minutes, distance, step days, nights of enough sleep, average sleep,
  zone 2+ minutes, working sets, active energy, rest days, hydration days, habit days, strength minutes,
  moderate and vigorous minutes.
- **Fair pace:** weekly targets are spread over planned training days with rest days left out, with a marker
  for where you should be today.
- **States in words:** Reached, Ahead, On track, Close, Behind, Out of reach, Protected.
- **Pause and protection:** pause a goal with a reason (Illness, Pain, Travel, Life, Other); paused weeks are
  protected.
- **Correct what counted** (iPhone, Mac).
- **Long-term goals** from about 30 templates: endurance, strength, heart and fitness, everyday, body, sleep
  and recovery, habits. Each is drawn in its own shape. The page has milestones, "Extend the date" and weekly
  step-ups. **Start packs** are ready-made bundles (iPhone, Mac).
- **Safety and realism checks:** weight-rate warnings (never block), feasibility from your own history,
  combined-volume warnings and conflict notes.
- **Streaks, badges and records** *(optional)*, a **looking back** review and an **archive** of ended goals.
- **Goal notifications** *(optional, off by default)*: at most two a day, never after 21:00 or during a
  workout. Android adds Tick off and Remind me in 1 hour actions.
- **Goal widgets and complication, Siri.** See [Widgets](#widgets-live-activities-siri-and-shortcuts) and
  [Apple Watch](#apple-watch).

## Coach

An optional assistant that talks about your own data. It is **off by default**; you turn it on in Settings › AI
Coach and connect a provider with your own key. Nothing leaves the device until you ask a question, and a
"Before you talk to your coach" sheet explains what is sent.

**Providers.** OpenAI, Anthropic, Google Gemini and OpenRouter, plus Custom (any OpenAI-compatible server,
local or self-hosted). iPhone and Mac offer all five. **Android has four: OpenAI, Anthropic, Gemini and
Custom; it has no OpenRouter and no model search.** A model can be picked or typed; Disconnect keeps the key
and Forget deletes it. Custom sends the pre-assembled context rather than offering tools. The app counts
tokens on the device and shows approximate cost.

**Chat.** Streaming replies with Markdown, an evidence line (tools used and local context read), copy, share,
edit and ask again, regenerate, trend charts and metric or workout cards drawn inline, voice input (iPhone,
Android), and conversation history with search, pin, rename, archive and delete. Optional past-chat
summaries send the chat to your provider.

**40 data tools and 10 data purposes.** A model that supports tools may use 40 tools: read tools for biometrics,
sleep, workouts, strength, training load, stress, energy, body, metric history and the food log; write tools
for caffeine, journal, lab markers and weight; proposals that never commit alone (plan, goal setup, diet
change, Hevy routine and workout); memory tools; and chart and card tools. A master switch "Let the coach use
my data" and ten purposes decide which are offered: Core biometrics, Long-term trend, Workouts, Planning,
Stress, Food, Logging, Sensitive journal, Memory tools and Patterns. Four simple levels (Essentials, Personal,
Deep insights, Expert) set them together. A tool whose purpose is off is not offered to the model. The
sensitive journal always needs its own choice. Food is on with the coach by default.

**Memory.** Durable facts by category (Goal, Injury, Preference, Physiology, Schedule, Other) with importance,
source, expiry and a health marker; edit, add, forget one or forget all. A memory receipt under a reply shows
what was saved, with undo. On iPhone an embedding model bundled in the app finds related saved text without
uploading it. **Android has no on-device memory model**, so it uses keyword retrieval; the Mac is
expected to fall back the same way.

**Identity and style.** Name and picture (two ready-made coaches, a symbol or your photo, which stays on the
device), a tone (Warm, Grounded, Neutral), a persona (Guardian, Friend, Commander), reply length, emoji,
proactive level and three quick presets. Replies use the app's language. Coach instructions can be edited.

**On Today and in notifications** *(each optional)*. A coach card, a movable floating button and an unseen dot;
the morning suggestion; a **morning brief** at a time you choose; a **daily check-in**; **plan reminders and
nudges** with a budget of three coach-started messages a day, quiet hours and a "why am I seeing this?" sheet
with a switch for that kind. **Log with the coach** accepts writing, speaking or a photo. **Ask coach** on a
metric page sends a short card read.

**Plans and goals.** The **plan book** collects every session the coach suggests for your yes first: move,
swap, "Didn't happen" with a reason, rate the effect. The coach can draft goals and routines for review
and Hevy routine or workout drafts; nothing is committed until you send it.

**Backup.** Coach identity, facts, plan book and consents travel in an optional entry of a `.noopbak`.

## Devices and the strap

**Supported devices.** WHOOP 4.0 and WHOOP 5.0/MG give live heart rate, beat-to-beat intervals, battery,
history sync, buzz and alarm over Bluetooth. A model picker is on the Live screen, onboarding and the Strap
page. A 5.0/MG pairs with one host at a time. Other sources: any Bluetooth heart-rate strap (Polar, Wahoo,
Coospo, Garmin HRM and similar), gym equipment (treadmill, bike, rower, cross-trainer through Bluetooth
FTMS), and an Apple Watch as an Apple Health source. *(Experimental)* tier: Oura ring local take-over (beta,
with an irreversible-consent tick), Amazfit/Zepp and Xiaomi Mi Band best-effort heart rate, Garmin watch via
Broadcast Heart Rate.

**Add a device.** A four-step wizard (type, get-ready checklist, scan and pick, name and confirm). **Devices**
lists every device with Make active, Rename, Remove (data kept), Delete this device's data, Forget device,
Stop sync, Restart strap and ECG reading (MG). Cards show battery, charging, last seen, firmware, clock drift
and pairing notices. **Merge WHOOP entries** joins entries piled up from replaced straps, after a typed
confirmation and a full backup.

**Standard HR mode.** When a 5.0/MG will not complete the full bond, NOOP still reads live heart rate through
the standard service and says that buzz, alarm, battery and history need a full sync.

**Strap sync.** History is offloaded every 15 minutes while connected, on connect, when the app comes to the
foreground, on manual Sync now and as automatic continuation of a deep backlog. Automatic triggers back off
after empty syncs. *Keep screen on while syncing* is optional (iPhone).

**Live screen.** Live heart rate, zone, rolling RMSSD, battery, strap log, Start workout, HRV reading, Buzz
strap, Reconnect and Disconnect. The strap log is kept across restarts (about 2 MB) and exported with earlier
runs.

**Strap actions** (Settings › Strap actions):

| Feature | What it does |
| --- | --- |
| Double-tap action *(optional)* | Nothing, Buzz back, Mark a moment, Log a sleep mark, Buzz the time, Run a Shortcut (Apple), Lock Mac (Mac). In a strength session the double-tap logs the next set. |
| Wear and presence *(optional)* | Run a Shortcut when the strap is taken off or put on; on Mac, lock the Mac when you take it off. Not on Android. |
| Haptics toggles | Choose which cues buzz the wrist: breathing pacer, interval timer, Live session cues, workout start and end. |
| Heart-rate ceiling *(optional)* | Buzzes when smoothed heart rate reaches a ceiling (profile zone or fixed BPM), always or only during workouts. A training aid, not medical monitoring. |
| Inactivity reminder *(optional)* | Wrist buzz when seated too long, from strap motion at each sync. |
| Wrist alerts master switch | The gate for every wrist buzz. |
| Stress check-ins *(optional)* | See [Stress](#stress-and-mind). |

**Wrist alerts for other apps** *(optional, Android)*. Chosen apps' notifications, phone and VoIP calls and
native timers buzz the strap with a per-app pattern; it reads which app posted, never the content. The Mac
screen exists but says delivery is not live yet.

**Heart rate sharing** *(optional)*. Re-broadcasts live heart rate to Garmin, Zwift, treadmills and bike
computers: "Via this phone" while the screen is open, and "Via strap" (a reversible flag on a 5.0/MG that
keeps working without the app). A Mac cannot write the strap flag.

**Battery.** Low (15%) and charged notifications once per charge cycle, a predictive "recharge tonight"
heads-up and a stale-battery check *(optional, default on)*. **Battery and Recording** *(optional)* offers
power saving with a threshold, Pause HRV capture while low, Low refresh (hourly background sync) and
Continuous HRV with a Nights only choice.

**Strap rename** changes the Bluetooth name of a WHOOP 4.0 (Android also an experimental 5.0/MG rename).

**Android keep-alive** *(optional)*: Keep connected in the background (foreground service), Faster history sync
and Faster Bluetooth link (both Experimental), Keep NOOP alive overnight and an auto-start hint for some
phone makers. Android also has *(Experimental)* bond experiments for stubborn straps.

**Help.** A pairing-reset guide on Live and Devices, a strap choice prompt, and a "What each strap can do"
comparison of WHOOP 4.0 and 5.0/MG.

## Widgets, Live Activities, Siri and Shortcuts

### Home and Lock Screen widgets

All widgets read stored data only and are added by you. iPhone has them for Home Screen and Lock Screen. Mac
has no widgets. Android has Glance widgets for most of the same content (30 receivers).

| Widget | Shows | Sizes (iPhone) |
| --- | --- | --- |
| NOOP | Charge, Effort, Rest rings plus live heart rate and strap battery | small, medium, large, Lock Screen circular, inline, rectangular |
| NOOP Rings | Three rings like Today | small, medium |
| Forge Today | Rings with the coach's latest line | small, medium, large, rectangular |
| NOOP Energy | Total, active and basal calories with a projection | small, medium, inline, rectangular |
| NOOP Nutrition | Calories left, protein, carbs, fat | small, medium, inline, rectangular |
| Heart Rate | Live heart rate with the last three hours | medium |
| Stress | Today's stress curve | medium |
| Coach Brief | Today's coach brief; tap opens the coach | small, inline, rectangular |
| NOOP Goals (configurable) | Goals each drawn in its shape | small, medium, large, circular, rectangular, inline |
| Fitness set (10) | Sleep, HRV, Resting HR, Charge week, Effort week, Steps, Weight, Training week, Consistency, Vitals | small, medium, rectangular, inline |
| Weight set (4, configurable) | Weight trend, this month, figures, on a date | small, medium, rectangular |

### Live Activities and Dynamic Island (iPhone only)

- **Workout and live heart rate:** a Lock Screen banner and Dynamic Island with heart rate, zone and elapsed
  time. A cardio workout offers Pause, Resume and End (End opens the app to confirm). A strength workout shows
  the next set with Set done and a rest timer with -15, +15 and Skip. A stale banner drops the number when
  readings stop.
- **Strap sync:** one line with the sync phase and elapsed time while history is pulled.

Both are switched under Settings › Alerts and reminders › Live notifications *(default on)*. Android shows an
ongoing foreground notification instead.

### Siri, Shortcuts and quick actions

| Item | What it does |
| --- | --- |
| App shortcuts (iPhone) | Sync Strap, Mark a Moment, Log Sleep Mark, Buzz Strap, Recovery Status ("What's my Charge"), Goals Status, Open Goals, Ask Coach, Back Up NOOP Data. |
| Export Workout Route (iPhone) | Returns the most recent GPS route as GPX or FIT for Strava, Garmin Connect or any app. Available in Shortcuts. |
| Shortcuts Export *(optional, iPhone)* | Rewrites a text file each time you leave the app, one line per 15 minutes of heart rate, HRV and steps, so a Shortcut can move strap data into Apple Health on installs without the Health entitlement. |
| Siri and Shortcuts page | Lists the ready-made actions with phrases and a link to build your own. |
| Home Screen quick actions (iPhone) | Long-press the icon: Live HR, Start workout, Log journal, Goals. |
| Mac intents | Buzz Strap, Mark a Moment and Back Up NOOP Data, while NOOP is running. |
| Android quick actions | A "+" menu in the app for log, breathe, live HR and workout. |

There are no Control Center controls.

## Apple Watch

The Watch app is a companion: the phone computes scores and the watch measures its own heart rate and runs
its own sessions. It is dark-only and a vertical page deck.

- **Today glance:** Charge, Effort and Rest as rings with a legend, live heart rate from the watch, the
  phone's one-line sleep summary and "as of" age. A score still calibrating shows a dash, never an invented
  number.
- **Breathe:** haptic breathing with patterns (Relax, Coherence, Box, Deep, 4-7-8, 6-6 and more).
- **Workout:** a functional strength workout with live heart rate, zone and energy; it mirrors the phone's
  strength session and sends telemetry back. Needs Health access.
- **Intervals:** silent haptic HIIT, fixed at 30 s work, 15 s rest and 8 rounds.
- **Complications:** "NOOP Charge" (circular, corner, inline, rectangular) and "NOOP Goal" for your most
  important weekly goal.

NOOP can also run on a watch alone: a watch that fed Health data in the last 14 days is registered as a
device with Charge, Rest, Effort and Fitness Age from the metrics that arrived.

## Mac

The Mac app is the classic design with a sidebar (Today, Momentum, Intelligence, What works, Coach, Goals,
Live, Breathe, Intervals, Explore, Compare, Journal, Sleep, Trends, Workouts, Training, Strength, Cardio,
Training Load, Body, Energy, Health, Stress, Health records, Heart rhythm, Saved ECGs, Apple Health, Mi Band,
Data Sources, Backup and Sync, Values by source, Devices, Limitations, Notifications, Automations, Alarms,
Battery and Recording, Project, Settings, Test Centre).

- **Menu-bar item.** A heart tinted by heart-rate zone with the live number; the popover shows the Charge
  ring, connection state, strap battery, last sync and buttons to start or stop the live feed, refresh
  battery, scan and disconnect.
- **Shortcuts.** Command-3 opens Goals; Command-N starts a goal on that page.
- **Lock the Mac** as a double-tap action and when you take the strap off.
- **Pairing.** A Mac can be the only device and pairs with the strap itself.
- **Not on Mac:** widgets, Live Activities, the Siri Shortcuts page and quick actions, a live Apple Health
  link (import from an export file only), Apple Watch pages, the Forge screens (Nutrition tab, Food, cycle
  pages), Shortcuts Export, wrist delivery of Mac notifications and Keep screen on while syncing.

## Android

Android runs the shared Swift core with Forge screens in Compose, follows the iPhone feature by feature and
stores in the same database format. What differs:

**Only on Android:** phone smart alarm with wake window; wrist alerts for other apps, calls and timers;
Health Connect import and write-back; self-hosted push *(Experimental)*; keep-alive options and bond
experiments; nap detection *(optional)*; daily report notifications (Morning recap, Post-workout summary,
Optimal strain reached); backup time picker; a Name field and weight from Health Connect in Profile; the
"Classic screens" row; Android Test Centre probes; past days on Today; a "NOOP Forge Demo" flavor.

**Missing on Android compared with the iPhone:** Live Activities and Dynamic Island, Siri and Shortcuts,
Apple Health, Apple Watch and Wear OS apps, Strong, FitNotes and OpenGym import and plan share files,
live elevation, run plans, the pacer, laps and the best-split banner, the battery detail page, semantic coach
memory, OpenRouter in the coach, lab report PDF and photo reading, Coast and Meadow scenery, Motion effect,
swipe between tabs, coloured icons, wear and presence automations and the sync reminder.

Some items could not be confirmed on Android and may exist under other names: past-strength logging, timed
sets, mid-session supersets, plan sharing and PDF export, and start packs.

## Data in and out

### Imports

Where: Settings › Data and backup › Data Sources (and Apple Health, Training, Health records).

| Importer | What it brings | Platforms |
| --- | --- | --- |
| WHOOP export (zip or folder) | Recovery, strain, sleep, workouts and biomarkers history | all |
| Apple Health export | Streamed locally with an import-depth choice | iPhone, Mac, Android |
| Xiaomi Smart Band / Mi Fitness | Steps, heart rate, sleep stages, SpO₂, stress, sleep score | all |
| Oura, Fitbit and Garmin exports | Sleep, resting HR, HRV, steps from your own data export | all |
| Nutrition CSV (Cronometer, MacroFactor, others) | Daily calories and macros | all |
| Workout file (GPX, TCX, FIT) | One workout from any brand with route, heart rate, calories | all |
| Hevy API sync, Hevy CSV, Liftosaur JSON | Lifting history | all |
| Strong and FitNotes CSV, OpenGym plan, training plan file | Training history and plans | iPhone, Mac |
| Program spreadsheet (.xlsx, CSV) | Routines | iPhone, Mac |
| Health records (markers CSV, lab report PDF or photo) | Lab values with a review screen | iPhone, Mac (CSV also Android) |
| Oura history (cloud, Experimental) | One-time backfill with your own credentials; only in builds compiled for it | not in released builds |

Imported WHOOP journal history joins your journal questions. **Remove imported data** deletes Apple Health
imports or Hevy-synced sessions after a confirmation.

### Apple Health (iPhone)

*(optional)* Enable, Sync now, import history (choose months), Rebuild HRV history, Refresh permissions and
Diagnostics, with per-metric charts. Live observers deliver HRV, resting heart rate, active energy, heart
rate, VO₂max, sleep and workouts in the background. **Reads:** heart rate, resting HR, HRV, SpO₂, breathing,
body temperature, steps, energy, distance, VO₂max, weight, body fat, lean mass, BMI, waist, water and
nutrition, caffeine, sleep, workouts, routes, heartbeat series. **Writes** after authorisation: resting HR,
HRV, SpO₂, breathing, continuous heart rate, sleep with stages, workouts with route, energy, distance, weight,
waist *(optional)*, heartbeat series, and the full nutrient set for logged food. Only changed records are
rewritten. On the Mac there is no live link; use an export file.

### Health Connect (Android)

*(optional)* Import by type, grouped as Recovery, Steps, Training, Calories and Body composition, plus
nutrition and exercise routes. **Write-back** *(optional, off by default)* sends resting HR, HRV, SpO₂,
breathing, heart rate, sleep, exercise with route, VO₂max, weight and nutrition, only for computed days.

### Exports and backups

| Export | Description |
| --- | --- |
| Full backup (`.noopbak`) | Everything in one file, a plain ZIP that the app warns is unencrypted. Includes whitelisted profile and display settings. Old backups still import. |
| Backup and Sync to a folder *(optional)* | Pick a folder (for example in a cloud drive), daily auto-backup, keep last N, Back up now, Restore, stale-backup warning. On Apple platforms the daily backup is a catch-up when you open the app; on Android it runs around 1 a.m. |
| Back Up NOOP Data intent | Returns a `.noopbak` for a Shortcuts Save File step (iPhone, Mac). |
| CSV (WHOOP-format zip) | Re-imports on Mac and Android. |
| Raw sensor CSV | Decoded streams: heart rate, R-R, motion, steps, SpO₂, skin temperature, breathing, events. |
| Workout route | GPX or FIT (TCX is import only); also through the Export Workout Route intent. |
| PDF | Trends report and a training plan. |
| Other shares | Coach conversation as Markdown, Heart rhythm export, Raw Data Collector bundle. |

**Migration.** A database made by upstream NOOP opens in this fork, and Android adopts an old database or an
Android backup into the shared core. **Storage** shows a space breakdown with a one-tap clean-up.

## Settings, Lab and Experimental

Settings has 18 pages (with a search field on iPhone): Project, Profile, Goals, Strap, Battery and Recording,
Strap actions, Training, Today and Trends, Alerts and reminders, AI Coach, Siri and Shortcuts, Language and
units, Appearance, Calculations, Data and backup, Help and diagnostics, Lab and About.

| Page | What you can set |
| --- | --- |
| Profile | Photo (stays on the device), date of birth, sex, weight, height, waist, max heart rate, VO₂max (entered or measured), activity level, heart-rate zones. |
| Goals | Number of goals, rest days, daily step goal, goal notifications, motivation. |
| Training | Set effort, session rating, weight unit and step, rest-timer cues, workout view, exercise media, equipment, Guided training, Detect activities, Help teach the app. |
| Today and Trends | Water card, Journal card; on Mac the dashboard style and Arrange dashboard; Customize Today. |
| Alerts and reminders | Live notifications (iPhone), illness early-warning, cycle and rhythm options, sync reminder, Strain target, Training load alert, Morning advice, other reminders, Android daily reports. |
| AI Coach | See [Coach](#coach). |
| Language and units | Language (System, English, German, Spanish, French, Italian, Portuguese, Polish, Russian, Simplified and Traditional Chinese), clock, week start, units for body, distance, temperature and the Effort scale (0 to 100 or WHOOP 0 to 21; display only). |
| Appearance | Preset, theme (System, Light, Dark), accent, app icon (Default or Navy), colour profile (Colorful, Stone, Slate, Sage), tab bar options, background and scenery, chart colours, sleep and trend chart styles, motion and Score rings (Living or Classic). |
| Calculations | Day start, HRV window (whole night or deep sleep only), sleep stage method (V3, V2, V1), wake check. Changes recompute recent nights. **If scores look wrong** offers Refresh today, Recalculate the last 21 days and Reset Charge baseline. |
| Data and backup | Backup and restore, Backup and Sync, Apple Health, Data Sources, Storage, self-hosted push (Android). |
| Help and diagnostics | Guides (How NOOP works, How your scores work, What each strap can do), This iPhone diagnostics, raw sensor export, Test Centre. |
| About | Version, What's new, Acknowledgements, Check for updates, project home, Support the project, medical disclaimer. |

### Settings › Lab

Early features, off by default: **Personal stress baseline**, **Training-based VO₂max**, **Strength in Effort**
(rated strength sessions add to Effort beyond heart rate), **Sleep stages (test)**, **AgeLess** and **Daily
rhythm**. A Today tile board for every tile size is in debug builds only.

### Experimental

- **WHOOP 5/MG card** *(5.0/MG only)*: protocol probes, deep data unlock (writes persistent strap flags, with a
  switch to turn it back off), the ECG raw-data gate and ECG capture, and a puffin frames recorder for the
  optical experiment.
- **Oura all-day heart rate** *(Oura only)*.
- **Heart rhythm** and the **Oura, Amazfit/Zepp, Mi Band and Garmin** device tier.
- **Self-hosted push** (Android only) and Android's faster sync and link options.

### Test Centre

*(Settings › Help and diagnostics › Test Centre)*. Each test logs extra detail for one area (Sleep and Rest,
Connection and Sync, Workouts and GPS, Display and Performance, Import, Steps, Notifications and Alarm,
Battery, Recovery, HRV, Sources, Stress and Illness, Longevity, Circadian, or Log Everything), then bundles
it for a bug report. **Report a bug with my log** builds a redacted ZIP, shows what it contains and opens a
prefilled GitHub issue in the browser; you attach the file yourself. Also: scheduled strap-log export,
protocol probes for the 5.0/MG, read-only WHOOP device probes, maintenance tools (recalibrate the Charge
baseline, backfill skin temperature), and Raw Data Collector for bounded motion sessions on a 5.0/MG.

### First run

A terms screen appears before anything else until every statement is ticked. A 12-step onboarding wizard
follows (welcome, Bluetooth, find your strap, profile, optional history import, wrist-alert primer, look).
Only a strap is needed to finish. A What's New sheet shows once after an update, and demo data is not
available to users on Apple platforms. Android has a separate Demo flavor ("NOOP Forge Demo") preloaded with
120 days of synthetic data.

## Privacy-relevant network features

NOOP has no account and no server that processes your scores. Everything that can leave the device is
optional or one request with nothing about you in it: a daily update check (on by default, switchable), the
project's roadmap feed, wishes, votes and problem reports (sent only when you act; one master switch stops
them), the optional coach, optional food data lookups and packs, exercise media downloads, and on Android the
self-hosted push you configure. The full list, with what each sends and what it does not, is in
[PRIVACY_SECURITY.md](PRIVACY_SECURITY.md); the scope limits are in [SCOPE.md](SCOPE.md).

## For developers

The code layout, the shared Swift packages and how Android reaches them are described in
[ARCHITECTURE.md](ARCHITECTURE.md). Building is covered in [BUILD.md](BUILD.md), the iOS target in
[IOS.md](IOS.md) and the Android app in [ANDROID.md](ANDROID.md).
