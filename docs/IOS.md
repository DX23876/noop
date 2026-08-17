# iOS / iPadOS — install, sign, and build

NOOP AI 10.1.1 ships as an intentionally unsigned iOS release. You sign it with your own Apple ID
through AltStore/SideStore or build it with Xcode. There is no App Store or TestFlight distribution
and no project-owned signing identity.

## Choose an IPA

The [10.1.1 release](https://github.com/DX23876/noop/releases/tag/v10.1.1-dx) publishes two variants:

| Artifact | Includes | Intended use |
|---|---|---|
| `NOOP-ios-unsigned-v10.1.1-dx.ipa` | iPhone/iPad app, Home/Lock Screen widgets, Live Activity | AltStore/SideStore, including free Apple IDs |
| `NOOP-ios-full-unsigned-v10.1.1-dx.ipa` | Everything above plus Watch app and complication | A signer/developer team that can provision every nested target |

Both IPAs are unsigned. The AltStore variant removes only the embedded Watch bundle; it keeps the
widget extension and the capability template used to provision the shared App Group and HealthKit.

## Install with AltStore or SideStore

1. Install [AltStore](https://altstore.io) or [SideStore](https://sidestore.io) using its official
   setup guide and your own Apple ID.
2. Download `NOOP-ios-unsigned-v10.1.1-dx.ipa` from the
   [release page](https://github.com/DX23876/noop/releases/tag/v10.1.1-dx).
3. Open the IPA with the sideloader or import it from the sideloader's **My Apps** screen.
4. If iOS asks, trust your Apple ID under **Settings → General → VPN & Device Management**.

### Add the update source

Add this raw source URL once:

`https://raw.githubusercontent.com/DX23876/noop/main/altstore-source.json`

- AltStore: **Browse → + → Add Source**.
- SideStore: **Browse/Sources → Add Source**.

The source points at the phone/iPad IPA. The release workflow updates it only after the artifact has
actually been uploaded.

### Free Apple ID limits

- A free signature expires after seven days; the sideloader must refresh it.
- The app and widget use separate App IDs, so the install consumes two of Apple's weekly App-ID
  allowance.
- The Watch bundle is omitted from the AltStore IPA because nested watchOS provisioning is not
  reliable with generic free-Apple-ID sideloading.
- The Full IPA needs matching identifiers, profiles, entitlements, and App Group assignments for all
  four nested targets. Use it only when your signer supports that topology.

## Build from source

Requirements:

- macOS with Xcode 26 or newer.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- A physical iPhone for BLE validation; the simulator cannot connect to a strap.

Prepare the pinned on-device Coach model/runtime once, generate the project, and open it:

```bash
Tools/bootstrap-nomic.sh
xcodegen generate
open Strand.xcodeproj
```

Select the `NOOPiOS` scheme and your iPhone. A Personal Team is sufficient for a development
install, subject to Apple's normal seven-day expiry and capability limits.

### Use your own bundle prefix

The default identifiers use the repository's development prefix. To install alongside another NOOP
build or avoid an identifier collision, create the gitignored file
`Config/BundleIdSecrets.xcconfig`:

```xcconfig
BUNDLE_ID_PREFIX = com.example.yourname
```

`Config/BundleId.xcconfig` and `project.yml` derive the app, widget, Watch, complication, and App
Group identifiers from that prefix. Keep automatic signing enabled and select the same team for every
target Xcode asks to provision.

### Command-line build

```bash
xcodegen generate

xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -destination 'generic/platform=iOS' \
  build
```

The app target deploys to iOS 17+. Package manifests may declare lower reusable-library floors; the
target settings in `project.yml` are authoritative for the shipped app.

## Current target topology

| Target | Purpose |
|---|---|
| `NOOPiOS` | iOS/iPadOS application |
| `NOOPiOSWidgets` | Home/Lock Screen widgets and Live Activity |
| `NOOPWatch` | watchOS companion |
| `NOOPWatchComplications` | Watch complication extension |

The iOS shell and platform services live under `StrandiOS/`. Shared app behavior remains under
`Strand/`; reusable protocol, store, analytics, import, design, Oura/Polar, and semantic-memory code
lives under `Packages/`. `project.yml` is the source of truth for target membership.

The phone sends the latest bounded snapshot to the Watch through WatchConnectivity. The Watch does
not open the phone database. macOS-only menu-bar and automation surfaces are excluded from iOS;
iOS-specific HealthKit, widgets, Live Activities, App Intents, and quick actions stay under
`StrandiOS/`.

## HealthKit and privacy

HealthKit access is opt-in. The app requests only the read/write types needed by enabled features,
imports incrementally, and marks NOOP-originated samples so they are not re-imported as external
data. Raw strap history, scores, and the local database remain on the device.

The app is offline-first, not network-impossible: the optional Coach contacts the provider you
configure, a source-built Oura history lane can pull your own Oura data in, and the manual update
check reads public GitHub release metadata. See [privacy and security](PRIVACY_SECURITY.md).

## Publishing

Maintainers publish from `main` with the manual
[`publish-ios-release.yml`](../.github/workflows/publish-ios-release.yml) workflow. It validates the
version and release notes, builds both IPAs, attaches the macOS ZIP, promotes the release only after
all required jobs succeed, and then updates `altstore-source.json`.

See [build and release instructions](BUILD.md#publish-an-unsigned-apple-release) for the complete
checklist.
