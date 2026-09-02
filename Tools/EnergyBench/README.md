# EnergyBench

Reproducible release gate for the WHOOP v4 energy model. It evaluates only rows explicitly marked
`holdout`; development rows can coexist in the same file but never contribute to a pass.

The ground-truth column must come from indirect calorimetry. Apple Watch is the required secondary
comparator used for non-inferiority, not training truth.

```text
cohort,participant_id,context,ground_truth_kcal,noop_kcal,apple_watch_kcal,noop_low_kcal,noop_high_kcal
holdout,p01,unresolvedElevatedHR,31.2,32.0,31.5,27.0,37.0
```

Allowed contexts are the `EnergyContext` raw values. Run from this directory:

```sh
swift run energybench /path/to/validation.csv
```

The command prints a JSON report, exits `0` only when the pre-registered gate passes, and exits `2`
when the dataset is valid but the release remains blocked. The gate requires at least 20 held-out
participants, 20 samples in each required context, ≤15% overall WAPE, ≤10% absolute bias, ≤25% WAPE
per required context, NOOP no more than three percentage points worse than Apple Watch, and calibrated
uncertainty-interval coverage of 80–99%.
