# EcgQTDB

Measures `EcgAnalysis` (Packages/StrandAnalytics) against the cardiologist annotations of the
[PhysioNet QT Database](https://physionet.org/content/qtdb/1.0.0/) (`q1c` files, ODC Attribution License).

For each of the 103 annotated records it takes a 30 s window around the annotated beats, both leads,
brings it to 100 Hz with the app's own `EcgResample`, runs `EcgAnalysis.analyze`, and compares PR, QRS
and QT with the median of the annotated beats in the window. Records are split into two halves (even and
odd in sorted order) so a change that helps only one half is visible.

```sh
Tools/EcgQTDB/run.sh
```

Columns: `n` measured windows, `bias` mean signed error, `med|e|` median absolute error, `ok` share within
25 ms (PR), 20 ms (QRS) and 30 ms (QT). The annotations are global (multi-lead) intervals; one lead
tends to measure QT a little shorter.

Results as of the trapezium T end and the wavelet P onset (2026-10-08):

| half | PR n, bias, med abs error | QRS | QT |
|---|---|---|---|
| A | 84, +5, 8 ms | 95, -11, 16 ms | 91, -8, 18 ms |
| B | 82, +14, 12 ms | 88, -10, 12 ms | 84, +14, 16 ms |
