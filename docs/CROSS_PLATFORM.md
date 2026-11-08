# Platform architecture — macOS, iOS, watchOS and Android

NOOP Forge targets macOS, iOS/iPadOS and watchOS, and Android on a shared Swift core (decided
2026-10-24, see [`fork/android/PLAN.md`](fork/android/PLAN.md)). macOS and iOS share the same Swift
packages and most app-layer code; the watchOS companion receives a bounded snapshot from the iPhone.
Android was removed from this fork on 2026-08-14 and restored on 2026-10-25 as a Kotlin shell around
the same Swift core; it is in **testing** and not yet a published release download. The upstream
Kotlin parity contract (a byte-identical Kotlin twin of every formula) is retired here (2026-07-23):
there is no Kotlin twin. See [`fork/AGENT_RULES.md`](fork/AGENT_RULES.md).

## Current targets

| Target | Code home | Distribution | Role |
|---|---|---|---|
| macOS app (`Strand`) | `Strand/` + `Packages/` | Universal ZIP or Xcode | Reference desktop app |
| iOS/iPadOS app (`NOOPiOS`) | `StrandiOS/`, shared `Strand/`, `Packages/` | Unsigned IPA or Xcode | Phone/tablet app |
| Widgets/Live Activity (`NOOPiOSWidgets`) | `StrandiOS/Widgets/` | Embedded in both iOS IPAs | Home/Lock Screen and Live Activity |
| Watch app (`NOOPWatch`) | Watch sources selected by `project.yml` | Full IPA or Xcode | Companion surface |
| Watch complication (`NOOPWatchComplications`) | Watch complication sources selected by `project.yml` | Full IPA or Xcode | Snapshot complication |
| Android app (`io.github.dx23876.noop`, Android 8.0+) | `android/` (Kotlin, Compose) + `Packages/` via `NoopCoreJNI` | Testing APK ([`fork/android/TESTING.md`](fork/android/TESTING.md)) | Phone app on the shared core |

`project.yml` is the authoritative target and source-membership definition. Generate
`Strand.xcodeproj` with `xcodegen generate`; never hand-edit the generated project.

## Shared Swift packages

| Package | Purpose | Platforms |
|---|---|---|
| `WhoopProtocol` | WHOOP framing, CRC, schema and stream decode | iOS 16+, macOS 13+ |
| `WhoopStore` | GRDB/SQLite migrations, streams and caches | iOS 16+, macOS 13+ |
| `StrandAnalytics` | HRV, Charge, Effort, Rest, sleep and workout math | iOS 16+, macOS 13+, watchOS 10+ |
| `StrandImport` | WHOOP CSV and Apple Health archive import | iOS 16+, macOS 13+ |
| `StrandDesign` | Shared SwiftUI design system | iOS 16+, macOS 13+, watchOS 10+ |
| `OuraProtocol` | Clean-room Oura BLE protocol and decode | iOS 16+, macOS 13+ |
| `PolarProtocol` | Polar protocol primitives and PPI decode | iOS 16+, macOS 13+ |
| `SemanticMemory` | Local coach-memory index | iOS 17+, macOS 13+ |
| `StrandTraining` | Training catalogue, plans, routines and workout engine | iOS 16+, macOS 13+ |
| `StrandCore` | Fork: platform-neutral app core (daily analysis, `AnalysisRecipe`, collection/backfill, backup, metric resolver, energy, Hevy) | iOS 16+, macOS 13+, Android |
| `NoopCoreJNI` | Fork: Android JNI bridge (`NoopCore` library, `CJNI`) over `StrandCore` | macOS 13+ (tests), Android |
| `MuscleMap` | SwiftUI muscle-map views (third-party, MIT) | iOS 17+, macOS 13+ |
| `NoopLocalAccess` | Optional read-only local-access CLI/package | macOS 13+ |

`WhoopProtocol`, `StrandTraining`, `OuraProtocol` and `PolarProtocol` also build for Android unchanged;
`StrandCore` and its dependencies are cross-compiled for Android by
`android/swift-core/build-swift-core.sh` (Swift SDK for Android, NDK r30).

## Android on the shared core

Since 2026-11-01 ([`fork/android/CORE-ONLY-PLAN.md`](fork/android/CORE-ONLY-PLAN.md)):

- Android stores only in the core's GRDB database through the generated `CoreWhoopDao`
  (`Tools/gen_core_dao.py`); Room is gone from the app. A schema change is a `WhoopStore` migration
  that both platforms run.
- Scoring, analytics, import, backup and other computation live in `Packages/` and reach Android
  through `NoopCoreJNI`. Kotlin keeps the Bluetooth transport (with its own frame decoders under
  `com.noop.protocol`), Android services, the Forge Compose UI
  (`com.noop.ui.forge`) and presentation helpers.
- A change under `Packages/**` changes both platforms: `Tools/local-tests.sh` builds and tests Android
  for it, and the parity oracles in `android/app/src/test/resources/core_parity/` must still pass.
- Running state and open steps: [`fork/android/STATUS.md`](fork/android/STATUS.md).

## Where platform differences live

- Prefer package code for protocol, storage, analytics and import logic.
- Put shared SwiftUI/app behavior in `Strand/` and guard genuine OS differences with
  `#if os(macOS)`, `#if os(iOS)`, or `#if canImport(...)`.
- Route small AppKit/UIKit differences through `Strand/System/Platform.swift`.
- Keep iOS-only lifecycle, HealthKit, widgets, Live Activities and quick actions under `StrandiOS/`.
- Keep menu-bar and other macOS-only integrations behind the macOS target membership in
  `project.yml`.
- Treat the Watch app as a companion: the phone sends the latest bounded snapshot through
  WatchConnectivity; the Watch does not open the phone database.

## Adding a feature

1. Put platform-neutral logic in the appropriate package and add package tests.
2. Reuse the same app-layer implementation on macOS and iOS where possible.
3. Isolate unavoidable platform services at their existing seams rather than duplicating the
   feature.
4. Add Watch behavior only when the bounded snapshot contract supports it honestly.
5. Build both `Strand` and `NOOPiOS`; test package changes with `swift test`.
6. For Android, move missing logic into the core rather than writing a Kotlin version; run
   `Tools/local-tests.sh`, which builds and tests Android for package changes.

See [architecture](ARCHITECTURE.md), [build instructions](BUILD.md), and
[contributing](CONTRIBUTING.md) for the detailed module and verification rules.
