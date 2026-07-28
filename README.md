<p align="center">
  <img src="docs/assets/logo.svg" alt="NOOP AI" width="72">
</p>

<h1 align="center">NOOP AI</h1>

<p align="center"><b>Your WHOOP data, on your own devices, with a coach that remembers.</b></p>

<p align="center">
  <img alt="Current release" src="https://img.shields.io/badge/current%20beta-9.10.0%20Beta%201-C8902F?style=flat-square">
  <img alt="Platforms" src="https://img.shields.io/badge/iOS%2017%2B%20%C2%B7%20macOS%2013%2B-234F9E?style=flat-square">
  <img alt="Straps" src="https://img.shields.io/badge/WHOOP-4.0%20%C2%B7%205.0%2FMG-234F9E?style=flat-square">
  <img alt="Privacy" src="https://img.shields.io/badge/no%20account%20%C2%B7%20no%20cloud-6B737B?style=flat-square">
  <a href="LICENSE"><img alt="License: PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial-6B737B?style=flat-square"></a>
</p>

<p align="center">
  <img src="docs/assets/banner.svg" alt="NOOP — your strap, your data, your machine" width="640">
</p>

---

<!--
MAINTAINER NOTE — update this small release section for every beta or public release:
1. Change the badge and heading version.
2. Keep three or fewer concrete highlights.
3. Move shipped items out of “In development” and link the matching release note.
-->

## Latest beta — 9.10.0 Beta 1

- **A bell that remembers real events.** Battery, health, movement, and smart-alarm alerts now have a
  short local history in Today. The entry remains useful even when the operating system cannot show a banner.
- **A calmer Classic Today.** The first Synthesis insight no longer expands the entire card, and the
  redundant WHOOP label has been removed.
- **Unsigned iOS IPA, signed by you.** Install through AltStore or SideStore. NOOP AI does not use an
  Apple team, certificate, or personal signing name to distribute the build.

Read the full [9.10.0 Beta 1 notes](docs/releases/v9.10.0-beta.1.md).

## In development

- **Android distribution.** The Android source is version-aligned with 9.10.0; a public Android beta
  download will follow in a later rollout.
- **More practical alert history.** The inbox will keep evolving around events that actually happened,
  rather than becoming a second copy of scheduled reminders.

## Download and install

### iPhone and iPad — Beta 1

The iOS build is an **unsigned IPA on purpose**. Add the source below in AltStore or SideStore, then
the sideloader signs the app locally with the Apple ID you choose. NOOP AI never receives your Apple ID
or a signing certificate.

**Source URL:**

```
https://raw.githubusercontent.com/DX23876/noop/main/altstore-source.json
```

- **AltStore:** Browse → **+** → paste the source URL → add NOOP AI.
- **SideStore:** Sources → **+ Add Source** → paste the same URL → install NOOP AI.
- Prefer a direct file? Download `NOOP-ios-unsigned-v9.10.0-beta.1.ipa` from the
  [Beta 1 prerelease](https://github.com/DX23876/noop/releases/tag/v9.10.0-beta.1).

See [the iOS install guide](docs/IOS.md) for the free-Apple-ID limits, widget notes, and build-from-source
instructions.

### Platform status

| Platform | Status | Distribution |
|---|---|---|
| iOS / iPadOS | 9.10.0 Beta 1 | AltStore, SideStore, or build from source |
| macOS | Source build | Build with Xcode; a packaged beta follows separately |
| Android | Distribution in progress | Source version aligned; public beta follows later |

## What NOOP AI does

| | |
|---|---|
| ⌚ **Own your strap data** | Connect directly to a WHOOP 4.0 or 5.0/MG over Bluetooth. No WHOOP account, subscription, or cloud relay. |
| 📈 **Compute locally** | Charge, Effort, Rest, sleep, HRV, heart rate, recovery trends, and correlations are calculated and stored on your device. |
| 🤖 **Use a coach with context** | The optional coach can reason over the local data you explicitly allow, remember goals and preferences, and propose rather than impose a plan. |
| 🔒 **Keep control** | No telemetry, no NOOP account, and no server. The optional coach only contacts the provider and API key you configure when you send a message. |
| 📬 **See what happened** | Today and the bell keep daily signals, important status, and recent alerts visible without turning every event into noise. |

## Privacy, precisely

NOOP AI is offline-first. Your strap data, database, scores, history, goals, coach memory, and plans
stay on your device. The optional AI coach is the only feature that can make a network request, and it
does so only when you choose a provider, provide your own key, and send a message.

More detail: [Privacy and security](docs/PRIVACY_SECURITY.md).

## Build from source

You need a Mac with Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/DX23876/noop.git NOOP-AI
cd NOOP-AI
xcodegen generate
open Strand.xcodeproj
```

- Choose **NOOPiOS** and a physical iPhone to build iOS.
- Choose **Strand** to build macOS.
- For Android development, follow [Android build instructions](docs/ANDROID.md).

## Documentation

- [iOS install and build guide](docs/IOS.md)
- [Build and signing guide](docs/BUILD.md)
- [Coach guide](docs/COACH.md)
- [Feature reference](docs/FEATURES.md)
- [Privacy and security](docs/PRIVACY_SECURITY.md)
- [Contributing](docs/CONTRIBUTING.md)

## About the project

NOOP AI is a personal fork of [ryanbr/noop](https://github.com/ryanbr/noop). The upstream project
deserves credit for the protocol, analytics, and design-system foundations; this fork develops the
local coach and Apple-first beta distribution independently. It is an unofficial, non-commercial
interoperability project and is not affiliated with WHOOP.

## Disclaimer

NOOP AI is not a medical device. Its health and training values are on-device estimates, not clinical
advice or diagnosis. Use it as a personal tool and consult a qualified professional for medical decisions.

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE). See [NOTICE](NOTICE) and
[ATTRIBUTION.md](ATTRIBUTION.md) for bundled dependency and upstream credits.
