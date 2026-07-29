<p align="center">
  <img src="docs/assets/logo.svg" alt="NOOP AI" width="72">
</p>

<h1 align="center">NOOP AI</h1>

<p align="center"><b>Your WHOOP data, on your own devices, with a coach that remembers.</b></p>

<p align="center">
  <img alt="Current release" src="https://img.shields.io/badge/current%20beta-9.2.2%20DX%20Beta-C8902F?style=flat-square">
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

## What this fork adds

NOOP AI stays close to [RyanBR's NOOP](https://github.com/ryanbr/noop) for the strap protocol,
on-device analytics, storage and shared design system. The code below is the additional,
Apple-first layer maintained in this fork:

| Fork addition | What it does |
|---|---|
| 🤖 **A real coaching system, not just a chat box** | A configurable identity and coaching style, streaming replies, model-specific history budgets and 26 consent-gated tools that can read local summaries, explain readiness, draw charts, propose plans and write only the logs you explicitly request. Provider connections support Anthropic, OpenAI, Gemini, OpenRouter and custom OpenAI-compatible endpoints with your own key; tool calling is enabled where the selected provider and model support it. [Coach architecture →](docs/COACH.md) |
| 🧠 **Private long-term memory on the device** | Hybrid keyword and semantic retrieval over approved facts, your own chat turns and selected journal context. The Nomic embedding model runs locally on iPhone; raw sensor streams and numerical health histories are never embedded. Consent can be withdrawn at any time, and the derived index can be rebuilt or deleted. [SemanticMemory package →](Packages/SemanticMemory/) |
| 🎯 **Goals, Journey and a plan you control** | One structured goal with feasibility and safety checks, progress based on actual evidence, milestones without invented streaks, and weekly proposals you can accept, decline, reschedule, swap or skip. A model proposal never silently becomes your schedule. |
| 🔐 **Purpose-by-purpose data consent** | Essentials, Personal and Deep Insights presets make setup simple; Expert mode exposes the individual grants. Sensitive journal topics always require a separate decision, and unavailable grants remove the corresponding tools before a request is sent. [Privacy model →](docs/PRIVACY_SECURITY.md) |
| 🔔 **Proactive coaching with a local history** | Optional daily briefs, check-ins and goal reviews live in the Coach; plan proposals and important body/goal signals also feed the in-app bell, so useful events remain visible even when iOS cannot show a notification banner. |
| 🧪 **Review-first health workflows** | Lab reports can be read from a text PDF or on-device photo OCR, but only recognised marker candidates you confirm become Lab Book entries. Files, OCR text and unconfirmed values are not retained. |
| 🍎 **Apple-first interface and distribution** | A redesigned Today experience, configurable Coach entry points, compact-iPhone chat handling, fork-added surfaces covering upstream's full Apple language matrix, and an unsigned AltStore/SideStore beta that is signed only with the Apple ID you choose. |

The upstream base and the fork additions remain intentionally separated in code so upstream protocol,
analytics and safety fixes can continue to be merged without rewriting the coaching layer.

## Latest beta — 9.2.2 DX Beta

- **The Coach follows NOOP's selected language.** The same strict language contract now covers normal
  chat, custom prompts, card reads, check-ins and proactive messages.
- **Every fork-added Apple screen has caught up with upstream.** All 915 fork-specific strings ship in
  English plus the complete eight-language Apple matrix.
- **Compact-iPhone chat fixes.** The composer clears the floating navigation bar, and long answers stay
  fully opaque while scrolling.

Read the full [9.2.2 DX Beta notes](docs/releases/v9.2.2-dx-beta.md).

## In development

- **Android distribution.** The Android source is version-aligned with 9.2.2; a public Android beta
  download will follow in a later rollout.
- **More practical alert history.** The inbox will keep evolving around events that actually happened,
  rather than becoming a second copy of scheduled reminders.

## Download and install

### iPhone and iPad — DX Beta

The iOS build is an **unsigned IPA on purpose**. Add the source below in AltStore or SideStore, then
the sideloader signs the app locally with the Apple ID you choose. NOOP AI never receives your Apple ID
or a signing certificate.

**Source URL:**

```
https://raw.githubusercontent.com/DX23876/noop/main/altstore-source.json
```

- **AltStore:** Browse → **+** → paste the source URL → add NOOP AI.
- **SideStore:** Sources → **+ Add Source** → paste the same URL → install NOOP AI.
- Prefer a direct file? Download `NOOP-ios-unsigned-v9.2.2-dx-beta.ipa` from the
  [DX Beta prerelease](https://github.com/DX23876/noop/releases/tag/v9.2.2-dx-beta).

See [the iOS install guide](docs/IOS.md) for the free-Apple-ID limits, widget notes, and build-from-source
instructions.

### Platform status

| Platform | Status | Distribution |
|---|---|---|
| iOS / iPadOS | 9.2.2 DX Beta | AltStore, SideStore, or build from source |
| macOS | Source build | Build with Xcode; a packaged beta follows separately |
| Android | Distribution in progress | Source version aligned; public beta follows later |

## The NOOP foundation retained

| | |
|---|---|
| ⌚ **Own your strap data** | Connect directly to a WHOOP 4.0 or 5.0/MG over Bluetooth. No WHOOP account, subscription, or cloud relay. |
| 📈 **Compute locally** | Charge, Effort, Rest, sleep, HRV, heart rate, recovery trends, and correlations are calculated and stored on your device. |
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
