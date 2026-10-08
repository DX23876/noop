# ECG as an optical timing reference

Status: offline research tooling, 2026-10-08. Source baseline: `feature/openstrap-ecg`
at `3d204e5d3`. No private recordings, measurements, paths or derived reports are
stored in this document. **Analysis migration required: no** — instrumentation
and documentation only; production scoring and capture are unchanged.

## What the app actually scores

Source inspection, not an assumption based on file names:

| Signal | Ingestion and storage | Consumers |
|---|---|---|
| WHOOP 5/MG band RR | v18 history → channel 5; type-40 realtime → channel 6; standard BLE 0x2A37 → channel 7. `rrInterval` stores `rrMs`, second-resolution `ts`, `ord`, `seq`, `srcChannel`, `transport`, `tsSuspect`, device ownership. | `WhoopStore.rrIntervals` reconciles delivery paths; `HRVAnalyzer` and `SleepStager` compute variability from selected RR values. |
| v26 optical buffer | `HistoricalStreams` → `PpgHr.derivePpgHr`, default 24 Hz, per-second windowed autocorrelation. `ppgHrSample`; underlying buffer in `ppgWaveformSample`. | HR-only fallback where measured `hrSample` is absent. No per-beat timestamps, RR or HRV output. |
| R20 optical blocks | `Whoop5RawOptical` decodes five blocks, each with two slots and configuration metadata. | Experimental inspection; no R20-to-RR production path. Do not label slots as wavelengths. |
| Saved ECG | `ecgReading` and `ecgReadingPacket`: accepted live R17 window at 100 Hz, gap markers and band summary, including `variabilityRaw`. | ECG detail analysis; the summary field has no established unit and is not the nightly RR-derived HRV input. R16 and R20 are not children of the saved reading. |

Relevant source: [RR units](../../../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5RR.swift),
[history mapping](../../../Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift),
[BLE live mapping](../../../Strand/BLE/BLEManager.swift),
[read selection](../../../Packages/WhoopStore/Sources/WhoopStore/Reads.swift),
[RR reconciler](../../../Packages/WhoopStore/Sources/WhoopStore/RRTransportReconciler.swift),
[HR-only estimator](../../../Packages/WhoopProtocol/Sources/WhoopProtocol/PpgHr.swift),
[HRV cleaning](../../../Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift),
[night aggregation](../../../Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift),
[ECG storage](../../../Packages/WhoopStore/Sources/WhoopStore/EcgReadingStore.swift).

WHOOP 5/MG RR words are milliseconds, including its nonstandard use of 0x2A37;
do not apply 1000/1024 again. The read policy restores older unlabelled standard
rows and excludes quarantined rows, including identified 500 ms fill values.

AI-12 chooses one delivery path per **epoch-aligned five-minute segment**:
history > standard > realtime > unknown, provided its occupied seconds reach
80% of the fullest path. It does not splice labelled sources inside a segment.
Full segments are read before cutting to the caller's interval. This avoids
mixing strap-clock and phone-receipt copies when their offsets drift by seconds.
The detailed exceptions for unlabelled legacy rows are in `RRTransportReconciler`.

The RR values themselves retain millisecond resolution; their integer `ts`
column is not a millisecond beat timestamp. A future ECG comparison must align
ordered interval sequences using `ord`/`seq`, record provenance and cumulative
RR durations. Nearest-second matching across transports is not a valid shortcut.
Read the complete five-minute selection segments and necessary clock margins,
not only the short ECG window. Compare each raw transport separately as well as
the **same selected read** used by the app. Do not implement a second SQL version
of AI-12 that can silently diverge from the shared resolver.

`HRVAnalyzer` applies range and local-median rejection and avoids differences
across removed intervals. Nightly RMSSD additionally uses five-minute sleep
windows and session aggregation. A short ECG comparison tests beat timing, not
the accuracy of a whole-night recovery score or the physiological validity of
every interval retained by the cleaning heuristic.

## Reproducible offline comparison

[Tools/EcgPpgReference](../../../Tools/EcgPpgReference/README.md) documents exact
decoding, filters, detector thresholds, boundary exclusions, matching tolerance,
conditional versus raw RMSSD, and the 25 Hz downsampling control. It also compiles
the actual `PpgHr.swift` for an optional HR-only control; feeding it R20 with an
explicit 50 Hz rate is an experiment, not something the app currently does.
Do not derive RR from its rounded per-second BPM.

The two detectors are independent until evaluation. A constant ECG-to-optical
lag is fitted, then detections are matched one-to-one. All misses and extras
remain in the detection metrics. Timing and variability agreement on matched
contiguous runs cannot replace those metrics: reporting only cleaned RMSSD can
hide a poor detector. The optical candidate has no validated artifact classifier
and is not wired to recovery, respiratory rate, or any downstream gate.

The synthetic suite varies inputs rather than fitting one fixed expected pulse.
This establishes implementation behavior on those constructed signals. It does
not establish general performance on native optical recordings, motion, different
subjects, rates outside the tested range or different firmware. A 25 Hz decimation
of a 50 Hz recording is not a native 25 Hz validation set.

## Proposed durable reference capture (not implemented)

The current [reject archive](../../../Strand/Collect/RawHistoryArchive.swift) has
a 5 MiB soft cap, version retention floors and value-aware eviction. A floor
protects a number of records, **not an entire ECG session**. Increasing the cap
does not give saved readings durable reference signals.

Extend the existing ECG feature with a versioned raw-reference store, independent
of reject retention:

1. Preserve complete CRC-valid R16/R20 frame bytes, family, device identity,
   firmware provenance, record counter, strap seconds, uninterpreted header word,
   sample counts/configurations and content hash. Keep undecoded/reserved fields.
   No conversion of raw ADC into assumed calibrated amplitude.
2. Associate records by strap clock/counters with a saved ECG. Offload can arrive
   after live R17 ends; saving only while the measurement UI is open loses data.
   Preserve pending association and explicit gaps/rate/configuration changes.
   Define bounded retention for unmatched material independently of matched data.
3. Commit selected raw frames durably **before acknowledging their offload**.
   Replays must be idempotent; conflicting copies must remain distinguishable.
   Store exact bytes once and use stable frame identity rather than phone seconds
   or a millisecond value as a dedup key.
4. Reading deletion should cascade through exclusive children; shared frames need
   explicit ownership/reference handling. Include `deleteAllData`, device deletion,
   existing offline export/restore and schema-oracle tests. Measure binary storage
   requirements; hex JSON doubles payload size.
5. Store reference-analysis results beside the incumbent, with method version,
   selected transport, counts, exclusions, interval errors and confidence limits.
   Do not replace nightly band-RR scoring on the evidence of a few quiet sessions.

This needs a new ordinary database migration. Raw prospective capture alone does
not require historical rescoring; changing RR precedence, cleaning or derived
score semantics does require a new analysis recipe and resumable migration.
No extra device commands are part of this proposal: preserve already received
records first. Hardware integration remains unvalidated until a later authorized
device test verifies arrival, persistence, restart and deletion behavior.

## Literature and interpretation

- **Charlton et al., 2022:** evaluated 15 PPG beat detectors against ECG on eight
  datasets, with sensitivity and positive predictive value. Performance depends
  strongly on activity; detector evaluation and timestamp fiducial selection are
  separate steps. Their work supports testing multiple signal conditions rather
  than inferring general accuracy from quiet recordings.
  [Paper](https://doi.org/10.1088/1361-6579/ac826d),
  [authors' framework](https://ppg-beats.readthedocs.io/en/latest/).
- **Peralta et al., 2019:** compared five pulse fiducials for PRV; pulse maxima,
  derivative maxima and intersecting tangents are distinct choices, not
  interchangeable definitions of a beat time.
  [Primary study](https://pubmed.ncbi.nlm.nih.gov/30669123/).
- **Yuda et al., 2020:** simultaneous observations show that pulse variability
  can contain variability beyond ECG RR. The R-to-pulse-foot delay includes
  pre-ejection and vascular propagation; call it pulse arrival time (PAT), not
  isolated vascular transit time.
  [Primary observations](https://pmc.ncbi.nlm.nih.gov/articles/PMC7437069/).
- **Choi and Shin, 2017:** studied PRV at multiple downsampled rates. Their pilot
  does not provide a universal guarantee that any 25 Hz waveform/detector yields
  accurate variability.
  [Primary study](https://pubmed.ncbi.nlm.nih.gov/28169836/).

For matched beats, `PP[i] = RR[i] + PAT[i] - PAT[i-1]`. A constant delay cancels;
beatwise delay variation and detector jitter do not. Agreement of average HR
therefore establishes much less than agreement of successive interval changes.
Neither matching nor a local-median filter establishes that all retained beats
are physiologically NN intervals. No diagnostic classifications follow here.

## What would resolve the high-pass question

A matched R16/R17 comparison identifies their **relative transfer function**.
The documented alignment is on the 500 Hz grid: `5*j - 132`; rounding that offset
to the 100 Hz grid adds a phase error. Use antialiasing before decimation and
separate coherent transfer from uncorrelated drift/noise. Recover several injected
cutoffs on a known paired signal before interpreting a fitted filter.

R16 and R17 sharing a passband does not establish the absolute analog response:
a common upstream filter would cancel in their ratio. Conversely, a good 1.5 Hz
fit between sequential WHOOP/Watch median beats does not identify the strap's
physical corner frequency. Electrode geometry, contact, sequential morphology
variation and each device's processing remain confounders. Low-frequency drift
in R16 alone is also not proof against an upstream high-pass; the input amplitude
and origin of that drift are unknown. A simultaneous, independently calibrated
reference or known injected waveform is needed. Treat inverse compensation as
a model assumption until then, and keep unmodified raw samples for reanalysis.
