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

248 documents / 242 queries across all ten shipped locales (`de en es fr it pl pt-PT ru zh-Hans zh-Hant`).
It is shaped like the real index rather than like a clean evaluation set: curated memory facts next to raw
chat turns, one-line notes next to a summary long enough to chunk, priorities and ages spread the way the app
spreads them, and a five-message sleep thread per language whose every message is a plausible answer to one
question.

Four query categories, each scored separately, because a variant that wins one and loses another is not an
improvement and a single average hides the trade:

| Category | What it is for |
|---|---|
| `paraphrase` | Synonym, rephrasing, negation — the semantic arm's core competence. |
| `exact` | A name, a date, a number, a dose. What the two rescue slots were kept for. |
| `temporal` | Two documents contradict each other and the **newer** one is right. |
| `irrelevant` | Nothing answers this. The target is **zero** emitted lines. |

Crosslingual cases are ordinary queries whose graded documents sit in another language; they need no category
of their own, only a judgment pointing across.

Judgments are graded 0/1/2 so nDCG is computable, and `0` is written down rather than omitted — an omitted
judgment and a judged-irrelevant one score the same, but writing the zero records that the case was
considered. `CorpusTests` enforces the design, not just the syntax: every locale carries every category, every
`temporal` case really does grade the newer document above an older distractor, every `exact` case really does
turn on a token containing a digit, and every locale really does have a thread big enough to flood a context.

**It is smaller than the 600/300 that was planned.** 248/242 is what could be written at a quality worth
scoring; the shortfall is in query count per locale, not in category or locale coverage. Growing it is
additive — one more `<lang>.queries.json` entry at a time — and the shape to keep is above.

**What it cannot tell you.** It is synthetic, so it cannot capture how a particular person actually phrases
things, and it is small enough that a per-language cell rests on ~24 queries. Use the global and per-category
columns to decide, and treat a single per-language cell as a smoke signal rather than a verdict.

---

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

## The first run, for reference

Against the bundled `nomic-embed-text-v2-moe.Q4_K_M` at 256 dimensions, `llama-embedding` built from
`b9623` (2026-08-19). Embedding the whole corpus took 45 s on an M-series Mac; the index is 131 072 bytes.

```
variant                          nDCG@8   P@8   R@1   R@8  irrel. domin.
semantic-only                    0.611 0.114 0.423 0.704   8.00 0.643
today (+rescue)                  0.606 0.114 0.423 0.689   8.00 0.579
+IDF rescue (numeric tokens)     0.643 0.117 0.457 0.725   8.00 0.642
+recency                         0.652 0.117 0.467 0.723   8.00 0.725
+kind prior                      0.647 0.117 0.463 0.725   8.00 0.728
+floor 0.35                      0.630 0.118 0.463 0.688   0.33 0.745
+quotas                          0.616 0.215 0.463 0.668   0.27 0.476
+MMR                             0.609 0.216 0.463 0.655   0.27 0.477
recommended (IDF+recency+floor)  0.634 0.116 0.463 0.690   0.87 0.737
recommended, K=32                0.634 0.116 0.463 0.690   0.87 0.736
```

Three things this settled, none of which could be argued before:

- **The rescue arm as shipped is a small net loss** (0.606 against 0.611 semantic-only), and it loses most
  in `es`, `pl` and `zh-Hant`. Weighted by IDF and given a tokeniser that can see numbers and dates, the
  same arm becomes the biggest single gain in the ladder (+0.037, R@1 0.423 → 0.457, and it helps every
  one of the ten languages).
- **A floor is calibratable here.** Relevant hits sit at p25 = 0.395; the best hit of a question with no
  answer sits at p95 = 0.396. A floor at 0.35 cuts emitted lines for those questions from 8.00 to
  0.33–0.87 for about 0.018 nDCG.
- **Three plausible-sounding ideas do not survive contact**: the kind prior costs 0.005, MMR costs 0.017
  and buys no diversity beyond the quotas, and raising K from 32 to 128 changes literally nothing — even
  when re-tested at the end of the ladder, where rescoring could have made it bind.

One methodological wrinkle worth knowing before trusting a floor number: the score modulation is
multiplicative, so it is **not** floor-neutral. Shrinking scores by 20% is arithmetically the same as
raising the floor by 25% — visible above as `+floor` leaking 0.33 lines with the kind prior on and
`recommended` leaking 0.87 with it off. Calibrate the floor and the modulation weights together.

---

## CORRECTION: the numbers below were measured in a broken mode

Everything in the two sections that follow was measured with all ten locales in one index, and that mode
does not measure what it claims to. The corpus was built by translating one set of scenarios into ten
languages, so **every query has nine semantically correct answers that the judgments grade 0.** Measured
directly: for the German `Wie hoch war mein Ferritin am 2026-03-14?`, jina-reranker-v2 scored the Spanish
(+2.15), French (+2.12) and Italian (+2.10) versions of the same fact ABOVE the German one (+2.00). The
reranker was right; the judgments were wrong.

That artifact does not fall evenly. An embedder gets a free language cue — same-language text sits closer
in the space — while a multilingual cross-encoder deliberately erases exactly that cue, so the mixed mode
was largely measuring *how well a model separates languages* rather than how well it retrieves. A real
index holds one person's memories in the language or two they write in, never nine translations of their
own notes, so `score` now restricts candidates to the query's own language by default
(`--mixed-language-index` keeps the old behaviour).

Corrected, per-language, same corpus and same pinned runtime:

| Model | Dims | semantic-only | +IDF rescue | +recency | RERANK@16 | Oracle K=32 |
|---|---|---|---|---|---|---|
| nomic-embed-text-v2-moe (shipped) | 256 | 0.837 | 0.837 | 0.845 | **0.876** | 0.996 |
| google/embeddinggemma-300m | 256 | 0.852 | 0.858 | 0.851 | 0.870 | 0.999 |
| microsoft/harrier-oss-v1-0.6b | 1024 | **0.873** | 0.873 | 0.858 | 0.868 | 1.000 |

What changes, and it is most of the story:

- **The model gap collapses from +0.239 to +0.036.** The shipped model is 0.837 against harrier's 0.873, not
  0.611 against 0.850. Paying 4× index bytes and +69 MB of bundle for +0.036 is a very different proposition
  from paying it for +0.239.
- **A reranker helps, and the earlier argument against it was wrong.** The oracle ceiling at K=32 is
  0.996–1.000, so recall is essentially perfect and ranking is the entire bottleneck — the opposite of the
  "not enough headroom" reasoning this file used to carry. Measured, jina-reranker-v2-base-multilingual Q8_0
  adds +0.039 to Nomic, +0.018 to EmbeddingGemma and −0.005 to harrier: it compensates for a weaker first
  stage and has nothing to add to a strong one.
- **The three best configurations are indistinguishable**: Nomic + reranker 0.876, harrier alone 0.873,
  EmbeddingGemma + reranker 0.870. On 242 queries those are the same number.
- **The floor is still the one change with a large, unambiguous effect.** With it, EmbeddingGemma emits 0.03
  lines for a question nothing answers instead of 8.00, and P@8 rises from 0.166 to 0.591, for 0.055 nDCG.

Reranker cost, for the record: p50 67–87 ms and p95 94–120 ms for 15–20 pairs, on a Mac with Metal. A phone
should be assumed two to four times slower, against a 2.5-second budget the embedder already loses.

### And the corpus itself is the next thing to fix

Neither mode is realistic, which is the deeper finding. Mixed-language poisons the judgments; per-language
leaves roughly 25 documents per query's language, so the retrieval problem becomes far easier than a real
index of thousands of notes. The ten-locale spread bought locale coverage at the cost of index realism.

The shape to build instead: **one large single-language index** — 400+ documents with many near-miss
distractors — for every ranking and reranking measurement, plus the existing small per-locale sets used only
to answer "does this model work in this language at all". Until that exists, treat every absolute number
here as soft, and only compare rows measured in the same mode.

---

## The model comparison

Same corpus, same selection, same `llama-embedding` build, same truncate-renormalise-Float16 path. The
`semantic-only` baseline is quoted because it is independent of any selection change.

| Model | GGUF | Dims | Index | nDCG@8 | R@1 | R@8 | parap. | exact | temp. | Embed |
|---|---|---|---|---|---|---|---|---|---|---|
| nomic-embed-text-v2-moe (shipped) | 328 MB Q4_K_M | 256 | 131 k | 0.611 | 0.423 | 0.704 | 0.499 | 0.862 | 0.682 | 45.3 s |
| google/embeddinggemma-300m | **278 MB** q4_0-QAT | 256 | 131 k | 0.755 | 0.563 | 0.823 | 0.698 | 0.934 | 0.707 | **25.5 s** |
| microsoft/harrier-oss-v1-0.6b | 397 MB Q4_K_M | 1024 | 524 k | **0.850** | **0.637** | **0.929** | **0.803** | **0.993** | **0.816** | 36.8 s |
| harrier-oss-v1-0.6b **@256, untrained truncation** | 397 MB | 256 | 131 k | 0.725 | 0.496 | 0.846 | 0.628 | 0.931 | 0.803 | 36.8 s |

Both alternatives beat the incumbent clearly and in every language — EmbeddingGemma wins 9 of 10
(losing `zh-Hant` by 0.006), harrier all 10, and harrier is the most even of the three (0.791–0.921 per
language, against Nomic's 0.487–0.761). Both are also **faster** than the shipped model despite being
dense rather than MoE, which is the on-device case where a mixture of experts pays its cost without
collecting its benefit: all the weights stay resident, only the compute is sparse.

The last row is the one that decides between them. Truncating harrier to 256 costs **0.125 nDCG** and
inverts its floor separation (relevant p25 0.643 against best-of-irrelevant p95 0.685 — no usable
absolute threshold left). That is the difference between trained Matryoshka and extrapolation, and it
means **at equal index size EmbeddingGemma wins**: 0.755 against 0.725.

So the choice reduces to one question — are 4× index bytes acceptable? If yes, harrier-0.6b at its full
1024 is the best retrieval available here, under MIT, and still faster than what ships. If no,
EmbeddingGemma-300m gives the best result per byte with the smallest bundle, trained MRL at 256 and
official ggml-org quants, at the price of Gemma Terms instead of MIT. Keeping Nomic is the only option
no number here supports.

### Two candidates could not be measured, which is itself a result

- **harrier-oss-v1-270m does not load on the pinned `b9623`.** The only GGUF that exists is
  community-built and writes `tokenizer.ggml.suffix_token_id` as i32 where this runtime expects u32. Its
  architecture is supported; the artifact is not. The fair test is converting the HF weights with the
  pinned tag's own `convert_hf_to_gguf.py` — running it on a newer llama.cpp would measure a runtime the
  app does not ship.
- **The `multilingual-e5-small` community quant is broken, so there is no e5 number.** It scored 0.187,
  but the calibration came back inverted and every cosine sat above 0.89. Three lines settled it: for
  `query: Magnesium vor dem Schlafengehen`, the diesel-oil-filter passage scored 0.9367 and the magnesium
  passage 0.9303.

**Hence a rule this harness now follows: run a trivial-pair check before scoring any model.** A
community GGUF is an instrument of unknown calibration, and two of four candidates failed on it. The
check costs three invocations and it is the difference between measuring a model and reporting
quantisation damage as model quality. EmbeddingGemma passes it decisively (0.756 against 0.212);
harrier-0.6b passes it (0.489 against 0.324).

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
