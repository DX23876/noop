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

`embed` asks for the raw pooled vector (`--embd-normalize -1`) and then applies the app's own
`SemanticVector.normalizedTruncated` — truncate to the stored width, then renormalise, exactly as
`NomicTextEmbeddingProvider.embedOne` does — before encoding to Float16. So the score includes the
quantisation and Matryoshka loss the device actually has.

---

## What the corpus is, and what it is not

520 documents / 360 queries, organised into **indexes** rather than languages, because an index is what a
question is actually asked against: one person's own memories.

| Index | Documents | Queries | Languages | Job |
|---|---|---|---|---|
| `main` | 272 | 120 | de + en (~1 in 10) | every ranking and reranking question |
| `locale-*` × 10 | 24–28 each | 24 each | one each | does this model work in this language at all |

`main` is shaped like a real index and sized so that **ranking, not recall, decides** — the previous version
left about 25 candidates per query, which made every ranking change unmeasurable. The near-misses are the
point of the size: three ferritin values on three dates, two knees across five activities, two magnesium
forms and two timings, two sleep goals, two caffeine cut-offs, three training frequencies, two Achilles
tendons, five recovery mornings, declined-versus-accepted recommendations. Plus curated facts next to raw
chat turns, one-liners next to a summary long enough to chunk, and a thread big enough to flood a context.

Eight categories, scored separately, because a change that wins one and loses another is not an improvement:

| Category | What it is for |
|---|---|
| `synonym` | A different word for the same thing — and the weakest category in practice. |
| `paraphrase` | Same vocabulary, different sentence. |
| `negation` | The question turns on a NOT, and the positive counterpart is graded 0 so a model that ignores the negation cannot score. |
| `numeric` | A name, a date, a dose. |
| `recency` | Two memories contradict and the **newer** is right. |
| `near-miss` | Almost the same sentence, only one answers — a different knee, dose, time of day. |
| `terse` | Three or four words, the way people type. |
| `unanswerable` | Nothing answers it. Target: **zero** lines. |

Judgments are graded 0/1/2, and `0` is written down rather than omitted: an omitted judgment and a
judged-irrelevant one score the same, but writing the zero records that the case was considered.
`CorpusTests` enforce the design, not the syntax — every `recency` case really grades the newer document
above an older distractor, every `numeric` case turns on a token with a digit, every `near-miss` case carries
a deliberately rejected sibling, `terse` questions really are short, and `main` really is bilingual without
holding two translations of one sentence. Those tests caught three authoring gaps on their first run.

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

## Results

**Scope matters, and getting it wrong cost every number in this file once already.** The corpus holds 320
answerable queries: 110 on the `main` index (272 documents, the realistic problem) and 210 spread over ten
24-document locale sets. Averaging all of them makes two thirds of every headline come from a problem too easy
to separate anything — which is what the earlier tables did, and they ran about 0.06 optimistic as a result.

`score` now reports three scopes explicitly: **`main`** (the headline, where ranking is decided), **locale
sets** (a language smoke test, never a ranking measurement) and **pooled** (labelled as mixed difficulty, kept
only so the older figures stay reproducible). `ScorePipelineTests` asserts every variant reports all three and
that the pooled mean lies between its parts, so the mistake cannot be made silently again.

Everything below is the **`main` scope** unless it says otherwise.

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
Q4_K_M, 305 MB at Q8_0 — and Q4_K_M was not verified, see the trivial-pair rule below).

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

## Known debt: two mirrors

`MirroredTokeniser` and `MirroredChunker` are transcriptions of `CoachMemory.tokens` and
`CoachSemanticMemory.chunks`, which live in the `Strand` app target and cannot be reached from a SwiftPM
executable. `Tools/SleepBench` carries the same kind of mirror for the same kind of reason, and it is handled
the same way: transcribed line for line, with `MirrorTests` pinning the properties that must not drift.

The honest fix is to move the tokeniser into `Packages/SemanticMemory` so there is one copy. That belongs to
the change which introduces IDF weighting — it has to touch this code anyway — not to a benchmark whose whole
point is to change no production behaviour.

One thing the transcription surfaced: the stopword list covers `en de es fr it pt ru` and deliberately leaves
CJK to the bigram path, but **`pl` is missing entirely** despite being a shipped locale, and
`CoachMemoryRankingTests.testStopwordsCoverTheShippedLanguages` only probes seven of the ten. The mirror
copies the list as it is rather than quietly fixing it, so the corpus can measure what that costs.
