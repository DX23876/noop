# Coach analysis roadmap

The plan for bringing the Coach to the depth of Google's personal health coach (Google Health Coach,
May 2026) without giving up what NOOP is: bring-your-own-key, on-device data, no server. Settled in a
design review on 2026-09-23; the matching rows are in [`decisions.md`](decisions.md). The current Coach
architecture is described in [`COACH.md`](COACH.md).

## What the reference system does

Google's coach is described in three publications:

- **Personal Health Agent** (arXiv 2508.20148): an orchestrator routes each question to a primary and
  a supporting specialist — a *data science* agent (question → analysis plan → code over the wearable
  time series), a *domain expert* agent (multi-step reasoning with authoritative sources) and a *health
  coach* agent (motivational interviewing, goals, progress) — then reflects and updates memory.
- **PHIA** (Nature Communications; arXiv 2406.06464): a ReAct loop with code execution and web search.
  On 4,000 objective questions it reached 84 % exact answers, against 74 % for single-shot code
  generation and 22 % for tables pasted into the prompt. Its dominant failures were hallucinated columns
  and wrong time windows.
- **SHARP** evaluation: safety, helpfulness, accuracy, relevance, personalization, rated by experts and
  scaled with autoraters.

The Coach already has most of the coaching surface (30+ tools, memory, goals, a plan book, proactive
nudges, a scheduled brief, charts). What it lacks is free-form analysis, grounding checks, cited domain
knowledge and a way to measure answer quality.

## Constraints that shape the design

- **Providers:** Anthropic, OpenAI and Gemini are first-class. OpenRouter participates only with models
  that support tools (already gated on `supported_parameters`). Custom (local servers) keeps its
  tool-less path and gets no analysis. No on-device model for now.
- **Privacy:** only aggregates leave the device — the boundary `get_metric_history` already draws. No raw
  series goes to a provider, including through provider-side code execution. Analyses see categories,
  never free text. Existing `ToolConsent` purposes gate every data source.
- **Quality bar (pre-registered):** objective questions ≥ 90 % exact; open-ended questions ≥ 80 % rated
  good or better; zero critical safety errors. Each provider's flagship model must clear it; cheaper models
  are reported. Between two variants that both clear it, the one with fewer median tokens per data
  question wins. This rule settles every later architecture question, including whether specialists
  become sub-agents.
- **Platforms:** iOS and macOS. No phase changes a score: **Analysis migration required: no.**

## Phases

Each phase lands on `main` separately after a macOS and an iOS build, `swift test` for touched packages
and the CoachEval smoke set.

### 0a — Coach state in the backup

`.noopbak` carried the database and whitelisted settings but none of the Coach's own state: memory,
conversations, plans, goals and the coach's identity lived in Application Support and UserDefaults, so a
reinstall restored from a backup lost them. A `coach-state.json` entry now carries them. API keys stay in
the Keychain and never enter a backup.

### 0 — Foundations

- `Packages/CoachAnalysis`: the analysis spec, its validator, the executor, the per-answer test ledger
  and the tool schema, testable with `swift test`. Foundation only — no GRDB, no `StrandAnalytics` — so
  it builds in seconds for the app and for `Tools/CoachEval` alike. The few statistics it needs (Spearman,
  OLS, Hedges' g, a seeded circular block bootstrap, Benjamini–Hochberg) are its own; `StrandAnalytics`
  had none of the bootstrap or correction machinery to reuse.
- `Tools/CoachEval`:
  - a synthetic data generator with several injected effects of different sizes, so a method is shown to
    track a varying input rather than match one value;
  - about 300 objective questions with exact answers and 60 open-ended ones, stratified by question type,
    plus a 30-question smoke set for iteration;
  - cross-provider autoraters (a model never grades its own provider), calibrated against about 40
    answers the wearer rates by hand;
  - an optional local run against the wearer's own database, kept in a gitignored folder; results from
    real data are never committed.

### 1 — Free-form analysis (spec language)

- A `run_analysis` tool taking a natural-language `plan` (shown to the wearer) and a declarative `spec`.
  Operations are fixed: `describe`, `trend`, `compare_periods`, `compare_groups`, `correlate` (with lag),
  `event_response`, `rank_days` (at most five). Derived series (`rolling_mean`, `delta_from_baseline`) and
  filters (weekday, journal category, threshold, date range). Alignment such as `night_after` is an enum
  with one documented meaning that follows NOOP's day ownership.
- Validation errors come back as repairable messages ("unknown metric `sleep_eff`; did you mean
  `sleep_efficiency`?"), which is what let PHIA recover from failed attempts.
- Statistics: groups below n = 5 are reported as too small, confidence intervals by block bootstrap
  (consecutive days are not independent), effect size, missing days and likely confounders. Every analysis
  run while answering one question is counted; the Coach states how many it ran and p-values are corrected
  across them (Benjamini–Hochberg).
- A collapsed "How this was calculated" card under each data-backed answer: plan, window, sources, n,
  interval, number of tests, confounders, chart.
- Number grounding: every number in a reply must trace to a tool result or the wearer's own input. A miss
  gets one repair pass from the cheap model; a number still untraced is marked in the reply.
- Web search through the provider's own tool (Gemini 3 combines it with function calling in one request;
  Anthropic `web_search`), opt-in.
- Cycle phase (`CyclePhaseEngine`) is available as an analysis category from the start.
- Health wording follows the rule in `decisions.md` (2026-09-23): signal, action, and — only alongside
  everyday explanations — common benign causes.

### 2 — Measure the architecture

- The analyst as a sub-agent (`ask_analyst`, its own loop, prompt and model) against phase 1, decided by the
  quality bar above.
- A local code sandbox (JavaScriptCore in a killable web view, or Pyodide) only if CoachEval shows a
  meaningful share of questions the spec language cannot express. Both runtimes are prototyped against each
  other first; the sandbox gets the phase-1 statistics as a library, and its output passes the same
  aggregate gate. JavaScriptCore has no public execution time limit, which is why the process has to be
  killable.

### 3 — Proactive insights

- A fixed daily set of analyses runs locally at no token cost: departures from the wearer's own baseline,
  new associations with journal categories, trend breaks. Only a result that survives the phase-1
  correction is phrased by the cheap model, at most once a day, honouring `ProactiveLevel`.
- Insights are kept as history in the database with the wearer's helpful / not helpful feedback, so the
  Coach can refer back to them and they travel with the backup.
- Shown on Today and optionally as a notification. The run is repeated on app open when the background task
  did not fire.

### 4 — Coaching

- A motivational-interviewing module for every conversation (open questions, reflections, summaries,
  readiness to change).
- Chat onboarding for goals, routine, equipment and injuries, writing through `propose_goal_setup` into the
  same stores as the existing onboarding flow, which stays.

### 5 — Breadth

In this order:

1. Photos and PDFs in the chat. Documents are read on device (Vision) and only the value table leaves the
   device, after a preview. Meal photos are sent as images only after confirmation and logged as a marked
   estimate the wearer confirms; nutrition advice stays general. Meals get their own table (versioned
   migration, in the backup).
2. App Intents (Siri, Shortcuts, Spotlight).
3. Widget for the daily insight.
4. Share extension.
5. A cycle-context tool for the Coach.

## Deferred

- **A curated knowledge base** of own summaries with source links (sleep, HRV, load, recovery, caffeine,
  alcohol, cycle), retrieved through the existing Nomic embeddings so it works offline and with every
  provider. Deferred in favour of provider web search; still wanted.
- **On-device model** (Foundation Models) as a fallback — it would limit the feature to too few devices.
- **Medical records** (HealthKit clinical records) — not available in Germany and needs a paid developer
  account.

## Sources

- [How we are building the personal health coach](https://research.google/blog/how-we-are-building-the-personal-health-coach/)
- [The anatomy of a personal health agent](https://research.google/blog/the-anatomy-of-a-personal-health-agent/) · [arXiv 2508.20148](https://arxiv.org/abs/2508.20148)
- [Transforming wearable data into personal health insights using LLM agents](https://www.nature.com/articles/s41467-025-67922-y) · [arXiv 2406.06464](https://arxiv.org/abs/2406.06464)
- [Google Health Coach](https://blog.google/products-and-platforms/products/google-health/google-health-coach/)
- [Gemini API tool combinations](https://blog.google/innovation-and-ai/technology/developers-tools/gemini-api-tooling-updates/)
