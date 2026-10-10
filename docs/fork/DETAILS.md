# NOOP Forge — for nerds 🤓

👈 Looking for the friendly tour? **[Back to the README](../../README.md)**

This is the technical deep-dive: the fork rationale, an overview of the coach's tools, token-cost
mechanics, the architecture, build/signing minutiae, and where this fork stands relative to upstream
today. If you just want to know what the app does and how to get it running, the README has everything
you need. This page is for when you want to know *why*, or you're about to touch the code yourself.

## Contents

- [Why a fork, not a contribution upstream?](#why-a-fork-not-a-contribution-upstream)
- [The coach's 38 tools](#the-coachs-38-tools)
- [Token cost and prompt caching](#token-cost-and-prompt-caching)
- [Under the hood: the architecture](#under-the-hood-the-architecture)
- [Quickstart: the signing fine print](#quickstart-the-signing-fine-print)
- [Relationship to upstream today](#relationship-to-upstream-today)
- [Full docs index](#full-docs-index)
- [Attribution, in full](#attribution-in-full)

---

## Why a fork, not a contribution upstream?

NOOP Forge is a **personal fork** of [ryanbr/noop](https://github.com/ryanbr/noop). Not a competitor,
not a rebrand that hides where it came from. Every protocol decoder, every analytics formula, every
pixel of the design system comes from upstream NOOP and its own credited sources (see
[Attribution](#attribution-in-full)). What this fork adds on top is **a much bigger coach** — and
that addition is Apple-only.

Upstream NOOP runs on a hard rule: **analytics and stored data must be byte-identical between the
Swift and Kotlin implementations.** That's exactly the right rule for a dependable cross-platform
WHOOP client — but it means every feature has to earn its place on macOS, iOS *and* Android at
once, kept in lockstep, forever.

A fast-moving, opinionated AI coach is precisely the kind of thing that rule *should* keep out of
the core project. It doesn't need an Android twin, and it doesn't need to be re-derived in Kotlin to
be worth having. It needs to iterate quickly, for one person. So rather than push upstream toward a
"no" it would be right to give, it lives here.

**What that means in practice:**

- **Apple platforms, both of them.** This fork builds and tests `NOOPiOS` (iOS 17+) *and* `Strand`
  (macOS 13+) — the coach's shared files have to compile for both, and `StrandTests` runs under the
  macOS scheme, so macOS isn't merely carried along: it is where the test suite executes. **As of
  2026-07-23, Android is dropped as a target entirely** — not merely carried along for merge
  convenience — and the cross-platform parity contract that drove the byte-identical rule above is
  formally retired for this fork. Dropping Android parity is also what unblocked iOS-only system
  surface this fork wouldn't otherwise have bothered with — a home-screen widget and a Siri
  "How's my recovery?" intent, for instance, that would have needed an Android twin before.
- **Additive only.** Everything this fork adds lives in its own new files under `Strand/AI/`. No
  upstream logic is rewritten in place. Nothing touches BLE, protocol decoding, or the analytics
  math — the parts that genuinely benefit from cross-platform parity are left completely alone.
- **It worked, while merging was the practice.** Upstream `9.0.0` and `9.0.1` both merged cleanly
  into this fork before the 2026-07-23 pivot — between them exactly one merge conflict, ever, and not
  one coach file ever needed a manual merge. The additive-files design is *why* that was painless; see
  [Relationship to upstream today](#relationship-to-upstream-today) for where things stand now.

## The coach's 38 tools

The README covers the idea (the coach fetches its own data instead of being handed a fixed
summary). `get_readiness`, `get_charge_drivers` and `get_training_load` read from the **exact same
engines** the Today and Training Load screens do, so the coach's verdict can never contradict what you
already see there.

| Group | Tools |
|---|---|
| 📊 Today and recovery | `get_biometric_summary`, `get_readiness`, `get_charge_drivers`, `get_stress_index`, `get_body_metrics` |
| 😴 Sleep | `get_sleep_detail` |
| 🏃 Training | `get_recent_workouts`, `get_strength_history`, `get_training_load`, `get_zone_minutes`, `get_plan_adherence`, `get_training_preferences` |
| ⚖️ What-if | `get_session_outlook`, `simulate_day`, `estimate_session_effort` |
| 🔥 Energy | `get_energy_balance` |
| 📅 Long range | `get_range_report`, `get_metric_history`, `get_data_catalog` |
| 🔍 Patterns | `get_personal_patterns` |
| 📓 Logs | `get_my_logs`, `get_sensitive_logs` |
| 🧠 Memory | `remember_fact`, `update_fact`, `forget_fact`, `search_past_conversations` |
| 📝 Propose | `propose_plan`, `propose_goal_setup` |
| 🏋️ Hevy | `find_hevy_exercises`, `get_hevy_routines`, `propose_hevy_routine`, `propose_hevy_workout` |
| ☕ Log for you | `log_caffeine`, `log_journal`, `log_lab_marker`, `log_weight` |
| 📈 Show | `plot_metric`, `show_card` |

The log tools are the fun ones: **"just had a double espresso"** becomes a genuine entry in the
Caffeine card, **"drank last night"** a journal entry, **"my Vitamin D came back at 38"** a Lab Book
marker. Every propose tool only creates a draft; nothing is saved, scheduled or sent to Hevy until the
user accepts it in the app.

**Access to all 38 is gated per purpose, not by one switch.** Every tool belongs to exactly one of
nine `CoachPurpose` groups (`coreBiometrics`, `longHistory`, `workouts`, `planning`, `stress`, `logs`,
`sensitiveLogs`, `memory`, `patterns`) via an exhaustive `switch`, so a new tool cannot ship without
being assigned a group. Essentials, Personal and Deep insights are simple presets over these groups;
Expert mode exposes the individual controls. Sensitive logs remain a separate extra choice.

📖 The full schema for every one of these (parameters, gating, the two safety gates, the plan book's
state machine, the memory ranking algorithm) lives in **[`COACH.md`](COACH.md)**.

## Token cost and prompt caching

Anthropic conversations get an explicit **prompt cache breakpoint**: the tool loop's largest
recurring cost — the tool-definition list and system prompt, re-sent on every round of a multi-round
answer — is cached after the first hit. Because a cache can silently fail to engage below a length
threshold rather than erroring, Settings shows a **plain-language card** after every question:
cached, just written, or "no caching, and here's probably why" — a number, not a hope.

**Token counts are no longer Anthropic-only.** The OpenAI-shaped providers report usage too, and it
matters more there: on OpenRouter *you* pick the model, from a catalogue spanning three orders of
magnitude in price. Shipping model choice without any way to see what a turn cost would leave the
one decision you actually make unmeasurable. Their `prompt_tokens` includes cached tokens where
Anthropic's `input_tokens` excludes them, so the parser subtracts — a turn means the same thing
whatever produced it.

## Under the hood: the architecture

If you like knowing how the sausage is made — the layering is genuinely nice, and it's upstream's
design, not this fork's:

| Layer | Where | What lives there |
|---|---|---|
| **Protocol** | `Packages/WhoopProtocol`, `OuraProtocol`, `PolarProtocol` | Raw BLE frames → structs. CRC-checked, pure Swift, no CoreBluetooth. Builds and tests on Linux. |
| **Storage** | `Packages/WhoopStore` | SQLite via GRDB. Migrations, caches. |
| **Analytics** | `Packages/StrandAnalytics` | The actual science: HRV, recovery, strain, sleep, training load, goal pace. Database-free, pure functions. |
| **Import** | `Packages/StrandImport` | WHOOP CSV, Apple Health, Strong, Hevy, FitNotes. |
| **Training** 🆕 | `Packages/StrandTraining`, `Packages/MuscleMap` | Routines, the offline exercise catalogue, set maths, muscle taxonomy and body maps. |
| **Memory** 🆕 | `Packages/SemanticMemory` | On-device embeddings and retrieval for the coach. |
| **Design system** | `Packages/StrandDesign` | Palette, components, charts. UI uses tokens only, no hardcoded colours. |
| **App** | `Strand/`, `StrandiOS/`, `StrandiOSWidgets/`, `NOOPWatch*` | CoreBluetooth, the Repository, the screens, `RootTabView`, widgets and the watch. |
| **The coach** 🆕 | `Strand/AI/` | Chat, providers, tools, goals and consent. |

The rule that keeps this fork sane: **the more wire-level or math-level a change is, the deeper
into `Packages/` it belongs — and the more it must be covered by tests that run with no app, no
strap, and no Bluetooth.** The coach sits at the very top of that stack and pulls from it through
the same consent-gated summaries the UI uses.

One piece worth naming inside `Strand/AI/`: **`CoachNotifier`** is what decides category, priority
and relevance-window for anything that reaches the user outside the chat itself — a proposed session
versus a proactive hint versus a status reminder, each rendered and actioned differently in the
bell. It is why a proposal arrives with Accept, Change and Decline while a hint only needs reading;
see [`COACH.md`](COACH.md) §11a for the full mapping.

Deeper: [`ARCHITECTURE.md`](../ARCHITECTURE.md) · [`ANALYTICS.md`](../ANALYTICS.md) ·
[`PROTOCOL.md`](../PROTOCOL.md)

## Quickstart: the signing fine print

Source builds and the Full IPA contain everything: the iPhone app, widgets, Live Activities, the
Apple Watch app and its complications. The AltStore/SideStore IPA is built from the same bundle with
the `PlugIns/` and `Watch/` folders stripped from a staged copy, because sideloaders install an
embedded watch bundle unreliably and a failure there costs the whole install.

Two things to know when you build and sign it yourself:

- **Your own bundle ID.** Put `BUNDLE_ID_PREFIX` in the gitignored
  `Config/BundleIdSecrets.xcconfig` so the app signs under your own Apple ID without touching
  `project.yml`.
- **Free-signed apps expire after 7 days.** Reconnect and ⌘R to renew. `xcodegen generate` clears
  the Team field, so reselect it after each generate.

The [iOS guide](../IOS.md) covers the AltStore/SideStore path, free-account limits and known
AltStore errors.

## Relationship to upstream today

**Since 2026-07-23 this fork is Apple-only and diverges freely.** The cross-platform parity contract
is retired and the Android tree was removed on 2026-08-14. What still binds, and is unrelated to that
retirement: the app stays offline, on-device, with no server, no account, no cloud sync, no telemetry,
and the project stays anonymous (see `CLAUDE.md`).

Upstream is still merged on purpose. Release 12.0.1 carries three syncs, through upstream 12.0.0 and
the 12.1.0 test beta. On 2026-10-10 the fork was **692 commits ahead and 0 behind** upstream's `main`
(re-check with `git rev-list --left-right --count upstream/main...HEAD`; the number moves and is not
maintained here). How a sync is done, and the gotchas that recur, are in [FORK_GUIDE](../FORK_GUIDE.md);
every judgement call is recorded in [decisions](decisions.md).

Because fork-specific work mostly lives in its own files (the coach in `Strand/AI/`, training in its
own packages), merges stay manageable. Two things still need care on every sync: upstream migrations
that land in a slot the fork already used must be renumbered, and `Tools/i18n_audit.py` gates
translation coverage, so new upstream UI text needs its translations before the merge can pass.

## Full docs index

The complete, maintained index is the [documentation map](../README.md). The fork's own guides:

- [`COACH.md`](COACH.md): the coach in full, with tools, goal gates, the plan book, memory, providers
  and architecture.
- [`MUSCLE_ANALYTICS.md`](MUSCLE_ANALYTICS.md): Balance, Fatigue and Strength on the muscle map.
- [`LIVE_STRENGTH_WORKOUTS.md`](LIVE_STRENGTH_WORKOUTS.md): the workout lifecycle, trackers and resume.
- [`opengym-integration.md`](opengym-integration.md): native training, routines and the logger.
- [`decisions.md`](decisions.md): every fork decision, in order.
- [`releases/`](releases/): the fork's release notes.
- [`IOS.md`](../IOS.md): installing, signing and building for iPhone.
- [`DETAILS.md`](DETAILS.md): this page.

## Attribution, in full

NOOP Forge is a fork of **[NOOP](https://github.com/ryanbr/noop)** by ryanbr — please treat that
repository as the canonical project, not this fork. NOOP itself stands on community
protocol-documentation work:

- **`johnmiddleton12/my-whoop`** — the WHOOP 4.0 BLE protocol behind `WhoopProtocol` / `WhoopStore`.
- **`b-nnett/goose`** — the WHOOP 5.0 / MG BLE protocol documentation.
- **`groue/GRDB.swift`** — SQLite persistence. · **`weichsel/ZIPFoundation`** — export unzipping.

NOOP contains no WHOOP proprietary code, firmware, logos, or assets. Full detail in
[`../ATTRIBUTION.md`](../../ATTRIBUTION.md).

---

👈 **[Back to the README](../../README.md)**
