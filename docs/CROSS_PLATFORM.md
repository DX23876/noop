# Apple-platform architecture — macOS, iOS, and watchOS

NOOP AI in this fork is Apple-only. macOS and iOS share the same Swift packages and most app-layer
code; the watchOS companion receives a bounded snapshot from the iPhone. The fork no longer carries
an Android source tree or Kotlin parity contract. For Android, use
[RyanBR's upstream repository](https://github.com/ryanbr/noop).

## Current targets

| Target | Code home | Distribution | Role |
|---|---|---|---|
| macOS app (`Strand`) | `Strand/` + `Packages/` | Universal ZIP or Xcode | Reference desktop app |
| iOS/iPadOS app (`NOOPiOS`) | `StrandiOS/`, shared `Strand/`, `Packages/` | Unsigned IPA or Xcode | Phone/tablet app |
| Widgets/Live Activity (`NOOPiOSWidgets`) | `StrandiOS/Widgets/` | Embedded in both iOS IPAs | Home/Lock Screen and Live Activity |
| Watch app (`NOOPWatch`) | Watch sources selected by `project.yml` | Full IPA or Xcode | Companion surface |
| Watch complication (`NOOPWatchComplications`) | Watch complication sources selected by `project.yml` | Full IPA or Xcode | Snapshot complication |

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
| `NoopLocalAccess` | Optional read-only local-access CLI/package | macOS 13+ |

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

See [architecture](ARCHITECTURE.md), [build instructions](BUILD.md), and
[contributing](CONTRIBUTING.md) for the detailed module and verification rules.
