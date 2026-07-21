# NOOP AI — for nerds 🤓

👈 Looking for the friendly tour? **[Back to the README](../README.md)**

This is the technical deep-dive: the fork rationale, the full 22-tool table, token-cost mechanics,
the architecture, build/signing minutiae, and the upstream-sync mechanics. If you just want to know
what the app does and how to get it running, the README has everything you need — this page is for
when you want to know *why*, or you're about to touch the code yourself.

## Contents

- [Why a fork, not a contribution upstream?](#why-a-fork-not-a-contribution-upstream)
- [The coach's 22 tools, in full](#the-coachs-22-tools-in-full)
- [Token cost and prompt caching](#token-cost-and-prompt-caching)
- [Under the hood: the architecture](#under-the-hood-the-architecture)
- [Quickstart: the signing fine print](#quickstart-the-signing-fine-print)
- [Staying in sync with upstream](#staying-in-sync-with-upstream)
- [Full docs index](#full-docs-index)
- [Attribution, in full](#attribution-in-full)

---

## Why a fork, not a contribution upstream?

NOOP AI is a **personal fork** of [ryanbr/noop](https://github.com/ryanbr/noop). Not a competitor,
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
  macOS scheme, so macOS isn't merely carried along: it is where the test suite executes. The
  **Android** tree is the one kept untouched, purely so `git merge upstream/main` keeps working; it
  is not built or tested here.
- **Additive only.** Everything this fork adds lives in its own new files under `Strand/AI/`. No
  upstream logic is rewritten in place. Nothing touches BLE, protocol decoding, or the analytics
  math — the parts that genuinely benefit from cross-platform parity are left completely alone.
- **It works.** Upstream `9.0.0` and `9.0.1` have both merged into this fork. Between them they've
  produced exactly one merge conflict, ever — two purely additive edits to the translation catalog
  landing in the same spot, not overlapping content. Not one coach file has ever needed a manual
  merge. That's the additive-files design paying off, not luck.

## The coach's 22 tools, in full

The README covers the idea (the coach fetches its own data instead of being handed a fixed
summary); here's every tool it can reach for, mid-sentence, while answering you. `get_readiness`
and `get_charge_drivers` in particular read from the **exact same engines** the Today screen does,
so the coach's verdict can never contradict what you already see there.

| | Tool | What it pulls |
|---|---|---|
| 📊 | `get_biometric_summary` | 14 days of charge/effort/rest/HRV/RHR + 30-day averages |
| 🏃 | `get_recent_workouts` | Your recent sessions, with effort and heart rate |
| 😰 | `get_stress_index` | Today's autonomic load (Baevsky index over your R-R intervals) |
| 😴 | `get_sleep_detail` | Per-night stages, efficiency, and your rolling sleep-debt ledger |
| 📅 | `get_range_report` | Any 7–365 day window: averages, trends, headline changes |
| 🎯 | `get_readiness` | The same push/maintain/rest verdict Today shows — ACWR, training monotony, contributing signals |
| 🔬 | `get_charge_drivers` | *Why* today's Charge is what it is, term by term — never an invented reason |
| 📝 | `propose_plan` | Suggests a session. Never schedules one — that's your call, in the app |
| ⚖️ | `get_session_outlook` · `simulate_day` | What a session (or a swap, or a hypothetical) actually costs, from your own history |
| ✅ | `get_plan_adherence` | What you agreed to vs. what happened — and why, when you told it |
| 🔍 | `get_personal_patterns` | Your own n-of-1 correlations ("late meals cost you 8 % recovery") |
| 📈 | `plot_metric` | Draws a real chart, inline in the chat |
| 🧠 | `remember_fact` · `update_fact` · `forget_fact` | Its own long-term memory |
| 🕰️ | `search_past_conversations` | Finds what you discussed weeks ago — by keyword, by day, or both ("what did I ask you yesterday?") |
| 📓 | `get_my_logs` | Reads back what you logged: caffeine, journal, lab markers, hydration, mood |
| 💓 | `get_zone_minutes` | Minutes per heart-rate zone, so a prescribed intensity can be checked rather than assumed |
| ☕ | `log_caffeine` · `log_journal` · `log_lab_marker` | **Writes** to your real app data |

That last row is the fun one: **"just had a double espresso"** becomes a genuine entry in the
Caffeine card. **"drank last night"** becomes a journal entry. **"my Vitamin D came back at 38"**
becomes a Lab Book marker. Same data the app always had — just logged by talking instead of tapping
through a form.

📖 The full schema for every one of these — parameters, gating, the two safety gates, the plan
book's state machine, the memory ranking algorithm — lives in **[`COACH.md`](COACH.md)**.

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
| **Protocol** | `Packages/WhoopProtocol` | Raw BLE frames → structs. CRC-checked, pure Swift, no CoreBluetooth. Builds and tests on Linux. |
| **Storage** | `Packages/WhoopStore` | SQLite via GRDB. Migrations, caches. |
| **Analytics** | `Packages/StrandAnalytics` | The actual science: HRV, recovery, strain, sleep. Database-free, pure functions. |
| **Design system** | `Packages/StrandDesign` | Palette, components, charts. UI uses tokens only — no hardcoded colours. |
| **App** | `Strand/`, `StrandiOS/` | CoreBluetooth, the Repository, the screens, `RootTabView`. |
| **The coach** 🆕 | `Strand/AI/` | Everything this fork adds. All new files. |

The rule that keeps this fork sane: **the more wire-level or math-level a change is, the deeper
into `Packages/` it belongs — and the more it must be covered by tests that run with no app, no
strap, and no Bluetooth.** The coach sits at the very top of that stack and pulls from it through
the same consent-gated summaries the UI uses.

Deeper: [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`ANALYTICS.md`](ANALYTICS.md) ·
[`PROTOCOL.md`](PROTOCOL.md)

## Quickstart: the signing fine print

The README's Quickstart gets you to `⌘R`. Here's what's actually going on with a free Apple ID,
and the two trade-offs it carries — both already handled in `project.yml`:

- **The Watch app and widget are excluded from the iOS build.** A free account gets no App Groups
  and only 10 app IDs per 7 days, and every embedded extension burns one. The main app and every
  coach feature are unaffected. Got a paid account? Both are one line each to re-enable, documented
  inline in `project.yml`.
- **Free-signed apps expire after 7 days.** Reconnect and ⌘R to renew. (Note that `xcodegen
  generate` clears the Team field — reselect it, or pin `DEVELOPMENT_TEAM` in `project.yml`.)

## Staying in sync with upstream

This fork tracks [ryanbr/noop](https://github.com/ryanbr/noop) so upstream's protocol work,
analytics fixes and features keep flowing in:

```bash
git remote add upstream https://github.com/ryanbr/noop.git   # once
git fetch upstream --tags
git merge upstream/main    # keep this fork's README/branding + project.yml signing
```

Because every fork-specific change lives in its own file rather than editing upstream code in
place, this stays remarkably clean — two merges in, `Strand/AI/` has needed **zero** manual
conflict resolutions. Watch for one thing after any merge: `Tools/i18n_audit.py` gates German,
Spanish and French coverage as a *standing invariant* (upstream tightened this in `9.0.1`), so a
merge that adds upstream UI text needs upstream's own translations to already cover it — which they
do; it's new **fork** strings that need adding by hand.

## Full docs index

**This fork**
- [`COACH.md`](COACH.md) — the coach in full: tools, goal gates, the plan book, memory, providers,
  architecture.
- [`IOS.md`](IOS.md) — iOS build + HealthKit details.
- [`DETAILS.md`](DETAILS.md) — this page.

**Upstream (all still accurate)**
- [`FEATURES.md`](FEATURES.md) — the full feature guide for NOOP itself.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — how the whole thing fits together.
- [`ANALYTICS.md`](ANALYTICS.md) — the recovery/strain/sleep maths, with citations.
- [`PROTOCOL.md`](PROTOCOL.md) — the WHOOP BLE protocol.
- [`PRIVACY_SECURITY.md`](PRIVACY_SECURITY.md) — the data posture in detail.
- [`BUILD.md`](BUILD.md) — full build + signing.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — the BLE safety contract and design-system rules.
- [`../CHANGELOG.md`](../CHANGELOG.md) — upstream release history.

## Attribution, in full

NOOP AI is a fork of **[NOOP](https://github.com/ryanbr/noop)** by ryanbr — please treat that
repository as the canonical project, not this fork. NOOP itself stands on community
protocol-documentation work:

- **`johnmiddleton12/my-whoop`** — the WHOOP 4.0 BLE protocol behind `WhoopProtocol` / `WhoopStore`.
- **`b-nnett/goose`** — the WHOOP 5.0 / MG BLE protocol documentation.
- **`groue/GRDB.swift`** — SQLite persistence. · **`weichsel/ZIPFoundation`** — export unzipping.

NOOP contains no WHOOP proprietary code, firmware, logos, or assets. Full detail in
[`../ATTRIBUTION.md`](../ATTRIBUTION.md).

---

👈 **[Back to the README](../README.md)**
