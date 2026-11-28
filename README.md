<p align="center">
  <img src="docs/assets/forge-icon.png" alt="NOOP Forge" width="112">
</p>

<h1 align="center">NOOP Forge</h1>

<p align="center">
  <b>Your strap. Your numbers. No subscription.</b><br>
  A complete recovery, sleep and training app for WHOOP 4.0, 5.0 and MG straps.<br>
  One shared core for iPhone, iPad, Mac, Apple Watch and Android. No account, no cloud.
</p>

<p align="center">
  <a href="https://dx23876.github.io/forge/"><b>Website</b></a> ·
  <a href="https://dx23876.github.io/forge/install/"><b>Install</b></a> ·
  <a href="https://dx23876.github.io/forge/features/"><b>Features</b></a> ·
  <a href="https://dx23876.github.io/forge/compare/"><b>Compare</b></a> ·
  <a href="https://dx23876.github.io/forge/firmware/"><b>Firmware</b></a> ·
  <a href="docs/README.md"><b>Docs</b></a>
</p>

<p align="center">
  <a href="https://github.com/DX23876/noop_forge/releases/latest"><img alt="Release 13.0" src="https://img.shields.io/badge/release-13.0-C8902F?style=for-the-badge"></a>
  <img alt="iPhone, iPad, Mac, Apple Watch and Android" src="https://img.shields.io/badge/iPhone%20%C2%B7%20iPad%20%C2%B7%20Mac%20%C2%B7%20Watch%20%C2%B7%20Android-234F9E?style=for-the-badge">
  <a href="LICENSE"><img alt="License: PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20NC-6B737B?style=for-the-badge"></a>
  <a href="https://discord.com/invite/wKgyqVdjrP"><img alt="Discord: Noop Community" src="https://img.shields.io/badge/Discord-Noop%20Community-5865F2?style=for-the-badge&logo=discord&logoColor=white"></a>
</p>

<p align="center">
  <img src="docs/assets/screenshots/v13.0.0/hero.webp" width="940" alt="Four screens of NOOP Forge in demo mode: Today with the Charge, Effort and Rest rings over a mountain photograph, the Health tab with last night's vitals, Today in dark mode and the muscle map">
</p>
<p align="center"><sub>NOOP Forge 13.0 in demo mode, with made up numbers.</sub></p>

> [!WARNING]
> **Keep your strap away from the official WHOOP app.** It installs firmware updates by itself. On WHOOP
> 5.0 and MG, firmware **50.43.1.0** and **50.43.2.0** are reported to hold back data from independent
> apps, and there is no way back. Never connect the strap to the WHOOP app again and uninstall it.
> [What has been reported and how to check your strap](https://dx23876.github.io/forge/firmware/).

## What it is

NOOP Forge reads your WHOOP strap over Bluetooth and works everything out on your own device: how well
you recovered, how hard your day was, how you slept and how your training is going. Your data never has
to leave your phone and there is nothing to subscribe to.

More than 500 features, checked against the code. The main areas:

| Area | What you get |
|---|---|
| **Today** | Living Charge, Effort and Rest rings, a board of 26 measure and about 20 card tiles you arrange yourself, a timeline of the day, one Log sheet for everything |
| **Scores** | Every factor with your own range and its effect, a scoring guide, history pages, the whole history rescored once when a formula changes |
| **Sleep** | Stages against your typical night, sleep debt, a bedtime for full recovery, editing and adding nights, a silent strap alarm per weekday, a wind-down reminder; a phone smart alarm on Android |
| **Health** | Vitals in your own range, six focus areas, about 55 metrics in Explore, a per-second Deep Timeline, a 60-second HRV reading, Trends, Compare, a weekly report |
| **Stress and mind** | Hourly stress, stress check-ins with a buzz, 22 breathing patterns, resonance pace, journal, What works, mood, caffeine, water, cycle awareness |
| **Training** | Strength logger with last time's sets and progression hints, rest timer on the Lock Screen, supersets, plate calculator, 1,324 exercises, routines, plans and plan builder |
| **Running and cycling** | GPS with honest distance, voice feedback, zone and pace warnings, auto-pause, interval plans, pacer, elevation, GPX and FIT export |
| **Muscles and load** | A muscle map for balance, fatigue and strength, strength and cardio load kept apart, room today, daily advice, VO₂max |
| **Goals** | Daily to long-term goals with fair pace, protection for bad weeks, badges and records, widgets, Watch and Siri |
| **Body, energy, nutrition** | Weight trend and forecast, tape and body fat, progress photos, three estimates of what you burn, a food log with barcode and label reading, a nutrition score, a diet plan with twelve ways of eating |
| **ECG** | 30-second readings on the WHOOP MG with analysis and an Apple Watch comparison |
| **AI coach** | Optional, your own key or server, 40 data tools, morning brief, plan book, memory you control, ten data permissions |
| **Everywhere** | Home and Lock Screen widgets, Live Activities, Siri, an Apple Watch app, a Mac app with a menu bar, Android with Health Connect |
| **Your data** | Imports from WHOOP, Apple Health, Health Connect, Hevy, Strong, FitNotes, Liftosaur, Oura, Fitbit, Garmin, Mi Fitness and workout files; one backup file, saved daily to a folder you choose |

Every area explained, with pictures: [dx23876.github.io/forge/features](https://dx23876.github.io/forge/features/).
The full reference: [Feature guide](docs/FEATURES.md).

## Why Forge

There are four free apps for a WHOOP strap: [ryanbr/noop](https://github.com/ryanbr/noop), Aura,
OpenStrap Edge and NOOP Forge. Forge is the one to pick if you want:

- **every Apple device and Android on one core**, so each device shows the same numbers;
- **the deepest training tools**, from the gym notebook to the muscle map;
- **every number explained**, with formula changes applied to your whole history in one controlled step;
- **the complete source in the open**, and releases built by GitHub from it with a SHA-256 checksum and a signed provenance record for every file;
- **NOOP carried forward**: every change of the original project is merged, and Forge keeps building while the original has been quiet since 26 October 2026.

The others are ahead in places, and the comparison says where:
[four apps side by side](https://dx23876.github.io/forge/compare/).

## Install

| Device | How |
|---|---|
| **iPhone and iPad** (iOS 17+) | Add `https://raw.githubusercontent.com/DX23876/noop_forge/main/altstore-source.json` in [AltStore](https://altstore.io) or [SideStore](https://sidestore.io), then install NOOP Forge |
| **Mac** (macOS 13+) | Download the zip from the [latest release](https://github.com/DX23876/noop_forge/releases/latest), move NOOP to Applications, right click and Open |
| **Apple Watch** | The `full` IPA from the release page, signed with the [Forge Signer](https://dx23876.github.io/forge/sign/) |
| **Android** (8+) | The APK from the [latest release](https://github.com/DX23876/noop_forge/releases/latest) |

Step by step, Feather and Apple Health, checking a download and moving from another app:
[install guide](https://dx23876.github.io/forge/install/). Backups from ryanbr/noop open in Forge.

## Privacy

Everything stays on your device. There is no NOOP server and no account, and nobody, the developer
included, can see your data. The app goes online only for a short daily update check (on by default, can
be switched off) and for what you turn on or press yourself: the AI coach, Hevy sync, food lookups,
exercise media, and votes, wishes or problem reports on the project page. No ads, no tracking, no
analytics.
Details: [Privacy and security](docs/PRIVACY_SECURITY.md).

## For the technically curious

| Topic | Read |
|---|---|
| How every score is calculated, with sources | [Analytics](docs/ANALYTICS.md) · [FAQ](docs/FAQ.md) |
| Every feature in detail | [Feature guide](docs/FEATURES.md) |
| One core, several platforms | [Cross-platform](docs/CROSS_PLATFORM.md) · [Android](docs/ANDROID.md) · [Android status](docs/fork/android/STATUS.md) |
| The AI coach | [Coach guide](docs/fork/COACH.md) |
| How the app talks to the strap | [Protocol](docs/PROTOCOL.md) |
| Code, building, contributing | [Architecture](docs/ARCHITECTURE.md) · [Build](docs/BUILD.md) · [Fork guide](docs/FORK_GUIDE.md) · [Contributing](docs/CONTRIBUTING.md) |
| Everything else | [Documentation map](docs/README.md) |

<details>
<summary><b>How the code is built</b></summary>

All logic lives in Swift packages that run without the app, without a strap and without Bluetooth. The
apps for iPhone, Mac and Watch are thin layers on top, and so is Android: its Kotlin code handles
Bluetooth, Android services and the screens and asks the same Swift core for every number.

```
 Apps        iPhone · iPad · Mac · widgets · Apple Watch     Android (Kotlin, Compose)
 Coach       chat, AI providers, tools, goals, permissions
 ─────────────────────────────────────────────────────────────
 Bridge      NoopCoreJNI           the shared core for Android
 Core        StrandCore            daily analysis, rebuilds, backups, energy, food, sync
 Design      StrandDesign          colours, components, charts (Apple only)
 Training    StrandTraining        routines, exercises, set maths
             MuscleMap             muscles and body maps
 Memory      SemanticMemory        on-device search for the coach
 Import      StrandImport          WHOOP, Apple Health, Strong, Hevy, Oura, Garmin…
 Analytics   StrandAnalytics       HRV, recovery, strain, sleep, load
 Storage     WhoopStore            SQLite database and migrations
 Protocol    WhoopProtocol         reading the strap's Bluetooth data
             OuraProtocol · PolarProtocol
```

The app never sends commands that could change or erase anything on the strap, and checks every message
from it for transmission errors.

</details>

## Taking part

- **Ideas and votes:** [Discussions](https://github.com/DX23876/noop_forge/discussions/categories/ideas), one
  idea per thread; press the upvote arrow on the ones you want.
- **Bugs:** an [issue](https://github.com/DX23876/noop_forge/issues/new/choose) with a strap log.
- **Questions and setup help:** the [Noop Community Discord](https://discord.com/invite/wKgyqVdjrP), the
  shared NOOP community, so say which app you run.
- **Code:** welcome, but open an idea or an issue first and wait for a yes. The scope rules are in
  [CONTRIBUTING](docs/CONTRIBUTING.md).

## About the project

NOOP Forge is an independent, non-commercial fork of [ryanbr/noop](https://github.com/ryanbr/noop) and
not the official NOOP app. The original project deserves the credit for the strap connection, the scores
and the design. NOOP Forge is not affiliated with WHOOP.

The Bluetooth work builds on community research, with thanks to
[`johnmiddleton12/my-whoop`](https://github.com/johnmiddleton12/my-whoop) (WHOOP 4.0),
[`b-nnett/goose`](https://github.com/b-nnett/goose) (WHOOP 5.0/MG),
[OpenStrap](https://github.com/OpenStrap) (MG ECG) and
[`groue/GRDB.swift`](https://github.com/groue/GRDB.swift) (database).

> [!IMPORTANT]
> NOOP Forge is not a medical device. Its scores, ECG readings and health values are estimates for
> personal use, not medical advice or a diagnosis. If you have health concerns, talk to a doctor.

NOOP Forge is free. If it saves you a subscription, you can
[buy me a coffee on Ko-fi](https://ko-fi.com/dx23876). The app works exactly the same either way.

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE): free for personal,
non-commercial use. See [NOTICE](NOTICE) and [ATTRIBUTION.md](ATTRIBUTION.md) for credits.

Building on NOOP Forge? You are welcome to, within the license. It carries two Required Notices:

```
Required Notice: Copyright 2026 NoopApp
Required Notice: Copyright 2026 DX23876 (NOOP Forge) – https://github.com/DX23876/noop
```

Anyone who passes on any part of this code, changed or not, has to include both lines with the license
terms.
