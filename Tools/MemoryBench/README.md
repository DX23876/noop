# MemoryBench — measuring what the coach's memory actually retrieves

The coach hands the model **eight lines** of local text memory per turn. Which eight is decided by
`SemanticIndexStore.search` and `SemanticRanking.fuse`, and until this tool existed the only evidence for
that decision was a six-document self-test on device
([`NomicTextEmbeddingProvider.runRetrievalSelfTest`](../../StrandiOS/AI/NomicTextEmbeddingProvider.swift))
and a 300-query measurement quoted in a comment that was never committed. The comment's numbers are almost
certainly right — they rejected symmetric reciprocal-rank fusion, correctly — but nobody can re-run them, so
no further change to the ranking can be argued for or against.

This is that missing instrument. It is read-only, it opens no NOOP database, and **no wearer's health data
is involved at any point**: the corpus under `Corpus/` is synthetic and committed.

---

## Two stages, and why they are separate

The embedder is iOS-only. `Tools/bootstrap-nomic.sh` deliberately rebuilds the pinned llama.cpp XCFramework
with only the two iOS slices, so a macOS executable has nothing to link against — and building a second,
differently-configured copy of the runtime for the bench would mean measuring a runtime the product does not
have. So:

| Stage | Needs a model? | Deterministic? | In CI? |
|---|---|---|---|
| `embed` | yes — a GGUF and a `llama-embedding` built from the pinned tag | n/a | no |
| `score` | no — reads vectors files | yes | yes |

That split is also what makes a model comparison fair. `score` replays the **real** `SemanticIndexStore`,
the **real** Float16 encoding and the **real** cosine scan, and only swaps the selection above them. So every
model comparison runs under one identical selection, and every selection comparison runs over one identical
set of vectors.

---

## Run it

Nothing below needs a model:

```bash
swift test
```

```bash
swift run memorybench lint --corpus Corpus
```

```bash
swift run memorybench score --corpus Corpus --synthetic
```

`--synthetic` replaces the vectors with hashed token bags. It exercises the entire pipeline and prints the
whole report in about a second, which is how the tables and the ablation ladder were developed. It is **not a
model**: exact token overlap survives the hashing and paraphrase does not, so it is a keyword baseline
wearing a vector's clothes — a useful floor and a useless ceiling. Never put it in a comparison table.

For a real measurement, embed once per model, outside this repository:

```bash
swift run memorybench models
```

```bash
swift run memorybench embed --corpus Corpus --contract nomic-embed-text-v2-moe --model ~/models/nomic-embed-text-v2-moe.Q4_K_M.gguf --llama-embedding ~/llama.cpp/build/bin/llama-embedding --out ~/vectors/nomic
```

```bash
swift run memorybench score --corpus Corpus --vectors ~/vectors/nomic --floor 0.20,0.25,0.30,0.35
```

Build `llama-embedding` from the **tag pinned in `Tools/bootstrap-nomic.sh`** (currently `b9623`). A different
build is a different runtime, and the point of pinning is that the number means something.

Before it writes anything, `embed` runs three trivial-pair checks through the model's own contract and
refuses to proceed if any of them ranks the wrong document first — see "The trivial-pair check" below. That
is what stands between a real measurement and reporting a broken GGUF's quantisation damage as model quality.

`embed` asks for the raw pooled vector (`--embd-normalize -1`) and then applies the app's own
`SemanticVector.normalizedTruncated` — truncate to the stored width, then renormalise, exactly as
`NomicTextEmbeddingProvider.embedOne` does — before encoding to Float16. So the score includes the
quantisation and Matryoshka loss the device actually has.

---

## What the corpus is, and what it is not

520 documents / 624 queries, organised into **indexes** rather than languages, because an index is what a
question is actually asked against: one person's own memories.

| Index | Documents | Queries | Languages | Job |
|---|---|---|---|---|
| `main` | 272 | 384 | de + en (~1 in 10) | every ranking and reranking question |
| `locale-*` × 10 | 24–28 each | 24 each | one each | does this model work in this language at all |

`main` is shaped like a real index and sized so that **ranking, not recall, decides** — the previous version
left about 25 candidates per query, which made every ranking change unmeasurable. The near-misses are the
point of the size: three ferritin values on three dates, two knees across five activities, two magnesium
forms and two timings, two sleep goals, two caffeine cut-offs, three training frequencies, two Achilles
tendons, five recovery mornings, declined-versus-accepted recommendations. Plus curated facts next to raw
chat turns, one-liners next to a summary long enough to chunk, and a thread big enough to flood a context.

Nine categories, scored separately, because a change that wins one and loses another is not an improvement:

| Category | What it is for |
|---|---|
| `synonym` | A different word for the same thing — and the weakest category in practice. |
| `paraphrase` | Same vocabulary, different sentence. |
| `negation` | The question turns on a NOT, and the positive counterpart is graded 0 so a model that ignores the negation cannot score. |
| `numeric` | A name, a date, a dose. |
| `recency` | Two memories contradict and the **newer** is right. |
| `near-miss` | Almost the same sentence, only one answers — a different knee, dose, time of day. |
| `terse` | Three or four words, the way people type. |
| `crosslingual` | The question is in one language and the only answer is in the other. |
| `unanswerable` | Nothing answers it. Target: **zero** lines. |

### The grade scale is 0–3, and the change is not cosmetic

| Grade | Meaning |
|---|---|
| `3` | The one document that directly answers. **At most one per query** — enforced. |
| `2` | Strongly relevant: a co-equal answer, or something the coach clearly ought to see. |
| `1` | Supporting. The diagnosis behind the complaint, the goal behind the habit. Not an answer alone. |
| `0` | Judged and rejected. Written down rather than omitted, because that is how the corpus records that a near-miss sibling was considered. |

It was 0–2 until 2026-08-19. **Numbers taken before that date were taken with a different instrument.** Adding
a top band steepens the answer-to-support ratio in `gain` from 3:1 to 7:1, and brute-forcing every ranking of
every affected query puts the worst single-query shift at **0.149 nDCG@8**, mean worst case 0.099 across the
quarter of queries that can move at all. That is larger than every effect under study (0.002–0.071), so old and
new numbers must never be compared — the change was made deliberately and once, alongside the corpus growth
that requires re-embedding anyway.

The relabel itself was mechanical and meaning-preserving rather than a re-reading: a query with exactly one
grade-2 had a unique direct answer, so that became 3; a query with several kept them at 2, because 34 of them
genuinely have co-equal answers and forcing a winner would have invented a distinction the corpus does not
contain. That is also why the invariant is "at most one 3", not "exactly one".

### Crosslingual is a category, which it should have been from the start

It was originally left as a property of individual judgments, on the reasoning that a crosslingual case is just
an ordinary query pointing across. That was wrong in a way worth recording: with no category it had no slice in
any report, so it disappeared into the average — and counting revealed only **two** genuine cases in the whole
index, which nobody had noticed for exactly the same reason. Multilinguality is the largest single cost the
bundled model is paid for; it needs a column. There are now 23.

Genuine means enforced: a `crosslingual` query may have no answer graded 2 or 3 in its **own** language, or it
is measuring content rather than language crossing. Under that rule only three of the pre-existing candidates
qualified; the rest were ordinary queries that happened to have a supporting line in the other language.

And explicitly **not** translation pairs. Ten translations of one fact in one index is what ruined the first
corpus: every model then had nine correct answers graded 0, which punished precisely the language-agnostic
behaviour being tested. These are facts that exist in one language only — a work trip's notes written in
English inside an otherwise German index — the way a bilingual person's own memories actually look.

`CorpusTests` enforce the design, not the syntax — every `recency` case really grades the newer document above
an older distractor, every `numeric` case turns on a token with a digit, every `near-miss` case carries a
deliberately rejected sibling, `terse` questions really are short, all four grade bands are actually in use, and
`main` really is bilingual without holding two translations of one sentence. The validator is also tested by
being shown broken input and made to reject it, because a check that has only ever seen a passing corpus is not
known to fire at all. Those tests caught three authoring gaps on their first run.

**What it cannot tell you.** It is synthetic, so it cannot capture how a particular person phrases things;
`main` is one person, so it cannot capture variation between people; and the locale sets are far too small for
their per-language cells to be verdicts rather than smoke signals. A second large index in another language is
the obvious next addition, and the format takes it without changes — one more `index` value.

## What the report says

**A. Floor calibration** — the cosine of a genuinely relevant hit against the best cosine an `irrelevant`
query produces. A usable absolute floor lives between those two distributions. If they overlap, no single
threshold exists and the floor has to be per-kind or relative to the top hit instead — which is a real
possible answer, and the reason this section prints before the ladder rather than after it.

**B. Ablation ladder** — `semantic-only` → `today (+rescue)` → each proposed feature added one at a time.
`today` does not re-describe production, it **calls** `SemanticRanking.fuse`, so it is genuinely today.
Alongside the retrieval metrics: `irrel.` (mean lines emitted for a question with no answer, target 0),
`domin.` (the largest share one thread or kind holds among the eight lines) and `under` (contexts shorter
than the available material, reported only where no floor is configured — with a floor, a short context is
the policy working and the recall columns already price it).

**C. Per category** and **D. Per language** — the two tables that would have rejected symmetric RRF, and the
two that catch a change which helps English and hurts Polish.

Cost figures that matter — cold load, query-embed p50/p95, peak RSS, indexing throughput — are **not here**,
because they cannot be measured honestly off-device. The iOS Simulator is explicitly excluded: it produces
incorrect Nomic embeddings on its synthetic Metal device and runs the CPU backend, so both its numbers and
its rankings are wrong. Those figures come from the Expert memory card on real hardware.

---

## The trivial-pair check

A community GGUF is an instrument of unknown calibration. `multilingual-e5-small`'s Q4_K_M quant scored an
nDCG@8 of 0.187 — a plausible-looking number — while ranking a diesel-oil-filter passage (0.9367) above the
correct magnesium one (0.9303) for a magnesium query. Nothing in the retrieval metrics alone said the artifact
was broken rather than the model being weak; only inspecting one trivial pair by hand did.

`embed` now runs that check itself, automatically, before it writes anything. Three fixed pairs — a German
paraphrase, a German exact-value question, and an English one so a German-only failure cannot hide — are
embedded through the model's own contract (`SanityPair.all` in `SanityCheck.swift`) and each must rank its
correct document above an unrelated one. Any failure aborts the run with `exit(1)` and **no vectors file is
written**, so a broken artifact cannot silently reach `score` and produce a comparison-table row.
`--skip-sanity-check` overrides this for deliberately debugging a model already known to be broken; using it
prints a loud warning and the run must not be quoted as a result.

`SanityCheckTests` pins the checking logic itself (`SanityCheck.evaluate`) on hand-built vectors — no model, no
network — the same split as everywhere else pure scoring is tested in this tool. What it cannot test is
whether a NEW model's embeddings are healthy; only a real `embed` run answers that, which is why the check
lives inside `embed` rather than only in `swift test`.

## Where the bench is not the app

Two known gaps, both in `embed`:

- **The app truncates a prompt at 384 tokens** (`NomicEmbeddingContract.maximumInputTokens`, enforced with
  the model's own tokenizer); `embed` does not. It does not bite for word-chunked text, but a
  240-character unsegmented chunk sits right at that boundary by design — the chunker's own comment says
  240 characters "stay clear of the provider's 384-token ceiling even at the worst case of more than one
  token per character", and 240 × 1.6 is 384. So for Chinese chunks the app may truncate where the bench
  does not, and a model that handles those chunks well could look very slightly better here than it is.
- **`-c`/`-b`/`-ub` are scaled to the batch**, not pinned at the app's 512. They are a throughput knob:
  n_batch counts the total tokens across the batch, and n_batch may not exceed n_ctx. Both halves of that
  were got wrong here in turn — see the comment in `Embed.swift` — and neither changes the window a single
  prompt gets, because every chunk is far below 512 tokens by construction.

A third gap is deliberate, not a defect: the bench applies no rate, thermal or memory pressure, and it
runs on a Mac. Nothing here is a device measurement.

---

## Tuning, holdout, and what the intervals say

Around a dozen settings have been chosen by looking at scores on this corpus. `main` is therefore split into a
**development** half (79 queries) and a **frozen holdout** (41), by whole scenarios — the connected components
of the query-document graph, so no document is graded from both sides. The assignment is committed
(`Corpus/split.json`); every reading of the holdout is appended to `Corpus/holdout-access.log`.

`main` grew from 120 queries to 384, which is what the holdout needed: a third of 120 is 41 frozen queries,
enough to catch a large regression and nothing else. It now holds 134, and the paired intervals on it are worth
reading. Growth was authored per theme against the documents rather than in bulk — judgments are the handwork,
and a judgment written without reading the document it points at is worse than no query.

Two things the growth changed on its own. **Single-target queries fell from 50% to 33%** through an additive
audit: supporting evidence was added only where it genuinely exists, never to hit a ratio, because inventing
relevance is a worse defect than a query that legitimately has one answer. And the questions got
**cross-theme** — "what changed this training year", "what came together in the bad sleep week" — which is the
realistic shape and turned out to have a structural consequence for the split, below.

**Growth extends that assignment, it does not recompute it.** Recomputing after every batch of new queries is
the obvious implementation and it quietly destroys what the split is for: a query that sat in the holdout while
a dozen settings were tuned against dev has been kept honest, and moving it to dev spends that; moving a
tuned-on dev query into the holdout contaminates the holdout with material already used for decisions. So
`memorybench split` extends by default — existing queries never move, only genuinely new scenarios are placed —
and `--regenerate` is the deliberate, almost-never-right escape hatch.

That leaves exactly one way growth can still leak, and it is not obvious: a **new** query whose graded documents
span a dev scenario and a holdout scenario merges two components that were kept apart on purpose. There is no
correct side for the result, so it is a hard error naming the query to regrade rather than a heuristic that
picks one. Adding the 20 crosslingual queries triggered none of these, and left all 120 prior assignments
byte-identical.

### What a scenario is had to change, and the corpus is what forced it

A scenario was the connected component of the query-document graph over **any** positive judgment. Growing to
384 queries destroyed that definition outright:

| edges from | components | largest holds |
|---|---|---|
| any positive judgment (≥1) | 62 | **73% of all queries** |
| answer or strongly relevant (≥2) | 130 | 17% |
| direct answer only (=3) | 220 | 2% |

This is structural, not an authoring slip. Questions people actually ask combine evidence across themes, and one
long conversation summary that mentions shoes, knees, supplements and sleep wires the whole graph together. At
grade 1 the corpus is a single blob and **there is no holdout to be had at all**. The choice was between a
stronger guarantee about a corpus that no longer resembles anyone's memories, and a weaker guarantee about a
realistic one.

So a scenario is now documents sharing an **answer or strongly relevant evidence** (grade ≥2), and the guarantee
is stated precisely: no shared **answer** across the halves, not no shared evidence. The residual is measured
rather than footnoted — `memorybench split` prints it every time, currently **46 documents (19%) carry grade-1
support on both sides**. A holdout whose evidence overlaps dev heavily is weaker than one whose overlap is a
handful of lines, and without the number the difference is invisible.

Changing the definition cost the freeze once: six scenarios spanned both sides under the new grouping, so the
assignment could not be extended across the change. It was regenerated exactly once, and because a regeneration
matters more to the holdout's meaning than any reading of it, `--regenerate --write` **refuses without a reason**
and appends a `REGENERATED` line to `Corpus/holdout-access.log` beside the two readings. The previous holdout's
two readings are in that log and neither was used to choose anything.

One consequence worth stating plainly: the committed split is now deliberately **not** what a from-scratch
computation produces, so the test that used to assert exactly that has been inverted rather than deleted — it
now pins that extension is a fixed point, and warns if the committed file ever matches a fresh computation
again, because that would mean the freeze was thrown away.

Every comparison now carries a **paired** bootstrap interval. Paired matters: both variants answer the same
questions, so what limits resolution is the variance of the *differences*, not of the scores. A small but
consistent gain is resolvable even when scores swing across the whole range; a gain that changes sign per
query is not, however good its mean looks.

> **Superseded.** The two subsections that follow were measured on the 120-query `main`, the 0–2 grade scale and
> a 79/41 split. They are kept because the *method* they introduced is still the method, and because one of them
> records a reversal that later turned out to be noise — which is itself the argument for intervals. The current
> figures are under [Results](#results). Do not carry a number across that line.

### On development, several effects are solid

Against `today (+rescue)`, 72 scored queries:

| Variant | Δ nDCG@8 | 95% CI | verdict |
|---|---|---|---|
| `semantic-only` | +0.013 | [+0.003, +0.026] | **better** — the shipped rescue arm is a measurable loss |
| `+IDF rescue` | +0.020 | [−0.002, +0.044] | indistinguishable |
| `+recency` | +0.058 | [+0.030, +0.088] | **better** |
| `+kind prior` | +0.071 | [+0.039, +0.104] | **better** |
| `+floor` | +0.070 | [+0.036, +0.103] | **better** |
| `+quotas` | +0.021 | [−0.020, +0.060] | indistinguishable |
| `+MMR` | −0.037 | [−0.090, +0.015] | indistinguishable |
| `top×0.7 + gate` | +0.046 | [+0.014, +0.077] | **better** |
| `top×0.9 + gate` | −0.055 | [−0.103, −0.010] | **worse** |
| Oracle K=32 | +0.288 | [+0.230, +0.352] | ceiling |

Two corrections fall straight out of this. **The kind prior was dropped earlier on a −0.005 reading from a
pooled measurement; on dev it is the single strongest addition** at +0.071 and clearly resolved. And **MMR and
quotas were described as costing 0.017 and 0.020 — neither is resolvable**, so the earlier statements were
firmer than the data supported in both directions.

### On the holdout, nothing is resolvable — and the effects shrink

Read once, for statistical power rather than for choosing anything (logged as such). 38 scored queries:

| Variant | Δ on dev | Δ on holdout | holdout 95% CI |
|---|---|---|---|
| `+recency` | +0.058 | **+0.014** | [−0.037, +0.066] |
| `+kind prior` | +0.071 | **+0.009** | [−0.042, +0.057] |
| `+floor` | +0.070 | **−0.014** | [−0.074, +0.042] |
| `recommended` | +0.057 | **+0.003** | [−0.052, +0.056] |

Every point estimate collapses toward zero and not one interval excludes it. That is the signature of
overfitting — but it is **not proof of it**, and the difference matters: the holdout's intervals are wide
enough (±0.05) to contain the dev estimates too, so the two halves are not in statistical conflict. What is
real is that **no effect measured here has been confirmed on data it was not chosen on**, and that the pattern
of every variant shrinking at once is a warning rather than a coincidence.

The practical conclusion is about the corpus, not the architecture: at 41 holdout queries the frozen half can
catch a large regression and confirm nothing. It becomes decisive only when `main` grows. Until then the dev
numbers are the best available evidence and should be read as provisional — including the two corrections
above.

Note also that an earlier estimate of ±0.11 for the holdout's resolution was too pessimistic: it modelled the
variance of scores instead of the variance of paired differences. The measured width is about ±0.05.

## Results

### Current measurement: 384 queries, 0–3 scale, dev only, real Nomic vectors

Taken 2026-08-19 after the corpus grew, with `llama-embedding` from the pinned `b9623` over the bundled
`nomic-embed-text-v2-moe.Q4_K_M`. All three trivial pairs passed (+0.72/+0.58/+0.51 margins). Scope is the
**development** half of `main` — 233 scored queries — and the paired-bootstrap baseline is the **shipped**
configuration, `today (+rescue)`.

| variant | nDCG@8 | Δ vs shipped | 95% CI | verdict |
|---|---|---|---|---|
| semantic-only (drop the rescue arm) | 0.727 | +0.008 | [+0.004, +0.013] | **better** |
| today (+rescue) — shipped | 0.719 | — | — | baseline |
| + IDF rescue | **0.746** | **+0.027** | [+0.015, +0.040] | **better** |
| + recency | 0.729 | +0.010 | [−0.012, +0.030] | indistinguishable |
| + kind prior | 0.724 | +0.005 | [−0.021, +0.029] | indistinguishable |
| + floor | 0.721 | +0.002 | [−0.024, +0.027] | indistinguishable |
| + quotas | 0.701 | −0.018 | [−0.046, +0.009] | indistinguishable |
| + MMR | 0.679 | −0.040 | [−0.068, −0.012] | **worse** |
| absolute floor 0.35 | 0.669 | −0.050 | [−0.079, −0.021] | **worse** |
| absolute floor 0.40 | 0.613 | −0.106 | [−0.147, −0.067] | **worse** |
| relative floor top×0.9 + gate | 0.641 | −0.078 | [−0.106, −0.049] | **worse** |
| relative floor top×0.7 + gate | 0.724 | +0.004 | [−0.018, +0.025] | indistinguishable |
| **ORACLE, same 32 candidates** | **0.954** | **+0.235** | [+0.201, +0.270] | ceiling |
| ORACLE, K=128 candidates | 0.995 | +0.276 | [+0.238, +0.314] | ceiling |

**What holds.** The shipped rescue arm is a small but now *resolvable* loss — third independent confirmation of
P5 — and replacing it with an IDF-weighted arm carrying numeric tokens is the only feature on the ladder that
wins outside its interval (+0.027). `negation` 0.718 → 0.783 and `recency` 0.581 → 0.647 are where it earns it.

**What this overturns.** Three earlier conclusions do not survive a realistic index:

- **Recency is not confirmed, and it does not win its own category.** It read as "real and targeted" before
  (+0.009 overall, `temporal` 0.681 → 0.785). Here it is +0.010 [−0.012, +0.030], and on the `recency` category
  it scores 0.634 against the IDF arm's 0.647 — adding the recency term makes the recency cases *worse*. The
  earlier result came from a 24-document-dominated pooled average.
- **The kind prior is unresolvable again.** It had been dropped at −0.005, then reinstated as "the strongest
  single addition" at +0.071 [+0.039, +0.104] on the 79-query dev half. At 233 queries it is +0.005
  [−0.021, +0.029]. That reversal was itself noise, and this is the second time this feature has moved with the
  measurement rather than with the code.
- **The absolute floor is not the good trade it looked like.** It was calibrated at 0.35 on the old corpus with
  relevant p25 0.395 against best-irrelevant p95 0.396 — clean separation. On dev of the grown corpus the
  distributions **overlap heavily**: relevant p25 0.397, best-irrelevant *median* 0.418. Any threshold that
  silences the median unanswerable query cuts below a quarter of the true hits, and the measurement agrees:
  floor 0.35 costs −0.050 nDCG and still leaks 2.35 lines per unanswerable question (it took them to 0.33 on the
  old corpus). The mechanism is plain — in a denser index something always looks moderately similar.

**The largest finding is the ceiling.** Reordering the *same 32 candidates* perfectly is worth **+0.235** nDCG@8
[+0.201, +0.270] — an order of magnitude more than every feature on the ladder combined. Deepening to 128
candidates adds only 0.041 on top of that, so the candidate pool is not the binding constraint; the ranking is.

This is the number that reopens the reranker question, which was closed on the reasoning that recall was
saturated (R@1 86%, R@3 96.7% on the old measurement). On dev of the grown corpus R@1 is **0.368** against an
oracle 0.532. That earlier saturation was a property of a 25-candidates-per-query index, not of the problem. It
does not by itself justify shipping a cross-encoder — the latency argument in section 4 stands, and the scale
measurement shows the scan is not what loses the race, so the second model's load and forward passes would be —
but "too little headroom" is no longer a true statement.

> Everything in the subsections below predates this: **0–2 grade scale, no crosslingual category, 120-query
> `main`, and metrics pooled across ten 24-document locale sets.** They are kept as the record of how the
> measurement got more honest, not as current results. Do not compare a figure across that line.

### The model question is settled, and harrier is the worst of the three

| Configuration | nomic (shipped, 256d) | embeddinggemma-300m (256d) | harrier-oss-v1-0.6b (1024d) |
|---|---|---|---|
| `semantic-only` | **0.744** | 0.740 | 0.677 |
| `today (+rescue)` | **0.735** | 0.732 | 0.668 |
| `+IDF rescue` | 0.751 | **0.760** | 0.696 |
| `+recency` | 0.778 | **0.792** | 0.730 |
| Oracle ceiling K=32 | 0.976 | 0.982 | 0.936 |
| Bundle | 328 MB | **278 MB** | 397 MB |
| Index bytes | **0.5 kB/chunk** | **0.5 kB/chunk** | 2 kB/chunk |

harrier's history in this file is a lesson in scope. It read 0.850 on the first corpus (ten translations
pooled), 0.806 on the second (pooled across index sizes), and **0.677 on the realistic index** — where it is
now last by 0.067. Its pooled figures were carried by the easy locale sets, where its language separation
looked like retrieval quality.

Nomic and EmbeddingGemma are within 0.004 raw and 0.014 with recency, which is noise on 110 questions. So the
shipped model sits at the top of the pack, the 397 MB bundle and 4× index bytes buy a **regression**, and
nothing here justifies a change. The one non-noise difference from earlier still stands: EmbeddingGemma is far
better on `synonym`, Nomic better on `recency`.

### What does help, in order

Measured on `main`, against `today (+rescue)` at 0.735:

| Change | nDCG@8 | Δ | Costs |
|---|---|---|---|
| `today + IDF/numeric rescue` | 0.735 | **±0.000** | nothing, and it buys nothing |
| `+IDF rescue` (inside the new selection) | 0.751 | +0.016 | nothing |
| `+recency` | 0.778 | **+0.043** | nothing; the column is already in the index |
| `RERANK@8 +recency` | to be re-measured | — | a second model |
| Oracle ceiling K=32 | 0.976 | +0.241 | — |

Two things changed with the scope fix. **Recency is worth nearly twice what was reported** — +0.043 on the real
index against +0.023 pooled — and the **reorderable headroom is 0.241**, not 0.194. The case for the ranking
work is stronger on the realistic index, not weaker.

The first row is the one that cancelled a planned change. Improving the lexical arm **inside the shipped
`fuse`** — IDF weighting, numeric and date tokens, the entire declared purpose of the rescue slots — moves
every retrieval metric by exactly nothing, on either scope. `fuse` gives that arm two tail slots and only for
sources the semantic arm never returned at all, and the semantic top-32 already holds nearly everything
relevant, so no amount of better ranking *within* unused candidates can surface. The rescue MECHANISM is the
bottleneck, not the lexical scoring — and the same tokeniser work is worth +0.016 one row down, where the
lexical signal enters as an additive bonus across all candidates. It is not an independent cheap win.

### The reranker and the floor

The reranker and floor tables below were measured **pooled**, before the scope split, and are kept because
their internal comparisons were all made against each other under identical conditions — but their absolute
values carry the same ~0.06 optimism as the old model table, and they need re-running on `main`. The
directional findings that survive scope are: depth 8 beats 16 beats 32, the reranker and recency are
complementary rather than competing, and a relative floor dominates an absolute one.

### The reranker needs fewer candidates than expected

| Depth | nDCG@8 | +recency | Pairs scored per query |
|---|---|---|---|
| `RERANK@8` | 0.846 | **0.860** | 8 |
| `RERANK@16` | 0.840 | 0.852 | 16 |
| `RERANK@32` | 0.832 | 0.843 | 32 |

Eight is not merely good enough, it is the **best** of the three — deeper candidate sets make it worse, which
is what a reranker looks like when the extra candidates it can promote are mostly noise. That is the cheap
answer winning on quality as well as cost: `RERANK@8` alone runs at **p50 37 ms, p95 55 ms** on a Mac with
Metal. Assume two to four times that on a phone, against a 2.5-second budget the embedder already loses
sometimes, and remember it needs a second model resident (jina-reranker-v2-base-multilingual is 222 MB at
Q4_K_M, 305 MB at Q8_0 — and Q4_K_M was checked once, separately from Q8_0, before the language artifact below was found. A quantisation-specific re-check is cheap now that `embed` runs one automatically; see "The trivial-pair check" below.

### The floor should be relative, not absolute

| Variant | nDCG@8 | P@8 | lines emitted for an unanswerable question |
|---|---|---|---|
| no floor | 0.804 | 0.178 | 8.00 |
| absolute ≥ 0.35 | 0.768 | 0.411 | 0.70 |
| `top×0.7` + gate | **0.776** | **0.499** | 1.73 |
| `top×0.8` + gate | 0.754 | 0.627 | 1.57 |
| `top×0.9` + gate | 0.713 | 0.742 | 0.88 |

`top×0.7` **dominates** the absolute floor — higher nDCG *and* higher precision — because "clearly worse than
the best thing we found" means the same thing on every query, while one absolute number cannot suit both a
well-answered question and a weakly-answered one. The absolute threshold keeps one job worth having:
refusing to answer at all when even the best hit is poor. Note the calibration is unfinished — the gate at
0.35 lets more through than the absolute floor did (1.73 lines against 0.70), so gate and ratio have to be
tuned together, and the same applies per model: harrier's relevant p25 (0.590) sits *below* its
best-of-unanswerable p95 (0.627), so no absolute threshold separates them at all.

A probability threshold on the reranker's own score is not the answer either, at least not at 0.5: it lifts
P@8 to 0.845 and takes unanswerable output to zero, but nDCG collapses to 0.435 because it discards most true
positives. If it is used at all it belongs far lower.

---

## Pareto instead of a winner column

Every model comparison so far ended in a ranking, and a ranking hides the trade that decides the question.
harrier scored best on retrieval while storing four times the index and shipping a larger file; EmbeddingGemma
scored slightly lower at a quarter of the index. As a league table the first one simply "wins".

```bash
swift run memorybench pareto --corpus Corpus --vectors out/nomic-256 --vectors out/gemma-256 --vectors out/harrier-1024
```

prints quality beside index bytes, model size and embed time, and marks the **front**: a row is dominated only
when another is at least as good on *every* axis and strictly better on one. No axis is weighted into a score,
because a weight is a decision disguised as arithmetic — choose bytes-per-point and the ranking follows from the
choice rather than the measurement.

Two rules the tests pin. An unrecorded cost is **unknown, not zero**: `modelFileBytes` is optional so vector sets
written before it existed still load, and a row with no size cannot dominate one whose size is known — otherwise
an old run would sweep the front by being unmeasurable. And a row with no quality number is not on the front at
all: a model that failed to load is not a cheap model.

The `trained` column says whether the stored dimension is a documented Matryoshka stage or an untrained
truncation. It is not a cost. It is a different contract, and it is in the table because comparing an untrained
truncation against a trained stage measures the truncation — which is exactly what harrier@256 versus
EmbeddingGemma@256 turned out to be.

`embed --synthetic --dims N --out <dir>` writes a vectors set without a model, so `score`, `scale` and `pareto`
can all be exercised where no GGUF exists. Such a file names itself `synthetic-hashed-tokens (NOT a model)` and
every report prints the model name it came from, which is what keeps it from being mistaken for a measurement.

## Floors are calibrated on dev only, per model

Section A of the report used to pool every query in the corpus — and that is the worst place in the report for
that mistake, because section A is where the threshold is **chosen**. A pooled floor is fitted partly on the
frozen holdout, leaking precisely what the split exists to prevent, and partly on ten 24-document locale sets
whose cosines come from a much easier problem. It is now split by scope, the dev row is the only one a floor may
come from, the holdout row is withheld unless `--holdout <reason>` is passed, and the locale row is labelled as a
different distribution.

The separation matters empirically, not just in principle: on the same run the dev best-of-irrelevant median sits
at 0.387 while the locale sets' sits at 0.217. A single threshold drawn from the pool would land between two
different problems.

Absolute cosines are also not comparable **between** models — Nomic's relevant-hit p25 was 0.405 where harrier's
was 0.590 on the same corpus — so the calibration is per model as well as per scope. A floor calibrated on one
model and applied to another measures the mismatch.

One limit worth stating: the noise side of the calibration rests on the `unanswerable` queries, of which dev holds
17. That is enough to see the distributions separate and not enough to place a threshold to two decimals.

## Scale: what a lived-in index costs

`main` holds 272 documents. A real one is bigger — fifty conversations, a journal running for years — and two
questions follow that a 272-document index cannot answer: is K=32 still enough when the pool is twenty times
larger, and how does the full-table scan grow.

```bash
swift run -c release memorybench scale --corpus Corpus --synthetic --tiers 1000,5000,20000
```

The plan called for committed `scale-1k` and `scale-5k` indexes of generated distractors, with a test forbidding
any judgment from pointing at them. Generating at run time is strictly safer at the same cost: generated text
cannot leak into a quality claim if it never exists in the corpus, so there is no rule to enforce and none to
forget. It also keeps six thousand machine-written sentences out of the repository and out of every model's
embedding run.

The filler is vectors. Each one is a real corpus vector pushed away by gaussian noise, calibrated so the
resulting cosine spread matches the corpus's own document-to-document spread. **The calibration is the entire
design**, and getting it wrong is not a small error: a first version omitted the dimension factor in
`σ = √((1/c² − 1)/d)`, which at 256 dimensions is sixteen times too much noise — asking for cosine 0.8 produced
0.088 and every filler vector came out near-orthogonal to the whole corpus. Orthogonal filler sits below every
real document, so crowding becomes invisible and the tier cheerfully reports that scale is free. That is the exact
failure the calibration exists to prevent, a full release measurement had already been taken with it, and
`ScaleTests` caught it on the first run.

| documents | index | scan p50 | scan p95 | best hit within 8 / 32 / 128 | doc-doc cos med/p95 |
|---|---|---|---|---|---|
| 1 000 | 832 KB | 6.06 ms | 6.16 ms | 0.54 / 0.77 / 0.84 | 0.00 / 0.29 |
| 5 000 | 3 992 KB | 30.66 ms | 31.08 ms | 0.53 / 0.65 / 0.80 | 0.00 / 0.29 |
| 20 000 | 15 844 KB | 133.68 ms | 137.06 ms | 0.51 / 0.58 / 0.70 | 0.00 / 0.29 |

**What is valid here and what is not.** The scan decodes and dots every row regardless of what the vectors
contain, so the timings are real: the cost is linear (20× rows → 22.1× scan) and 20 000 chunks cost ~134 ms per
query on an M-series Mac in a release build. Against the app's 2.5-second race budget the scan is not the binding
constraint even at that size — the model load and the query embedding are — which is worth knowing before
optimising `cosine` into a dot product. An iPhone will be several times slower; the device measurement decides.

The K columns are **not** valid from this run, and the last column is why it is visible. `--synthetic` vectors are
hashed token bags whose own document-to-document cosine median is 0.00, so calibrated filler is near-orthogonal
because the corpus is, and the tier says nothing about crowding. With real vectors that column rises well above
zero and the K figures become meaningful. Even then they are a **floor** on real difficulty rather than an
estimate: noise reproduces the geometry of a bigger index, never its semantics, and a real distractor is
confusable in ways only text carries — the same supplement at another dose, the other knee.

Two build notes, both learned the hard way. Timings need `-c release`: the first debug run reported 76 ms per scan
at 1 000 documents, which reads as a finding about the race budget and is an artefact of unoptimised Float16
decoding, so the timing columns now refuse to print from a debug build. And the tier is file-backed rather than
in-memory, because `byteSize()` returns 0 for an in-memory store — the index-size column was silently empty — and
because the app searches a file.

## The two mirrors, and the fixture that keeps them honest

`MirroredTokeniser` and `MirroredChunker` are transcriptions of `CoachMemory.tokens` and
`CoachSemanticMemory.chunkTexts`, which live in the `Strand` app target and cannot be reached from a SwiftPM
executable. `Tools/SleepBench` carries the same kind of mirror for the same kind of reason.

Transcribing line for line and pinning each copy with its own tests is not enough, and it is worth being
precise about why: two implementations with two passing test suites can drift apart while every check stays
green, because nothing compares them to each other. The failure mode is silent and it is bad — the benchmark
would keep reporting numbers for a pipeline the app no longer runs, and every conclusion drawn from it would
be about a system that does not ship.

`Fixtures/tokeniser-golden.json` closes that. Fifteen inputs with their expected tokens and chunks, read by
**both** sides:

- `Tests/memorybenchTests/GoldenFixtureTests.swift` — against `MirroredTokeniser` / `MirroredChunker`
- `StrandTests/CoachTokeniserGoldenTests.swift` — against `CoachMemory.tokens` /
  `CoachSemanticMemory.chunkTexts`

A one-sided change now breaks one of the two suites on the next run. The cases are chosen for the paths that
actually differ rather than for coverage: CJK bigrams, a single ideograph, mixed script in one run, an ISO
date, sub-three-character runs, unsegmented text long enough to force the character chunker, empty and
punctuation-only input. Verified by perturbing the fixture and confirming both suites fail, which is the only
way to know a golden test is wired up at all.

```bash
swift run memorybench golden --fixtures Fixtures
```

checks the fixture; `--write` regenerates it. **Order matters when it fails**: find out which side is wrong
and fix that, then regenerate. Regenerating first makes the red go away and destroys the only signal.

One asymmetry to know about, because it is the wrong way round. `swift-packages.yml` runs the bench half on
every change, but the app half lives in `StrandTests` and only runs under `xcodebuild … test` on macOS, which
no default workflow does. So the direction most likely to drift — somebody edits `CoachMemory.tokens` for a
good reason and never opens this directory — is the direction default CI does **not** catch. Until the
tokeniser moves into a package, editing either function means running the macOS suite by hand:

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:StrandTests/CoachTokeniserGoldenTests
```

The expected values are produced by this tool rather than by the app, for the mundane reason that the app
cannot be run from here. That makes `StrandTests` the real check — a bad transcription fails there on the
first run, which is the detection working, not a gap in it.

The honest fix is still to move the tokeniser into `Packages/SemanticMemory` so there is one copy. That belongs
to the change which introduces IDF weighting — it has to touch this code anyway — not to a benchmark whose
whole point is to change no production behaviour. Until then the fixture is what makes one copy safe.

One thing the transcription surfaced: the stopword list covers `en de es fr it pt ru` and deliberately leaves
CJK to the bigram path, but **`pl` is missing entirely** despite being a shipped locale, and
`CoachMemoryRankingTests.testStopwordsCoverTheShippedLanguages` only probes seven of the ten. The mirror
copies the list as it is rather than quietly fixing it, so the corpus can measure what that costs.
