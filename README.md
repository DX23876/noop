<p align="center">
  <img src="docs/assets/logo.svg" alt="NOOP AI" width="72">
</p>

<h1 align="center">NOOP AI</h1>

<p align="center"><b>Your WHOOP data, on your iPhone, with a coach that actually remembers you.</b></p>

<p align="center">
  <img alt="Fork of ryanbr/noop" src="https://img.shields.io/badge/fork%20of-ryanbr%2Fnoop-6B737B?style=flat-square&logo=github&logoColor=white">
  <img alt="Version" src="https://img.shields.io/badge/version-9.0.2-234F9E?style=flat-square">
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%20only-234F9E?style=flat-square">
  <img alt="AI coach" src="https://img.shields.io/badge/AI%20coach-19%20tools-C8902F?style=flat-square">
  <img alt="Apple Health" src="https://img.shields.io/badge/Apple%20Health-auto%20sync-60A0E0?style=flat-square">
  <img alt="No cloud" src="https://img.shields.io/badge/no%20server-no%20account-E8B84B?style=flat-square">
  <a href="LICENSE"><img alt="License: PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-6B737B?style=flat-square"></a>
</p>

---

## What is this?

You own a WHOOP strap. It measures you all day. But the numbers live behind someone else's app and
someone else's subscription.

**NOOP** solves the first half of that: it talks to your strap over Bluetooth, stores everything in
a database on your phone, and computes recovery, strain, sleep and HRV **entirely on-device** — no
server, no account, no telemetry. It's a genuinely lovely piece of clean-room engineering, and it's
somebody else's project: **[ryanbr/noop](https://github.com/ryanbr/noop)**.

**NOOP AI** — this fork — solves a second half that only matters to one person: *the numbers still
don't talk back.* So it grows an AI coach into a thing you'd actually open every morning. One with a
real goal, a real memory, a plan you actually agreed to, and a Readiness verdict it never contradicts
— because it's reading the same numbers Today shows you, not guessing.

> **Just want a great WHOOP app?** Use **[ryanbr/noop](https://github.com/ryanbr/noop)**. It's the
> real project — macOS, Android, iOS, actively maintained, and the right answer for almost everyone.
> This fork is for the narrow case: you only carry an iPhone, and you want the coach pushed further
> than a cross-platform project could reasonably justify.

## This is a fork, not a rename

NOOP AI is a **personal fork** of [ryanbr/noop](https://github.com/ryanbr/noop). Not a competitor,
not a rebrand that hides where it came from. Every protocol decoder, every analytics formula, every
pixel of the design system comes from upstream NOOP and its own credited sources
(see [Attribution](#attribution)). This fork carries exactly two deliberate changes on top:
**iOS only**, and **a much bigger coach**.

### Why fork instead of contributing upstream?

Upstream NOOP runs on a hard rule: **analytics and stored data must be byte-identical between the
Swift and Kotlin implementations.** That's exactly the right rule for a dependable cross-platform
WHOOP client — but it means every feature has to earn its place on macOS, iOS *and* Android at
once, kept in lockstep, forever.

A fast-moving, opinionated, iPhone-only AI coach is precisely the kind of thing that rule *should*
keep out of the core project. It doesn't need an Android twin. It doesn't need macOS to make sense.
It needs to iterate quickly, on one platform, for one person. So rather than push upstream toward a
"no" it would be right to give, it lives here.

**What that means in practice:**

- **iOS only.** This fork builds the `NOOPiOS` target. The macOS (`Strand`) and Android trees are
  **kept but untouched** — purely so `git merge upstream` keeps working. They're not built, not
  tested, not supported here.
- **Additive only.** Everything this fork adds lives in its own new files under `Strand/AI/`. No
  upstream logic is rewritten in place. Nothing touches BLE, protocol decoding, or the analytics
  math — the parts that genuinely benefit from cross-platform parity are left completely alone.
- **It works.** Upstream `9.0.0` and `9.0.1` have both merged into this fork. Between them they've
  produced exactly one merge conflict, ever — two purely additive edits to the translation catalog
  landing in the same spot, not overlapping content. Not one coach file has ever needed a manual
  merge. That's the additive-files design paying off, not luck.

## The coach

The base app already had a chat-with-your-own-API-key coach that got one pre-baked block of text
per message. This fork turns that into something with a goal, a plan, a memory, and hands to go
fetch its own data instead of being handed a fixed summary and hoping for the best.

### It has a name and a face

The coach used to just be "Guardian" or "Friend" — a tone with no one behind it. Now **who it is**
and **how it talks** are two separate things: pick **Svea** or **Marv** (each a name, a curated
avatar, and a voice), or make your own — any name, a symbol from the design system, or your own
photo, uploaded once and never leaving the device. The coaching *style* — Guardian (calm,
protective), Friend (warm), Commander (direct) — still layers on top unchanged; only the tone
shifts, never the methodology or the "I'm not a doctor" guardrails. The avatar follows the coach
everywhere: the chat header, beside every reply in the now messenger-style chat, and — optionally —
right on the Today entry card.

### It knows your goal, and says so honestly

Set one target — a run, a consistency streak, sleep, weight, or something free-text — and the coach
stops improvising:

- **Two safety checks, and neither one ever blocks you.** Is the pace *aggressive*? Rate is measured
  as a percentage of your own body weight or volume per week, so the same 20 kg cut reads correctly
  whether you weigh 60 kg or 160 kg — an aggressive pace just asks for a one-line reason (cut phase,
  medically supervised, your call) and remembers it. Is it *realistic*? A separate check against your
  on-device VO₂max estimate, evidence-based rather than a guess — and for weight goals, always
  honestly reported as "no data to judge that on," because there isn't.
- **It never plans your diet.** Weight is tracked, training is planned around it, and that's the
  entire lever the coach has — it says so outright rather than pretending otherwise.
- **The [Journey page](#the-rest-of-it)** shows where you stand — with no invented percentages.

### It proposes a plan; you decide

The coach can **suggest** a session for a day — it cannot schedule one. Every suggestion sits as a
proposal until you accept, decline, reschedule, or swap it yourself in the plan book.

Swapping shows the consequence *before* you decide, computed from your own workout history, not a
generic chart: *"CrossFit at 10:00 instead of Zone 2 — about 18 points and 2 recovery days instead of
6 and one. Tomorrow's projection drops from ~62 to ~45."* The same engine answers "what if" questions
free-form (*"hard session today, 7 hours' sleep — how do I look tomorrow?"*). Skipping something is
one tap and a reason, never a daily ritual, and reasons like pain or illness are read back with
context, not judgment — a skip streak doesn't get you permanently written off, either.

### It fetches its own data (19 tools)

Instead of being handed a fixed summary, the coach decides what it needs and goes and gets it —
mid-sentence, while it's answering you. `get_readiness` and `get_charge_drivers` in particular read
from the **exact same engines** the Today screen does, so the coach's verdict can never contradict
what you already see there.

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
| 🧠 | `remember_fact` · `update_fact` · `forget_fact` | Its own long-term memory (below) |
| 🕰️ | `search_past_conversations` | Finds what you discussed weeks ago |
| ☕ | `log_caffeine` · `log_journal` · `log_lab_marker` | **Writes** to your real app data |

That last row is the fun one: **"just had a double espresso"** becomes a genuine entry in the
Caffeine card. **"drank last night"** becomes a journal entry. **"my Vitamin D came back at 38"**
becomes a Lab Book marker. Same data the app always had — just logged by talking instead of tapping
through a form.

### It has a real memory

This is the part most AI chat features get wrong: they either forget everything, or they dump
everything into every prompt until it's expensive and unfocused. NOOP AI's memory works more like a
person's.

- **Facts have shape.** Each remembered fact carries a *category* (goal, injury, preference,
  physiology, schedule) and an *importance*. **Pinned** facts — a serious injury, a hard constraint
  — ride along on every single reply. Everything else is only pulled in when it's actually relevant
  to what you just asked.
- **It corrects itself.** The coach can `update_fact` and `forget_fact`, not just append. Tell it
  your knee is fine now and the stale fact gets rewritten, not stacked next to a contradiction.
  Near-duplicates are detected and merged, so rephrasings don't eat the memory budget.
- **It remembers past conversations.** Old chats aren't dead scrollback — the coach can search them,
  and a short digest of recent conversations rides along for continuity.
- **It tidies up cheaply.** When you move on from a chat, a **small, cheap model** (Haiku /
  gpt-4o-mini / Flash-Lite — you pick) quietly distils it into a one-line summary plus any durable
  facts. Your expensive coaching model never pays for housekeeping.

Every fact is visible and editable in Settings. Nothing is remembered that you can't see, correct,
or delete.

### It's honest about token cost, and caches what it can

Anthropic conversations get real **prompt caching**: the tool loop's largest recurring cost — the
tool-definition list and system prompt, re-sent on every round of a multi-round answer — is cached
after the first hit. Because a cache can silently fail to engage below a length threshold rather than
erroring, Settings shows a **plain-language card** after every question: cached, just written, or "no
caching, and here's probably why" — a number, not a hope.

### The rest of it

| Feature | What it does |
|---|---|
| **Settings hub** | A landing page and five focused subpages (Connection & model · Goal & Journey · Coaching · Memory · Privacy & data) instead of one long scroll. |
| **A daily briefing that's actually daily** | Gated on the calendar day, not on "haven't opened this chat yet" — it can't go stale across a long-running conversation. Each day's brief gets its own thread now; one you never reply to quietly archives itself once its day passes — restorable any time, never deleted. |
| **Coaching style** | **Guardian** (calm, protective), **Friend** (warm), **Commander** (direct) — HOW the coach talks. Separate from *identity* (WHO it is — Svea, Marv, or your own, [above](#it-has-a-name-and-a-face)). Methodology and the "I'm not a doctor" guardrails never change either way. |
| **Streaming** | Replies land token-by-token, with tool calls running inline, instead of a silent wait. |
| **Real chat UI** | Full-screen messenger: docked composer, time separators, copy + regenerate, stop mid-reply — with the coach's own avatar beside its replies. |
| **Conversation history** | Named, searchable threads. "New chat" no longer throws the old one away. Auto-archived brief threads live in their own section, one tap from restoring. |
| **In-chat charts** | Native trend charts drawn in the conversation, tappable to enlarge, and they survive a relaunch. |
| **Two ways in** | A card on Today, and/or a **draggable floating button** you can pin to any corner (clear of the tab bar) or lock in place. Your choice, in Settings. |
| **A guided goal setup** | A short, step-by-step flow (what → details → why → confirm) instead of one dense form, offered on first run and re-startable any time from Goal & Journey. The quick one-page editor is still one tap away for anyone who'd rather fill it in all at once. |
| **Goal & Journey, not five taps deep** | Its own entry in More, right alongside the coach itself — not buried in a settings subpage. |
| **Turn the coach off, keep the intelligence** | One Settings switch hides the Today card and the floating button entirely. Per-metric "Ask coach" and the AI that writes your card summaries keep working regardless — it only hides the chat, never the on-device analysis. |
| **Editable instructions** | Upstream's free-text system-prompt editor still works underneath any persona. |
| **Bring almost any model** | Anthropic, OpenAI, Gemini, or any OpenAI-compatible endpoint — a local Ollama/LM Studio server, or a hosted gateway like OpenRouter (confirmed working today over the same Custom path). |
| **Deutsch** | The coach's own UI — goal editor, plan book, Journey page, settings — is fully localised in German alongside English, on top of upstream's own translation coverage. |

All of it rides on NOOP's **automatic Apple Health sync** (HealthKit background delivery), inherited
unchanged from upstream — so the coach is always reasoning over fresh data.

📖 **Want the deep version?** → **[`docs/COACH.md`](docs/COACH.md)** — architecture, every tool's
schema, the two safety gates, the plan book's state machine, the memory ranking algorithm, provider
support, and the file map.

## What actually leaves your phone

Worth being precise about, because "AI" and "private" usually don't share a sentence:

- **The app itself is still fully offline.** Your strap data, your database, your computed scores,
  your goal, your plan, your memory, your chat history — all on-device. There is no NOOP server.
  There is no account.
- **Only the coach talks to the internet**, only when you send a message, only to **your own API
  provider using your own key**, and only if you've turned on data access. Turn that off and the
  coach still works — it just doesn't see your numbers.
- **It sends summaries, never raw signal.** Derived daily numbers and short text — never your raw
  R-R stream or raw sensor buffers.
- **You can go fully local.** Point the Custom provider at Ollama or LM Studio on your own machine
  and *nothing* leaves your network at all.

More: [`docs/PRIVACY_SECURITY.md`](docs/PRIVACY_SECURITY.md).

## What NOOP itself does

If you landed here without knowing the base project: everything below is **ryanbr/noop**, not this
fork — credit and detail belong to [the real project](https://github.com/ryanbr/noop) and
[`docs/FEATURES.md`](docs/FEATURES.md). The short version:

- **Pairs directly with a WHOOP 4.0 or 5.0/MG strap over Bluetooth Low Energy** — no WHOOP account,
  no WHOOP cloud, nothing in the middle. WHOOP straps don't show up in *Settings → Bluetooth*; NOOP
  finds them on their own advertising profile.
- **Computes its own scores, entirely on-device, from published methods**: **Charge** (recovery),
  **Effort** (strain), **Rest** (sleep quality) — an energy economy you wake with, spend through the
  day, and rebuild overnight — alongside HRV, resting heart rate, SpO₂, respiration and skin
  temperature. These are honest approximations, explicitly **not WHOOP's own scores**.
- **Everything lives in an on-device SQLite database.** Import a WHOOP or Apple Health export for
  instant history, or just wear the strap and let it build over the following nights.
- **No server, no account, no telemetry, anywhere in the project** — this fork included. The AI
  coach above is the *one* opt-in exception, and it only ever talks to the provider you chose.

## Quickstart (iOS)

You'll need a Mac with **Xcode 26+**, [`xcodegen`](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a **physical iPhone** — Bluetooth and HealthKit don't exist in the
Simulator.

```bash
# 1. Clone
git clone https://github.com/DX23876/noop.git NOOP-AI
cd NOOP-AI

# 2. Generate the Xcode project (project.yml is the source of truth —
#    Strand.xcodeproj is generated and never committed)
xcodegen generate

# 3. Open it
open Strand.xcodeproj
```

In Xcode: pick the **NOOPiOS** scheme → select your iPhone → **Signing & Capabilities** → set your
Team → **⌘R**. On the phone, trust the certificate under *Settings → General → VPN & Device
Management*.

**A free Apple ID works.** Two trade-offs, both already handled in `project.yml`:

- **The Watch app and widget are excluded from the iOS build.** A free account gets no App Groups
  and only 10 app IDs per 7 days, and every embedded extension burns one. The main app and every
  coach feature are unaffected. Got a paid account? Both are one line each to re-enable, documented
  inline in `project.yml`.
- **Free-signed apps expire after 7 days.** Reconnect and ⌘R to renew. (Note that `xcodegen
  generate` clears the Team field — reselect it, or pin `DEVELOPMENT_TEAM` in `project.yml`.)

Then in the app: pair your strap → grant Apple Health access → open **Coach** → paste your API key
→ pick a persona (and give your coach a name and a face, if you like) → optionally set a goal.

## Under the hood

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

The rule that keeps this fork sane: **the more wire-level or math-level a change is, the deeper into
`Packages/` it belongs — and the more it must be covered by tests that run with no app, no strap,
and no Bluetooth.** The coach sits at the very top of that stack and pulls from it through the same
consent-gated summaries the UI uses.

Deeper: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · [`docs/ANALYTICS.md`](docs/ANALYTICS.md) ·
[`docs/PROTOCOL.md`](docs/PROTOCOL.md)

## Staying in sync with upstream

This fork tracks [ryanbr/noop](https://github.com/ryanbr/noop) so upstream's protocol work,
analytics fixes and features keep flowing in:

```bash
git remote add upstream https://github.com/ryanbr/noop.git   # once
git fetch upstream --tags
git merge upstream/main    # keep this fork's README/branding + project.yml signing
```

Because every fork-specific change lives in its own file rather than editing upstream code in place,
this stays remarkably clean — two merges in, `Strand/AI/` has needed **zero** manual conflict
resolutions. Watch for one thing after any merge: `Tools/i18n_audit.py` gates German, Spanish and
French coverage as a *standing invariant* (upstream tightened this in `9.0.1`), so a merge that adds
upstream UI text needs upstream's own translations to already cover it — which they do; it's new
**fork** strings that need adding by hand.

## Docs

**This fork**
- [`docs/COACH.md`](docs/COACH.md) — the coach in full: tools, goal gates, the plan book, memory,
  providers, architecture.
- [`docs/IOS.md`](docs/IOS.md) — iOS build + HealthKit details.

**Upstream (all still accurate)**
- [`docs/FEATURES.md`](docs/FEATURES.md) — the full feature guide for NOOP itself.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the whole thing fits together.
- [`docs/ANALYTICS.md`](docs/ANALYTICS.md) — the recovery/strain/sleep maths, with citations.
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — the WHOOP BLE protocol.
- [`docs/PRIVACY_SECURITY.md`](docs/PRIVACY_SECURITY.md) — the data posture in detail.
- [`docs/BUILD.md`](docs/BUILD.md) — full build + signing.
- [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) — the BLE safety contract and design-system rules.
- [`CHANGELOG.md`](CHANGELOG.md) — upstream release history.

---

## Attribution

NOOP AI is a fork of **[NOOP](https://github.com/ryanbr/noop)** by ryanbr — please treat that
repository as the canonical project, not this fork. NOOP itself stands on community
protocol-documentation work:

- **`johnmiddleton12/my-whoop`** — the WHOOP 4.0 BLE protocol behind `WhoopProtocol` / `WhoopStore`.
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
