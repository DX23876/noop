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
| Body maps and balance | Adapt the useful interaction to NOOP's primary-set activity map, existing estimated muscle-stimulus/current-load views and personal balance bands. Do not add a cross-muscle "strength" heat map: kilograms from different exercises and muscles have no defensible common scale. |
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
on that workout and never averages multiple devices. HealthKit workouts continue through the existing
canonical-session importer; a NOOP-authored HealthKit mirror enriches the native session and is not
imported as another set log.

The Training destination includes weekly scheduling, one-day overrides, multiple routines per day,
guided routine starts, freestyle and past-workout entry, resumable drafts, rest notifications,
last-performance context, RPE/RIR, set intensifiers, supersets, timed/distance work, progression and
deload rules, custom exercises, favourites, plate loading, activity history, detailed workout history,
and a primary-muscle heat map. Plans can be shared as compact JSON or as an offline PDF; neither format
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

Native workouts project read-only into the existing strength vocabulary. That lets Records, progress
trends, muscle balance, Training Load and Coach evidence use the richer sets without keeping a second
workout copy. Existing Hevy history remains readable through its established tables and is merged at
read time; it is not rewritten destructively into the native log.

Analysis migration required: **yes**. Source semantics, detailed strength storage and downstream load
inputs change; the implementation bumps the analysis recipe and performs a resumable rescore only after
the new storage and logger are in place.
