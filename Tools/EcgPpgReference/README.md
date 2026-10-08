# Offline ECG / optical timing reference

Research instrumentation, not an app detector, medical measurement or rhythm classifier.
**Analysis migration required: no** — no production formula, stored value or source selection changes.

The app's `PpgHr` is a **v26 HR-only autocorrelation estimator**. WHOOP 5/MG HRV
uses band-reported `rrInterval` rows. R20 is not passed to an app beat detector.
This tool independently detects candidate optical pulses and compares them with
simultaneous R16 R peaks. It cannot validate the band's reported RR without those
separate observations. See [data path and capture plan](../../docs/fork/research/ecg-ppg-reference.md).

## Run locally

Use Python 3.12 or 3.13 in a local virtual environment. Install `requirements.txt`,
then run with an explicitly supplied local archive and strap-clock interval:

```sh
python3 -m pip install -r Tools/EcgPpgReference/requirements.txt
python3 Tools/EcgPpgReference/run_tests.py
python3 Tools/EcgPpgReference/reference.py /path/to/rejected_history.jsonl \
  --start FIRST_STRAP_SECOND --end LAST_STRAP_SECOND > /path/outside/repo/result.json
```

No network requests, database access or device commands occur during analysis.
The input is read only. Reports contain aggregate measurements, not waveforms or
absolute timestamps, but **are still private health data**. Keep them outside Git.
No real-user fixtures belong in this directory. CI uses generated signals only.

## Method and interpretation

- Check header CRC16, payload CRC32, magic, length, type and revision. Refuse
  conflicting same-second records; deduplicate exact copies. Decode signed 18-bit
  R16 and signed 32-bit R20 slots. Use only full 500/50-sample shared seconds.
- Split at missing/partial seconds, rate changes or optical configuration changes.
  Require equality of the uninterpreted header word at byte 19 between streams;
  **do not interpret that word as a subsecond timestamp**. Partial-buffer phase
  and the within-record electrical sampling phase are not independently calibrated.
- R16: 5–40 Hz second-order Butterworth bandpass, forward/backward; dominant
  polarity, 40% of the 99.5th-percentile height, 250 ms refractory, parabolic
  peak timing. A second 8–35 Hz / 50% run checks parameter sensitivity. This is
  not an independent annotation or a clinical reference validation. Inspect ECG
  detections before treating them as reference beats.
- R20 block 0: 0.5–8 Hz forward/backward bandpass, orient the steeper edge upward.
  `peak_grid` / `peak`: prominence 35% of the 5th–95th-percentile amplitude, 300 ms
  refractory; grid timing versus parabolic interpolation. `slope` / `foot` use
  the steepest rise preceding these detections. Broad/double maxima can fail.
- `rise` / `rise_foot` detect the derivative directly, height and prominence
  35% of the derivative's interior 99th percentile. `adaptive_rise` /
  `adaptive_foot` replace this global threshold with an eight-second centred
  moving 99th percentile, so weaker stretches can still be detected. This looks
  four seconds ahead; it is an **offline** method, not a live implementation.
- Foot: intersect the tangent at the parabolically refined maximum derivative
  with a horizontal baseline at the minimum in its preceding 250 ms. Shape,
  filtering and sample rate affect its bias; interpolation does not create new
  information or establish sub-sample physical accuracy.
- Detect each signal independently. Only then estimate a single constant lag
  in 50–650 ms and match monotonically, one-to-one, within ±100 ms. No beatwise
  time warping or ECG-guided PPG search. Exclude the first second and last two
  ECG seconds; apply the same interval, shifted by the lag, to optical detections.
- Report every missed/extra detection. `raw_*_rmssd_ms` includes all detected
  intervals, so missed/extra pulses can produce very large values.
  `rr_rmssd_ms` / `pp_rmssd_ms` compare **the same consecutive matched intervals**;
  no successive difference crosses a missed/extra beat. These conditional values
  must always be shown beside detection counts and `successive_interval_pairs`.
  They are interval variability, not proven NN variability; no rhythm inference
  or physiological beat classification is performed.
- The 25 Hz arm is an antialiased downsample of the 50 Hz input, with DC removal
  and linear edge extension. It is not a separate native 25 Hz recording and
  does not establish native capture quality. Show both rates and both slots;
  do not select a winner using ECG and call that prospective performance.

The candidate has no validated motion/artifact classifier. Periodic noise may
look pulsatile; changing input tests are necessary, not sufficient. Development
and evaluation on the same few recordings is exploratory evidence. Hold-out
recordings, variable rates and signal quality, and the actual band RR are needed
before any scoring change. Existing nightly five-minute HRV cannot be validated
by treating a short resting recording's RMSSD as a nightly recovery score.

## Actual Swift HR-only control

```sh
sh Tools/EcgPpgReference/build_hr_control.sh /path/to/local/work
/path/to/local/work/ppg-hr-control < /path/to/private-input.json
```

Input: `{"sampleRate":50,"samples":[...]}` with complete seconds. Output contains
relative-second `PpgHrSample` arrays for the default integer-lag and opt-in
interpolated-lag estimator. The source is compiled directly from `PpgHr.swift`;
it is not reimplemented in Python. On R20, the explicit rate is an experimental
adaptation: the shipping app only invokes this estimator on v26 at 24 Hz. Do not
convert its rounded BPM output into RR or HRV.

## Validation

`run_tests.py` requires an exact roster and zero skipped/failed/expected-failure
results. Synthetic tests vary ECG rate (45–175 bpm), optical rate (45–120 bpm),
interval modulation (15/60/100 ms), polarity, ADC offset, pulse amplitude,
sample rate (25/50 Hz), and constant/variable arrival delay. Known gaps and false
detections exercise the evaluator independently of its detectors. Archive tests
cover both CRCs, lengths, signed decoding, duplicates, conflicts and run splits.
The Python CI job observes every PR and push to main; it fetches no health data.
