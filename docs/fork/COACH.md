# The Coach — in full

Everything NOOP AI adds on top of [ryanbr/noop](https://github.com/ryanbr/noop) lives here. The
[README](../../README.md) has the friendly tour; this is the technical one.

**Design rule for every line of it:** additive, in its own file, never a rewrite of upstream logic.
That's what keeps `git merge upstream/main` a non-event (upstream `9.0.0` and `9.0.1` both merged
with zero conflicts touching a single file under `Strand/AI/`).

---

## 1. Architecture

```
Strand/AI/
├── AICoach.swift              The engine: state, context building, send/stream, tool loop
├── AIProvider.swift           Provider enum: endpoints, models, cheap models, client factory
├── CoachIdentity.swift        Who the coach is: name, avatar (symbol or photo), voice — Svea/Marv
│                                presets or fully custom
├── CoachPersona.swift         Guardian / Friend / Commander — coaching STYLE only; the name lives
│                                in CoachIdentity now
├── CoachTools.swift           The 30 tools: schemas + dispatch
├── CoachDataCatalog.swift     Metadata-only local metric discovery + safe source labels
├── CoachLocalContextPlanner.swift  On-device, question-specific context-category selection for tool-less providers
├── CoachMetricHistory.swift   Bounded local long-range trend aggregation + source selection
├── CoachTrainingPreferences.swift  Conservative repeated plan-decision patterns
├── CoachMemory.swift          Long-term memory: facts, categories, ranking, dedup
├── CoachTranscriptStore.swift Conversations: model + JSON persistence
├── MemoryMaintainer.swift     Cheap-model summarisation + fact distillation
├── CoachChart.swift           In-chat chart artifacts
├── CoachStreaming.swift       SSE streaming
├── CoachGoal.swift            The structured goal: kind, target, date, status, history
├── GoalSafetyGate.swift       Pace check — warn, require a reason, never block
├── GoalFeasibility.swift      "Is this realistic?" — evidence-based, from VO₂max, not a guess
├── CoachPlanStore.swift       The plan book: propose → accept/decline/swap, one active week
├── PlanWorkoutMatcher.swift   Deterministic planned-vs-actual reconciliation + legacy goal attribution
├── PlanConsequence.swift      What a session or a swap actually costs, from your own history
├── CoachNotifier.swift        Bridges ProactiveSignal + PlanProposal into the bell (§11a) — never a
│                                CoachTool, always additive to the existing chat-nudge path
├── JourneyMilestones.swift    Non-performance milestones — facts, never a streak counter
├── GoalTrackingEngine.swift   Shared result trend, goal-week series, risk state, next action
├── GoalActions.swift          Reusable daily actions, automatic completion + multi-goal attribution
├── CoachGoalSetupProposal.swift Review-only goal/routine bundles + their validated apply boundary
├── CoachGoalSetupTool.swift   Parses Coach drafts and resolves consented local baselines
├── CoachUsageLog.swift        Per-turn token accounting (all providers): cache hit/write/miss
├── CoachHistoryBudget.swift  Per-model token budget for the history window
└── Providers/
    ├── Anthropic.swift             Base client (upstream file — kept untouched, see §9)
    ├── AnthropicTools.swift        Tool-use loop
    ├── AnthropicStreaming.swift    Token-by-token SSE
    ├── AnthropicCaching.swift      Prompt-cache breakpoint + usage parsing
    ├── OpenAI/OpenRouter/Custom/Gemini.swift   The other base clients
    ├── OpenAICompatibleTools.swift             Tool loop for OpenAI + OpenRouter
    ├── OpenAICompatibleStreaming.swift         SSE for OpenAI + OpenRouter + Custom
    ├── GeminiTools.swift                       Gemini function calling + streaming
    └── CoachOutputBudget.swift                 Output ceiling, OpenAI-shaped providers

Strand/Screens/
├── CoachView.swift              The messenger chat + the shared `coachCover` presenter
├── CoachSettingsView.swift      A hub (status pill + 5 rows) into grouped subpages
├── CoachAvatarView.swift        Renders the current identity's avatar at any size — chat header,
│                                  beside each reply, the Today entry
├── CoachIdentityEditor.swift    Name field, Svea/Marv presets, symbol grid, photo picker, voice picker
├── CoachGoalView.swift          The one-page quick goal editor (`CoachGoalEditorView`)
├── CoachGoalOnboardingFlow.swift Guided, step-by-step goal onboarding — sits alongside the quick editor
├── CoachGoalJourneyView.swift   Goal + Journey UI, extracted so it's reachable from Coach settings
│                                  AND as its own top-level "Goal & Journey" destination
├── CoachGoalSetupReviewView.swift Combined edit/select/confirm UI for Coach-authored setup drafts
├── CoachPlanView.swift          The plan book: accept, schedule, swap-with-consequence, one-tap skip
├── JourneyView.swift            Progress, milestones, plan history — no invented percentages
├── CoachHistoryView.swift       Conversation list: switch / rename / delete / archive — stale,
│                                  never-replied-to threads get their own Archived section
└── CoachEntry.swift             Entry mode + the draggable floating button
```

`AICoachEngine` is a `@MainActor ObservableObject`, constructed once in `AppModel` and injected via
`.environmentObject(model.coach)`. It owns the conversation list, the active conversation, streaming
state, and every setting.

### The request path

```
user types
   ↓
systemPrompt          identity preamble + persona preamble + methodology + PINNED facts + goal
   ↓
context               tool-mode note  ─OR─  a local context plan when a provider has no tools:
                        • compact biometric snapshot by default; detailed recent days only for a related question
                        • only the relevant granted purposes (training, planning, stress, patterns, memory)
                        • aggregate-only deep-history evidence when the user explicitly requests it
                      buildFullContext() is reserved for deliberate app-generated prompts and still honours every grant:
                        • clock (date/weekday/time-of-day, days since last workout)
                        • 14-day metric table + 30-day averages     (buildContext)
                        • recent workouts
                        • Readiness verdict — ACWR, Foster monotony, contributing signals
                        • Charge confidence (never states progress off a still-calibrating score)
                        • active plan + adherence (what was agreed vs. what happened, and why)
                        • today's stress index
                        • personal patterns (Lab Book only with the separate Logs grant)
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
- **The history window is a per-model TOKEN BUDGET** (`CoachHistoryBudget`), not the flat
  `maxHistoryMessages = 10` it used to be — one number can't serve both a 2 048-token local Ollama
  model and a 200 000-token Claude. The old count survives as a FLOOR, so no provider gets less
  context than before, and an unknown Custom/OpenRouter model id stays conservative: guessing large
  risks a hard context overflow, guessing small only costs scrollback. (Android still uses the flat
  count; the floor keeps the two agreeing on the small-model case.)
- **Readiness and Charge drivers are read from the SAME engines Today uses**
  (`ReadinessEngine.evaluate`, `ChargeDrivers.chargeDrivers`) — never re-derived or eyeballed by the
  model. The coach cannot contradict what the Today screen already told you.

---

## 2. The 30 tools

Declared in `CoachTools.swift` as `CoachTool`, offered to the model as JSON Schema, dispatched in
`runCoachTool(_:input:)`. **All of them are gated behind `dataConsent`** — without it the dispatcher
returns a polite "no data access" string and the model coaches generally. Underneath that master switch,
each tool ALSO belongs to one of nine `CoachPurpose` groups (`ToolConsent.swift`) — core biometrics,
long-term history, workouts, planning, stress, logging, sensitive logs, memory, patterns — that the user grants independently in Settings →
Privacy & data → Data access. A tool whose purpose isn't granted is left out of the list offered to the
model entirely (`coachTools`), with a defensive re-check in `runCoachTool` for a stale in-flight round.
`get_personal_patterns` and `get_training_preferences` share the `patterns` group, which doubles as the
pre-existing *second* opt-in (`includeOnDeviceSignals` is now a computed passthrough onto it). Lab Book
values remain separately protected by the `logs` group even though their chart projection technically
lives beside ordinary metrics.

Tool-calling engages for every provider that conforms to `ToolCallingClient` — Anthropic, OpenAI,
OpenRouter (per selected model, gated on `supported_parameters`) and Gemini. **Custom is the only one
left out, deliberately**: tool support on a local server depends on both the server and the model, and
many local models fail silently or return malformed JSON instead of a clean error. That path still
falls back to the pre-baked context, which is why Readiness, Charge drivers, the active plan and its
adherence are *also* folded into `buildFullContext()` directly — it sees the same verdicts, just
pre-baked instead of fetched on demand.

The tool path additionally carries the **clock** and a **titles-only index of recent threads**
(`toolModeContext`). Without them the model had no date to resolve "yesterday" against and no reason
to believe past conversations existed — which is what made *"what did I ask you yesterday?"*
unanswerable. Neither belongs in the system prompt: that block carries Anthropic's `cache_control`
breakpoint, and a per-request clock would invalidate the prefix cache every turn.

### Read

| Tool | Params | Returns |
|---|---|---|
| `get_data_catalog` | optional `query` | Metadata-only inventory of locally available metric keys, sources and coverage, plus only the separately granted high-level stores (workouts, plan, logs, memory). When given a topic, the app uses a transparent local alias/keyword match before returning metric metadata, so unrelated entries stay on-device. It contains no readings, log text, device IDs or import identifiers. Omit the query only to route a genuinely broad deep-history question. |
| `get_biometric_summary` | — | 14-day table + 30-day averages: charge, effort, rest, HRV, RHR, SpO₂, respiration, skin-temp deviation, steps, energy |
| `get_recent_workouts` | `limit` 1–30 | Sport, duration, effort, avg HR, energy, distance |
| `get_stress_index` | — | Today's Baevsky Stress Index over today's R-R |
| `get_energy_balance` | — | Today's expenditure with source, coverage, model uncertainty and any applied Apple Watch calibration factor. It reports measured and modelled portions honestly, never sums overlapping sources, and — when enough imported intake/weight history exists — adds a clearly separate retrospective expenditure range. Never infers food intake or diet advice from either figure. |
| `get_sleep_detail` | `nights` 1–14 | Bed/wake, efficiency, deep/REM/light minutes, disturbances + the rolling 14-night sleep-debt ledger |
| `get_range_report` | `days` 7–365 | Per-metric averages, trends, headline changes |
| `get_metric_history` | `metric`, `days` 7–3,650, optional named `source` | One compact long-range aggregate, directional trend and bounded monthly/quarterly timeline. Without a named source, the app builds a local per-day timeline: compatible Apple Health history fills the period before or between WHOOP data, while the metric-specific source priority resolves overlaps. The result names every contributing source and never exports readings. Numeric analysis and each timeline group need at least three observations; no min/max values leave the device. |
| `get_training_preferences` | `days` 28–3650 | Conservative hypotheses from repeated accepted, declined or skipped training proposals and explicit post-completion effect feedback. Automatic context compares 28-, 90-, 365-day and all-available windows. It never changes a plan. |
| `get_readiness` | — | The SAME verdict Today shows (primed/balanced/strained/rundown/insufficient), acute:chronic workload ratio (Gabbett), Foster training monotony, and the contributing signals in plain English. Carries a HEALTH SIGNAL / SAFETY note when relevant — the model is told not to suggest more load regardless of the readiness level when it's present. |
| `get_charge_drivers` | — | *Why* today's Charge is what it is: each contributing term (HRV, resting HR, respiration, skin temperature) with its signed point contribution, your value, your baseline, and a plain-English read. Answers the single most common coaching question without the model inventing a reason. |
| `get_session_outlook` | `sport`, optional `swap_from` | What a session costs *this user*, from their own history: typical next-morning Charge cost, bounce-back days, tomorrow's projection. Pass `swap_from` to compare two activities side by side. |
| `simulate_day` | `effort`, `sleep_hours` | Projects tomorrow-morning Charge for a hypothetical ("hard session + 7h sleep tonight → how do I look tomorrow?"). Returns nothing rather than a guess when there's too little history to project honestly. |
| `get_plan_adherence` | `days` | What was agreed vs. what actually happened, including *why* a session was skipped when the user told the coach. Days still calibrating carry no verdict at all — never treated as adherence data. |
| `get_personal_patterns` | — | Top n-of-1 correlations (`EffectRanker`, significant only) + Lab Book roll-up. **Second opt-in required** (`includeOnDeviceSignals`) |
| `get_my_logs` | `kind` (caffeine/journal/lab/hydration/mood), `days` 1–90 | Reads back what the user LOGGED, so "is my coffee hurting my sleep?" is answered from their real entries rather than a guess. The write tools below are how these get there. |
| `get_sensitive_logs` | `days` 1–90 | Reads only locally flagged sexual, relationship, illness or cannabis journal fields after a separate sensitive-logs grant. It is offered only for an explicit related question. |
| `get_zone_minutes` | `days` | Minutes per HR zone, so a prescribed intensity can be checked against what was actually hit instead of assumed from a "done" status. The reply STATES the user's band boundaries in both % and bpm — "Zone 2" stops being a shared constant once the wearer can move it |
| `estimate_session_effort` | `zone` 1–5, `duration_min` | What a PLANNED session is worth in Effort, computed from the user's own bands and recent resting HR. Effort follows from intensity × duration; the model must not state a figure it invented (see below) |
| `search_past_conversations` | `query`, `on_days_ago`, `since_days` — **all optional** | Past chats as dated snippets **quoting the user's own questions**. Either axis works alone: a purely temporal question ("what did I ask you yesterday?") carries no keywords, so requiring `query` made it structurally unanswerable. Filtering is per MESSAGE date, so a thread reopened today doesn't hide what was asked in it yesterday. |

### Propose (never commits anything by itself)

| Tool | Params | Effect |
|---|---|---|
| `propose_plan` | `day`, `sport`, `intent`, `rationale`, optional `zone`, `duration_min`, `target_effort`, `goal_ids` (legacy `goal_id`) | Creates a `PlanProposal` in status `.proposed`. Every ID must be an exact active-goal UUID supplied in context; invalid IDs are rejected, one unambiguous active goal is linked automatically, and otherwise the session stays General. The accept sheet still asks the user to confirm the multi-selection. **Not a schedule** — the user must accept, decline, reschedule or swap it in the app. The model is told to never describe a proposal as settled. With `zone` + `duration_min` the app **computes** `target_effort` and overrides an unreachable one (see below). |
| `propose_goal_setup` | optional `goal`, up to five `routines`, `rationale` | Stores a review-only create/update bundle. Exact IDs are required for edits; one routine may link to several goals. `use_current_baseline` resolves a consented local measurement and labels its source. Goal/action stores remain untouched until the user edits the bundle, selects individual routines and confirms it in Coach or Goal & Journey. Nutrition, medication, dosage and treatment routines are rejected. |

### Write

Real mutations to real app data — the same stores the UI writes.

| Tool | Params | Effect |
|---|---|---|
| `log_caffeine` | `mg`, `minutes_ago` | Entry in the Caffeine log |
| `log_journal` | `behavior`, `answered_yes` \| `value`, `day` | Journal behaviour entry |
| `log_lab_marker` | `marker`, `value`, `unit`, `day` | Lab Book marker |
| `log_weight` | `weight_kg`, `day` | A dated entry in the canonical weigh-in history (v43 `bodyWeightEntry`), feeding the smoothed trend, weight goals and Apple Health write-back. |

### Memory

| Tool | Params | Effect |
|---|---|---|
| `remember_fact` | `fact`, `category`, `importance`, `confirmed_by_user`, `valid_until` | Saves a durable fact (near-dup aware). Reports back when the fact landed **unconfirmed**, so the coach knows to ask |
| `update_fact` | `old`, `new` | Rewrites a fact in place; names near misses when nothing matched |
| `forget_fact` | `fact` | Deletes a fact; names near misses when nothing matched |

### Visual

| Tool | Params | Effect |
|---|---|---|
| `plot_metric` | `metric` (charge/effort/hrv/rhr/sleep), `days` 7–180 | Renders a `StrandDesign.TrendChart` inline in the transcript; the snapshot persists with the conversation |

---

## 3. Coach identity

WHO the coach is and HOW it talks are two independent axes, both editable in Settings → Coaching.

- **Identity** (`CoachIdentity.swift`) — a name, an avatar, and a voice. Two presets: **Svea** (warm
  voice) and **Marv** (grounded voice), each with its own name and curated avatar symbol — or fully
  custom: any name, a symbol picked from a curated design-system-safe set, or your own photo via
  `PhotosPicker`. A photo is stored in Application Support and never leaves the device. Back-compat
  `Codable` decode means an install from before this existed just loads as `.svea`.
- **Style** (`CoachPersona.swift`) — Guardian (calm, protective), Friend (warm), Commander (direct).
  Unchanged from before identity existed, except the persona preambles no longer claim a name
  themselves ("You are Guardian…") — the name now comes from identity, so the two never fight over
  who the coach is.
- **Assembly**: `systemPrompt` leads with the identity preamble ("You are {name}, the user's
  coach. {voice nuance}"), then the persona's style preamble, then methodology/facts/goal — see
  "The request path" above.
- **`CoachAvatarView.swift`** is the single render path for the avatar — a tinted-disc symbol or the
  clipped photo — used everywhere it shows: the chat header, beside every run of coach replies in
  the messenger-style chat, and, optionally, on the Today entry card (its own toggle, independent of
  whether the Today entry itself is shown at all).

---

## 4. Goals & the two safety gates

`CoachGoal` (`CoachGoal.swift`) supports a small, bounded portfolio of **up to five active goals, with
at most one active goal of each kind**: `kind`
(`run` / `consistency` / `sleep` / `strength` / `weight` / `custom`), a baseline, a target, a unit, an
optional target date, a status (`active`/`paused`/`achieved`/`abandoned`/`archived`), local-only
motivation text, and a history of adjustments. Setting one is entirely optional — NOOP works fully
without a goal. First-run onboarding uses a guided, step-by-step flow
(`CoachGoalOnboardingFlow.swift` — what → details → why → confirm), offered once and skippable,
that never nags twice; the one-page quick editor (`CoachGoalEditorView`, in `CoachGoalView.swift`)
stays reachable any time via the goal bar for anyone who'd rather fill it in all at once. Both save
through the same `CoachGoalStore.commit(_:startsFresh:...)`, so neither path can diverge from the
other on what actually gets persisted. A re-startable "Set up with a few questions" entry also
appears in Goal & Journey (see §6) whenever there's no active goal.

Goals can be paused and resumed with a structured reason. Pause intervals survive a resume so past goal
weeks remain machine-readable; achieving or setting aside a paused goal closes the open interval. A
pause freezes monitoring but deliberately does not rewrite calendar commitments. New closures also keep
a structured date/reason while legacy goals continue to decode with empty pause/closure fields.

The Coach may prepare a new goal or changes to an existing goal together with up to five routines via
`propose_goal_setup`, but this is deliberately a proposal inbox, not a write shortcut. A pending dot and
chat action open one combined review where the user can change every value, omit the goal, and select
routines individually. The shared `CoachGoalSetupApplier` validates stale update IDs, active-goal limits,
multi-goal links and replacements before mutating either store, then records the proposal decision. A
locally measured baseline is included only when the relevant data-purpose consent is enabled and is
shown with its source in the review.

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

## 5. The plan book

`CoachPlanStore.swift` is the participatory core: the model can *suggest*, the person *decides*.

```swift
enum Status { case proposed, accepted, declined, modifiedByUser, completed, skipped, paused, rescheduled }
```

`propose_plan` is the **only** model-reachable entry point, and it force-resets status to
`.proposed` no matter what — there is no tool that accepts, schedules, or commits a plan on the
model's behalf. Turning a proposal into a `ScheduledSession` (day **and time** — "10:00 CrossFit", not
just "CrossFit sometime") is a UI action the person takes in `CoachPlanView`. **Accept opens the time
sheet** rather than committing untimed: `accept(_:at:)` always took a time, but the button didn't pass
one, so agreeing and saying *when* were two steps and the second was easy never to take — leaving
commitments no reminder can fire for. "Accept without a time" remains the escape hatch.

### Effort is computed, not chosen

`target_effort` used to be a free number the model wrote down. It offered a user "a 15-effort,
20-minute Zone 2 cycle" — not merely optimistic but arithmetically unreachable, since on that profile
the session is worth about 30. The model had no way to know: NOOP's display zones are %HRmax while
Effort uses Edwards' %HRR with its own fixed thresholds (see `docs/ANALYTICS.md`, "Two zone models"),
and nothing bridged them.

Now, whenever `propose_plan` receives `zone` **and** `duration_min`, `EffortFeasibility` evaluates the
shipped Effort maths at that intensity — against the wearer's OWN bands and recent resting HR — and:

- a supplied figure within `targetTolerance` (5 points) of the computed one survives, because leaning
  easy inside a band is a coach's judgement, not an error;
- anything further is **replaced**, and the tool reply names the old value, the new one and the
  arithmetic, so the model corrects its prose in the same turn;
- with no figure supplied, one is computed rather than left blank.

Without both parameters nothing changes — rest days, mobility and non-tool providers are unaffected.
`estimate_session_effort` lets the model check before it writes prose, and the system prompt forbids
stating an Effort figure for a suggested session without one of these two paths.

### The brief waits for a night the data supports

A user reported the automatic wake time landing "far far earlier" than they woke, recovery reading
wrong, and the coach planning on it anyway. The cause is offload lag, not staging: `detectSleep` runs
over the raw streams that exist, so a strap synced only to 04:00 produces a night that ends at 04:00.

`SleepWindowSettledness` judges last night from the session end, the raw-data coverage edge, the clock
and the learned habitual wake:

- **`awaitingSync`** — the data stops within 2 min of the "wake" and has done for 45 min. Objectively
  truncated, so `startBriefIfNeeded` **withholds** the brief and does **not** stamp the day; it runs
  for real once the data lands. Bounded three ways so the coach can't go quiet indefinitely: the user
  can vouch for the time on the morning card, a ~3 h deadline lets it through, and the card offers a
  one-tap route to the Sleep editor.
- **`wakeLooksEarly`** — readings continue an hour past the wake, or it sits 90 min before the habit.
  A suspicion, not a proof, so the brief runs and leads with the doubt.

Either way the caveat rides on `chargeConfidenceBlock()`, so it reaches every path that quotes a
Charge — not just the brief. And because correcting the sleep by hand used to leave the wrong brief
standing all day, the Sleep screen's edit / delete / add-nap paths now clear the day-stamp via
`CoachBriefStamp`, which also raises the "stale" mark that lets the re-run bypass the
already-has-today's-messages gate.

When several goals are active, the time sheet asks which concrete goals the commitment serves, or
whether it is **General**. The user confirms a multi-selection; conservative local suggestions only
preselect likely goals. A walk can therefore support movement, weight and wellbeing while remaining one
stored activity. Only explicitly linked goals count it, so it never leaks into every goal merely because
their date ranges overlap.
Installations from before goal links are migrated once and conservatively: an old completed session is
linked only when exactly one goal lifetime contains it. Ambiguous history remains General.

### Closing the loop — planned vs. actual

`PlanWorkoutMatcher.swift` reconciles accepted/modified/rescheduled commitments against the canonical,
cross-source-deduplicated workout feed after imports, app activation, and when Plan or Journey opens.
It is deterministic Swift, not a model judgment:

- an untimed commitment matches only the same local day; a timed one uses a ±4-hour window;
- known sport families (run, ride, strength, swim, and so on) must agree for automatic completion;
- generic imports such as “Workout” may be suggested for confirmation but are never automatic;
- one unique strong candidate completes the commitment and stores immutable workout evidence;
- several candidates, cross-plan conflicts, or weak labels ask the person to confirm the link;
- an old commitment with no candidate stays neutrally **open**. It is never silently marked skipped.

Rejected candidates are remembered so they are not asked about again. The evidence snapshot records the
workout key, timing, sport/source, duration, effort, distance, match method, and match time. Plan and
Today show unresolved questions; the bell mirrors them without re-arming a row on every foreground pass.
An automatic match posts a short informational receipt so background completion is quiet, not invisible.

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
happened and why". The **everyday** reasons (`noTime` / `tired` / `notFeelingIt`) used to be recorded
and then read by nobody, so the coach kept proposing into the same wall; `skipPatternLine` now states
a dominant one as a fact in the plan context. It explicitly instructs the model to *ask what would
actually fit* and **not** to stop suggesting that kind of session — that would be the filter bubble
`declineStreakFloor` exists to prevent. A **decline-streak floor** (`declineStreakFloor = 3`) stops the coach from
permanently going quiet on a sport after a few no's — it's offered again after a few days, not shelved
forever (no filter-bubble collapse).

---

## 6. The Journey page

`JourneyView.swift` + `JourneyMilestones.swift`, reachable from the goal card once a goal exists —
and now also from its own top-level **"Goal & Journey"** entry in More (`CoachGoalJourneyView.swift`
/ `CoachGoalJourneyScreen`), independent of whether a goal exists yet: with no goal, it shows the
guided-setup entry (§4) instead of the journey itself.

**A goal whose target date passes gets one look-back, once per goal ever**
(`ProactiveCoach.expiredGoalNeedingReview`, with a day of grace — a target date is a target, not a
stopwatch). Before this, a date simply went by and nothing was said, which reads as not having
noticed. The instruction forbids congratulating or commiserating on a number the coach hasn't
verified, and allows "can't be judged from the data" as an answer: a missed date can mean illness,
travel, or a target that was never realistic, and the app cannot tell which.

**No invented percentages.** Progress is only ever shown as a real measurement against the goal's
baseline and target. Without both, there is no percentage at all — the page falls back to what's
actually known: sessions completed, consistency, recovery trend. A goal that's five minutes old
correctly shows *nothing achieved yet*, and that's treated as a normal state, not an empty error.
Quantified goals that reach their measured target are presented as a closure candidate: the person can
mark the goal achieved or keep working. Measurement alone never changes goal status in the background.
Session totals count only completed proposals explicitly linked to that goal and on/after its start.

Reusable **daily actions** live beside the plan: steps, a workout family with an optional minimum
duration, or a manual check-off, scheduled daily or on selected weekdays. One action holds an ordered
set of goal IDs and is evaluated only once per day even when it supports several goals. Steps and
workouts complete from local data; manual actions require an explicit tap. If an imported workout was
neither a plan completion nor an automatic daily-action match, Today may quietly ask which suggested
goals it supported. That answer remains editable in Journey and is attribution evidence, not proof that
an outcome changed.

Milestones (`JourneyMilestones.achieved`) remain **facts, not a daily streak counter**: first week in, N
sessions completed, longest run, a stretch training pain-free, recovery trending up past a real
threshold (3.0 Charge points week-over-week, not week-to-week noise). Nothing here rewards a daily
habit loop or penalises a gap — deliberately, since a streak mechanic shames exactly the people who
get sick or travel, which is precisely when they need the app least judgmental.

`GoalTrackingEngine` adds a flexible execution series with two visible lanes: **plan commitments** and
**daily actions**. A completed local calendar week succeeds only when every non-empty lane reaches 80%
(rounded up: 1/1, 2/2, 3/3, 4/5). This prevents a pile of easy check-offs from hiding missed plan work,
or one hard session from hiding an abandoned daily routine. Weeks intersecting a goal pause or containing
a linked illness/pain/travel skip are protected;
weeks with no commitments are neutral. Neither extends nor breaks the series. An unresolved past
commitment asks for a decision before the week is judged, and the live week never changes the series
until it ends.

Execution and outcome are deliberately separate. A completed walk can improve the execution lane for
every goal it was linked to, but it cannot manufacture weight loss, mood improvement, distance or another
result. Quantified outcome progress still comes only from the corresponding measurement and target trend.

The same pure snapshot drives every surface: measured progress, target-date trend, current-week
planned/completed counts, current/best series, and one ordered state (`decision needed` → `at risk` →
`attention` → `on track` → `building evidence` → `paused`). At-risk requires either a measurable
behind-trend or two evaluated weak weeks; an unmeasurable goal is never called risky merely for lacking
data. Goal & Journey is the portfolio dashboard, sorted by that need before deadline, with an expandable
past-goals history. Journey shows the same snapshot plus six goal weeks and the supporting activities.
Today has a dedicated reorderable/hideable **Goals** section (alongside Coach), showing the highest-priority
goal, separate plan/action counts, current series, up to three due actions and at most one quiet attribution
question. The bell mirrors only decision-needed/at-risk states without re-arming read
rows. The coach receives these as deterministic facts and is instructed not to invent another series or
risk label.

---

## 7. Memory

`CoachMemory` is a `@MainActor` singleton, JSON in `UserDefaults`, capped at **120 facts**.

### Storage size and bounds

Canonical coach memory uses ordinary local JSON. The Memory settings card measures that source
material's current serialised footprint on-device: drive icon = conversation + fact bytes, speech
bubbles = conversation count, brain = fact count. It does **not** count the main health database,
sensor streams, attachments, provider traffic or the separately displayed rebuildable semantic index.

- Facts: maximum **120** entries; normal use is still small because each is short text plus metadata.
- Normal conversation history: up to **50** conversations, with the newest **200** messages retained in
  each. A pinned conversation is deliberately exempt from the 50-thread count cap, so there is no false
  promise of a global byte ceiling when someone explicitly pins many long chats.
- On iOS, approved text can additionally have a derived Float16 vector in
  `coach-semantic.sqlite`. Original text is not duplicated there; the index has its own visible size,
  progress and deletion controls and can always be rebuilt from canonical sources.

The visible byte counter is therefore the authoritative answer for a particular device and history; the
limits describe normal retention, not a fabricated fixed MB claim.

### The fact model

```swift
struct MemoryFact {
    let id: UUID
    var text: String
    var category: Category         // goal | injury | preference | physiology | schedule | other
    var importance: Importance     // pinned | normal
    var createdAt: Date
    var verification: Verification // hypothesis | pendingConfirmation | confirmed
    var sensitivity: Sensitivity   // ordinary | health
    var source: Source             // user | coachTool | conversationSummary | legacy
    var validFrom: Date
    var validUntil: Date?          // nil = open-ended
    var evidenceCount: Int
    var evidence: [Evidence]       // per observation: source, reference, when
    var revisions: [Revision]      // previous wordings, capped at 20
}
```

Decoding is back-compatible throughout: a fact saved before categories existed decodes as
`.other` / `.normal`, one saved before provenance existed decodes as `.legacy` / `.confirmed`, and a
missing `validUntil` simply means the fact doesn't expire. An upgrade never drops your memory.

### The confirmation lifecycle

This is the part that decides whether a fact ever reaches the model at all.

- A fact in a health-adjacent category — `injury`, `physiology`, `goal` — is saved
  **`pendingConfirmation`**; the rest start as a `hypothesis`.
- **`pinnedBlock` admits only `confirmed` facts**, so an unconfirmed injury does *not* frame every
  reply no matter how it was pinned. It can still surface through `relevantBlock`, flagged as
  unconfirmed, which is what tells the coach to ask rather than assume.
- Three things confirm a fact: the user saying so in the chat (`remember_fact` with
  `confirmed_by_user`, which also promotes a fact the coach already holds), the receipt under the
  reply that saved it, and the Memory list in settings. Adding a fact by hand is confirmed on the
  spot — the user typed it.
- `validUntil` retires a fact on its own. `remember_fact` takes a `valid_until` day for anything
  temporary; the settings list can set or clear one. An expired fact leaves every retrieval path,
  stays visible under **Expired**, and is the first thing evicted at the cap.

### Retrieval — the interesting part

Dumping 120 facts into every prompt is the naive approach: expensive, unfocused, and it crowds small
context windows. Instead:

- **`pinnedBlock`** — every `.pinned`, `.confirmed`, in-force fact. Goes in the *system prompt* only
  while Data access and the separate Memory purpose are enabled. This is for things that must frame
  every reply: a serious injury, a hard constraint. (The training goal has its own structured model
  and is injected separately by `goalBlock`.)
- **`relevantBlock(for:limit:alreadyInContext:)`** — ranks the remaining facts against the **current
  question** and takes the top few (default 8, minus whatever pinned already took). Goes into the
  *turn's context*.

The ranking is deliberately deterministic and on-device — no embeddings, no extra API call:

```
overlap = |tokens(fact) ∩ tokens(question)|   // stopwords removed, ≥3 chars
score   = overlap · exp(-ln2 · ageDays / 30)  // a real 30-day half-life, not a tiebreak
```

Zero overlap scores zero **whatever** its age: decay discounts an already-relevant fact, it never
manufactures relevance. A zero-scoring fact stays local rather than riding along because it happened
to be recent. Boring, cheap, debuggable, and good enough: a question about sleep surfaces the sleep
facts.

`alreadyInContext` is the other half. The semantic index (§ below) holds the same facts as `[Memory]`
documents and runs on the same turn, so the block skips any fact whose text the context already
carries — otherwise one sentence goes on the wire twice.

### Writing — self-healing

- **`add`** does **near-duplicate detection**, not exact-string matching. Texts are normalised
  (lowercased, punctuation stripped, single-spaced) and treated as duplicates when equal, when one
  contains the other at a close enough length ratio, or when their meaningful words almost entirely
  overlap. The thresholds are **per category** (`thresholds(for:)`): `.injury` / `.goal` need
  near-medical precision (0.85 overlap, 0.80 containment, ≥5 tokens) because an ACL tear and a
  meniscus tear share a lot of vocabulary and are different facts; `.preference` / `.schedule` /
  `.other` collapse more readily (0.65 / 0.65 / ≥3), where losing a rephrasing costs nothing.
- A near-dup **supersedes** the old fact in place — same id, refreshed text and timestamp, one more
  observation — rather than stacking a rephrasing and burning a slot. It never *downgrades*: a
  restatement can't unpin a pinned fact, un-confirm a confirmed one, or clear an expiry it didn't
  mention.
- **`update` / `remove`** are exposed to the model as `update_fact` / `forget_fact`, so a correction
  rewrites the stale fact instead of coexisting with a contradiction. Both match at `.injury`'s
  strictest thresholds regardless of category — deleting the wrong memory is the costlier error — and
  when that finds nothing the tool result names the **near misses** so the coach can ask which was
  meant instead of giving up.
- Eviction at the 120 cap takes the oldest **expired** fact first. Otherwise non-pinned facts compete
  by verification (`hypothesis` before `pendingConfirmation` before `confirmed`), then by lower evidence
  count, then by age. The incoming fact competes under the same rules, so a weak new hypothesis is
  rejected instead of displacing stronger memory. A fully pinned store also rejects new writes rather
  than silently deleting an always-on constraint; the tool and manual-add UI tell the user to review it.

Everything is visible and editable in `CoachSettingsView`'s Memory subpage: grouped by what needs the
user first (awaiting confirmation, then always-on, then by category, then expired), with confirm, pin,
edit, expire, delete and add-by-hand. **Forget-all asks twice**: nothing here is recoverable — facts have
no archive as conversations do — so the first step asks and the second names what is actually at stake
(how many of them frame every reply: injuries and hard constraints the user would have to say again)
rather than posing the same question a second time. Each row discloses its provenance —
where the fact came from, when it was first saved, how many observations back it, what it used to say.
A hub badge marks the subpage when something is waiting to be confirmed.

Facts also leave a **receipt in the chat**: the reply that saved one carries its id, and the
transcript renders it under that reply with confirm / edit / forget. Remembering is never silent.

### Cross-conversation recall

`CoachConversation` carries an optional `summary` (plus `summarizedCount` for the cost gate). Two
paths get it back to the model:

1. **`search_past_conversations`** — deterministic keyword search over every stored conversation
   (title + summary + messages), returning the best 3 as titled, dated snippets. On demand only.
2. **`recentSummariesDigest()`** — one line per recent summarised chat, injected into
   `buildFullContext()`. Cheap, and it works on providers with no tool-calling.

### Daily briefs get their own thread

Each day's brief (`startBriefIfNeeded`) now opens its **own** conversation thread instead of
appending to whatever was active — see `startBriefThread()` in `AICoach.swift`. A day-boundary sweep
(`archiveStaleAutoThreads()`, run on launch and after every brief) then archives **auto-only**
threads — a brief or nudge the user never replied to (`CoachConversation.isAutoOnly`) — once their
day has passed, moving them into a new **Archived** section of `CoachHistoryView` rather than
deleting them. A thread the user actually took a turn in is never swept, and archiving is additive:
`archived: Bool` decodes `false` for any pre-existing conversation JSON. Manual archive/unarchive is
available too, via `setArchived(_:_:)`.

### Finding a thread again

Two searches, deliberately different:

- **`search_past_conversations`** (the model's) matches whole TOKENS — it searches by topic — and can
  also filter by time alone.
- **`CoachConversation.matches(search:)`** (the history field's) matches SUBSTRINGS, case- and
  diacritic-insensitively, because a person typing expects "schl" to find "Schlaf" mid-word and
  "grosse" to find "größe".

Threads can be **pinned** to the top, and a pinned thread is exempt from the 50-conversation cap
(`CoachConversationStore.applyCap`). That exemption is the point: the cap drops the *oldest* threads,
which is exactly what people pin — the plan they keep returning to. Pinning something and having the
app silently bin it later would defeat the feature. A conversation can also be shared as Markdown
(`markdownExport`), rendered from the model so the export can't disagree with what was stored.

---

## 7a. Two models, and only when asked

`CoachModelRole` is how the app has always chosen a model per kind of work — `chat` (strong),
`summary` and `cardAnalysis` (cheap). A fourth role, **`deepAnalysis`**, answers "can I get a more
thorough look at this one?" without inventing a second mechanism.

**Depth is a MODEL, not a "thinking" flag, and that is the whole design.** With free model choice —
OpenRouter fronts 300+ — a reasoning parameter is silently ignored by roughly half of them, so one
switch would deepen one model and do nothing for the next: behaviour nobody can explain to a user. A
second model always differs, on every provider, including those with no reasoning support at all.

Two things were considered and rejected:

- **Automatic escalation by question type** ("this looks like a trend analysis, use the big model").
  It multiplies cost invisibly, and the classification is unreliable — *"Wie war meine Woche?"* is five
  words and a trend analysis. A question answered quickly one day and slowly the next, with no visible
  reason, reads as broken rather than clever.
- **A per-message toggle in the composer**, which asks the user to predict how hard their own question
  is before they've seen an answer.

What ships instead: **"Look at this more closely"** on a reply the user has already read. There is no
built-in default model for the role on any provider — which model is worth its price is the user's
call — so unset means the action never appears at all. `deepTurn` is armed for one question and cleared
on completion, error, Stop and cancellation; a sticky depth mode is how a chat quietly becomes ten
times dearer. Every send path and the history budget read `requestModel`, so a deep model with a
different context window gets the matching window.

Its prerequisite shipped with it: `CoachUsageLog` now records the OpenAI-shaped providers too. Their
`prompt_tokens` *includes* cached tokens where Anthropic's `input_tokens` excludes them, so
`parseOpenAIUsage` subtracts — a `Round` means the same thing whatever produced it.

---

## 7b. When something goes wrong

Every network failure used to become `AICoachError.network(localizedDescription)` and land in the chat
as raw CFNetwork prose under a single Retry — including cases where retrying cannot possibly work.

`AICoachError.recovery` now decides what the error row offers, derived from the TYPED error rather than
its message (matching a localized sentence works in English and nowhere else):

| Failure | Offered |
|---|---|
| `badKey` (401/403) | **Enter your key again** → straight to Connection & model. Retrying a rejected key fails identically. |
| `rateLimited` (429) | **Retry in Ns**, counting down from the provider's own `Retry-After` (seconds *or* an HTTP date; a past date clamps rather than counting from negative). |
| `offline` | Its own case, with a message that also says the rest of NOOP keeps working — the coach is the only feature needing a connection. |
| `server(5xx)` | Retry — the provider's problem, usually transient. |
| `server(4xx)`, setup problems | Nothing. Offering a Retry that will fail the same way is a lie. |

**"Test connection"** (Connection & model) answers "did that work?" where the key is pasted rather than
at the user's first real question. It goes through the ORDINARY send path, not `/models`: a key can
list models and still be refused by the chat endpoint, and a model list says nothing about whether
*this* model is servable to this account. The verdict resets on any provider or model change.

---

## 8. Cheap-model maintenance

Summarising chats shouldn't cost coaching-model money. `AIProvider.cheapModel` picks a small model
per provider:

| Provider | Coaching default | Cheap model |
|---|---|---|
| Anthropic | `claude-sonnet-4-6` | `claude-haiku-4-5-20251001` |
| OpenAI | `gpt-4o-mini` | `gpt-4o-mini` |
| Gemini | `gemini-flash-latest` | `gemini-flash-lite-latest` |
| Custom | *(you pick)* | *(falls back to your model)* |

The engine exposes `memoryModel` (an optional Settings override) and `autoSummarize`. Automatic
summaries are **off by default**: ordinary coaching, structured facts and local recall do not require a
background model.

`MemoryMaintainer` fires on `switchTo` / `newConversation` — i.e. when you *leave* a chat — and only
when **all** of these hold:

- `dataConsent` and the separate Memory purpose are on (chat content leaves the device, so both gates apply)
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

Fact distillation deliberately favours precision over recall. Only explicit statements in the user's
new turns may become facts; coach text, tool output, previous summaries, prompt-like instructions,
transient measurements, hypotheticals and rejected/corrected claims are excluded. Facts stay atomic,
standalone and in the user's language, and one maintenance call is capped at three facts in both the
prompt and parser. The prior summary may update the thread-level `SUMMARY`, but it is never itself a
source of new facts.

---

## 9. Providers

| Provider | Chat | Streaming | Tool-calling | Prompt caching | Token counts |
|---|---|---|---|---|---|
| Anthropic | ✅ | ✅ SSE | ✅ | ✅ explicit breakpoint | ✅ |
| OpenAI | ✅ | ✅ SSE | ✅ | automatic (provider-side) | ✅ |
| OpenRouter | ✅ | ✅ SSE | ✅ per model | passthrough | ✅ |
| Gemini | ✅ | ✅ SSE | ✅ | — | — |
| Custom (OpenAI-compatible) | ✅ | ✅ SSE | **deliberately not** | — | ✅ |

**Custom streams but gets no tools, on purpose.** Streaming is where it benefits most — a local
server generating at a few tokens a second showed nothing at all until the whole reply was done — while
tool support there depends on both the server *and* the model, and many local models fail silently or
emit malformed JSON rather than a clean error. The two therefore live in separate protocols
(`OpenAICompatibleStreamingClient` vs `OpenAICompatibleToolClient`); binding them would have forced
tools on Custom just to get streaming.

**Gemini's schema is a subset.** `CoachTool.geminiSchema` strips every JSON-Schema keyword Gemini's
own `Schema` type doesn't model (`minimum`/`maximum` appear in several of ours). This is not tidiness:
an unsupported keyword rejects the **entire request**, so one stray bound costs all 30 tools at once
rather than degrading one. A test reduces every real schema and asserts nothing unsupported survives.

**Reasoning tokens are tracked, never rendered.** OpenRouter's `delta.reasoning` (and the
`reasoning_content` spelling some gateways use) is the model's scratch work; showing it as coaching
would be misleading. But a model that spends its whole output budget thinking and never reaches an
answer now says so, instead of an unexplained "(no reply)" for a request the user paid for.

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

## 10. The privacy model

The app is offline-first and stays that way; the coach is the *only* thing that ever opens a socket.

**Consent is a master switch plus purpose controls, all off by default:**

1. **`dataConsent`** — without it, no metrics are included in any request and every tool returns
   "no data access". If the separately enabled Coach is connected, it can still answer generally; it
   just doesn't know you.
2. **Purpose controls** — once the master switch is on, the user separately grants core biometrics,
   long-term history, workouts, planning, stress, logging, sensitive logs, memory and patterns. The
   normal interface starts with Essentials, Personal and Deep insights presets; Expert mode reveals the
   individual choices. Long-term history is
   off by default, including for a migrated legacy consent: a request for months or years is not part of
   normal day-to-day coaching. `includeOnDeviceSignals` remains the
   compatibility toggle for the patterns purpose, which includes n-of-1 signals and conservative
   training-decision patterns. Lab Book remains under the separate logs purpose.

**What is sent:** derived daily numbers (charge, HRV, RHR…), short summary lines, your saved facts,
your goal and plan state, and — under consent — past-conversation snippets for recall. A deep-history
request additionally needs the separate long-term-history grant and is first resolved locally: the provider
receives at most one selected source's aggregate, trend and bounded timeline. The optional catalog contains
only metric names, coverage and safe source labels.
Lab Book series are excluded from both routes unless the separate **logs** purpose is granted; their
database projection must never accidentally turn them into ordinary core biometrics.

For a provider without tools, the app does not use the former one-size-fits-all context. A transparent
on-device router first chooses relevant categories from the wording (for example, readiness and recent
workouts for a run question, but neither for an ordinary chat question). It starts with a compact
snapshot rather than the complete recent-day table and upgrades detail only for a recent metric/trend
question. A training question also asks for the conservative local training-preferences report when its
separate Patterns grant exists, so a recurring decline/skip can inform a proposal without changing it.
Each chosen category is then checked against its separate purpose grant; routing never grants
access on its own. The resulting assistant turn stores a small, on-device **data-access receipt** — only
category names such as “Readiness” or “Recent workouts”, never copied values — which the person can
expand below a tool-less reply even after reopening the chat.

Tool-capable providers follow the same local-first policy: `get_data_catalog` is only put on the wire
for an explicit inventory or long-history question, `get_metric_history` only for an explicit long-history
question, and `get_my_logs` only when the question names a non-sensitive log topic. `get_sensitive_logs`
additionally requires its own grant and an explicit related question. The local matcher also considers
the person's own configured journal labels (including a custom numeric field) for explicit retrospective
questions; those labels never enter provider context merely to make that decision. The external model
cannot call a tool it was not offered; the dispatcher also re-checks that per-turn allow-list before it
reads anything. Consent remains the first, separate gate.

### External architecture check

The design borrows the useful part of a local RAG workspace — local retrieval before model context —
without importing a general document-agent stack into a health app:

- [Apple's HealthKit privacy guidance](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)
  requires fine-grained user control and clear disclosure for sensitive health data. That is why a
  local routing match is never an authorisation: the per-purpose grant remains the hard gate.
- [AnythingLLM's self-hosted terms](https://github.com/Mintplex-Labs/anything-llm/blob/master/TERMS_SELF_HOSTED.md)
  demonstrate that an air-gapped local document workspace is feasible, but its product also has an
  optional telemetry feature. NOOP does not adopt that feature, any analytics, or a server component.
- [Apple Vision's text-recognition request](https://developer.apple.com/documentation/vision) is the
  platform facility used by the Lab Book photo path; the app performs the recognition locally and does
  not retain image/OCR text after review.

The iOS app adds a deliberately narrow local semantic layer on top of this architecture. Nomic Embed
Text v2 searches only approved text: remembered facts, the user's own chat turns, conversation titles
and summaries, journal questions/notes, recommendation feedback and explicitly labelled habit hypotheses. Raw
R-R/PPG/motion streams, numerical health histories, lab-value tables and provider replies are never
embedded. Structured health questions still use exact local aggregate queries.

The derived vectors live in a separate rebuildable `coach-semantic.sqlite`, not in the canonical health
database and not in `.noopbak`. It stores source ids, hashes, consent scopes and Float16 vectors, but no
duplicate original text. Consent is checked before search and again before context hand-off. Deleting a
source or withdrawing a scope removes its vectors; Settings also exposes delete and rebuild controls.
Semantic and keyword ranks are fused so names, dates and exact terms stay competitive.

Recommendation history keeps five outcomes distinct: declined, accepted but not completed, completed
and helpful, completed with no noticeable effect, and completed followed by feeling worse. An absent
effect answer remains missing. Habit hypotheses compare 28-, 90-, 365-day and all-available windows,
carry a sample-size-based personal uncertainty label, and never claim that an observational association
is causal. Stronger causal language requires a deliberate personal N-of-1 comparison.
The proposal boundary also applies feedback deterministically: repeated recent negative decisions add a
short re-pitch cooldown, repeated negative effect ratings stop another moderate/hard version until the
coach asks, weekend rejection changes the proposed timing/form, and a stable time among helpful
completions can prefill an otherwise untimed suggestion. Every resulting proposal still requires the
person's explicit acceptance.

Remembered preferences start as hypotheses. Injury/health facts, goals and other sensitive facts remain
pending until the person confirms them. Each fact carries validity dates, sensitivity, evidence count
and a bounded revision history; expired facts do not enter retrieval.

**What is never sent:** raw R-R streams, raw sensor buffers, raw PPG/IMU. The tool layer routes
through the same summarised reads the UI uses, so there's no path for raw egress even by accident.
The coach also **never plans nutrition** — there's no data to found that on, and a weight goal's
feasibility is always reported as `.unknown` rather than guessed.

**Lab-report import stays local and review-first.** A selected text PDF is read through PDFKit; a selected
photo is recognised with the platform's on-device OCR. The narrow parser considers only known marker
labels immediately next to a numeric value, then shows each candidate and its report date for the person
to confirm or deselect. It does not retain the file, OCR text, filename or path, does not extract a
reference range, does not infer an unknown marker, and does not make a clinical judgement. Only the
confirmed values become ordinary private Lab Book rows; the coach can see them later only through its
existing, consent-gated summaries.

**Retrieval is hybrid on iOS.** Durable facts and past conversations retain the deterministic keyword
ranker, while Nomic adds paraphrase/synonym retrieval over the same allowed textual sources. Deep metric
discovery continues to use the inspectable alias vocabulary (`weight`/`Gewicht`,
`ferritin`/`iron`/`Eisen`, `sleep`/`Schlaf`, …) and aggregate queries, never vectors over measurements.
macOS and Android retain keyword retrieval at this stage. Nomic improves finding context; it does not
replace consent, statistics, the provider's reasoning or the aggregate-only data boundary.

### iOS Nomic runtime

`nomic-embed-text-v2-moe` Q4_K_M and a pinned llama.cpp XCFramework are build inputs prepared by
`Tools/bootstrap-nomic.sh`. The script downloads the official release artifacts, verifies hard-coded
SHA-256 hashes, and leaves the model/runtime under `Vendor/Nomic/`; the large binary files are ignored by
Git. The finished iOS app embeds both and needs no model download at runtime.

The provider is not loaded during an ordinary fresh launch. Opening Coach starts an asynchronous warm-up
and indexes high-priority pending text first. A question waits at most 2.5 seconds for semantic retrieval;
keyword retrieval answers that turn if Nomic is still starting.

Within that budget the **question is embedded first** and the indexing backlog is worked afterwards, in
the background. The reverse order — draining up to 64 documents before looking at the question — lost the
race by construction on a cold model or with any backlog: the user paid the full 2.5 seconds and still got
the keyword fallback. Searching an index a few documents behind beats not searching at all.

The reconcile that precedes retrieval is **incremental**: canonical sources are rebuilt off the main
actor, and only documents whose text actually changed are enqueued, with the deletion scan run only when
the live document set changed. Document tokens for the keyword arm are cached beside the documents rather
than recomputed per question. This matters because the whole path sits between the user's tap and the
request going out. The model unloads after 120 seconds idle,
on memory or serious thermal pressure, when Coach is disabled, or when consent is withdrawn. A
best-effort `BGProcessingTask` handles remaining work near night-time while charging; iOS may decline or
delay it, so a 24-hour foreground catch-up and Coach-open indexing remain authoritative.

Memory settings shows the continuously updated indexed/pending counts and a percentage progress bar.
“Continue indexing” explicitly drains the current queue in small cancellable foreground batches;
“Stop indexing” leaves every committed row valid and the remainder pending. “Rebuild index” clears only
the derived vectors, requeues the currently allowed canonical text and starts the same manual worker.

The Expert memory card can run a fixed on-device retrieval check against the actual bundled model. Its
German corpus covers paraphrases, synonyms, negation and ambiguous health wording, compares recall with
the keyword baseline, and separately verifies that exact-name queries remain correct.

The same card reports **how often the semantic arm actually wins its own race**, for this session:
how many turns retrieved semantically against how many fell back to keywords, the p50/p95 of the
query embedding, and how long the model's cold load took. A lost race costs the whole semantic arm for
that turn — a far larger loss than any ranking detail — and `lastRetrievalMode` only ever showed the
most recent turn, so the rate had no answer on any device, least of all for the first question of a
session, which pays the cold load inside the same budget. The counters live in memory for the life of
the process (`CoachSemanticTelemetry`): never written to disk, never in `.noopbak`, never sent anywhere.
They measure; they change nothing about what is retrieved.

### Measuring retrieval off-device

[`Tools/MemoryBench`](../../Tools/MemoryBench/README.md) is the instrument any change to this ranking
has to be argued with. It runs in two stages, because the embedder is iOS-only and because a model
comparison is only fair when the selection is identical: `embed` drives the pinned llama.cpp's own
`llama-embedding` once per model, applying that model's own contract (prefix or instruction, pooling,
attention) and then the app's own truncate-renormalise-Float16 path; `score` is deterministic and
model-free, replaying the real `SemanticIndexStore`, the real Float16 encoding, the real cosine scan
and the real `SemanticRanking.fuse` — the baseline calls the shipped code rather than re-describing it.

Its corpus is synthetic and committed (248 documents / 242 queries across all ten shipped locales); no
wearer's health data is involved and no NOOP database is opened. Four query categories are scored
separately, because a change that wins one and loses another is not an improvement and one average
hides the trade: `paraphrase`, `exact` (a name, date, number — what the two rescue slots were kept
for), `temporal` (two documents contradict and the newer one is right) and `irrelevant`, where the
target is **zero** emitted lines. That last category and the report's floor-calibration section are
what the existing measurement could not express: every target in it was reachable semantically, so
nothing measured what the retrieval does when the honest answer is nothing.

For a provider without tool calling (for example a local OpenAI-compatible server), a second conservative
router covers the obvious deep-history case. It activates only when the user's own question explicitly
asks for a long trend (such as weight over three years), selects one named metric locally and appends the
same aggregate-only evidence that `get_metric_history` would return. If the metric is not one of the
small built-in aliases, it can match an explicit locally stored key such as `vitamin_d` — still without
emitting the catalog. It never runs for an ordinary coaching question and never sends an inventory or raw
series to compensate for missing tool support.

**Where it goes:** only to the provider *you* chose, with *your* key, when *you* send a message.
There is no NOOP server. There is no account. Local provider ⇒ zero egress.

Everything stored — memory, conversations, goal, plan, chart snapshots — is on-device
(`UserDefaults` / Application Support JSON), capped, and never synced.

---

## 11. Entry points

| Route | Where |
|---|---|
| **Banner** | "Ask your Coach" — a reorderable `TodaySection.coach` card on both Today screens (classic's `CoachTodayRow`; Liquid's own banner, styled in its own chrome), movable via the same **Customize Today** sheet as every other section — it is an ordinary Shown/Hidden row there, draggable to any position |
| **Header icon** | Liquid Today only — a compact avatar/sparkle button in the header's icon cluster |
| **Floating button** | Draggable, pinnable to any of 4 chrome-clear corners, lockable |
| **More tab** | **AI Coach** opens Coach settings even while the feature is off; active Coach deep links use `MoreDestination.coach` |
| **Goal & Journey** | Its own `MoreDestination.goalJourney` row, right alongside Coach — no longer nested five taps deep in settings |
| **Daily check-in** | Notification → deep-links to the Coach with a fresh brief (gated on the *logical* day, not per-conversation, so it can only fire once per real day). Carries **Remind me in 2 hours** / **Not today** actions; snoozing adds a one-off request beside the untouched daily trigger. |

**When the coach speaks first, it says so.** `ChatMessage.Origin`
(`reply` / `brief` / `checkIn` / `nudge` / `weeklyReview`) tags each turn at its append site, and the
chat labels the unprompted ones — otherwise a brief reads as an answer to a question the user has
forgotten asking. The floating button carries a dot while something unseen is waiting; "unseen" is
DERIVED from message dates against a last-opened stamp rather than tracked separately, so there is no
second read-state store to keep in sync with the transcript.

**The check-in notification text is deliberately generic.** It is a *repeating* calendar trigger: its
content is fixed when scheduled and reused every day without the app running, so naming today's
readiness would quote whatever was true the last time NOOP was opened — possibly days ago. A stale
number is worse than none. The brief itself is generated on open, where the data is current.

The banner, header icon and floating button are each an independent on/off switch —
`CoachEntryPrefs.bannerKey` / `.headerIconKey` / `.floatingButtonKey` (`Strand/Screens/CoachEntry.swift`)
— not a single either/or choice, so a user can combine any of them (e.g. banner + floating button, or
header icon alone). This replaced a three-way `CoachEntryMode` (card / button / both) picker
(2026-07-25): that shape couldn't express "more than one, but not all three" once the header icon
became a real third option, and it also couldn't give the banner a POSITION — it was always pinned
above everything else on classic Today. A one-time migration off the old `coach.entryMode` key
preserves an existing install's header-icon/floating-button choice; the banner defaults on for
everyone. Corners are resolved against the safe area with clearances (bottom `+96`, top `+64`) so a
pinned floating button never covers the tab bar or the Today header.

All routes present through one shared `View.coachCover(isPresented:coach:)` helper in
`CoachView.swift` — `fullScreenCover` on iOS, `sheet` on macOS. The composer inside it clears
`RootTabView`'s floating tab bar via a measured (not guessed) environment value,
`\.floatingTabBarInset` — see the fix's commit for why a guessed pixel constant would have been wrong.

**The AI Coach itself is an explicit feature opt-in.** `CoachFeaturePrefs.enabledKey`
(`coach.featureEnabled`) defaults to **off** on a fresh installation: without a provider/key there is
no useful chat to surface. More → **AI Coach** remains available for setup. Turning the feature off
hides all Coach entries (Today banner/tile/header icon, floating button and per-metric “Ask coach”),
closes an open Coach cover, cancels its daily check-in and prevents its automatic brief/nudge/review
requests. It does **not** delete chats, memory, health data or the person's entry preferences.

`CoachEntryPrefs.uiEnabledKey` (`coach.uiEnabled`, default on) is a smaller, independent *home-surface*
preference for an enabled Coach: it hides the banner, header icon and floating button while remembering
their individual settings. It is deliberately separate from data consent and from on-device card
analysis that is not a Coach chat action.

## 11a. Notifications & the bell

Before this, the bell (`UpdateStore`/`UpdatesInboxView.swift`) and the coach's proposals
(`CoachPlanStore`/`PlanProposal`) were two disconnected shapes: the bell only ever carried release
notes, "new data arrived" readings, and restorable dismissed cards, and a proposed session always
titled itself "Today's session" regardless of what it actually was — a rest day read exactly like a
hard one. Proactive hints (`ProactiveSignal`, §"Proactive coaching" logic in `ProactiveCoach.swift`)
existed only as chat text: a body-concern signal or a small win was invisible unless you happened to
open Coach.

**`UpdateItem` (`Strand/Data/UpdateStore.swift`) now carries what the coach decided about a
notification**, not just its content:

```swift
enum Category { case actionable, informative, statusReminder }
enum Priority { case low, normal, high }

var category: Category            // does this need a decision, a read, or nothing?
var priority: Priority             // sort/badge weight within the inbox
var expiresAt: Date?               // when this stops being relevant (never for .actionable)
var actionRequired: Bool           // true only while an .actionable item awaits a decision
var planProposalId: UUID?          // .actionable items point at a PlanProposal, never copy it
var showOnToday: Bool              // prominent on Today, or bell/inbox-only
```

All six are additive — a row persisted before this existed decodes via `Kind.defaultCategory`
(`.dismissedCard`/`.strapAlert` → `.statusReminder`, `.whatsNew`/`.reading` → `.informative`), so an
existing on-device inbox never drops a row on upgrade (`UpdateItemCategoryDecodeTests`).

**`Strand/AI/CoachNotifier.swift`** is the bridge from the coach's two structured outputs into the
bell — a plain Swift enum, not a `CoachTool`, because `ProactiveSignal` detection is deterministic
Swift that runs unconditionally, before any model call:

- `postProactiveSignal(_:level:)` — called from `runProactiveNudgeIfNeeded()` the moment a signal is
  detected, independent of whether the chat generation that follows succeeds. Maps
  `ProactiveSignal.Category` to a bell category/priority/relevance window:

  | Signal | Bell category | Priority | Relevance |
  |---|---|---|---|
  | `.milestone` | `.informative` | high if important else normal | 7 days |
  | `.setback` | `.informative` | high | 3 days |
  | `.bodyConcern` | `.informative` | high | 2 days |
  | `.bodyPositive` | `.informative` | normal | 5 days |
  | `.goalDeadline` | `.statusReminder` | high if important else normal | the goal's own target date |

  No signal ever produces `.actionable` — only a `PlanProposal` asks for a decision. Gated by
  `ProactiveLevel` exactly like the chat nudge (`.off` posts nothing; `.important` drops non-important
  signals) — a user who turned proactive coaching down doesn't get a bell full of hints their chat pane
  would never have shown either. A same-day guard (a synthetic `"proactive:<category>"` deep link,
  checked against the logical day) stops a retried nudge attempt — `runProactiveNudgeIfNeeded()` only
  stamps its once-per-day guard on a *successful* reply, so a failed network call deliberately retries
  the same signal later — from duplicating the bell row.
- `postPlanProposal(_:)` — called from `proposePlanTool` right after `CoachPlanStore.shared.propose(_:)`
  succeeds. Posts an `.actionable`, `actionRequired: true`, `showOnToday: true` item pointing at the
  proposal's id. A re-proposal that `CoachPlanStore` collapses onto the same id (the existing
  same-`(day, sport)` dedup) refreshes the existing bell row in place rather than duplicating it.
- `syncPlanReconciliation(_:)` — mirrors ambiguous/overdue plan questions as expiring status reminders,
  removes them once the question disappears, and preserves the read state across foreground checks.
- `postAutomaticCompletion(proposal:workout:)` — records one expiring informational receipt when an
  unambiguous local workout closes a commitment automatically.

**`UpdatesInboxView.swift` now varies its ROW, not just its icon**, by category: `.actionable` resolves
the live `PlanProposal` and shows Accept / Change / Decline while it's still `.proposed`, or a read-only
status line once decided elsewhere (e.g. accepted from the Today card first) — never stale buttons.
`.informative` is read-only: mark read or leave it. `.statusReminder` keeps the existing "Restore to
Today" affordance for `.dismissedCard` rows, otherwise read-only. Items still awaiting a decision sort
first within the unread/read split, so a pending session never buries under hints.

**`MorningSuggestionCard`'s title is no longer hardcoded.** `.rest` reads "Rest day suggested",
`.mobility` reads "Mobility suggested"; everything else keeps "Today's session", which already read
fine for easy/moderate/hard.

**Liquid Today gained the bell** (`LiquidUpdatesBellButton`, inline in the header's existing utility-icon
cluster, same `UpdateStore.shared` Classic Today reads) — both Today screens now share one inbox instead
of Liquid having none.

**Deliberately out of scope, so far:** the six independent OS-level local-notification producers
(`CoachCheckIn`, `WindDownNudge`, `StrainTargetNotifier`, `BatteryNotifier`, `IllnessNotifier`,
`PlanReminder`) are untouched — this is an in-app system. `runGoalReviewIfNeeded()` and
`runWeeklyReviewIfNeeded()` don't post a `.statusReminder` item yet (`// TODO(notifications)` at both
call sites in `AICoach.swift`) — same shape as the goal-deadline signal, just not wired up yet.

---

## 12. Settings

`CoachSettingsView` is a landing page (status pill + five rows) drilling into grouped subpages —
**Connection & model**, **Goal & Journey**, **Coaching**, **Memory**, **Privacy & data** — rather than
one long scroll of every card at once. Every card is the same view property it always was; only the
page it lives on changed. One genuine addition alongside the reshuffle: provider/key/model can now be
changed from **Connection & model** while already connected — previously the only path back to those
controls was Disconnect first.

**Accessibility.** Reduce Motion is honoured throughout the chat — the transcript still scrolls
itself (not scrolling would strand the reader above a reply that has already arrived), it simply jumps
rather than animating. The composer grows to 12 lines at the accessibility text sizes, where five lines
holds a few words. The proactive-level picker states its active option in words rather than carrying it
on a highlight colour alone.

**Coaching** leads with the coach-identity editor and the home-surface preferences (including the
avatar toggle). The feature-level **Enable AI Coach** control lives at the top of Coach settings, so it
is available before connection setup as well as after it — see §11 for what each control does.

---

## 13. Contributing / hacking on it

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

⚠️ **New fork UI text needs the complete upstream Apple language matrix, not just English.** That is
`de`, `es`, `fr`, `it`, `pt-PT`, `ru`, `zh-Hans` and `zh-Hant`. `Tools/i18n_audit.py` only recognises a
string as translatable when it is a **literal** argument directly at a `Text(...)` /
`.navigationTitle(...)` / similar call site. Route it through a `title: String` helper parameter first
and the audit cannot see it at all, which is exactly how coach strings shipped English-only before the
fork-wide backlog was closed. Prefer a few repeated literal call sites over a
DRY-but-invisible-to-the-scanner helper.

⚠️ **The `it` / `pt-PT` / `ru` / `zh-Hans` / `zh-Hant` fork strings are machine-translated, unreviewed.**
`de` / `es` / `fr` are the long-standing CI-gated set (`Tools/i18n_audit.py`'s focus locales); the
other five were filled in wholesale to close the fork translation gap, without a native speaker
checking idiom, register or culturally loaded phrasing (especially coach tone and health disclaimers).
They're a correct-shaped starting point, not a shipped-quality bar — a native pass on any of the five is
a welcome, low-risk PR (string-only, no code). The coach's *replies* are separately covered:
`CoachReplyLanguage` (`Strand/AI/CoachReplyLanguage.swift`) resolves the active app localization from
`Bundle.main.preferredLocalizations` and appends a strict, final system instruction to every coach
request. The selected app language therefore wins over the device formatting locale, differently
written user messages and older chat history; unsupported languages follow the UI's English fallback.

Good first contributions:

- **Native review of the `it` / `pt-PT` / `ru` / `zh-Hans` / `zh-Hant` fork strings.** Currently
  machine-translated (see the warning above) — string-only, no code, no strap needed.
- **Verification against live providers.** Streaming, tool rounds, the token counts, the 429 countdown
  and the offline path are unit-tested and compile-clean, but several have never run against a real
  API. Each needs one real turn per provider.
- **Prompt caching beyond Anthropic.** OpenAI caches automatically and reports `cached_tokens` (already
  read); OpenRouter can pass `cache_control` through to Anthropic models. Neither is exploited.
- **Cost, not just tokens.** `CoachUsageLog` counts tokens on every provider now, but OpenRouter's
  `/models` also reports per-model price — which `OpenRouterModel` already parses. Turning a turn into
  an actual figure is a small step from there, and matters most where the user picks the model.

Three earlier entries are done and gone: streaming + tool-calling beyond Anthropic, a first-class
OpenRouter provider, and the token-budgeted history window.
