# The Coach — in full

Everything NOOP AI adds on top of [ryanbr/noop](https://github.com/ryanbr/noop) lives here. The
[README](../README.md) has the friendly tour; this is the technical one.

**Design rule for every line of it:** additive, in its own file, never a rewrite of upstream logic.
That's what keeps `git merge upstream/main` a non-event (upstream `9.0.0` and `9.0.1` both merged
with zero conflicts touching a single file under `Strand/AI/`).

---

## 1. Architecture

```
Strand/AI/
├── AICoach.swift              The engine: state, context building, send/stream, tool loop
├── AIProvider.swift           Provider enum: endpoints, models, cheap models, client factory
├── CoachPersona.swift         Guardian / Friend / Commander — voice only
├── CoachTools.swift           The 19 tools: schemas + dispatch
├── CoachMemory.swift          Long-term memory: facts, categories, ranking, dedup
├── CoachTranscriptStore.swift Conversations: model + JSON persistence
├── MemoryMaintainer.swift     Cheap-model summarisation + fact distillation
├── CoachChart.swift           In-chat chart artifacts
├── CoachStreaming.swift       SSE streaming
├── CoachGoal.swift            The structured goal: kind, target, date, status, history
├── GoalSafetyGate.swift       Pace check — warn, require a reason, never block
├── GoalFeasibility.swift      "Is this realistic?" — evidence-based, from VO₂max, not a guess
├── CoachPlanStore.swift       The plan book: propose → accept/decline/swap, one active week
├── PlanConsequence.swift      What a session or a swap actually costs, from your own history
├── JourneyMilestones.swift    Non-performance milestones — facts, never a streak counter
├── CoachUsageLog.swift        Per-turn token accounting (Anthropic): cache hit/write/miss
└── Providers/
    ├── Anthropic.swift             Base client (upstream file — kept untouched, see §5)
    ├── AnthropicTools.swift        Tool-use loop
    ├── AnthropicStreaming.swift    Token-by-token SSE
    └── AnthropicCaching.swift      Prompt-cache breakpoint + usage parsing

Strand/Screens/
├── CoachView.swift            The messenger chat + the shared `coachCover` presenter
├── CoachSettingsView.swift    A hub (status pill + 5 rows) into grouped subpages
├── CoachGoalView.swift        The goal editor + skippable first-run onboarding
├── CoachPlanView.swift        The plan book: accept, schedule, swap-with-consequence, one-tap skip
├── JourneyView.swift          Progress, milestones, plan history — no invented percentages
├── CoachHistoryView.swift     Conversation list: switch / rename / delete
└── CoachEntry.swift           Entry mode + the draggable floating button
```

`AICoachEngine` is a `@MainActor ObservableObject`, constructed once in `AppModel` and injected via
`.environmentObject(model.coach)`. It owns the conversation list, the active conversation, streaming
state, and every setting.

### The request path

```
user types
   ↓
systemPrompt          persona preamble + methodology + PINNED facts + goal
   ↓
context               tool-mode note  ─OR─  buildFullContext() when consent is on:
                        • clock (date/weekday/time-of-day, days since last workout)
                        • 14-day metric table + 30-day averages     (buildContext)
                        • recent workouts
                        • Readiness verdict — ACWR, Foster monotony, contributing signals
                        • Charge confidence (never states progress off a still-calibrating score)
                        • active plan + adherence (what was agreed vs. what happened, and why)
                        • today's stress index
                        • personal patterns + Lab Book   (2nd opt-in only)
                        • digest of recent conversation summaries
                        • facts RELEVANT to this question   (wireMessages)
   ↓
windowedMessages()    first user turn + last 10 messages (the middle is dropped)
   ↓
callProvider()        tool-use loop (Anthropic, cache-primed) or plain single-shot
```

Three deliberate choices in there:

- **Pinned vs. relevant facts are split.** Pinned facts ride the *system prompt* (always true, always
  relevant). Query-relevant facts are folded into the *turn's context* in `wireMessages()`, where the
  question is actually known. A large memory therefore doesn't inflate every request.
- **The history window is a message count, not a token budget** (`maxHistoryMessages = 10`). Blunt,
  but it keeps small local models (Ollama defaults to a 2048-token window) from having the reply
  crowded out. Parity with the Android implementation upstream.
- **Readiness and Charge drivers are read from the SAME engines Today uses**
  (`ReadinessEngine.evaluate`, `ChargeDrivers.chargeDrivers`) — never re-derived or eyeballed by the
  model. The coach cannot contradict what the Today screen already told you.

---

## 2. The 19 tools

Declared in `CoachTools.swift` as `CoachTool`, offered to the model as JSON Schema, dispatched in
`runCoachTool(_:input:)`. **All of them are gated behind `dataConsent`** — without it the dispatcher
returns a polite "no data access" string and the model coaches generally. A 20th, `get_personal_patterns`,
needs the *second* opt-in (`includeOnDeviceSignals`) on top.

Tool-calling only engages for providers that conform to `ToolCallingClient` (Anthropic today);
everything else falls back to the pre-baked-context path, which is why Readiness, Charge drivers,
the active plan and its adherence are *also* folded into `buildFullContext()` directly — a
non-tool-calling provider still sees the same verdicts, just pre-baked instead of fetched on demand.

### Read

| Tool | Params | Returns |
|---|---|---|
| `get_biometric_summary` | — | 14-day table + 30-day averages: charge, effort, rest, HRV, RHR, SpO₂, respiration, skin-temp deviation, steps, energy |
| `get_recent_workouts` | `limit` 1–30 | Sport, duration, effort, avg HR, energy, distance |
| `get_stress_index` | — | Today's Baevsky Stress Index over today's R-R |
| `get_sleep_detail` | `nights` 1–14 | Bed/wake, efficiency, deep/REM/light minutes, disturbances + the rolling 14-night sleep-debt ledger |
| `get_range_report` | `days` 7–365 | Per-metric averages, trends, headline changes |
| `get_readiness` | — | The SAME verdict Today shows (primed/balanced/strained/rundown/insufficient), acute:chronic workload ratio (Gabbett), Foster training monotony, and the contributing signals in plain English. Carries a HEALTH SIGNAL / SAFETY note when relevant — the model is told not to suggest more load regardless of the readiness level when it's present. |
| `get_charge_drivers` | — | *Why* today's Charge is what it is: each contributing term (HRV, resting HR, respiration, skin temperature) with its signed point contribution, your value, your baseline, and a plain-English read. Answers the single most common coaching question without the model inventing a reason. |
| `get_session_outlook` | `sport`, optional `swap_from` | What a session costs *this user*, from their own history: typical next-morning Charge cost, bounce-back days, tomorrow's projection. Pass `swap_from` to compare two activities side by side. |
| `simulate_day` | `effort`, `sleep_hours` | Projects tomorrow-morning Charge for a hypothetical ("hard session + 7h sleep tonight → how do I look tomorrow?"). Returns nothing rather than a guess when there's too little history to project honestly. |
| `get_plan_adherence` | `days` | What was agreed vs. what actually happened, including *why* a session was skipped when the user told the coach. Days still calibrating carry no verdict at all — never treated as adherence data. |
| `get_personal_patterns` | — | Top n-of-1 correlations (`EffectRanker`, significant only) + Lab Book roll-up. **Second opt-in required** (`includeOnDeviceSignals`) |
| `search_past_conversations` | `query` | Top-3 matching past chats as titled, dated snippets |

### Propose (never commits anything by itself)

| Tool | Params | Effect |
|---|---|---|
| `propose_plan` | `day`, `sport`, `intent`, `rationale` | Creates a `PlanProposal` in status `.proposed`. **Not a schedule** — the user must accept, decline, reschedule or swap it in the app. The model is told to never describe a proposal as settled. |

### Write

Real mutations to real app data — the same stores the UI writes.

| Tool | Params | Effect |
|---|---|---|
| `log_caffeine` | `mg`, `minutes_ago` | Entry in the Caffeine log |
| `log_journal` | `behavior`, `answered_yes` \| `value`, `day` | Journal behaviour entry |
| `log_lab_marker` | `marker`, `value`, `unit`, `day` | Lab Book marker |

### Memory

| Tool | Params | Effect |
|---|---|---|
| `remember_fact` | `fact`, `category`, `importance` | Saves a durable fact (near-dup aware) |
| `update_fact` | `old`, `new` | Rewrites a fact in place |
| `forget_fact` | `fact` | Deletes a fact |

### Visual

| Tool | Params | Effect |
|---|---|---|
| `plot_metric` | `metric` (charge/effort/hrv/rhr/sleep), `days` 7–180 | Renders a `StrandDesign.TrendChart` inline in the transcript; the snapshot persists with the conversation |

---

## 3. Goals & the two safety gates

`CoachGoal` (`CoachGoal.swift`) is deliberately **one active goal, not a portfolio**: `kind`
(`run` / `consistency` / `sleep` / `strength` / `weight` / `custom`), a baseline, a target, a unit, an
optional target date, a status (`active`/`paused`/`achieved`/`abandoned`/`archived`), local-only
motivation text, and a history of adjustments. Setting one is entirely optional — NOOP works fully
without a goal — and the onboarding sheet (`CoachGoalEditorView`, offered once, skippable) never nags
twice.

**The governing principle for both gates: warn, require a reason, then allow. Never block.** A
20 kg cut in 8 weeks might be irresponsible for one person and medically supervised for another — the
app has no way to know which, so it states the concern, asks the person to own the decision, and gets
out of the way. The one *exception* is not a training-pace gate at all: warning-sign symptoms (chest
pain, dizziness, unusual breathlessness) get a hard, non-overridable stop with a referral to a
professional — that's a safety instruction to the model, not something either gate below computes.

### `GoalSafetyGate` — "is this pace aggressive?"

Rate is measured as **percent of body weight per week** for weight goals (so the same absolute rate
reads correctly whether someone weighs 60 kg or 160 kg) and **percent of volume per week** for
running/consistency goals:

```swift
static let weightAggressiveFraction = 0.0075       // > 0.75 %/week of body weight → warn
static let weightVeryAggressiveFraction = 0.015    // > 1.5 %/week → warn harder, REQUIRE a reason
```

Verdicts: `ok` / `aggressive` / `veryAggressive`. Only `veryAggressive` sets `requiresReason` — the
UI then asks for one (cut phase, high starting weight, medically supervised, or free text) before
saving, and the reason is written to `acknowledgedRisk` so it's visible in the goal's own history and
travels with the goal into the coach's context. The gate never refuses to save.

### `GoalFeasibility` — "is this realistic?"

A separate, narrower question: not "is this safe" but "does the evidence support hitting it". Built
from the on-device VO₂max estimate (`FitnessAgeEngine.compute`) for performance goals — it is
evidence-based, not predictive; there's no race-time model here, just "your current fitness supports
this kind of pace change" vs. "unrealistic from where you are today". Weight goals are **always**
`.unknown`: there is no nutrition data to found a feasibility verdict on, and the coach says so rather
than guessing.

---

## 4. The plan book

`CoachPlanStore.swift` is the participatory core: the model can *suggest*, the person *decides*.

```swift
enum Status { case proposed, accepted, declined, modifiedByUser, completed, skipped, paused }
```

`propose_plan` is the **only** model-reachable entry point, and it force-resets status to
`.proposed` no matter what — there is no tool that accepts, schedules, or commits a plan on the
model's behalf. Turning a proposal into a `ScheduledSession` (day **and time** — "10:00 CrossFit", not
just "CrossFit sometime") is a UI action the person takes in `CoachPlanView`.

### Swapping — with the consequence shown before you decide

`PlanConsequence.swift` answers "what does swapping to X actually cost me" using two engines that
already existed for Today and Trends, now wired to the coach:

- **`ActivityCostEngine`** — typical Charge cost and recovery days for a sport, computed from *your own*
  workout history, not a generic table.
- **`RecoveryForecaster`** — projects tomorrow's Charge given today's effort and planned sleep.

`get_session_outlook` and `simulate_day` expose the same math as tools, so the coach can say *"CrossFit
at 10:00 instead of Zone 2: about 18 points and 2 recovery days instead of 6 and one. Tomorrow's
projection drops from ~62 to ~45. Your call"* — and mean it literally, because it's the same
computation `CoachPlanView`'s swap sheet shows before you tap.

### Skipping — a reason, not a guilt trip

One tap, on demand, never a daily ritual: `noTime` / `tired` / `pain` / `notFeelingIt` / `ill` /
`travel`. `pain` and `ill` trigger the same soft safety framing as the goal gate — informing, not
blocking. `get_plan_adherence` reads these back so a review is never "you failed", it's "here's what
happened and why". A **decline-streak floor** (`declineStreakFloor = 3`) stops the coach from
permanently going quiet on a sport after a few no's — it's offered again after a few days, not shelved
forever (no filter-bubble collapse).

---

## 5. The Journey page

`JourneyView.swift` + `JourneyMilestones.swift`, reachable from the goal card once a goal exists.

**No invented percentages.** Progress is only ever shown as a real measurement against the goal's
baseline and target. Without both, there is no percentage at all — the page falls back to what's
actually known: sessions completed, consistency, recovery trend. A goal that's five minutes old
correctly shows *nothing achieved yet*, and that's treated as a normal state, not an empty error.

Milestones (`JourneyMilestones.achieved`) are **facts, not a streak counter**: first week in, N
sessions completed, longest run, a stretch training pain-free, recovery trending up past a real
threshold (3.0 Charge points week-over-week, not week-to-week noise). Nothing here rewards a daily
habit loop or penalises a gap — deliberately, since a streak mechanic shames exactly the people who
get sick or travel, which is precisely when they need the app least judgmental.

---

## 6. Memory

`CoachMemory` is a `@MainActor` singleton, JSON in `UserDefaults`, capped at **40 facts**.

### The fact model

```swift
struct MemoryFact {
    let id: UUID
    var text: String
    var category: Category    // goal | injury | preference | physiology | schedule | other
    var importance: Importance // pinned | normal
    var createdAt: Date
}
```

Decoding is back-compatible: facts saved before categories existed decode as `.other` / `.normal`,
so an upgrade never drops your memory.

### Retrieval — the interesting part

Dumping 40 facts into every prompt is the naive approach: expensive, unfocused, and it crowds small
context windows. Instead:

- **`pinnedBlock`** — your training goal + every `.pinned` fact. Goes in the *system prompt*, every
  single request. This is for things that must frame every reply: a serious injury, a hard
  constraint.
- **`relevantBlock(for:limit:)`** — ranks the `.normal` facts against the **current question** and
  takes the top few (default 8, minus whatever pinned already took). Goes into the *turn's context*.

The ranking is deliberately deterministic and on-device — no embeddings, no extra API call:

```
score = |tokens(fact) ∩ tokens(question)|     // keyword overlap, stopwords removed, ≥3 chars
tie-break = createdAt (newer wins)
```

Boring, cheap, debuggable, and good enough: a question about sleep surfaces the sleep facts.

### Writing — self-healing

- **`add`** does **near-duplicate detection**, not exact-string matching. Texts are normalised
  (lowercased, punctuation stripped, single-spaced) and treated as duplicates when equal, or when
  one contains the other *and* they're within 60 % of each other's length. A near-dup **supersedes**
  the old fact in place (keeping its id, refreshing the text and timestamp) rather than stacking a
  rephrasing and burning a slot.
- **`update` / `remove`** are exposed to the model as `update_fact` / `forget_fact`, so a correction
  rewrites the stale fact instead of coexisting with a contradiction.
- Eviction is FIFO at the 40 cap.

Everything is visible and editable in `CoachSettingsView`'s Memory subpage — category icon, pinned
marker, inline edit, delete, forget-all.

### Cross-conversation recall

`CoachConversation` carries an optional `summary` (plus `summarizedCount` for the cost gate). Two
paths get it back to the model:

1. **`search_past_conversations`** — deterministic keyword search over every stored conversation
   (title + summary + messages), returning the best 3 as titled, dated snippets. On demand only.
2. **`recentSummariesDigest()`** — one line per recent summarised chat, injected into
   `buildFullContext()`. Cheap, and it works on providers with no tool-calling.

---

## 7. Cheap-model maintenance

Summarising chats shouldn't cost coaching-model money. `AIProvider.cheapModel` picks a small model
per provider:

| Provider | Coaching default | Cheap model |
|---|---|---|
| Anthropic | `claude-sonnet-4-6` | `claude-haiku-4-5-20251001` |
| OpenAI | `gpt-4o-mini` | `gpt-4o-mini` |
| Gemini | `gemini-flash-latest` | `gemini-flash-lite-latest` |
| Custom | *(you pick)* | *(falls back to your model)* |

The engine exposes `memoryModel` (editable in Settings) and `autoSummarize`.

`MemoryMaintainer` fires on `switchTo` / `newConversation` — i.e. when you *leave* a chat — and only
when **all** of these hold:

- `dataConsent` is on (chat content leaves the device, so it's the same gate as everything else)
- `autoSummarize` is on
- the conversation has ≥ 1 real user turn
- ≥ 4 new messages since the last summary (`summarizeThreshold`)

Then **one** cheap call returns a strict, easily-parsed shape:

```
SUMMARY: <one or two sentences>
FACT: <durable fact>
FACT: <another>
```

The summary lands on the conversation; the facts go through `CoachMemory.add` (so near-dup detection
and the cap still apply). It runs in a background `Task`, is best-effort, and **fails silently** —
memory upkeep must never interrupt a chat. A manual "Summarise this chat now" is in Settings.

---

## 8. Providers

| Provider | Chat | Streaming | Tool-calling | Prompt caching |
|---|---|---|---|---|
| Anthropic | ✅ | ✅ SSE | ✅ | ✅ |
| OpenAI | ✅ | — | — | — |
| Gemini | ✅ | — | — | — |
| Custom (OpenAI-compatible) | ✅ | — | — | — |

**Custom** points at any OpenAI-compatible base URL — Ollama (`http://localhost:11434/v1`), LM
Studio, llama.cpp, or a hosted gateway. Keyless for a local server, so a fully local coach means
*nothing* leaves your network at all. It's also confirmed working against **OpenRouter**
(`https://openrouter.ai/api/v1`) today — that's this same Custom path, not a dedicated integration;
a first-class OpenRouter provider with a searchable model picker (its catalogue is 300+ entries) is
on the fork roadmap.

**Prompt caching (Anthropic only).** The tool-use loop re-sends the full tool-definition list and
system prompt on every round of a multi-round answer — the exact prefix a `cache_control: ephemeral`
breakpoint on the system block is built for, since Anthropic renders `tools → system → messages` and
one breakpoint covers both. Because the cache silently does nothing below a model-dependent minimum
prefix length (4096 tokens on the Opus family) rather than erroring, `CoachUsageLog` reads
`cache_read_input_tokens` / `cache_creation_input_tokens` back off every response and a card in
Settings' Connection & model subpage states plainly whether it engaged, wrote, or never triggered —
so "is this actually saving money" is answered by a number, not a hope. The plain (tool-less)
`send()` path is deliberately **not** cached: it carries no tools, so its prefix sits under every
model's minimum on its own, and a breakpoint there would do nothing.

**Reasoning models need output headroom.** A model whose reasoning is mandatory (Gemini 2.5 Pro,
several OpenRouter models) spends output tokens on thinking *before* the visible answer — at a tight
`max_tokens` the budget can be gone before the reply starts. `CoachOutputBudget.maxTokens` (4096) is
the shared ceiling for the OpenAI-shaped providers, documented in `Providers/CoachOutputBudget.swift`
with the incident that motivated it.

Keys live in the **Keychain**, never in `UserDefaults`, never in the repo, never logged. Streaming
and tool-calling for OpenAI/Gemini remain open — see "Contributing / hacking on it" further down.

---

## 9. The privacy model

The app is offline-first and stays that way; the coach is the *only* thing that ever opens a socket.

**Consent is two-stage, both off by default:**

1. **`dataConsent`** — without it, no metrics are included in any request and every tool returns
   "no data access". The coach still works; it just doesn't know you.
2. **`includeOnDeviceSignals`** — additionally folds in your n-of-1 patterns and Lab Book roll-up.
   Summary-only, and gated behind `dataConsent` too.

**What is sent:** derived daily numbers (charge, HRV, RHR…), short summary lines, your saved facts,
your goal and plan state, and — under consent — past-conversation snippets for recall.

**What is never sent:** raw R-R streams, raw sensor buffers, raw PPG/IMU. The tool layer routes
through the same summarised reads the UI uses, so there's no path for raw egress even by accident.
The coach also **never plans nutrition** — there's no data to found that on, and a weight goal's
feasibility is always reported as `.unknown` rather than guessed.

**Where it goes:** only to the provider *you* chose, with *your* key, when *you* send a message.
There is no NOOP server. There is no account. Local provider ⇒ zero egress.

Everything stored — memory, conversations, goal, plan, chart snapshots — is on-device
(`UserDefaults` / Application Support JSON), capped, and never synced.

---

## 10. Entry points

| Route | Where |
|---|---|
| **Today card** | "Ask your Coach" on Today → full-screen chat |
| **Floating button** | Draggable, pinnable to any of 4 chrome-clear corners, lockable |
| **More tab** | The original `MoreDestination.coach` row |
| **Daily check-in** | Notification → deep-links to the Coach with a fresh brief (gated on the *logical* day, not per-conversation, so it can only fire once per real day) |

The card and button are user-selectable via `CoachEntryMode` (card / button / both) in Settings.
Corners are resolved against the safe area with clearances (bottom `+96`, top `+64`) so a pinned
button never covers the tab bar or the Today header.

All routes present through one shared `View.coachCover(isPresented:coach:)` helper in
`CoachView.swift` — `fullScreenCover` on iOS, `sheet` on macOS. The composer inside it clears
`RootTabView`'s floating tab bar via a measured (not guessed) environment value,
`\.floatingTabBarInset` — see the fix's commit for why a guessed pixel constant would have been wrong.

## 11. Settings

`CoachSettingsView` is a landing page (status pill + five rows) drilling into grouped subpages —
**Connection & model**, **Goal & Journey**, **Coaching**, **Memory**, **Privacy & data** — rather than
one long scroll of every card at once. Every card is the same view property it always was; only the
page it lives on changed. One genuine addition alongside the reshuffle: provider/key/model can now be
changed from **Connection & model** while already connected — previously the only path back to those
controls was Disconnect first.

---

## 12. Contributing / hacking on it

The whole coach is app-target Swift, which means **no default CI validates it**
(`swift-packages.yml` only builds `Packages/**`, and `app-build.yml` is disabled). So:

```bash
xcodegen generate
# iOS
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build
# macOS — shared files must keep compiling there too
xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

⚠️ **Always `git checkout -- "*.xcstrings"` after a build** — unless you just committed *intentional*
catalog content yourself. Xcode reformats the string catalogs on every build (~200k-line diff of pure
churn); discard that before committing, but never blindly discard a diff that carries real
translations you just added.

⚠️ **New user-facing text needs `de` + `es` + `fr`, not just English.** `Tools/i18n_audit.py` (rewritten
upstream in `9.0.1`) gates on all three as a *standing invariant* — every catalog key, everywhere, not
just new ones — and only recognises a string as translatable when it's a **literal** argument directly
at a `Text(...)` / `.navigationTitle(...)` / similar call site. Route it through a `title: String`
helper parameter first and the audit can't see it at all, which is exactly how 27 coach strings
shipped English-only for months before `9.0.1` closed the fork-wide backlog. Prefer a few repeated
literal call sites over a DRY-but-invisible-to-the-scanner helper.

Good first contributions:

- **Streaming + tool-calling for OpenAI/Gemini.** Only Anthropic has a `ToolCallingClient` today —
  everyone else falls back to the pre-baked-context path.
- **A first-class OpenRouter provider** with a searchable model picker (its catalogue is 300+ models;
  a flat `Picker` doesn't scale) and per-model tool-capability gating, replacing today's
  point-Custom-at-it workaround.
- **A token-budgeted history window**, replacing the flat 10-message cap.
