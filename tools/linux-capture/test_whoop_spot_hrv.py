"""Tests for whoop_spot_hrv.py — the spot-HRV DSP, on synthetic signals with KNOWN beats.

These test the algorithm (peak detection, RR, RMSSD, glitch rejection) against signals whose ground truth
we control — not strap frames. Stdlib only; run with `pytest test_whoop_spot_hrv.py` or
`python3 -m pytest test_whoop_spot_hrv.py`.
"""
import math

import whoop_spot_hrv as H


def _synth_ppg(fs, n_beats, ibi_ms, width_s=0.12):
    """A clean PPG-like waveform: a Gaussian pulse at each beat time given an IBI sequence."""
    beat_t = [0.5]
    for ms in ibi_ms[: n_beats - 1]:
        beat_t.append(beat_t[-1] + ms / 1000.0)
    dur = beat_t[-1] + 0.5
    nsamp = int(dur * fs)
    t = [i / fs for i in range(nsamp)]
    v = []
    for ti in t:
        s = 0.0
        for bt in beat_t:
            d = (ti - bt) / width_s
            if abs(d) < 4:
                s += math.exp(-d * d)
        v.append(s * 1000.0 + 50000.0)   # scale + DC offset, like the real channel
    return t, v


def test_spot_hrv_recovers_hr_and_rmssd():
    fs = 24.0
    # 60 bpm with a deliberate alternating ±30 ms jitter → successive |diff| = 60 ms → RMSSD ≈ 60 ms
    ibi = [1030 if i % 2 == 0 else 970 for i in range(40)]
    t, v = _synth_ppg(fs, 40, ibi)
    r = H.spot_hrv(t, v, fs)
    assert r is not None
    assert 55 <= r["hr"] <= 65, r["hr"]                 # ~60 bpm
    assert r["n_clean"] >= 25 and r["quality"] == "GOOD"
    assert 35 <= r["rmssd"] <= 90, r["rmssd"]           # ~60 ms, allowing 24 Hz quantisation slack


def test_rmssd_sequential_clean_and_glitch():
    assert H.rmssd_sequential([800, 800, 800, 800]) == 0.0          # no variation
    # a single ectopic (1600) must be rejected, not inflate RMSSD (enough clean beats remain)
    rm = H.rmssd_sequential([800, 800, 800, 800, 1600, 800, 800, 800, 800])
    assert rm is not None and rm < 50, rm
    # too few clean diffs after rejecting the ectopic → conservatively None (no false HRV)
    assert H.rmssd_sequential([800, 800, 1600, 800, 800]) is None


def test_rmssd_sequential_too_short_is_none():
    assert H.rmssd_sequential([]) is None
    assert H.rmssd_sequential([800]) is None


def test_reconstruct_empty_rows():
    t, v, fs = H.reconstruct([])
    assert t == [] and v == [] and fs == 0.0


def test_reconstruct_grid_is_monotonic():
    rows = [(1000, 0, 5), (1000, 1, 6), (1000, 2, 7), (1001, 0, 5), (1001, 1, 6), (1001, 2, 7)]
    t, v, fs = H.reconstruct(rows)
    assert fs == 3.0
    assert t == sorted(t) and t[0] == 0.0
    assert abs(t[3] - 1.0) < 1e-9                       # second 1, sample 0 → t=1.0
    assert len(v) == 6


def test_find_peaks_counts_beats():
    fs = 24.0
    t, v = _synth_ppg(fs, 10, [1000] * 9)               # 10 clean beats at 60 bpm
    vv = H.detrend(v, int(fs))
    import statistics
    pk = H.find_peaks(vv, min_dist=int(0.4 * fs), min_prom=0.3 * statistics.pstdev(vv))
    assert 9 <= len(pk) <= 11, len(pk)


def test_spot_hrv_returns_none_on_too_few_samples():
    # too few samples → None (no false HRV)
    assert H.spot_hrv([0, 1, 2], [1.0, 2.0, 1.0], 24.0) is None


def test_spot_hrv_returns_none_on_flat_signal():
    # a flat (no-beat) signal of plenty of samples → no detectable RR → None, never a fabricated value
    fs = 24.0
    t = [i / fs for i in range(120)]
    v = [50000.0] * 120
    assert H.spot_hrv(t, v, fs) is None
