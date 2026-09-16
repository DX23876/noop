# Muscle Fatigue

Muscle Fatigue answers: **How much estimated training stimulus may still remain for each muscle?** It is a recovery aid, not a measurement of tissue damage or readiness.

NOOP starts with completed working sets from the shared strength history. Primary muscles receive `1.0`, secondary muscles `0.5`; warm-ups and stabilizers are excluded. Recorded RPE or RIR and relative load may weight the stimulus. Missing effort remains visible in coverage rather than being presented as measured exertion.

Each contribution decays exponentially from the workout time. The time constant is the established NOOP default for that muscle, or a personal fit when sufficient soreness feedback exists. Work older than eight time constants is omitted because less than 0.04% remains. The displayed level is normalized against the wearer's typical session for that muscle.

Imported workouts contribute when their exercises can be mapped. Imports without effort still contribute with lower data quality. Colours describe low-to-high residual estimated stimulus; they do not establish recovery, soreness, overtraining, injury risk or whether another session is safe.

