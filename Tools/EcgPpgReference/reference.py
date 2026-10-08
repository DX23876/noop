"""Local, offline R16/R20 beat-timing experiment; not a production HRV estimator.

No waveform or absolute timestamp is printed. Inputs are never modified. The
detectors do not see one another's signal; only the evaluator matches their beats.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import zlib

import numpy as np
from scipy.ndimage import percentile_filter
from scipy.signal import butter, find_peaks, sosfiltfilt, resample_poly


def crc16(data):
    value = 0xFFFF
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0xA001 if value & 1 else 0)
    return value


def valid_frame(frame):
    return (len(frame) >= 13 and frame[0] == 0xAA
            and struct.unpack_from('<H', frame, 2)[0] + 8 == len(frame)
            and crc16(frame[:6]) == struct.unpack_from('<H', frame, 6)[0]
            and zlib.crc32(frame[8:-4]) == struct.unpack_from('<I', frame, len(frame)-4)[0])


def read_archive(path, start, end):
    """Exact duplicates collapse; conflicting same-second records refuse the run."""
    records, counts = {}, Counter()
    with Path(path).open() as source:
        for line in source:
            try:
                frame = bytes.fromhex(json.loads(line)['frameHex'])
            except (ValueError, KeyError, TypeError):
                counts['malformed_lines'] += 1
                continue
            if len(frame) < 21 or frame[8] != 47 or frame[9] not in (16, 20):
                continue
            second = struct.unpack_from('<I', frame, 15)[0]
            if not start <= second <= end:
                continue
            if not valid_frame(frame):
                counts['invalid_frames'] += 1
                continue
            if len(frame) != {16: 1584, 20: 2140}[frame[9]]:
                counts['wrong_layout'] += 1
                continue
            key = (frame[9], second)
            if key in records:
                if records[key] != frame:
                    raise ValueError('Conflicting records at one strap second; cannot align safely')
                counts['exact_duplicates'] += 1
            records[key] = frame
    return records, counts


def complete_runs(records):
    """Do not concatenate across gaps, partial seconds, rate or configuration changes.

    The unknown header word at 19 is retained as a consistency check, not treated
    as a documented subsecond timestamp. Partial R16 frames have unknown phase.
    """
    runs, current, prior_config = [], [], None
    for second in sorted({s for version, s in records if version == 16}):
        ecg, ppg = records[(16, second)], records.get((20, second))
        eligible = (struct.unpack_from('<H', ecg, 32)[0] == 500
                    and ppg is not None and ppg[26] == 50
                    and ecg[19:21] == ppg[19:21])
        config = ppg[27:47] if ppg is not None else None
        if current and (not eligible or second != current[-1] + 1 or config != prior_config):
            runs.append(current)
            current = []
        if eligible:
            current.append(second)
            prior_config = config
    if current:
        runs.append(current)
    return runs


def signals(records, seconds, block=0):
    ecg, a, b = [], [], []
    for second in seconds:
        frame = records[(16, second)]
        packed = np.frombuffer(frame[34:1534], dtype=np.uint8).reshape(500, 3).astype(np.int32)
        values = ((packed[:, 0] & 3) << 16) | (packed[:, 1] << 8) | packed[:, 2]
        ecg.extend(np.where(values >= 131072, values-262144, values))
        frame = records[(20, second)]
        offset = 26 + block * 422
        if frame[offset] != 50:
            raise ValueError('Selected optical block is not populated at 50 Hz')
        a.extend(struct.unpack_from('<50i', frame, offset+21))
        b.extend(struct.unpack_from('<50i', frame, offset+221))
    return np.asarray(ecg, float), np.asarray(a, float), np.asarray(b, float)


def filtered(x, fs, low, high):
    x = np.asarray(x, float)
    if not np.all(np.isfinite(x)):
        raise ValueError('Non-finite samples')
    return sosfiltfilt(butter(2, [low, high], fs=fs, btype='bandpass', output='sos'), x-np.median(x))


def at_25_hz(x):
    # Zero padding a large ADC DC level creates a large fictitious endpoint pulse.
    return resample_poly(x-np.median(x), 1, 2, padtype='line')


def refined_index(x, index):
    if index < 1 or index >= len(x)-1:
        return float(index)
    left, mid, right = x[index-1:index+2]
    den = left - 2*mid + right
    delta = 0.5*(left-right)/den if den < 0 else 0.0
    return index + float(np.clip(delta, -0.5, 0.5))


def ecg_beats(x, fs=500, band=(5, 40), threshold=0.4):
    y = filtered(x, fs, *band)
    if np.percentile(y, 99.5) < -np.percentile(y, 0.5):
        y = -y
    height = threshold*np.percentile(y, 99.5)
    peaks, _ = find_peaks(y, height=height, distance=int(0.25*fs))
    return np.array([refined_index(y, p)/fs for p in peaks]), y


def optical_beats(x, fs=50):
    """Simple independent candidate, fixed before reference comparison.

    Bandpass 0.5–8 Hz, orient the steeper edge upward, prominence-based pulse
    peaks with 300 ms refractory period. Three fiducials share the SAME detections.
    Intersecting tangent: baseline minimum in 250 ms preceding the steepest rise.
    This heuristic is research instrumentation, not a claimed universal detector.
    """
    if fs not in (25, 50) or len(x) < 3*fs:
        raise ValueError('Optical experiment requires >=3 seconds at 25 or 50 Hz')
    y = filtered(x, fs, 0.5, 8)
    dy = np.gradient(y)*fs
    interior = dy[fs:-fs]
    if np.percentile(interior, 99) < -np.percentile(interior, 1):
        y, dy = -y, -dy
    amplitude = np.percentile(y, 95)-np.percentile(y, 5)
    if amplitude <= 1e-9:
        return {name: np.array([]) for name in (
            'peak_grid', 'peak', 'slope', 'foot', 'rise', 'rise_foot',
            'adaptive_rise', 'adaptive_foot')}, y
    peaks, _ = find_peaks(y, prominence=0.35*amplitude, distance=int(np.ceil(0.30*fs)))
    out = {name: [] for name in ('peak_grid', 'peak', 'slope', 'foot')}
    for peak in peaks:
        lo = max(0, peak-int(0.35*fs))
        if peak-lo < 3:
            continue
        up = lo + int(np.argmax(dy[lo:peak]))
        baseline = np.min(y[max(0, up-int(0.25*fs)):up+1])
        if dy[up] <= 0:
            continue
        u = refined_index(dy, up)
        level = np.interp(u, np.arange(len(y)), y)
        slope = np.interp(u, np.arange(len(y)), dy)
        foot = u/fs + (baseline-level)/slope
        out['peak_grid'].append(peak/fs)
        out['peak'].append(refined_index(y, peak)/fs)
        out['slope'].append(u/fs)
        out['foot'].append(foot)
    # Alternative: detect the steep rise directly, so a broad/double systolic
    # maximum does not decide whether a pulse exists. Same fixed refractory time.
    thresholds = [('rise', 'rise_foot', 0.35*np.percentile(dy[fs:-fs], 99)),
                  ('adaptive_rise', 'adaptive_foot',
                   0.35*percentile_filter(dy, 99, size=fs*8+1, mode='reflect'))]
    for rise_name, foot_name, height in thresholds:
        rises, _ = find_peaks(dy, height=height, prominence=height,
                              distance=int(np.ceil(0.30*fs)))
        out[rise_name], out[foot_name] = [], []
        for up in rises:
            u = refined_index(dy, up)
            baseline = np.min(y[max(0, up-int(0.25*fs)):up+1])
            level = np.interp(u, np.arange(len(y)), y)
            slope = np.interp(u, np.arange(len(y)), dy)
            if slope <= 0:
                continue
            out[rise_name].append(u/fs)
            out[foot_name].append(u/fs + (baseline-level)/slope)
    return {name: np.array(values) for name, values in out.items()}, y


def match_beats(reference, candidate, lag, tolerance=0.1):
    """Monotone one-to-one assignment: maximum matches, then minimum squared error."""
    n, m = len(reference), len(candidate)
    score = [[(0, 0.0) for _ in range(m+1)] for _ in range(n+1)]
    move = np.zeros((n+1, m+1), dtype=np.uint8)
    for i in range(1, n+1):
        for j in range(1, m+1):
            choices = [(score[i-1][j], 1), (score[i][j-1], 2)]
            error = candidate[j-1]-reference[i-1]-lag
            if abs(error) <= tolerance:
                count, cost = score[i-1][j-1]
                choices.append(((count+1, cost-error*error), 3))
            score[i][j], move[i, j] = max(choices, key=lambda item: item[0])
    pairs, i, j = [], n, m
    while i > 0 and j > 0:
        step = move[i, j]
        if step == 3:
            pairs.append((i-1, j-1))
            i, j = i-1, j-1
        elif step == 1:
            i -= 1
        else:
            j -= 1
    return list(reversed(pairs))


def rmssd(intervals):
    return float(np.sqrt(np.mean(np.diff(intervals)**2))) if len(intervals) >= 2 else None


def compare(reference, candidate, duration, tolerance=0.1):
    # Estimate only a constant latency, never warp individual beats. Predeclared
    # physiological candidate range, 50–650 ms. ECG does not guide pulse detection.
    core_r = reference[(reference >= 1) & (reference < duration-2)]
    if len(core_r) < 3 or len(candidate) < 3:
        return {'status': 'insufficient_beats'}
    lags = np.arange(0.05, 0.6501, 0.01)
    def trial(lag):
        pairs = match_beats(core_r, candidate, lag, tolerance)
        cost = sum((candidate[j]-core_r[i]-lag)**2 for i, j in pairs)
        return len(pairs), -cost
    lag = float(max(lags, key=trial))
    pairs = match_beats(core_r, candidate, lag, tolerance)
    if not pairs:
        return {'status': 'no_matches'}
    lag = float(np.median([candidate[j]-core_r[i] for i, j in pairs]))
    # Identical boundary beats must stay identical after floating-point lag fitting.
    epsilon = 1e-9
    core_p = candidate[(candidate >= 1+lag-epsilon) & (candidate < duration-2+lag-epsilon)]
    pairs = match_beats(core_r, core_p, lag, tolerance)
    offsets = np.array([core_p[j]-core_r[i] for i, j in pairs])*1000
    # Only adjacent intervals in BOTH original trains; never bridge a missed beat.
    rr, pp, run_ids = [], [], []
    run = 0
    for (i0, j0), (i1, j1) in zip(pairs, pairs[1:]):
        if i1 == i0+1 and j1 == j0+1:
            rr.append((core_r[i1]-core_r[i0])*1000)
            pp.append((core_p[j1]-core_p[j0])*1000)
            run_ids.append(run)
        else:
            run += 1
    diffs_r = [rr[k]-rr[k-1] for k in range(1, len(rr)) if run_ids[k] == run_ids[k-1]]
    diffs_p = [pp[k]-pp[k-1] for k in range(1, len(pp)) if run_ids[k] == run_ids[k-1]]
    rms = lambda x: float(np.sqrt(np.mean(np.square(x)))) if len(x) else None
    return dict(status='ok', reference_beats=len(core_r), optical_beats=len(core_p),
                matched=len(pairs), missed=len(core_r)-len(pairs), false=len(core_p)-len(pairs),
                sensitivity=len(pairs)/len(core_r), precision=len(pairs)/len(core_p) if len(core_p) else 0,
                lag_median_ms=float(np.median(offsets)) if len(offsets) else None,
                lag_sd_ms=float(np.std(offsets, ddof=1)) if len(offsets)>1 else None,
                lag_p05_p95_ms=np.percentile(offsets, [5, 95]).tolist() if len(offsets) else [],
                rr_rmssd_ms=rms(diffs_r), pp_rmssd_ms=rms(diffs_p),
                paired_intervals=len(rr), successive_interval_pairs=len(diffs_r),
                interval_mae_ms=float(np.mean(np.abs(np.array(pp)-rr))) if rr else None,
                reference_hr_bpm=60/float(np.mean(np.diff(core_r))),
                raw_rr_rmssd_ms=rmssd(np.diff(core_r)*1000),
                raw_pp_rmssd_ms=rmssd(np.diff(core_p)*1000))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--start', type=int, required=True, help='First strap Unix second, inclusive')
    parser.add_argument('--end', type=int, required=True, help='Last strap Unix second, inclusive')
    parser.add_argument('--block', type=int, choices=range(5), default=0)
    args = parser.parse_args()
    if args.end < args.start:
        parser.error('end must be >= start')
    records, counts = read_archive(args.archive, args.start, args.end)
    result = dict(integrity=dict(counts), runs=[])
    for seconds in complete_runs(records):
        if len(seconds) < 10:
            continue
        ecg, a, b = signals(records, seconds, args.block)
        reference, _ = ecg_beats(ecg)
        alt, _ = ecg_beats(ecg, band=(8, 35), threshold=0.5)
        # Reuse the matching statistics with a documented artificial 200 ms offset
        # because compare's latency search is intentionally constrained to PPG.
        check = compare(reference, alt+0.2, len(seconds))
        if check.get('status') == 'ok':
            check['lag_median_ms'] -= 200
            check['lag_p05_p95_ms'] = [x-200 for x in check['lag_p05_p95_ms']]
        run = dict(complete_seconds=len(seconds), ecg_samples=len(ecg), optical_samples=len(a),
                   ecg_filter_sensitivity_check=check, slots={})
        for name, signal in [('A', a), ('B', b)]:
            run['slots'][name] = {}
            for fs, wave in [(50, signal), (25, at_25_hz(signal))]:
                beats, _ = optical_beats(wave, fs)
                run['slots'][name][str(fs)] = {key: compare(reference, times, len(seconds))
                                              for key, times in beats.items()}
        result['runs'].append(run)
    if not result['runs']:
        raise SystemExit('No eligible contiguous segment of at least 10 seconds')
    print(json.dumps(result, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
