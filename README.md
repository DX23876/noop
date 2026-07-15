<p align="center">
  <img src="docs/assets/logo-v3.png" alt="NOOP AI" width="72">
</p>

<h1 align="center">NOOP AI</h1>

<p align="center"><b>An iPhone-only fork of NOOP, built around one idea: a WHOOP coach that actually knows you.</b></p>

<p align="center">
  <img alt="Fork of ryanbr/noop" src="https://img.shields.io/badge/fork%20of-ryanbr%2Fnoop-6B737B?style=flat-square&logo=github&logoColor=white">
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%20only-234F9E?style=flat-square">
  <img alt="AI coach" src="https://img.shields.io/badge/AI%20coach-11%20tools-C8902F?style=flat-square">
  <img alt="Apple Health" src="https://img.shields.io/badge/Apple%20Health-auto%20sync-60A0E0?style=flat-square">
  <img alt="Local first" src="https://img.shields.io/badge/local-first-E8B84B?style=flat-square">
  <a href="LICENSE"><img alt="License: PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-6B737B?style=flat-square"></a>
</p>

---

## This is a fork, not a rename

**NOOP AI is a personal fork of [ryanbr/noop](https://github.com/ryanbr/noop).** It is not a
competing project, a rebrand that hides its origin, or an attempt to replace the original. Every
protocol decoder, every analytics formula, every design-system component comes from upstream NOOP
and its own credited sources (see [Attribution](#attribution)). This fork exists to carry two
deliberate, narrow changes on top of that foundation: **iOS only**, and **a coach worth talking to
every day**.

If you want the full cross-platform project (macOS reference app, full Android app, WHOOP + Oura
support, the whole feature surface), **go use [ryanbr/noop](https://github.com/ryanbr/noop)** — it's
the canonical, actively maintained project and the right choice for almost everyone. This fork is
for the narrower case: you only carry an iPhone, and you want the AI coach pushed further than a
project that has to stay in lockstep across three platforms can reasonably justify.

## Philosophy — why fork instead of contribute upstream

Upstream NOOP runs on a hard rule (see its own `CLAUDE.md`): **analytics and stored data must be
byte-identical across the Swift and Kotlin implementations.** That's the right rule for a project
serious about being a dependable, cross-platform WHOOP client — but it means every shipped feature
has to earn its place on macOS, iOS *and* Android at once, kept in parity, forever. A fast-moving,
opinionated, iPhone-only AI coach is exactly the kind of thing that rule should keep out of the
core project. It doesn't need an Android twin. It doesn't need macOS to make sense. It needs to
iterate quickly on one platform for one person.

So instead of proposing something upstream would reasonably have to say no to, it lives here:

- **iOS only.** This fork builds and ships the `NOOPiOS` target. The macOS (`Strand`) and Android
  source trees are **kept, untouched, unmaintained by this fork** — purely so `git merge upstream`
  keeps working cleanly. They are not built, not tested, and not supported here.
- **The coach is the whole point.** Everything this fork adds is in `Strand/AI/`: new files,
  additive changes, never a rewrite of upstream logic. The methodology, the safety guardrails
  ("not a doctor," never diagnoses) and the on-device-only data posture are all inherited from
  upstream and left intact — only the coach's *capabilities* are extended.

## What's different from upstream, at a glance

Everything on the left already exists in [ryanbr/noop](https://github.com/ryanbr/noop) and this
fork builds directly on it. Everything marked
<img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> is
new here and, as far as this fork's author knows, **not (yet) in the upstream project**.

| Area | Upstream NOOP | NOOP AI (this fork) |
|---|---|---|
| Platforms shipped | macOS (reference), Android (full), iOS (build-from-source) | **iOS only** <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> |
| Apple Health sync | ✅ Automatic (HealthKit background delivery) | ✅ Same, unchanged |
| AI coach | ✅ Chat with your own API key, one pre-baked context block per message | ✅ Same base, **substantially extended below** |
| Coach personas (voice) | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> Guardian / Friend / Commander |
| Coach tool-calling | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> 11 tools, fetches real data on demand |
| Streaming replies | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> Token-by-token (Anthropic) |
| Persistent memory | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> Remembers facts + your training goal, across sessions |
| Conversational logging | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> "Had a coffee" → real caffeine/journal/Lab-Book entries |
| Chat survives restart | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> On-device transcript persistence |
| Proactive daily check-in | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> Reminder → deep-links to a fresh brief |
| In-chat charts | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> Native trend charts drawn inline |
| Sleep detail / range reports | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> Stages, sleep debt, 7–365 day reports on demand |
| Profile-aware coaching | — | <img alt="fork only" src="https://img.shields.io/badge/-fork%20only-C8902F?style=flat-square"> Age/HRmax/goal folded into every reply |

Nothing in that right-hand column touches BLE, protocol decoding, or the analytics math — the
part of NOOP that genuinely benefits from staying byte-identical across platforms is completely
untouched by this fork.

## The coach, in full

| Feature | What it does |
|---|---|
| **Coaching personas** | Pick a voice — **Guardian** (calm, protective), **Friend** (warm, encouraging) or **Commander** (direct, action-oriented). Tone only; methodology and safety guardrails are unchanged. |
| **Tool-calling (11 tools)** | Instead of one pre-baked text block, the coach fetches what it needs: biometric summary, recent workouts, stress index, sleep detail (stages + sleep debt), a 7–365 day range report, your strongest personal patterns, and a chart tool — plus three *write* tools (see logging below). |
| **Streaming replies** | Anthropic replies appear token-by-token, tool calls run inline mid-stream, instead of a silent wait. |
| **Persistent memory** | A `remember_fact` tool lets the coach save durable facts about you (goals, injuries, preferences) that persist across every future conversation. Your training goal gets its own field. Fully visible and editable in-app; nothing is remembered without you being able to see and delete it. |
| **Conversational logging** | "Just had a double espresso" → a real entry in the Caffeine card. "Drank last night" → a journal entry. "My Vitamin D was 38" → a Lab Book marker. Existing app data, written by the coach instead of a form. |
| **Chat persistence** | The conversation survives a relaunch (on-device JSON, capped, never synced). |
| **Proactive daily check-in** | An opt-in daily reminder — tap it and the coach opens with a freshly generated brief, not a stale one. |
| **In-chat charts** | The coach can draw a native trend chart (charge, effort, HRV, RHR, sleep) directly in the conversation when a trend is easier to see than to describe. |
| **Editable instructions** | The upstream free-text system-prompt editor still works underneath any persona. |

All of it rides on NOOP's existing **automatic Apple Health sync** (HealthKit background delivery
via observer + anchored queries, plus write-back of NOOP-computed vitals, sleep and workouts) —
inherited unchanged from upstream, so the coach is always reasoning over fresh data.

Every tool call is gated behind your existing data-access consent, reads only the same
summarised, non-raw data the rest of the app already computes, and — like upstream — nothing
leaves your phone except the request you deliberately send to your own AI provider key.

> Engineering note: every addition lives in its own file (`CoachPersona.swift`, `CoachTools.swift`,
> `CoachMemory.swift`, `CoachTranscriptStore.swift`, `CoachChart.swift`,
> `Providers/AnthropicTools.swift`, `Providers/AnthropicStreaming.swift`, `CoachCheckIn.swift`) and
> never rewrites upstream logic in place — the whole point is that `git merge upstream/main` stays
> low-conflict indefinitely.

## Quickstart (iOS)

Requires a Mac with **Xcode 26+**, [`xcodegen`](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a **physical iPhone** (BLE and HealthKit don't work in the Simulator).

```bash
# 1. Clone your fork
git clone https://github.com/DX23876/noop.git NOOP-AI
cd NOOP-AI

# 2. Generate the Xcode project from project.yml
xcodegen generate

# 3. Open, then run the NOOPiOS scheme on your iPhone
open Strand.xcodeproj
#    Select the "NOOPiOS" scheme → pick your device → set your signing team → Run (⌘R)
```

**A free Apple ID works**, with two trade-offs this fork's default config already accounts for:

- The Watch app and home-screen widget are **excluded from the iOS build** (`project.yml`) — a
  free account gets no App Groups and only 10 app IDs per 7 days, and each embedded extension
  needs its own. The main app and every coach feature above are unaffected; only the watch
  companion and widget are unavailable this way. Building with a paid Apple Developer account?
  Both are one line each to re-enable, documented inline in `project.yml`.
- Apps signed with a free ID **expire after 7 days** — just re-run from Xcode with your iPhone
  connected to renew.

In the app: pair your strap, grant Apple Health access, then open **Coach**, connect a provider
(paste your own API key), choose a coaching style, and turn on the daily check-in.

## Staying in sync with upstream NOOP

This fork tracks [ryanbr/noop](https://github.com/ryanbr/noop) so new upstream features (protocol
support, analytics improvements, bug fixes) keep flowing in:

```bash
git remote add upstream https://github.com/ryanbr/noop.git   # one time
git fetch upstream
git merge upstream/main        # resolve README/branding conflicts in favour of this fork
```

Because every fork-specific change lives in its own files rather than editing upstream code in
place, this has stayed a clean fast-forward-style merge with essentially no conflicts so far.

---

## Attribution

NOOP AI is a fork of **[NOOP](https://github.com/ryanbr/noop)** by ryanbr — please treat that
repository as the canonical upstream project, not this fork. NOOP itself stands on community
protocol-documentation work:

- **`johnmiddleton12/my-whoop`** — the WHOOP 4.0 BLE protocol behind the `WhoopProtocol` / `WhoopStore` packages.
- **`b-nnett/goose`** — the WHOOP 5.0 / MG BLE protocol documentation.
- **`groue/GRDB.swift`** — SQLite persistence. · **`weichsel/ZIPFoundation`** — export unzipping.

NOOP contains no WHOOP proprietary code, firmware, logos, or assets. Full detail in
[`ATTRIBUTION.md`](ATTRIBUTION.md).

## Disclaimer

NOOP AI is an independent, unofficial, non-commercial interoperability project. It is **not
affiliated with, endorsed by, or connected to WHOOP, Inc.** All references to "WHOOP" are nominative.

**NOOP is not a medical device.** Heart rate, HRV, recovery, strain, sleep stages, SpO₂, respiratory
rate and skin temperature are **approximations** from published methods — not clinically validated,
not medical advice. The AI coach is not a doctor and must not be used to diagnose or treat. Consult a
qualified professional. Provided **as-is, with no warranty**, for **personal and educational use**.
See [`DISCLAIMER.md`](DISCLAIMER.md).

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE): **free for personal and
other non-commercial use** — read it, run it, fork it. Commercial use is not granted. This fork keeps
the upstream `LICENSE` and `Copyright 2026 NoopApp` notice intact, per NOOP's mirroring terms; bundled
dependencies keep their own licenses (see [`NOTICE`](NOTICE)).

## Docs

- [`docs/IOS.md`](docs/IOS.md) — iOS build and HealthKit details.
- [`docs/BUILD.md`](docs/BUILD.md) — full build instructions.
- [`CHANGELOG.md`](CHANGELOG.md) — upstream release history.
- [`project.yml`](project.yml) — XcodeGen project definition (source of `Strand.xcodeproj`).
