# Sleep export crash — 2026-10-06

Analysis migration required: no

Build 326 could terminate while constructing sleep samples for Apple Health. The device trace
identified `HealthKitBridge.writeSleep` and `_HKObjectValidationFailureException`: a sync identifier
requires a sync version. Commit `5023776ab1` introduced distinct sleep sync identifiers, but the
version was only assigned later in `HealthSampleWriter.save`. HealthKit validates sample metadata
during construction, so the writer was never reached.

The sleep sample factory now supplies an initial numeric version. The writer still replaces it
with the durable export revision before saving. Sync identifiers and external UUIDs are preserved;
the existing fingerprint excludes both sync metadata fields. Scoring, sleep intervals, source
precedence, stored raw samples and user corrections are unchanged. No analysis recipe bump or
historical rescore is required. This path is iOS-only; the fork has no Android target.

The extracted production factory reproduced the device exception against native HealthKit
(exit 134), then constructed all six sample categories successfully after the fix. The iOS
regression test calls that same factory for in-bed, awake, core, deep, REM and unspecified sleep.
It requires paired sync metadata and distinct sample identifiers without writing health data.
The NOOPiOS simulator build and `NOOPiOSTests/HealthSleepSampleTests` passed on iOS 27.0.
The test also verifies that replacing the initial version with a durable revision leaves the
export fingerprint unchanged. Source doc-comment lint and `git diff --check` passed.

The supplied trace proves this sleep-export failure; it does not establish that every reported
dashboard, goal-attribution or widget crash has the same cause. Those interactions still require
confirmation on the affected phone after installing the fix.

Follow-up 2026-10-07: the phone's own crash report from 2026-10-06 20:48 (`SIGABRT`) shows exactly this
stack, `HKObject _validateForCreation` under `HealthKitBridge.writeSleep` from the post-offload
write-back. The crash at 2026-10-07 08:15 had a different cause: a `0x8BADF00D` scene-update watchdog
kill with the main thread waiting in `HKHealthStore authorizationStatusForType` via
`HealthKitBridge.hasWriteAuthorization`. That one is addressed separately by moving the launch and
background-transition authorization probes off the main actor.
