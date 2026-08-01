# FORK_GUIDE.md — working in the DX23876 fork

Everything in [`../CLAUDE.md`](../CLAUDE.md) still applies. That file is kept **byte-identical to
upstream** apart from one pointer to this document, so a pull request back to `ryanbr/noop` never
carries fork context as noise. This file holds what is true *here and not upstream*: where the fork
deliberately diverges, how its commits are written, what its CI actually runs, and how its docs are
maintained.

Fork-only documentation lives under [`fork/`](fork/) for the same reason — upstream's `docs/` tree
stays recognisable, and a sync PR never has to explain a file upstream has never seen.

## Commit and attribution conventions

**Commits carry exactly one identity: `DX23876 <176692557+DX23876@users.noreply.github.com>`.**
NOOP is an anonymous project (see "What NOOP is" in `CLAUDE.md`); the real name belongs in neither
the author field nor a trailer.

**No commit message may name an AI assistant.** No `Co-authored-by:` naming Claude, Copilot, ChatGPT
or a vendor domain; no `Claude-Session:` backlink; no "Generated with …" watermark. A pushed message
is the one thing that cannot be taken back — GitHub mirrors, caches and quotes it long after any
local edit.

This is enforced, not merely written down, because writing it down demonstrably failed: such trailers
reached `origin/main` repeatedly while the rule already existed.

| Layer | Where | Catches |
|---|---|---|
| `commit-msg` hook | `.githooks/commit-msg` | Before the commit object exists. Enable once per clone: `git config core.hooksPath .githooks` |
| CI job `commit-attribution` | `.github/workflows/source-hygiene.yml` | Anything that bypasses the hook — `--no-verify`, a clone without `core.hooksPath`, the GitHub web editor |

The CI job audits only the commits a push or PR **adds**. History already carries such trailers,
including three commits inherited from upstream where they are ryanbr's to keep, and a job that
audited all of history would be permanently red and therefore ignored.

The subject matter is not the target — only authorship. "Anthropic" is a real AI provider this app
integrates (`Strand/AI/AIProvider.swift`), so a message may freely say "add Anthropic streaming".

**Versioning.** `MARKETING_VERSION` in `project.yml` and `versionName` in
`android/app/build.gradle.kts` move together; build numbers are independent counters. The fork's
release identity is `X.Y.Z DX Beta` — the numeric version stays numeric everywhere Apple reads it
(`CFBundleShortVersionString`), and the "DX Beta" branding lives only in the git tag
(`vX.Y.Z-dx-beta`), the asset filenames and the release title.

## Where this fork diverges from upstream

### The cross-platform parity contract is RETIRED (2026-07-23)

Upstream's `CLAUDE.md` calls it the #1 rule. **It does not bind here.** The project is iOS/macOS-only;
the Android target is dropped and no longer kept in sync. Byte-identical analytics, platform-neutral
FNV-1a hashing, the `.noopbak` byte-identical whitelist and Room/GRDB schema agreement are **no longer
gates** on a change. The Android tree may remain in the repo but is not a parity obligation.

**Separate and still binding:** the app stays fully offline, on-device — no server, no account, no
cloud sync, no telemetry, anonymous. That is upstream's rule and the fork's alike.

### The AI coach

The coach, its memory and its tools are fork-only; upstream has no equivalent. Design and tool
surface: [`fork/COACH.md`](fork/COACH.md).

### CI actually runs here

Upstream's own guide describes `app-build.yml` as disabled. **In this fork every workflow is active**,
which changes what validates a change:

| Workflow | Covers | Trigger |
|---|---|---|
| `swift-packages.yml` | `swift test` for `Packages/**` (incl. the fork-only `SemanticMemory`) | PR + push touching `Packages/**` |
| `app-build.yml` | Compile of `Strand` (macOS) + `NOOPiOS` (iOS), **plus `StrandTests` on the macOS leg only** | PR + push touching `Strand/**`, `StrandiOS*/**`, `Packages/**`, `project.yml` |
| `tools-python.yml` | The `Tools/linux-capture` Python suite (≥200 tests) | PR + push touching `Tools/**` |
| `source-hygiene.yml` | Detached doc comments + **commit attribution** (above) | every PR and push to `main` |
| `i18n-coverage.yml` | EN/DE/FR/ES completeness | every PR and push to `main` |
| `android.yml` | `assembleFullDebug` + unit tests | PR + push touching `android/**` |
| `publish-ios-beta.yml` | Cuts a DX Beta release: unsigned IPA + universal macOS zip, updates the AltStore source, marks it latest | `workflow_dispatch` |
| `sync-upstream.yml` | Opens a sync PR from `ryanbr/noop` | weekly cron + dispatch |

**`StrandTests` runs in exactly one place** — `app-build.yml`'s macOS leg. `Test Strand` is a later
step in the same job, so a red *build* step silently **skips** the tests rather than failing them. A
red `main` is not a background condition to work around.

**Always pass `-R DX23876/noop` to `gh`, or check what it resolved to.** This clone has two remotes
and no `gh repo set-default`, so a bare `gh run list` silently answers about **`ryanbr/noop`** —
where `app-build.yml` is disabled and the last run is old. Reading the upstream answer as the fork's
is an easy and very misleading mistake.

## Documentation & session workflow

Read this before touching docs, proposing an architecture/feature change, or ending a session
mid-task.

### Source-of-truth precedence

When two sources disagree, higher wins:

1. **Source code** — the current implementation; ground truth for what the system actually does.
2. **[`fork/decisions.md`](fork/decisions.md)** — architectural intent and rationale (the "why").
3. **Topic documentation** — `ARCHITECTURE.md`, `FEATURES.md`, and the rest of the map below.
4. **This file** and `CLAUDE.md` — the working guides.
5. **Session handoff** — `.claude/handoff/<branch>.md`.
6. **Chat context** — anything that exists only in the current conversation.

A doc's claim about current behaviour that conflicts with the source is wrong until proven otherwise
— trust the code and fix the doc; don't silently prefer one without flagging the conflict.

### Documentation map

Upstream docs (shared with `ryanbr/noop` — keep edits here mergeable):

| Doc | Covers |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Module map — how the packages and app layers fit together |
| [`FEATURES.md`](FEATURES.md) | User-facing behaviour — what the app does today |
| [`DATA_MODEL.md`](DATA_MODEL.md) | On-device SQLite schema, migrations |
| [`PROTOCOL.md`](PROTOCOL.md) | WHOOP BLE wire protocol |
| [`ANALYTICS.md`](ANALYTICS.md) | Recovery / strain / sleep scoring math |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | BLE safety contract, design-system rules, recipes |

Grouped, read the specific file when your change touches it:
- **Protocol/BLE detail:** `BLE_REVERSE_ENGINEERING.md`, `OURA_PROTOCOL.md`, `WHOOP5_DEEP_DATA.md`
- **Scoring detail:** `FITNESS_AGE.md`, `RR-OPTIMIZATION.md`
- **Device support:** `DEVICE_SUPPORT_ROADMAP.md`, `DEVICE_DRIVER_ARCHITECTURE.md`
- **Ops/trust:** `PRIVACY_SECURITY.md`, `SAFEGUARDS.md`, `HOMEBREW.md`
- **Reference:** `LIBRARY.md`
- **Predates the 2026-07-23 retirement decisions:** `CROSS_PLATFORM.md`, `ANDROID.md`

Fork-only docs, under [`fork/`](fork/):

| Doc | Covers |
|---|---|
| [`fork/decisions.md`](fork/decisions.md) | Project memory — see below |
| [`fork/COACH.md`](fork/COACH.md) | The AI coach's design and tools |
| [`fork/DETAILS.md`](fork/DETAILS.md) | Long-form reference |
| [`fork/feature-spec.md`](fork/feature-spec.md) | What the Heute screen does (states, data, persistence) |
| [`fork/design/design-spec.md`](fork/design/design-spec.md) | How it looks (colour, spacing, animation) |
| [`fork/design/mockup-today.html`](fork/design/mockup-today.html) | Binding visual reference where text and image disagree |
| [`fork/redesign-briefing.md`](fork/redesign-briefing.md) | Redesign specs |
| [`fork/releases/`](fork/releases/) | DX Beta release notes — `publish-ios-beta.yml` reads `fork/releases/v<VERSION>-dx-beta.md` and refuses to publish without it |

When you add a doc, file it into the matching group in the same change — this map stays current
because whoever adds a doc updates it, not because of a separate maintenance pass. A fork-only doc
goes under `fork/`; a doc upstream would also want goes beside theirs.

### Working with docs

1. **Read before proposing.** At minimum `ARCHITECTURE.md` and/or `FEATURES.md` for anything touching
   app structure or user-facing behaviour.
2. **Classify a new feature before building it.** Extends an existing feature, replaces one, or is
   genuinely new — update `FEATURES.md` accordingly *before* writing other documentation. That is what
   keeps it current instead of drifting behind what shipped.
3. **Infer from code when docs are silent, and say so.** State it as an assumption ("inferred from
   `Y.swift:Z`, not documented") rather than presenting a guess as documented fact.
4. **Never fork a second source of truth.** Search for a doc that already covers the topic and extend
   it. This is why there is no separate `PROJECT_MEMORY.md`.
5. **Clean up while you're in there.** Remove or mark deprecated whatever your change obsoletes.
6. **Optimise for token efficiency.** Read only the relevant docs; expand into source only when a doc
   is missing, outdated or ambiguous.
7. **Promote durable decisions out of ephemeral spaces.** A handoff file or a chat is never the
   permanent record — once settled, it belongs in `fork/decisions.md` or a topic doc.
8. **Check cross-doc consistency after a merge.** Verify `FEATURES.md`, `ARCHITECTURE.md`,
   `fork/decisions.md` and this file stayed consistent with what merged.

### Project memory vs. session handoff

Two different lifetimes, two different places — don't mix them:

| | `fork/decisions.md` (project memory) | `.claude/handoff/<branch>.md` (session handoff) |
|---|---|---|
| Lifetime | Forever | One branch |
| Holds | Architecture choices and why, ideas deliberately rejected, known tech debt, planned stages | In-progress state for resuming *this specific* branch |
| Tracked in git | Yes | No — git-ignored |
| Read when | "Why is X built this way", "what's worth improving" | Resuming work on this branch |

`fork/decisions.md` is a dated decision log; its purpose ("so a question settled once isn't
re-litigated later") is project-wide, not redesign-only.

### Session handoff — branch-scoped, git-ignored

`.claude/handoff/<branch-slug>.md` (sanitise `/` → `-`), one file per branch. Per-branch rather than
one shared file because this repo runs many parallel worktrees and branches at once — a shared file
would overwrite itself the moment two are in flight. Both `.claude/worktrees/` and `.claude/handoff/`
are in the tracked `.gitignore`, so the behaviour is identical for every clone.

Write or update one before switching sessions mid-task: goal, current status, done, open TODOs,
architecture decisions not yet in `fork/decisions.md`, known risks, the single concrete next step,
and the docs it depends on. **Promote and discard on merge** — the handfile dies with the branch.

## Redesign (in progress)

An iOS/macOS-focused redesign is underway. Specs: [`fork/redesign-briefing.md`](fork/redesign-briefing.md);
visual reference, binding where text and image disagree:
[`fork/design/mockup-today.html`](fork/design/mockup-today.html); durable decisions:
[`fork/decisions.md`](fork/decisions.md).

**Strategy — evolve in place, do NOT fork parallel screens.** The screens are shared `Strand/` code
and `StrandDesign` is already fork-owned, so the redesign edits the existing screens and Palette.
Re-theming happens by changing values behind the frozen `StrandPalette` token API (≈3,170 call sites
update for free) — never hardcode hex at a call site.

**Design rules:**
1. One value, one place. Each metric appears once per screen.
2. No empty tiles. Without data, render nothing — no "—", no placeholder.
3. Colour codes family via the "Signature" `ChartStyle`. Colour only re-skins data encodings
   (rings/charts/scales), never chrome/surfaces.
4. Size codes importance. Exactly one element per screen is clearly the largest.
5. Tabs are places, not actions. The coach hangs on content, not a tab.
6. Units are small, in a secondary colour, exactly once per value. All numbers `.monospacedDigit()`.
7. All trend charts go through Swift Charts.
8. iOS 26 Liquid Glass (`glassEffect`, `.navigationTransition(.zoom)`, Material) is the design language.

**Localization:** EN is the source locale; DE, FR and ES are kept complete. New strings ship with all
four.
