# Apple Health synchronisation — implementation of 6 October 2026

Analysis migration required: **yes**, recipe **AI-19**. No Android twin was needed: the fork shipped
Apple platforms only at the time. Android (back since 2026-10-25) reads Health Connect in Kotlin and
writes into the shared core; Apple Health itself is Apple-only.

Health → NOOP stores complete day windows together in one SQLite transaction. Outside that window,
historical body values change only their own columns and series. A failed sleep, daily-value or
workout query confirms neither an empty data set nor the Health anchor. A failed workout heart-rate
query does not replace an existing curve.

Sleep is first split into nights per source. Watch data takes precedence, then detailed stages, then a
stable source identifier. Overlapping minutes count once; a night belongs to its wake date. An all-day
block from another source does not join a night's sleep and a nap. Time in bed does not count as sleep.

Health workout deletions are processed by UUID and origin. A different Health UUID at the same former
natural key protects that key's workout row. Manual rows and the wearer's decisions are kept. The
affected import range is marked durably before the metadata is deleted and confirmed after successful,
bounded retry queries.

NOOP → Health uses stable sync identifiers and persisted versions for measurements, sleep segments,
workouts and their energy, distance and route data. Unchanged payloads are skipped. A replacement is
saved before observed legacy objects are cleaned up. Deletion failures are shown and can be retried.
A workout's identity includes its start time and sport; manual corrections and native sessions take
precedence over detected or imported WHOOP copies.

SQLite records the affected intervals of workout, sleep, vital and body-measurement changes and of late
heart-rate offloads. A confirmation applies only to the revision it processed, so changes made during a
running export stay open. Historical intervals are processed specifically, in addition to the current
window. Profile weight writes survive a restart. Waist export still requires the existing opt-in and
Health write permission.

Workout export reads the active and every retained WHOOP device, and every native page. Apple Watch
recordings of native sessions are not exported again. Original pauses, laps and phases are kept; heart
rate buckets that overlap a pause are not attached. Historical summaries without a timeline cannot
supply exact pause times.

AI-19 repairs missing historical Apple daily projections from retained `metricSeries` values in
resumable transactions. The analysis cursor is written only after the repair and the refresh. A separate
Health import cursor refreshes the retained history in 31-day windows. Permission requests and Health
deletions without a date can reset this run; a generation protects the reset from an older checkpoint
that is still running. Raw data and manual sleep or workout corrections are not deleted.

A read-only integration resumes after a restart based on the permissions that were successfully
requested. That does not claim a verifiable read grant: HealthKit does not disclose one. The background
export scheduler checks actual write permission separately.

The automated checks cover regressions for rollback, history retention, UUID deletion, source choice,
restart, revisions, the device registry, more than 500 workouts and the analysis migration. iOS and macOS
builds and package and app tests complement them. Permissions, background delivery, the Fitness
presentation and workout and route matching still need a test on an iPhone.
