# Android status

NOOP Forge for Android is a released platform since 13.0 (28 November 2026), next to iPhone and iPad, Mac
and Apple Watch. It runs on the same shared Swift core as the iPhone and Mac apps, so it computes the same
numbers from the same data, with Android's own Bluetooth layer and Forge screens. It is the youngest of the
platforms and has met far fewer phones and straps than the Apple apps, so a good problem report matters
([how to write one](fork/android/TESTING.md)).

If you prefer an Android app with its own independent Kotlin implementation, there is
[RyanBR's upstream NOOP](https://github.com/ryanbr/noop).

## Install

- Download the Android APK from the newest [release](https://github.com/DX23876/noop_forge/releases). The
  release workflow attaches a signed APK to each release (`android-release.yml`, called by
  `publish-ios-release.yml` or run by hand with the tag). Builds for testers are published under the rolling
  [`testing-latest`](https://github.com/DX23876/noop_forge/releases/tag/testing-latest) tag.
- Android 8.0 (API 26) or later and a WHOOP 4.0, 5.0 or MG. The project website has a step-by-step
  [install guide](https://dx23876.github.io/forge/install/).
- Health Connect is the Android counterpart of Apple Health: it can feed heart rate, sleep, steps,
  workouts and body data in, and NOOP can write its computed values back, each only for what you grant.
- The new design is the default. **Settings → About → Classic screens** switches back to the earlier screens.
- Not on Android: Live Activities, Siri and Shortcuts, an Apple Watch app, and the coach's on-device
  semantic memory. Android adds its own set: a phone alarm with a wake window, wrist alerts for other apps
  and calls, home-screen widgets and the Experimental self-hosted push (see [`SCOPE.md`](SCOPE.md)).
- A problem or a question: [`fork/android/TESTING.md`](fork/android/TESTING.md) says what a useful report
  contains.

## How it is built

Android is a shell around the shared core, not a second implementation:

| Layer | Where | What lives there |
|---|---|---|
| Shared core | `Packages/` (`StrandCore`, `StrandAnalytics`, `WhoopStore`, `StrandImport`, `StrandTraining`) | Scoring, analytics, imports, backups, goals, the coach's data reads and every other computation |
| Bridge | `Packages/NoopCoreJNI` | The JNI entry points (`NoopCore`, `CJNI`) Kotlin calls into |
| Native build | `android/swift-core/build-swift-core.sh` | Cross-compiles the core with the Swift SDK for Android and NDK r30 into the APK |
| Storage | the core's GRDB database through the generated `CoreWhoopDao` (`Tools/gen_core_dao.py`) | One store on every platform. Room left the app on 2026-11-01 ([`fork/android/CORE-ONLY-PLAN.md`](fork/android/CORE-ONLY-PLAN.md)); an old Room file is adopted once on first start, and older `.noopbak` backups (also from ryanbr's Android app) are converted on restore |
| Kotlin | `android/app/src/main/java/com/noop/…` | Bluetooth transport and its frame decoding (`com.noop.protocol`, `com.noop.ble`; the decoded samples are written into the core's tables), Health Connect reads, Android services and widgets, the Forge Compose screens (`com.noop.ui.forge`) and presentation helpers only |

The rules that keep it that way are in [`fork/AGENT_RULES.md`](fork/AGENT_RULES.md) ("Android is a shell
around the shared core"): logic goes into `Packages/`, never into Kotlin, and a schema change is a
`WhoopStore` migration that both platforms run. The parity oracles in
`android/app/src/test/resources/core_parity/` check the Android screens' calculations against the core.

Build prerequisites and commands: [`BUILD.md`](BUILD.md) and [`../android/README.md`](../android/README.md).
`Tools/local-tests.sh` builds and tests Android for any change under `android/`, `Packages/**` or
`project.yml`.

## Where to read more

- [`fork/android/STATUS.md`](fork/android/STATUS.md) — the running state and open steps (what is still
  unverified on a real strap is listed there).
- [`fork/android/PLAN.md`](fork/android/PLAN.md) — the plan for Android on a shared Swift core (decided
  2026-10-24) and [`fork/android/PARITY-PLAN.md`](fork/android/PARITY-PLAN.md) for its continuation.
- [`fork/android/INVENTORY.md`](fork/android/INVENTORY.md) — the iOS screen inventory the Android screens
  follow.

## History

The cross-platform parity contract was retired on 2026-07-23, and the upstream-derived `android/` tree
with its Gradle and GitHub Actions jobs was removed on 2026-08-14, when the fork shipped Apple platforms
only. Phase D of the shared-core plan restored `android/` from the upstream merge base on 2026-10-25 and
wired the core into every build. Older commits, release notes and protocol investigations that describe
the Kotlin/Room implementation refer to that earlier code or to upstream's.
