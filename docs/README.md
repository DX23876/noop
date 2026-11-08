# Documentation map

This index separates current guidance from historical records. The current fork ships iOS, macOS,
widgets/Live Activity, and an optional watchOS companion; the latest release is 12.2.1 and 13.0.0 is in
testing. Android is back since 2026-10-25 as a Kotlin shell around the shared Swift core and is in
testing ([Android status](ANDROID.md)); for a finished Android app use
[RyanBR's upstream NOOP](https://github.com/ryanbr/noop).

## Start here

- [README](../README.md) — product overview and downloads.
- [iOS installation](IOS.md) — AltStore/SideStore, Full IPA, and source builds.
- [Android status](ANDROID.md) — the testing build, how it sits on the shared core, and where its plans
  live.
- [Testing NOOP Forge 13](fork/TESTING-13.0.0.md) — what to check in the current testing build, and
  [Android testing](fork/android/TESTING.md) for the Android round.
- [Build and release](BUILD.md) — XcodeGen, package/app builds, and publication.
- [Features](FEATURES.md) — current product surfaces.
- [FAQ](FAQ.md) — common score, privacy, and calibration questions.
- [Privacy and security](PRIVACY_SECURITY.md) — exact local/network boundaries.
- [Homebrew](HOMEBREW.md) — why there is no tap today, and how one would be published.

## Coach, scores and health features

- [AI coach](fork/COACH.md) — all 38 tools, permission purposes, goal gates, the plan book, memory and
  providers.
- [Technical deep-dive](fork/DETAILS.md) — fork rationale, tool overview, prompt caching and the
  relationship to upstream.
- [Fitness Age](FITNESS_AGE.md) — the VO₂max model behind it and its limits.
- [Liquid Today](fork/LIQUID_TODAY_REDESIGN.md) — the default Today design and its animated rings.
- [Health sync](fork/health-sync.md) — what is read from and written to Apple Health.
- [Sleep heart-rate contrast](sleep-heart-rate-contrast.md) and
  [validation protocol](VALIDATION_PROTOCOL.md) — how new signals are checked before they are trusted.

## Contributor and architecture guides

- [Contributing](CONTRIBUTING.md)
- [System architecture](ARCHITECTURE.md)
- [Cross-platform architecture](CROSS_PLATFORM.md)
- [Package library](LIBRARY.md)
- [Data model](DATA_MODEL.md)
- [Analytics](ANALYTICS.md)
- [Fork maintenance](FORK_GUIDE.md)
- [Fork agent rules](fork/AGENT_RULES.md) — what overrides `AGENTS.md` here: the shared core, the
  analysis-migration rule and the local test gate.
- [Scope and non-goals](SCOPE.md)
- [GitHub and release safeguards](SAFEGUARDS.md)

## Training and strength

- [Native training](fork/opengym-integration.md) — routines, workout logger, resolved strength
  history, long-term statistics, training settings and accessibility.
- [Live strength workouts](fork/LIVE_STRENGTH_WORKOUTS.md) — workout lifecycle, trackers and resume.
- [Muscle analytics methodology](fork/MUSCLE_ANALYTICS.md) — Balance, Fatigue and Strength with
  their limits and import behaviour, detailed in [Balance](fork/MUSCLE_BALANCE.md),
  [Fatigue](fork/MUSCLE_FATIGUE.md) and [Strength](fork/MUSCLE_STRENGTH.md).
- [Training Load](fork/TRAINING_LOAD_PLAN.md) — strength, cardio and session load lanes.
- [Lift log program import](LIFT_LOG_PROGRAM_IMPORT.md) — importing a training program spreadsheet.
- Live cardio recording, GPS handling, voice feedback, auto-pause and interval plans are described in
  the [feature guide](FEATURES.md#training-strength-and-cardio).
- [Exercise content and media](fork/EXERCISE_CONTENT_AND_MEDIA.md) and
  [third-party notices](fork/THIRD_PARTY_NOTICES.md).

## Android on the shared core

- [Plan](fork/android/PLAN.md) — Android on a shared Swift core (decided 2026-10-24), with the
  [parity continuation](fork/android/PARITY-PLAN.md) and the
  [core-only plan](fork/android/CORE-ONLY-PLAN.md) that removed Room from the app.
- [Status](fork/android/STATUS.md) — running state and open steps.
- [Inventory](fork/android/INVENTORY.md) — the iOS screens, settings and actions the Android screens
  follow.
- [`android/README.md`](../android/README.md) — Gradle prerequisites (upstream's file with a fork note).

## Protocol and device references

- [WHOOP protocol](PROTOCOL.md), with its chapters on [concepts](PROTOCOL_CONCEPTS.md),
  [transport](PROTOCOL_TRANSPORT.md), [commands](PROTOCOL_COMMANDS.md),
  [configuration](PROTOCOL_CONFIGURATION.md), [sensors](PROTOCOL_SENSORS.md),
  [alarms](PROTOCOL_ALARMS.md), [ECG](PROTOCOL_ECG.md), [firmware updates](PROTOCOL_UPDATES.md),
  [implementation](PROTOCOL_IMPLEMENTATION.md), [WHOOP 4.0](PROTOCOL_WHOOP4.md) and
  [WHOOP 5.0/MG](PROTOCOL_WHOOP5.md)
- [Raw data capture](RAW_DATA_CAPTURE.md) and [push protocol](PUSH_PROTOCOL.md)
- [BLE reverse engineering](BLE_REVERSE_ENGINEERING.md)
- [WHOOP 5/MG deep data](WHOOP5_DEEP_DATA.md)
- [WHOOP 5/MG optical experiment](WHOOP5_OPTICAL_EXPERIMENT.md)
- [Oura BLE protocol](OURA_PROTOCOL.md)
- [Device support roadmap](DEVICE_SUPPORT_ROADMAP.md)
- [Device-driver architecture](DEVICE_DRIVER_ARCHITECTURE.md)

Some protocol documents retain clearly labelled Kotlin/Android observations as historical
provenance. They describe upstream's Kotlin implementation or the fork's pre-2026-08-14 tree, not the
current shared-core Android app.

## Historical records — do not rewrite as current behavior

- `docs/releases/` — upstream-era release notes.
- `docs/fork/releases/` — fork release notes, released up to 12.2.1; `v13.0.0.md` is the draft for the
  release in testing.
- `docs/fork/decisions.md` — chronological decisions; later rows may supersede earlier rows.
- `docs/superpowers/` — dated plans and specifications.
- `docs/fork/redesign-*`, `docs/fork/feature-spec.md` and `docs/fork/design/` — implementation inputs
  retained for design provenance.
- Dated fork work notes such as `docs/fork/today-ui-fixes-2026-10-03.md`,
  `docs/fork/workout-background-test.md`, `docs/fork/APPLE_WORKOUT_HR_PLAN.md` and
  `docs/fork/research/` — records of one investigation, not maintained guides.
- [R-R optimization](RR-OPTIMIZATION.md) — historical experiment record plus current Swift outcome.

When current guidance conflicts with a historical record, the current guide and the source tree win.
