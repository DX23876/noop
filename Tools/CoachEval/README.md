# CoachEval

The measuring instrument for the Coach's free-form analysis. The plan it serves, and the quality bar it
judges against, are in [`docs/fork/COACH_ANALYSIS_PLAN.md`](../../docs/fork/COACH_ANALYSIS_PLAN.md).

## What it measures

A model is asked questions about a **synthetic wearer**. It answers through the real `run_analysis` tool
from [`Packages/CoachAnalysis`](../../Packages/CoachAnalysis), and its answer is scored against a
reference that is computed **independently** of that tool (`Reference.swift`, plain code that shares
nothing with the executor but day arithmetic).

- **Cohort:** nine wearers, 400 days each, with realistic gaps. Five effects are injected at three sizes
  each, zero among them (sleep after evening workouts, HRV after alcohol, resting-HR drift, lagged
  strain → HRV coupling, weekend sleep), so a method has to track a varying input, not match one value.
- **Objective questions:** nine families (levels, counts, best and worst days, month-on-month,
  alcohol, evening workouts, weekend nights, trend, lagged correlation) — 278 questions, 30 of them in a
  fixed stratified smoke set. Questions whose answer would be ambiguous (a tie for the best day) are
  left out.
- **Scoring:** the expected number must appear within one rounding step of how the tool prints it; a
  day must appear in a common written form, never inside another date. Numbers are read with either
  decimal separator, and dates are removed before numbers are read.

## Why the numbers can be trusted

- `coach-eval oracle` runs every question's reference spec through the executor and scores the result.
  It must be 278/278: a failure means the reference and the executor disagree about what a question
  means, or that the spec language cannot express it.
- A **negative control** shifts every expected value well outside its tolerance and requires that
  nearly all then fail. It exists because a result holds many numbers (means, interval bounds, n) and
  a lenient scorer passes by coincidence. It found exactly that twice — dates read as numbers, and a
  tolerance loose enough to match interval bounds — and currently accepts 4 of 278 wrong values.

Both run in `swift test` and in CI (`swift-packages.yml`, tools job). Neither touches the network.

## Running a provider

```bash
cd Tools/CoachEval
export ANTHROPIC_API_KEY=…   # or OPENAI_API_KEY / GEMINI_API_KEY
swift run -c release coach-eval run --provider anthropic --model <model-id> --set smoke --lang de \
  --out Results/anthropic-smoke-de.json
swift run -c release coach-eval report Results/*.json
```

**A run calls the provider with your key and costs money.** The smoke set is 30 questions of two to four
tool rounds each; the full set is 278. Nothing runs this automatically. `Results/` is gitignored.

The report gives, per provider · model · language: objective accuracy against the ≥ 90 % bar, errors,
median tokens per question, questions answered without calling the tool, and how many refused specs the
model repaired.

## Not in yet

- **Open-ended questions and the cross-provider autorater** (SHARP: safety, helpfulness, accuracy,
  relevance, personalization), with the wearer's own ratings of about 40 answers to calibrate the rater.
- **A run against the wearer's own database.** It needs the dataset builder from phase 1, so the eval and
  the app assemble the analysis dataset through the same code.
