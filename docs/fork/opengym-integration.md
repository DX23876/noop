# OpenGym feature-donor contract

OpenGym is a feature and interaction reference for NOOP's native training platform. It is not a
runtime dependency, embedded web app or source-code donor. The primary reference is
`DuarteSantos8/openGym`; `alexpcosta/opengym` is a secondary reference for its coach review flow.

## Licensing boundary

- OpenGym application code and translations are AGPL-3.0 and are not copied or translated into NOOP.
- Publicly described behaviours are rewritten as NOOP requirements and independently implemented in
  Swift. Constants, strings, icons and tests are authored for NOOP rather than transcribed.
- Body geometry may be adapted directly from the original MIT-licensed MuscleMap project with its
  notice, not from OpenGym's converted path file.
- Exercise content comes from a separately licensed provider or the user's own data. OpenGym's media
  is not redistributed; its own notice says those image rights remain unresolved.
- NOOP's PolyForm Noncommercial licence remains unchanged.

## Adoption matrix

| OpenGym area | NOOP decision |
|---|---|
| Weekly schedule, day overrides, combined routines, editable starter plans | Adopt natively |
| Guided, freestyle and past-workout logging | Adopt natively |
| Warm-ups, drops, rest-pause, AMRAP, supersets, timed and unilateral work | Adopt natively |
| Linear, double, Greyskull, time and bodyweight progression; planned deloads | Adopt with independently specified Swift rules |
| Last-session prefill, in-workout history, favourites, equipment profiles, plate loading | Adopt natively |
| Exercise library, instructions and media | Adapt through `ExerciseContentProvider`; do not copy OpenGym content |
| Body maps and muscle analytics | Adapt the useful interaction to NOOP's shared detailed renderer for Balance, Fatigue and Strength. Primary muscles receive full evidence weight, secondary muscles half weight and stabilizers none. Muscle Strength first normalizes every eligible lift against its own history; kilograms from different exercises are never added or compared directly. |
| Activity heatmap, history import and plan sharing/PDF | Adopt natively |
| Weight chart and cardio | Keep NOOP's richer Body and Cardio systems |
| AI plan/review flow | Adapt into NOOP Coach; NOOP's approval and evidence rules remain authoritative |
| Accounts, passkeys, server sync, admin, web push, gym QR cards, Android updater | Exclude |

## Completion rule

An adopted behaviour is complete only when its Swift implementation, independent package or app test,
localized UI and on-device storage path are all present. The matrix is reviewed again before release so
no item disappears behind a broad claim of "OpenGym integration".

## Native implementation

The adopted surface is implemented in the Apple app as a first-class Training destination. The
logger, routine rules, import adapters, progression and plate arithmetic live in the independent
StrandTraining Swift package. WhoopStore migration v61-native-training stores definitions, routines,
planned sets, schedules, day overrides, one resumable draft and completed sets in normalized tables.
Completed rows contain compact measurements and source references; exercise instructions and media are
not duplicated per workout.

Each completed workout stores two independent identities:

- the logging source (NOOP, Hevy, Strong, FitNotes or another import);
- the one physiological tracker attributed to that workout, if any.

A later workout may choose another registered tracker. NOOP resolves heart rate from the tracker saved
on that workout and never averages multiple devices. Every surface that states a session's provenance
reads the stored logging source, so a session logged in NOOP is never labelled as an import. HealthKit workouts continue through the existing
canonical-session importer; a NOOP-authored HealthKit mirror enriches the native session and is not
imported as another set log.

The Training destination includes weekly scheduling, one-day overrides, multiple routines per day,
guided routine starts, freestyle and past-workout entry, resumable drafts that can also be discarded
without reaching history, rest notifications,
last-performance context, RPE/RIR, set intensifiers, supersets, timed/distance work, progression and
deload rules, custom exercises, favourites, plate loading, activity history, detailed workout history,
routine muscle previews, an import preview, a post-workout summary and the shared detailed muscle map.
Plans can be shared as compact JSON or as an offline PDF; neither format
contains completed workouts or tracker identifiers.

An explicit Coach control on a saved plan hands over only its compact schedule, progression methods and
recent completion count. It supports review and follow-up planning through the Coach's existing
proposal/approval path; it does not silently rewrite routines or treat a model answer as an accepted
plan.

Exercise metadata can come from NOOP's small offline starter catalog, a rights-declared local catalog,
or an optional ExerciseDB-compatible HTTPS source. The default is ExerciseDB's documented free V1
endpoint, which requires no key. A wearer may instead configure a compatible provider with a personal
key, which stays in the device Keychain. The client requests one page at a time and stores media URLs as
provider references; it does not send workout or health data, bulk-download videos or copy provider
media into workout history.

## Storage limits

The normalized history model is tested against a conservative twenty-year scenario and must remain
below 150 MB. Drafts older than seven days are removed. Workout history stores no media bytes. The
provider metadata-cache budget is 25 MB and the optional media-cache ceiling is 200 MB; the initial
implementation keeps both at zero by opening provider media on demand, so crossing either ceiling is
not possible.

## Analytics compatibility

`Repository.resolvedStrengthHistory(days:)` is the single read model for Training, Strength, Training
Load, Coach evidence, progress and the muscle map. It selects one detailed set log per canonical
session in this order: native NOOP, Hevy API, file import and manual completion. HealthKit and the
selected tracker may enrich duration, route and heart rate, but never add a second set list. Existing
Hevy rows remain in their established tables and native rows remain normalized; neither is copied into
the other store.

Everything that judges strength reads that model, not one source: the Strength screen, Training Load's
strength lane, the muscle views, the exercise library and detail, "last time" and progression in the
logger, the coach's strength history and workout card, the goal evidence for working sets per week, and
the routine plan gate's volume warnings. Hevy's own sync, the Hevy write tool and the Hevy template
lookup stay Hevy-specific by construction, because they address Hevy objects. "Is a lifting log
connected at all" counts NOOP's own log too, so a wearer who never connected Hevy is measured rather
than reported as unmeasured.

The versioned offline anatomy catalogue is reviewed before shipping. It resolves an explicit user
correction first, then a provider exercise id, a reviewed local mapping, an unambiguous
name/equipment/mode alias and finally the source's coarse muscle metadata. Standard mappings use only
stable `TrainingMuscleCatalog` ids. Unknown sets remain visible and the map says when its result is a
minimum. NOOP never sends exercise names or workout history to an AI service at runtime.

Before a personal Strength comparison exists, only the outer Strength ring receives a provisional
seven-day position. Complete session ratings use `session RPE × minutes`; if any session lacks a
rating, the whole ring switches to the highest mapped muscle stimulus. This provisional value cannot
enter “× usual”, adaptation, combined status or sustained-overload logic. At 21 complete days the
existing personal comparison replaces it automatically.

The original native-training addition required recipe 6 as recorded in the decision log. This
follow-up is read-time resolution and an additive alias table: **Analysis migration required: no**.

## Complete workout-domain semantics

The native workout domain records warm-up-specific rest, planned and actual timed-set duration,
unilateral repetitions, and explicit drop-set/rest-pause relationships without creating another set
hierarchy. Routine starts snapshot equipment and load meaning into the workout, while manually added
exercises snapshot the same facts from the canonical exercise definition. Historical sessions therefore
keep their original load interpretation even after a routine or catalog entry changes.

Active drafts can persist their current exercise/set cursor, timer and interruption state. The logging
surface may use those facts in the next UI phase, but old drafts decode with every new lifecycle field
absent. Session RPE is optional: choosing to rate creates a completion-time origin, later ratings remain
distinguishable, and existing values are retained as legacy ratings with an unknown origin.

Migration v64 is additive and leaves the existing analytics recipe untouched. Warm-ups keep using the
single established non-working-set boundary; native intensifier type and cluster metadata survive the
compatibility projection so analytics can distinguish technique segments. **Analysis migration
required: no**.

## Native physiology lifecycle

The set logger now coordinates with NOOP's existing physiological recorder rather than introducing a
second workout engine. One tracker is fixed for each session: a NOOP band or compatible external
tracker continues through `AppModel` and `ActiveWorkoutPersistence`; Apple Watch uses the existing
watchOS `HKWorkoutSession`/`HKLiveWorkoutBuilder`. Tracker loss leaves the set draft usable and records
unknown heart rate as missing rather than zero.

Phone and Watch exchange only latest companion state, idempotent commands and session-scoped live
telemetry. The phone remains the sole writer for weight, repetitions, effort and exercise history.
Every mutation advances a monotonic draft revision, so delayed or repeated Watch commands cannot edit
a newer set state. The Watch stores the stable session id as HealthKit metadata; the iOS Health import
uses it to link the Watch physiology component directly to the completed native session. An unrelated
Watch workout is never adopted or ended, and Apple-Watch-backed sessions are not mirrored into
HealthKit a second time.

Migration v65 adds only nullable lifecycle/provenance fields and a partial unique session index to the
native workout table. Existing workouts and analysis values are unchanged. **Analysis migration
required: no**.

Migration v66 adds an optional encoded pause list to the completed native workout. It preserves active
duration for the native session summary without changing source precedence, stored load values or any
historical analysis. **Analysis migration required: no**.

## Optional exercise media

Exercise metadata, instructions and exercise media remain separate provenance domains. NOOP may show
the exercise without any image or animation. If the wearer explicitly selects **Download exercise
media**, the app downloads one version-pinned archive directly from the external upstream source into
private application storage. NOOP neither bundles, hosts nor mirrors those files.

Before that action, the app names the source, attribution, known rights status, approximate download
size and the fact that a user-initiated download does not grant an additional licence through NOOP.
The initial upstream archive is pinned to an immutable source revision; it is staged, path-validated,
given a local manifest and atomically activated only after extraction succeeds. The local pack can be
disabled or deleted at any time. A disabled, unavailable, corrupt or withdrawn provider falls back to
the text-only exercise presentation and cannot block routine editing, workout logging or analytics.

Downloaded files live below `Application Support/ExerciseMedia/<provider>/<version>/`, are excluded
from device backup, and are never copied into workout rows, routines, exports, HealthKit, analytics or
the user database. The provider boundary exposes local media by canonical exercise id and permits a
future licensed, remote, user-imported or no-media provider without changing those product domains.

`ExerciseMediaProvider` is that boundary: views ask `ExerciseMediaRegistry` for an exercise and receive
a local file or nothing. The registry owns the central kill switch — a provider named in
`withdrawnProviderIds` reports nothing, cannot be downloaded and says so in its settings screen, while
exercises, routines, logging and analytics continue unchanged. `NoMediaProvider` is always last, so
"no media" is a normal state rather than an error.

The transfer is a background `URLSession`: progress, cancel and resume are real, a cancelled or failed
transfer keeps its resume data so continuing costs only the remaining bytes, and iOS hands a transfer
that finished while the app was suspended back through the app delegate. Installation happens off the
main actor and in this order: SHA-256 of the archive (compared with the provider's published digest
when it has one), path validation of every entry, the 200 MB pack limit, a free-space check that leaves
50 MB on the device, extraction into a staging directory, then one atomic version swap. A failure at
any step leaves the previously working version in place.

The local manifest records provenance and integrity only: provider, version, source URL, attribution,
rights holder, rights status, download time, the archive digest, the provider's expected digest when
published, and every installed file with its size and its own SHA-256. It contains no exercise or
workout data and is not a second exercise database.

Media is displayed as what it is: an animated image plays frame by frame with its own frame delays, a
video plays muted and looping, anything else is a still image. Reduce Motion holds the first frame
instead of animating, and a file that cannot be decoded falls back to the still presentation.

## Muscle analytics

Training and Strength expose three questions through the same detailed body renderer and the same
`resolvedStrengthHistory` read model. Balance describes the distribution of effective working sets
over 28 days and compares it with the wearer's previous eight complete weeks when that baseline is
available. Fatigue applies the existing muscle-stimulus and exponential-decay model and is presented as
an estimate of remaining stimulus, never as measured recovery. Strength uses eligible, RIR-corrected
e1RM observations, a robust Theil-Sen trend and exercise-local normalization before combining evidence
for a muscle.

Warm-ups do not enter these metrics. Primary muscles receive full credit, secondary muscles half
credit and stabilizers remain descriptive. Unmapped sets lower the displayed coverage instead of being
assigned to an invented muscle. Every calculation uses bounded history at read time and stores no
parallel muscle history. **Analysis migration required: no**.

## Long-term statistics and routine planning

Long-term strength facts stay where they already live rather than on a separate statistics screen.
For the selected range (quarter, year or all history), Strength summarises sessions, sessions per
week, working sets, logged duration, volume load, RPE coverage, average RPE, active weeks, the longest
run of consecutive active weeks and a personal-record timeline. Every value is read from
`resolvedStrengthHistory`, so a native, Hevy or file-imported session counts exactly once.

- **Average RPE** uses only working sets that carry a rating and is shown next to its coverage.
  Missing ratings are never filled in.
- **Active weeks** count calendar weeks with at least one session, from the first session in the
  range through today, aligned to the week start chosen in Settings › Training. Counting from the
  first session keeps an all-history range from reporting the years before the first log as missed.
- **Personal records** are e1RM points that exceed every earlier comparable working set of the same
  exercise. A later, lower session never removes a record, and warm-ups are excluded.
- The **consistency heatmap** on Training and Strength shows logged minutes per day for the past year
  in week columns that begin on the chosen week start. VoiceOver reads one summary of training days
  and total time instead of several hundred unlabeled squares.

Per-exercise history, the e1RM trend and records remain in Strength › Exercise progress, and every
session opens its set-level detail.

Routine planning offers a read-only preview with exercise order, working sets, rest, warm-ups,
supersets, a muscle preview and the scheduled days. The editor combines exercise order, supersets
(moved, added and removed as blocks), progression rules, a muscle preview and the weekdays the routine
is scheduled on. Choosing weekdays in the editor changes only that routine's place in the weekly
schedule: other routines keep their days and order, and a one-day change still takes priority.

These are read-time summaries and planning controls; no stored value, score or source precedence
changes. **Analysis migration required: no**.

## The shipped exercise catalogue

The offline catalogue is ExerciseDB v1, taken from `hasaneyldrm/exercises-dataset` at the pinned
revision `7455efae…` (`data/exercises.json`, SHA-256 `656634…`) and normalized by
`Tools/build_exercise_catalog.py` into `ExerciseCatalogArchive` — the same envelope a wearer-supplied
catalogue uses, so there is one exercise-content format rather than two.

Rights are settled at the source and are two separate questions. The upstream `LICENSE` and `NOTICE.md`
place the exercise **data** — names, categories, body parts, equipment, targets, muscle groups and
instruction text — under the **MIT licence**, which is what makes shipping 1,324 definitions offline
legitimate; the attribution travels with the catalogue and with every definition. The same files state
that the **media** in `images/` and `videos/` belongs to Gym visual and that cloning grants no licence
to it. NOOP therefore ships no media, stores only the opaque upstream media identifier, and keeps that
provider **withdrawn** in `ExerciseMediaRegistry.withdrawnProviderIds` until a licence exists.

Normalization decisions worth stating, because they are judgements rather than copies:

- A generic `delts` target is refined by name — lateral and upright work to the side head, rear and
  reverse work to the rear head, everything else to the front head with the other two as secondary.
- A prop is not a load. A stability ball, bosu, foam roller or ab wheel supports the body, so those
  exercises stay bodyweight repetitions with the prop recorded beside them.
- Battle ropes, tyres and sledgehammers are counted, not weighed: they become repetition work rather
  than a weight-and-repetitions exercise with an invented kilogram.
- Conditioning work keeps the muscles it involves but claims no primary muscle, so it never colours the
  muscle map with work the data cannot attribute.
- An alias ships only when the name minus its equipment word is unique across the catalogue, so an
  import can never be attached to the wrong variant.

**Analysis migration required: no.** Definitions are content; no stored workout, score or source
precedence changes. Seeding happens once per `BundledExerciseCatalog.contentVersion`, so a corrected
mapping reaches a wearer who already holds the old rows without touching their own exercises.

## Canonical exercise identity

Migration v67 adds five optional columns to the exercise definition: a canonical id, aliases, the
content version the definition was written for, its attribution, and explicit load semantics. Every
column is additive. A definition without them behaves exactly as before — `effectiveLoadSemantics`
still derives the meaning of a weight from measurement mode and equipment — and no workout, routine,
score or source precedence changes. **Analysis migration required: no.**

Resolution order is now explicit: a stored canonical id wins, then a provider exercise id, then an
unambiguous reviewed alias, and only then name with equipment and measurement mode as tie-breakers.
Two plausible variants still resolve to nothing rather than to a guess. The shipped starter exercises
carry their canonical id, `NOOP` as attribution, the catalogue version and their load semantics, so an
imported session of the same movement lands on the same exercise without rewriting stored history.

`ExerciseAnatomyCatalog.validationIssues` is the development tool for a catalogue revision. It fails a
duplicated exercise id, an unknown muscle or equipment id, a muscle credited as both primary and
secondary, an alias two entries claim, a primary muscle with no body region, an entry that is not
reviewed, and a contradiction between measurement mode and equipment such as bodyweight repetitions on
a loaded implement. A test runs it over the shipped catalogue, so a revision cannot ship unchecked.

Equipment spellings and body regions live in `StrandTraining`: `TrainingEquipmentCatalog` folds legacy
and provider spellings (`bar`, `power rack`, `resistance band`) onto one canonical id, and
`TrainingBodyRegion` derives a region from the muscles themselves, so a filter can never disagree with
the muscle map.

## Exercise library and exercise detail

The library combines four filters — body region, muscle, type of measurement and equipment — with
search, and any combination narrows the same list. "My equipment" shows only exercises whose entire
equipment list is available, with bodyweight always available. Each filter reads the reviewed anatomy
where an exercise has one and falls back to the exercise's own primary muscle where it does not.

The exercise detail shows what the wearer's own history says about that movement: how many sessions it
appears in, the heaviest working set, the best estimated one-rep maximum (weight-and-repetition work
only, with the same Epley estimate and RIR correction as the Strength screen), and the most recent
sessions with their date, set count and best set. Native and resolved imported sessions both count,
each exactly once, and an imported session is labelled as such. While a workout is running, the detail
can add the exercise straight into it.

## Training settings and accessibility

Settings › Training bundles set effort entry (Off, RIR or RPE), default, warm-up and rest-pause rest,
the active-workout layout, exercise-media size, media download and deletion, available equipment,
the training week start, timer feedback and sound, haptics, and keeping the screen awake during a
workout. Strength weights are stored and displayed in kilograms; body weight, distance and
temperature follow the Units section. Turning effort entry off hides the per-set control and keeps
ratings that were already logged.

During a workout the wearer can type a weight, repetition count or distance directly instead of
stepping to it; the − and + buttons step by two of the smallest saved plates on a barbell and by the
configured step elsewhere. An exercise can be ended early ("skip remaining sets"), keeps its own note,
and shows its earlier sessions without leaving the running workout. "Last time" and automatic
progression read the same resolved history as everything else, so an imported Hevy session counts
exactly like a native one and a session recorded on both sides counts once.

The workout summary adds what the session changed: records that exceed every earlier session of the
same exercise (estimated 1RM and heaviest set, never on a first session), the movement in weight and
repetitions against the previous session, every exercise with its logged sets and note, and the
session note.

Accessibility behaviour of the training surfaces:

- **VoiceOver:** a set row is a container. Weight, repetition, time and distance are adjustable
  elements (swipe up or down to step the value); set type, effort, completion, move and menu controls
  carry explicit labels, and the rest timer announces the remaining time. Muscle maps expose a text
  label and, outside the compact card, a list of muscles with their values.
- **Dynamic Type:** text uses `StrandFont` styles; dense numeric tiles scale down instead of clipping.
- **Reduce Motion:** the muscle map changes views without its transition animation.
- **Contrast:** map, heatmap and status colours come from `StrandPalette`, and coloured states are
  accompanied by text or an accessibility summary.
- **Decimal separators:** weights, volumes and averages use locale-aware number formatting.
- **Languages:** every training string is in the String Catalog for all NOOP languages.
