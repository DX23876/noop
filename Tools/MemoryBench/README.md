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
