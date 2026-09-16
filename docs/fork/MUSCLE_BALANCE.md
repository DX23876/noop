# Muscle Balance

Muscle Balance answers: **How was resistance-training work distributed across muscles, compared with the wearer's own prior training?** It does not define an ideal physique or a universal push/pull ratio.

NOOP uses completed working sets from the canonical strength history, including native workouts and resolved imports. Warm-up sets and stabilizers do not contribute. Primary muscles receive a share of `1.0`; secondary muscles receive `0.5`. Each share is multiplied by the set's transparent stimulus estimate, including recorded RPE or RIR when available.

The current view covers 28 days. Once eight earlier weeks are available, each muscle's current share is compared with the median of its own weekly shares. Two median absolute deviations form the descriptive usual range, with a small floor for zero-variance histories. Before then the UI says that the baseline is growing.

Unmapped exercises and missing effort reduce coverage and are shown as data limitations; NOOP does not invent those values. Colours mean below, within or above the wearer's usual distribution. They do not diagnose imbalance, injury risk, posture, symmetry or exercise quality.

