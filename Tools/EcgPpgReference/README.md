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

The R16/R20 command performs no network requests, database access or device commands.
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

## Stored band RR against R16

Build the Swift tool, then export a bounded interval from a **local database copy**
with its WAL/SHM siblings. Keep output outside the repository. This tool reads
private health data; it never invokes a device or sends data to a server.

```sh
swift build --package-path Tools/EcgPpgReference
Tools/EcgPpgReference/.build/debug/rr-reference-export \
  /path/to/whoop.sqlite FIRST_CONTEXT_SECOND LAST_CONTEXT_SECOND \
  > /path/outside/repo/rr-export.json
python3 Tools/EcgPpgReference/rr_reference.py /path/to/rejected_history.jsonl \
  /path/outside/repo/rr-export.json \
  --swift-tool Tools/EcgPpgReference/.build/debug/rr-reference-export \
  --start FIRST_CAPTURE_SECOND --end LAST_CAPTURE_SECOND \
  > /path/outside/repo/rr-audit.json
```

The export calls `WhoopStore.readOnly` (SQLite read-only, no migrations or
checkpoint) and **`WhoopStore.rrIntervals` itself**. There is no second AI-12 SQL
implementation. Source selection still reads complete five-minute segments before
clipping. Choose context covering complete segments plus the capture's clock
margin; insufficient context cannot establish coverage. The tool refuses multiple
RR owners rather than guessing an alias union. It expects a compatible schema.
Do not add `immutable=1` to a copy with uncheckpointed WAL: this hides WAL content.

`raw` contains stored labels including quarantined rows; comparisons exclude
`tsSuspect == 1`, as the app does. `selected` preserves the app's returned order.
For separate labels, ordering is `ts, ord, rrMs, seq`, matching the app read.
Neither `ord` nor `seq` is a global sequence number: same-second batches can have
equal `ord`. The report counts such ties, without inventing a lost emission order.

Integer seconds identify coarse delivery discontinuities (>3 seconds versus
cumulative RR) and bound capture overlap with a five-second clock margin. Beat
matching does **not** pair nearest seconds. Ordered interval patterns are matched
monotonically with explicit omissions/additions, then checked against cumulative
RR durations in each contiguous run. No rate fit or beatwise time warping occurs.
Residual curves start at zero and are relative drift, **not physical pulse-arrival
time**. Missing intervals reset the run and remain in the coverage count.

The local sequence alignment uses reward `2 - abs(error_ms)/20` and a gap penalty
of 4. Repeating with scales 10/30 must preserve the trace; otherwise the result is
labelled ambiguous and its point estimate must not be used. This remains an
exploratory alignment aid: periodic/constant sequences can have indistinguishable
phases even when the parameter check passes. Equal-scoring endpoint phases are
refused explicitly; near-ties still require judgement. Inspect every real-data trace.
Low coverage or a failed sequence match must never be presented as detector accuracy.

A second check compares exact ordered values across history and standard labels
within established ECG endpoints. **All** possible assignments of equal intervals
are retained (maximum 64; greater ambiguity fails). This can identify a missing
stored observation without picking the interpretation with the best ECG error.
It requires a shared block start and an exact-value prefix spanning the history
bracket; differing values or more complex overlap require manual investigation.
A label is not a lossless transport log: `StreamStore` can promote a standard row
to history when their `(deviceId, ts, rrMs, seq)` keys collide. A missing channel-7
row alone does not prove a missed optical beat or lost BLE packet.

The Swift executable's `--analyze` mode accepts JSON `[[rrMs,...],...]` on stdin.
It runs the **actual `HRVAnalyzer`**, returning surviving original indices,
contiguity, counts and its optional RMSSD. No cleaner is copied into Python.
The report checks both delivery-block context and the selected five-minute
source segment, and separately shows the minimum-beat refusal on matched-only
inputs. Selection segments are not necessarily the nightly sleep-window grid.
Paired research RMSSD uses the same adjacent intervals in both streams, skips
missing/rejected neighbours, and does not claim that retained intervals are NN.

Focused Swift validation (in a separate permitted worktree):

```sh
swift test --package-path Packages/WhoopStore --filter ReadOnlyStoreTests > /path/store-test.log 2>&1
swift test --package-path Packages/StrandAnalytics --filter 'HRVCleanProvenanceTests|EcgPeakTimingTests' > /path/analysis-test.log 2>&1
python3 Tools/EcgPpgReference/check_swift_roster.py /path/store-test.log /path/analysis-test.log
```

The Swift CI builds the tool and requires the exact 13 focused XCTest successes.
Its paths cover the tool, packages and workflow. Python CI requires all 29 synthetic
tests, including varying RR rates/errors, missing/extra entries, equal-value identity
ambiguity, source ordering, discontinuities and gate failures. Private fixtures are
never CI inputs. Analysis migration required: **no**; selection, HRV arithmetic,
storage schema and live capture behavior are unchanged.


## ECG detail timing regression (2026-10-09)

`EcgPeakTimingTests` protects the production ECG detail analyzer as well. Integer
R indices on the 100 Hz grid generated roughly 7.8 ms RMSSD on constant 613/777/
923/1107 ms inputs. A bounded three-point parabola refines the time of an already
detected R, leaving detection and template sample indices alone. The tested
constant inputs now remain below 2.5 ms RMSSD; injected 5/17/43/61 ms alternating
interval differences are recovered within 2 ms, in either polarity. These limits
are synthetic regression evidence, not physical accuracy specifications.

Flat/non-maximum/non-finite triplets keep their sample location. A boundary or
missing neighbour is never used for interpolation, and successive differences
remain separated across recording gaps. Tests also vary peak width, amplitude,
small additive noise, signal offset and position within a sample. The exact CI
roster includes all six timing cases and requires zero non-success results.

These are transient `EcgAnalysis` detail results recomputed from saved waveforms;
no persisted result, nightly band-RR analysis or recovery recipe is changed.
**Analysis migration required: no.** This improvement reduces grid quantisation;
it does not validate the strap's bandwidth, the 1.5 Hz compensation hypothesis,
P/T delineation, artifact classification or the physical accuracy of interpolation.
