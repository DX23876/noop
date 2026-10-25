# Skip spike (2026-10-25)

Question: can one SwiftUI screen serve both the iOS app and the Android app, so a change is made once? Tried
with [Skip](https://skip.dev) 1.9.19 in its native mode (Skip Fuse: Swift compiled for Android with the same
Swift 6.4.1 SDK for Android the shared core uses, SwiftUI rendered through Jetpack Compose). The spike lives
outside the repository (`~/NoopSpikes/skip-spike`); nothing in the app changed.

## What was built

A settings screen shaped like the More tab: a header card, grouped sections, three pickers, two toggles, a
navigation link to a detail screen with a progress ring, a slider and a material card, buttons and an alert.
One SwiftUI file. `skip export --debug` produced an iOS app and an Android app from it.

## Findings

| Area | Result |
|---|---|
| Lists, sections, pickers, toggles, navigation, alerts, sliders, gradients, `trim`/`stroke` rings, `.blur`, light and dark | Work on Android after one change; look like a clean Android version of the iOS grouped list (Material controls, Android back arrow) |
| `monospacedDigit()` | Not available on Android; the build fails until it is removed or fenced |
| `.ultraThinMaterial` (glass) | Compiles, draws nothing on Android: the card's fill is missing |
| Rounded system font (`design: .rounded`) | Falls back to the normal face |
| `Canvas`, `GraphicsContext` (layers, filters, blend modes), `TimelineView`, materials, Swift Charts | Present in SkipUI only as declarations whose bodies are `fatalError()`. The Today hero rings, sleep charts, trend charts and glass cards cannot be shared; they stay native per platform, which is what the Forge Compose screens already do (`OrganicRing.kt` ports the iOS ring) |
| Embedding in the existing Android app | Not done: Skip 1.9.19 needs Kotlin 2.3.0, Android Gradle Plugin 9.2.0, compile SDK 36, min SDK 28 and the Compose BOM 2026.05.01. The app is on Kotlin 1.9.24, AGP 8.5.2, Gradle 8.7, compile SDK 34, min SDK 26 and Compose BOM 2024.06.00. Upgrading is its own project (KSP and Room follow Kotlin; min SDK 28 drops Android 8) |
| Size | The debug APK is 230 MB (debug symbols, four ABIs, 31 arm64 libraries); the app bundle is 69 MB. Skip states about 60 MB for the Swift runtime in a Fuse app; the shared core already ships that runtime, so the two would share it |
| Memory | 179 MB PSS for the settings screen on the emulator |
| Build | iOS archive about 30 s, Android about 3 minutes from clean. Skip runs on macOS and, per its Homebrew bottles, on Linux, so the Linux Android CI is not ruled out (untried) |
| Licences | Skip's libraries are MPL-2.0 (file-level copyleft, fine to ship unmodified); the `skip` build tool is AGPL-3.0 and does not ship |

## Setup notes

- `brew install skip` pulls Gradle 9.8, OpenJDK and `swiftly`. `swiftly init --no-modify-profile --skip-install`
  satisfies Skip without putting another toolchain in front of Xcode's `swift`, which `Tools/local-tests.sh` uses.
  Skip found the installed Swift SDK for Android and used the 6.4.1 toolchain.
- On the owner's Mac, SwiftPM's binary downloads hang: the network settings have automatic proxy configuration
  (`http://wpad/wpad.dat`), which URLSession waits on and curl ignores. The spike served Skip's binary from a
  local HTTP server through a SwiftPM mirror, removed afterwards.
- Never run two SwiftPM resolutions in parallel; they wait on each other's cache lock.

## Conclusion

Skip shares list-and-form screens well, which are the cheap part of the app. The screens that make the app look
like itself (hero rings, charts, glass) cannot be shared with it and need per-platform code either way. Adopting
it first needs the Android toolchain upgrade above. Owner decision pending.
