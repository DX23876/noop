# The Coach — in full

Everything NOOP AI adds on top of [ryanbr/noop](https://github.com/ryanbr/noop) lives here. The
[README](../README.md) has the friendly tour; this is the technical one.

**Design rule for every line of it:** additive, in its own file, never a rewrite of upstream logic.
That's what keeps `git merge upstream/main` a non-event (upstream `v9.0.0` merged with zero
conflicts).

---

## 1. Architecture

```
Strand/AI/
├── AICoach.swift              The engine: state, context building, send/stream, tool loop
├── AIProvider.swift           Provider enum: endpoints, models, cheap models, client factory
├── CoachPersona.swift         Guardian / Friend / Commander — voice only
├── CoachTools.swift           The 14 tools: schemas + dispatch
├── CoachMemory.swift          Long-term memory: facts, categories, ranking, dedup
├── CoachTranscriptStore.swift Conversations: model + JSON persistence
├── MemoryMaintainer.swift     Cheap-model summarisation + fact distillation
├── CoachChart.swift           In-chat chart artifacts
├── CoachStreaming.swift       SSE streaming
└── Providers/
    ├── AnthropicTools.swift       Tool-use loop
    └── AnthropicStreaming.swift   Token-by-token SSE

Strand/Screens/
├── CoachView.swift            The messenger chat + the shared `coachCover` presenter
├── CoachSettingsView.swift    All configuration (behind the gear)
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
                        • 14-day metric table + 30-day averages     (buildContext)
                        • recent workouts
                        • today's stress index
                        • personal patterns + Lab Book   (2nd opt-in only)
                        • digest of recent conversation summaries
                        • facts RELEVANT to this question   (wireMessages)
   ↓
windowedMessages()    first user turn + last 10 messages (the middle is dropped)
   ↓
callProvider()        tool-use loop (Anthropic) or plain single-shot
```

Two deliberate choices in there:

- **Pinned vs. relevant facts are split.** Pinned facts ride the *system prompt* (always true, always
  relevant). Query-relevant facts are folded into the *turn's context* in `wireMessages()`, where the
  question is actually known. A large memory therefore doesn't inflate every request.
- **The history window is a message count, not a token budget** (`maxHistoryMessages = 10`). Blunt,
  but it keeps small local models (Ollama defaults to a 2048-token window) from having the reply
  crowded out. Parity with the Android implementation upstream.

---

## 2. The 14 tools

Declared in `CoachTools.swift` as `CoachTool`, offered to the model as JSON Schema, dispatched in
`runCoachTool(_:input:)`. **All of them are gated behind `dataConsent`** — without it the dispatcher
returns a polite "no data access" string and the model coaches generally.

Tool-calling only engages for providers that conform to `ToolCallingClient` (Anthropic today);
everything else falls back to the pre-baked-context path, which is why the conversation digest is
injected into the context too rather than living only in a tool.

### Read

| Tool | Params | Returns |
|---|---|---|
| `get_biometric_summary` | — | 14-day table + 30-day averages: charge, effort, rest, HRV, RHR, SpO₂, respiration, skin-temp deviation, steps, energy |
| `get_recent_workouts` | `limit` 1–30 | Sport, duration, effort, avg HR, energy, distance |
| `get_stress_index` | — | Today's Baevsky Stress Index over today's R-R |
| `get_sleep_detail` | `nights` 1–14 | Bed/wake, efficiency, deep/REM/light minutes, disturbances + the rolling 14-night sleep-debt ledger |
| `get_range_report` | `days` 7–365 | Per-metric averages, trends, headline changes |
| `get_personal_patterns` | — | Top n-of-1 correlations (`EffectRanker`, significant only) + Lab Book roll-up. **Second opt-in required** (`includeOnDeviceSignals`) |
| `search_past_conversations` | `query` | Top-3 matching past chats as titled, dated snippets |

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

## 3. Memory

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

Everything is visible and editable in `CoachSettingsView` — category icon, pinned marker, inline
edit, delete, forget-all.

### Cross-conversation recall

`CoachConversation` carries an optional `summary` (plus `summarizedCount` for the cost gate). Two
paths get it back to the model:

1. **`search_past_conversations`** — deterministic keyword search over every stored conversation
   (title + summary + messages), returning the best 3 as titled, dated snippets. On demand only.
2. **`recentSummariesDigest()`** — one line per recent summarised chat, injected into
   `buildFullContext()`. Cheap, and it works on providers with no tool-calling.

---

## 4. Cheap-model maintenance

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

## 5. Providers

| Provider | Chat | Streaming | Tool-calling |
|---|---|---|---|
| Anthropic | ✅ | ✅ SSE | ✅ |
| OpenAI | ✅ | — | — |
| Gemini | ✅ | — | — |
| Custom (OpenAI-compatible) | ✅ | — | — |

**Custom** points at any OpenAI-compatible base URL — Ollama (`http://localhost:11434/v1`), LM
Studio, llama.cpp. Keyless, so a fully local coach means **nothing leaves your network**.

Keys live in the **Keychain**, never in `UserDefaults`, never in the repo, never logged. Streaming
and tool-calling for OpenAI/Gemini are the obvious next contribution.

---

## 6. The privacy model

The app is offline-first and stays that way; the coach is the *only* thing that ever opens a socket.

**Consent is two-stage, both off by default:**

1. **`dataConsent`** — without it, no metrics are included in any request and every tool returns
   "no data access". The coach still works; it just doesn't know you.
2. **`includeOnDeviceSignals`** — additionally folds in your n-of-1 patterns and Lab Book roll-up.
   Summary-only, and gated behind `dataConsent` too.

**What is sent:** derived daily numbers (charge, HRV, RHR…), short summary lines, your saved facts,
and — under consent — past-conversation snippets for recall.

**What is never sent:** raw R-R streams, raw sensor buffers, raw PPG/IMU. The tool layer routes
through the same summarised reads the UI uses, so there's no path for raw egress even by accident.

**Where it goes:** only to the provider *you* chose, with *your* key, when *you* send a message.
There is no NOOP server. There is no account. Local provider ⇒ zero egress.

Everything stored — memory, conversations, chart snapshots — is on-device
(`UserDefaults` / Application Support JSON), capped, and never synced.

---

## 7. Entry points

| Route | Where |
|---|---|
| **Today card** | "Ask your Coach" on Today → full-screen chat |
| **Floating button** | Draggable, pinnable to any of 4 chrome-clear corners, lockable |
| **More tab** | The original `MoreDestination.coach` row |
| **Daily check-in** | Notification → deep-links to the Coach with a fresh brief |

The card and button are user-selectable via `CoachEntryMode` (card / button / both) in Settings.
Corners are resolved against the safe area with clearances (bottom `+96`, top `+64`) so a pinned
button never covers the tab bar or the Today header.

All routes present through one shared `View.coachCover(isPresented:coach:)` helper in
`CoachView.swift` — `fullScreenCover` on iOS, `sheet` on macOS.

---

## 8. Contributing / hacking on it

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

⚠️ **Always `git checkout -- "*.xcstrings"` after a build.** Xcode reformats the string catalogs on
every build (~200k-line diff of pure churn) and committing that poisons upstream merges.

Good first contributions: streaming + tool-calling for OpenAI and Gemini; a token-budgeted history
window instead of the fixed count; embeddings-free but smarter fact ranking.
