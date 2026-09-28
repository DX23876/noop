#!/usr/bin/env python3
"""Calibrate WHOOP 5/MG `dynamic_acceleration@41` against ENMO from the strap's own 100 Hz IMU.

CosinorAge (Shim, Fleisch & Barata, npj Digit. Med. 2024) maps a cosinor fit over minute-level ENMO in
milli-g to an age. The reference implementation (ADAMMA-CDHI-ETH-Zurich/CosinorAge: `ukb.py` reads the UK
Biobank `enmo_mg` values, `cosinor_analysis.py` fits them) applies no normalisation, so the absolute scale
of the input enters the result: about 16 years per 100 % scale error. The strap's per-second `@41` value is
labelled "g, gravity-removed magnitude", but nothing establishes that it is ENMO, or on ENMO's scale.

The strap can be its own reference. The Raw Data Collector (docs/RAW_DATA_CAPTURE.md) exports the 100 Hz
six-axis IMU (`imu/*.imus`) and, per second, the gravity vector with `@41` (`history-sensors.csv`), both on
the strap clock. This tool computes ENMO from the raw accelerometer the way the UK Biobank did, then asks
what `@41` is and how it maps onto that reference.

Reference pipeline, as implemented in OxWearables/biobankAccelerometerAnalysis (`device.py`,
`EpochWriter.java`, `AccStats.java`, `LowpassFilter.java`, `Filter.java`):

  1. auto-calibration: 10 s epochs whose per-axis SD is below 13 mg count as stationary, and their mean
     vectors are fitted to the unit sphere by iteratively re-weighted per-axis regression;
  2. ENMO = |a| - 1 per sample, low-pass filtered by a causal 4th-order Butterworth at 20 Hz (the filter runs
     on the ENMO signal, not on the axes), then truncated at zero;
  3. epoch means, then minute means for the cosinor fit.

Deliberate differences: the raw stream is already 100 Hz, so there is no resampling step; the filter state
restarts after a gap instead of running across it; there is no temperature term, because the export
carries no IMU temperature.

Usage:

    Tools/cosinor_calib.py inspect noop-5mg-raw-<id>.zip
    Tools/cosinor_calib.py fit --train A.zip --test B.zip C.zip [--json report.json]

Standard library only. Tests: Tools/test_cosinor_calib.py.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import struct
import sys
import zipfile
import zlib
from dataclasses import dataclass, field
from pathlib import Path

# ── Raw IMU segments (`ImuSessionFileStore.swift`) ─────────────────────────────────────────────────

IMUS_MAGIC = b"NOOPIMU2"
SAMPLE_RATE = 100
AXES = 6
PAYLOAD_BYTES = SAMPLE_RATE * AXES * 2
ACCEL_SCALE = 1.0 / 4096.0  # g per LSB (`Whoop5RawImu.accelScale`)
I16_RAIL = 32767            # |raw| at or beyond this is clipped: ±8 g at 1/4096 g per LSB

# ── UK Biobank reference constants (biobankAccelerometerAnalysis `device.py`, `AccelerometerParser.java`)

STATIONARY_EPOCH_S = 10
STATIONARY_STD_G = 0.013
CAL_MAX_ITERATIONS = 1000
CAL_IMPROVEMENT_TOLERANCE = 0.0001
CAL_ERROR_TOLERANCE = 0.01
CAL_CUBE_THRESHOLD = 0.3
CAL_MIN_SAMPLES = 50
LOWPASS_HZ = 20.0

# ── CosinorAge model (reference `bioages/cosinorage.py`; `CosinorAgeEngine.swift` carries the same) ──

COEFFS = {
    "generic": dict(mesor=-0.03204933, amp=-0.01971357, phi=-0.01664718, age=0.10033692, rate=-13.36715309),
    "female": dict(mesor=-0.02569062, amp=-0.02170987, phi=-0.13191562, age=0.08840283, rate=-13.28530410),
    "male": dict(mesor=-0.023988922, amp=-0.030620390, phi=0.008960155, age=0.101726103, rate=-13.016951633),
}
M_N, M_D = -1.405276, 0.01462774
BA_N, BA_D, BA_I = -0.01447851, 0.112165, 133.5989

# Illustrative operating point for turning a mapping error into years: the values the plan's sensitivity
# table uses. Override with --mesor/--amplitude/--age once a real week of the wearer's data is known.
DEFAULT_MESOR_MG = 37.0
DEFAULT_AMPLITUDE_MG = 32.0
DEFAULT_ACROPHASE_H = 15.0
DEFAULT_AGE = 40.0

# ── Pre-registered decision rule (plan phase 3). Changing these after seeing data defeats the point. ──

DETERMINISTIC_MIN_R = 0.99
DETERMINISTIC_SLOPE_SPREAD = 0.02
MAX_AGE_ERROR_YEARS = 1.0
MIN_USABLE_R = 0.5
MIN_SECONDS_PER_MINUTE = 50


# ═════════════════════════════════════════ Reading ═════════════════════════════════════════════════


@dataclass
class ImuRecord:
    ts: int
    received_ms: int
    columns: list[int]  # [ax×100, ay×100, az×100, gx×100, gy×100, gz×100], raw i16


def decode_imus(data: bytes) -> list[ImuRecord]:
    """Decode one `.imus` segment. Mirrors `ImuSessionFileStore.decode`: a truncated final block ends the
    read without discarding the blocks before it. Apple's `COMPRESSION_ZLIB` is raw deflate (no header)."""
    if len(data) < 24 or data[:8] != IMUS_MAGIC:
        return []
    rate, axes = struct.unpack_from(">ii", data, 16)
    if rate != SAMPLE_RATE or axes != AXES:
        return []
    out: list[ImuRecord] = []
    offset = 24
    while offset + 12 <= len(data):
        count, raw_size, comp_size = struct.unpack_from(">iii", data, offset)
        offset += 12
        if not (0 < count <= 30 and raw_size > 0 and comp_size > 0 and offset + comp_size <= len(data)):
            break
        try:
            raw = zlib.decompress(data[offset:offset + comp_size], -15)
        except zlib.error:
            break
        if len(raw) != raw_size:
            break
        offset += comp_size
        pos = 0
        for _ in range(count):
            if pos + 20 + PAYLOAD_BYTES > len(raw):
                break
            ts, received, length = struct.unpack_from(">qqi", raw, pos)
            pos += 20
            if length != PAYLOAD_BYTES:
                break
            out.append(ImuRecord(ts, received, list(struct.unpack_from(f"<{SAMPLE_RATE * AXES}h", raw, pos))))
            pos += length
    return out


def encode_imus(bucket: int, records: list[ImuRecord]) -> bytes:
    """Write a segment the way `ImuSessionFileStore.encode` does. Used by the tests."""
    out = bytearray(IMUS_MAGIC + struct.pack(">qii", bucket, SAMPLE_RATE, AXES))
    for start in range(0, len(records), 30):
        chunk = records[start:start + 30]
        raw = bytearray()
        for r in chunk:
            raw += struct.pack(">qqi", r.ts, r.received_ms, PAYLOAD_BYTES)
            raw += struct.pack(f"<{SAMPLE_RATE * AXES}h", *r.columns)
        comp = zlib.compressobj(wbits=-15)
        packed = comp.compress(bytes(raw)) + comp.flush()
        out += struct.pack(">iii", len(chunk), len(raw), len(packed)) + packed
    return bytes(out)


@dataclass
class GravityRow:
    x: float
    y: float
    z: float
    dyn: float | None  # `@41` in g; None on a 4.0 or when the field was out of gate


def parse_history_csv(text: str) -> dict[int, GravityRow]:
    """The `gravity` rows of `history-sensors.csv` (`Collector.historySensorsCSV`)."""
    rows: dict[int, GravityRow] = {}
    for rec in csv.reader(io.StringIO(text)):
        if len(rec) < 6 or rec[0] != "gravity":
            continue
        try:
            ts = int(rec[1])
            x, y, z = float(rec[2]), float(rec[3]), float(rec[4])
        except ValueError:
            continue
        dyn = float(rec[5]) if rec[5].strip() else None
        rows.setdefault(ts, GravityRow(x, y, z, dyn))
    return rows


@dataclass
class Session:
    name: str
    accel: dict[int, tuple[list[float], list[float], list[float]]]  # ts → (ax, ay, az) in g, uncalibrated
    gravity: dict[int, GravityRow]
    clipped_samples: int = 0
    coverage_complete: bool | None = None


def session_from_parts(name: str, imus: list[bytes], history_csv: str,
                       coverage: dict | None = None) -> Session:
    accel: dict[int, tuple[list[float], list[float], list[float]]] = {}
    clipped = 0
    for blob in imus:
        for r in decode_imus(blob):
            if r.ts in accel:  # duplicates: keep the first, as the export does
                continue
            c = r.columns
            n = SAMPLE_RATE
            clipped += sum(1 for v in c[:3 * n] if v >= I16_RAIL or v <= -I16_RAIL - 1)
            accel[r.ts] = ([v * ACCEL_SCALE for v in c[0:n]],
                           [v * ACCEL_SCALE for v in c[n:2 * n]],
                           [v * ACCEL_SCALE for v in c[2 * n:3 * n]])
    return Session(name, accel, parse_history_csv(history_csv), clipped,
                   None if coverage is None else bool(coverage.get("complete")))


def load_session(path: Path) -> Session:
    """An export ZIP, or the same files unpacked into a directory."""
    if path.is_dir():
        imus = [p.read_bytes() for p in sorted((path / "imu").glob("*.imus"))]
        hist = (path / "history-sensors.csv").read_text(encoding="utf-8")
        cov_path = path / "imu-coverage.json"
        cov = json.loads(cov_path.read_text()) if cov_path.exists() else None
        return session_from_parts(path.name, imus, hist, cov)
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        imus = [z.read(n) for n in sorted(names) if n.endswith(".imus")]
        hist_name = next((n for n in names if n.endswith("history-sensors.csv")), None)
        hist = z.read(hist_name).decode("utf-8") if hist_name else ""
        cov_name = next((n for n in names if n.endswith("imu-coverage.json")), None)
        cov = json.loads(z.read(cov_name)) if cov_name else None
    return session_from_parts(path.stem, imus, hist, cov)


# ═════════════════════════════════════ Small numerics ══════════════════════════════════════════════


def mean(v):
    return sum(v) / len(v)


def pstd(v, m=None):
    """Population SD, as `AccStats.std` computes it."""
    m = mean(v) if m is None else m
    return math.sqrt(sum((x - m) ** 2 for x in v) / len(v))


def quantile(v, q):
    """Linear-interpolation quantile (numpy's default), as `np.quantile` in the calibration loop."""
    s = sorted(v)
    pos = (len(s) - 1) * q
    lo = math.floor(pos)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def wls_line(x, y, w):
    """Weighted least squares y ≈ a + b·x. Returns (a, b), or None for a degenerate design."""
    sw = sum(w)
    if sw <= 0:
        return None
    mx = sum(wi * xi for wi, xi in zip(w, x)) / sw
    my = sum(wi * yi for wi, yi in zip(w, y)) / sw
    sxx = sum(wi * (xi - mx) ** 2 for wi, xi in zip(w, x))
    if sxx <= 1e-18:
        return None
    b = sum(wi * (xi - mx) * (yi - my) for wi, xi, yi in zip(w, x, y)) / sxx
    return my - b * mx, b


def pearson(x, y):
    n = len(x)
    if n < 3:
        return None
    mx, my = mean(x), mean(y)
    sxx = sum((a - mx) ** 2 for a in x)
    syy = sum((b - my) ** 2 for b in y)
    if sxx <= 1e-18 or syy <= 1e-18:
        return None
    return sum((a - mx) * (b - my) for a, b in zip(x, y)) / math.sqrt(sxx * syy)


# ═══════════════════════════════════ Butterworth low-pass ═══════════════════════════════════════════


def butterworth4_lowpass(fc: float, fs: float) -> tuple[list[float], list[float]]:
    """4th-order Butterworth low-pass coefficients (B, A), ported line for line from
    `LowpassFilter.CoefficientsButterworth4LP` (itself after Exstrom Laboratories)."""
    order = 4
    if fc >= fs / 2:
        fc = (fs / 2) * 0.999
    w = min(fc / (fs / 2), 0.999)
    tcof = [0] * (order + 1)
    tcof[0], tcof[1] = 1, order
    prev = order
    for i in range(2, order // 2 + 1):
        prev = (order - i + 1) * prev // i
        tcof[i] = prev
        tcof[order - i] = prev
    tcof[order - 1], tcof[order] = order, 1
    omega = math.pi * w
    fomega = math.sin(omega)
    parg0 = math.pi / (2 * order)
    sf = 1.0
    for i in range(order // 2):
        sf *= 1.0 + fomega * math.sin((2 * i + 1) * parg0)
    fomega = math.sin(omega / 2.0)
    sf = fomega ** order / sf
    b = [sf * t for t in tcof]
    theta = math.pi * w
    binom = [0.0] * (2 * order)
    for i in range(order):
        parg = math.pi * (2 * i + 1) / (2 * order)
        a = 1.0 + math.sin(theta) * math.sin(parg)
        binom[2 * i] = -math.cos(theta) / a
        binom[2 * i + 1] = -math.sin(theta) * math.cos(parg) / a
    poly = [0.0] * (2 * order)
    for i in range(order):
        for j in range(i, 0, -1):
            poly[2 * j] += binom[2 * i] * poly[2 * (j - 1)] - binom[2 * i + 1] * poly[2 * (j - 1) + 1]
            poly[2 * j + 1] += binom[2 * i] * poly[2 * (j - 1) + 1] + binom[2 * i + 1] * poly[2 * (j - 1)]
        poly[0] += binom[2 * i]
        poly[1] += binom[2 * i + 1]
    a_coef = [1.0, poly[0], poly[2]] + [poly[2 * i - 2] for i in range(3, order + 1)]
    return b, a_coef


class LowpassFilter:
    """Transposed direct-form II, state carried across calls: `Filter.filter` exactly."""

    def __init__(self, fc: float = LOWPASS_HZ, fs: float = SAMPLE_RATE):
        self.b, self.a = butterworth4_lowpass(fc, fs)
        self.z = [0.0] * len(self.b)

    def reset(self):
        self.z = [0.0] * len(self.b)

    def filter(self, xs: list[float]) -> list[float]:
        b, a, z = self.b, self.a, self.z
        n = len(b)
        z[n - 1] = 0.0
        out = []
        for x in xs:
            y = b[0] * x + z[0]
            for j in range(1, n):
                z[j - 1] = b[j] * x + z[j] - a[j] * y
            out.append(y)
        return out


# ═════════════════════════════════════ Auto-calibration ═════════════════════════════════════════════


@dataclass
class Calibration:
    intercept: list[float]
    slope: list[float]
    points: int
    init_error: float | None
    error: float | None
    good: bool
    reason: str = ""

    def apply(self, x, y, z):
        return (self.intercept[0] + x * self.slope[0],
                self.intercept[1] + y * self.slope[1],
                self.intercept[2] + z * self.slope[2])


IDENTITY = Calibration([0.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0, None, None, False, "not run")


def stationary_points(session: Session) -> list[tuple[float, float, float]]:
    """Mean vectors of complete 10 s epochs whose per-axis population SD is below 13 mg."""
    out = []
    epochs: dict[int, list[int]] = {}
    for ts in session.accel:
        epochs.setdefault(ts // STATIONARY_EPOCH_S, []).append(ts)
    for key in sorted(epochs):
        secs = sorted(epochs[key])
        if len(secs) < STATIONARY_EPOCH_S:
            continue
        xs, ys, zs = [], [], []
        for ts in secs:
            ax, ay, az = session.accel[ts]
            xs += ax
            ys += ay
            zs += az
        mx, my, mz = mean(xs), mean(ys), mean(zs)
        if pstd(xs, mx) < STATIONARY_STD_G and pstd(ys, my) < STATIONARY_STD_G and pstd(zs, mz) < STATIONARY_STD_G:
            out.append((mx, my, mz))
    return out


def autocalibrate(points: list[tuple[float, float, float]]) -> Calibration:
    """`get_calibration_coefs` without the temperature column (a zero column adds nothing to the fit)."""
    xyz = [p for p in points if math.sqrt(p[0] ** 2 + p[1] ** 2 + p[2] ** 2) > 1e-8]
    n = len(xyz)

    def errors_of(curr):
        errs, target = [], []
        for c in curr:
            norm = math.sqrt(c[0] ** 2 + c[1] ** 2 + c[2] ** 2)
            t = (c[0] / norm, c[1] / norm, c[2] / norm)
            target.append(t)
            errs.append(math.sqrt(sum((c[k] - t[k]) ** 2 for k in range(3))))
        return errs, target

    errors, target = errors_of(xyz)
    init_err = mean(errors) if errors else None
    if n < CAL_MIN_SAMPLES:
        return Calibration([0.0] * 3, [1.0] * 3, n, init_err, init_err, False,
                           f"{n} stationary points, need {CAL_MIN_SAMPLES}")
    for k in range(3):
        axis = [p[k] for p in xyz]
        if max(axis) < CAL_CUBE_THRESHOLD or min(axis) > -CAL_CUBE_THRESHOLD:
            return Calibration([0.0] * 3, [1.0] * 3, n, init_err, init_err, False,
                               f"axis {'xyz'[k]} never beyond ±{CAL_CUBE_THRESHOLD} g: too few orientations")
    intercept, slope = [0.0] * 3, [1.0] * 3
    best_intercept, best_slope, best_err = intercept[:], slope[:], 1e16
    curr = xyz
    it = 0
    for it in range(CAL_MAX_ITERATIONS):
        maxerr = quantile(errors, 0.995)
        weights = [max(1 - e / maxerr, 0.0) for e in errors] if maxerr > 0 else [1.0] * n
        for k in range(3):
            fit = wls_line([c[k] for c in curr], [t[k] for t in target], weights)
            if fit is None:
                return Calibration([0.0] * 3, [1.0] * 3, n, init_err, init_err, False, "degenerate fit")
            p0, p1 = fit
            intercept[k] = p0 + intercept[k] * p1
            slope[k] = p1 * slope[k]
        curr = [tuple(intercept[k] + p[k] * slope[k] for k in range(3)) for p in xyz]
        errors, target = errors_of(curr)
        err = mean(errors)
        improvement = (best_err - err) / best_err
        if err < best_err:
            best_intercept, best_slope, best_err = intercept[:], slope[:], err
        if improvement < CAL_IMPROVEMENT_TOLERANCE:
            break
    good = not (best_err > CAL_ERROR_TOLERANCE or it + 1 == CAL_MAX_ITERATIONS)
    if not good:
        return Calibration([0.0] * 3, [1.0] * 3, n, init_err, init_err, False,
                           f"residual {best_err * 1000:.1f} mg above {CAL_ERROR_TOLERANCE * 1000:.0f} mg")
    return Calibration(best_intercept, best_slope, n, init_err, best_err, True)


# ═══════════════════════════════════ Reference ENMO ═════════════════════════════════════════════════


def reference_enmo_seconds(session: Session, cal: Calibration) -> dict[int, float]:
    """Per-second mean of filtered, truncated ENMO in mg. The filter state restarts after a gap."""
    out: dict[int, float] = {}
    lp = LowpassFilter()
    prev = None
    for ts in sorted(session.accel):
        if prev is not None and ts != prev + 1:
            lp.reset()
        prev = ts
        ax, ay, az = session.accel[ts]
        enmo = []
        for x, y, z in zip(ax, ay, az):
            cx, cy, cz = cal.apply(x, y, z)
            enmo.append(math.sqrt(cx * cx + cy * cy + cz * cz) - 1.0)
        filtered = lp.filter(enmo)
        out[ts] = 1000.0 * mean([max(v, 0.0) for v in filtered])
    return out


def minute_means(per_second: dict[int, float], min_seconds: int = MIN_SECONDS_PER_MINUTE) -> dict[int, float]:
    """Mean per UTC minute, keeping only minutes with at least `min_seconds` values."""
    buckets: dict[int, list[float]] = {}
    for ts, v in per_second.items():
        buckets.setdefault(ts - ts % 60, []).append(v)
    return {m: mean(v) for m, v in buckets.items() if len(v) >= min_seconds}


# ═════════════════════════════════ What is `@41`? ═══════════════════════════════════════════════════


def _norm(x, y, z):
    return math.sqrt(x * x + y * y + z * z)


def candidate_values(ax, ay, az, strap_gravity: GravityRow | None) -> dict[str, float]:
    """Plausible on-chip definitions of a "gravity-removed motion magnitude" over one second of raw,
    uncalibrated samples (the chip works on its own uncalibrated data). All in g."""
    vm = [_norm(x, y, z) for x, y, z in zip(ax, ay, az)]
    dev = [v - 1.0 for v in vm]
    gx, gy, gz = mean(ax), mean(ay), mean(az)
    dyn_self = [_norm(x - gx, y - gy, z - gz) for x, y, z in zip(ax, ay, az)]
    out = {
        "enmo_trunc_mean": mean([max(d, 0.0) for d in dev]),
        "enmo_abs_mean": mean([abs(d) for d in dev]),
        "vm_mean_minus_one": abs(mean(vm) - 1.0),
        "vm_rms_dev": math.sqrt(mean([d * d for d in dev])),
        "vm_std": pstd(vm),
        "dyn_mean_selfgrav": mean(dyn_self),
        "dyn_rms_selfgrav": math.sqrt(mean([d * d for d in dyn_self])),
        "vm_first_dev": abs(dev[0]),
        "vm_last_dev": abs(dev[-1]),
    }
    if strap_gravity is not None:
        g = strap_gravity
        dyn_strap = [_norm(x - g.x, y - g.y, z - g.z) for x, y, z in zip(ax, ay, az)]
        out["dyn_mean_strapgrav"] = mean(dyn_strap)
        out["dyn_first_strapgrav"] = dyn_strap[0]
        out["dyn_last_strapgrav"] = dyn_strap[-1]
    return out


@dataclass
class CandidateFit:
    name: str
    lag_s: int
    n: int
    r: float
    intercept: float
    slope: float  # @41 ≈ intercept + slope · candidate


def identify_dyn41(session: Session, lags=range(-2, 3)) -> list[CandidateFit]:
    """Pair every candidate with `@41` at ts + lag, keep each candidate's best lag, rank by r."""
    per_ts = {ts: candidate_values(*session.accel[ts], session.gravity.get(ts)) for ts in session.accel}
    names = sorted({k for v in per_ts.values() for k in v})
    fits = []
    for name in names:
        best = None
        for lag in lags:
            xs, ys = [], []
            for ts, vals in per_ts.items():
                row = session.gravity.get(ts + lag)
                if name in vals and row is not None and row.dyn is not None:
                    xs.append(vals[name])
                    ys.append(row.dyn)
            r = pearson(xs, ys)
            if r is None:
                continue
            line = wls_line(xs, ys, [1.0] * len(xs))
            if line is None:
                continue
            if best is None or r > best.r:
                best = CandidateFit(name, lag, len(xs), r, line[0], line[1])
        if best is not None:
            fits.append(best)
    return sorted(fits, key=lambda f: -f.r)


# ═════════════════════════════════ Mapping onto the reference ═══════════════════════════════════════


def dyn41_seconds(session: Session) -> dict[int, float]:
    return {ts: 1000.0 * row.dyn for ts, row in session.gravity.items() if row.dyn is not None}


def gravity_delta_minutes(session: Session) -> dict[int, float]:
    """Summed L2 distance between successive 1 Hz gravity vectors per minute: the WHOOP 4.0 activity
    proxy. A delta belongs to the minute of the LATER sample, as `CosinorAgeCalibration.gravityDeltaMinutes`
    assigns it. Minutes are kept only when the ENMO reference will also exist for them (checked by the caller)."""
    ts_sorted = sorted(session.gravity)
    out: dict[int, float] = {}
    counts: dict[int, int] = {}
    for prev, cur in zip(ts_sorted, ts_sorted[1:]):
        if cur != prev + 1:
            continue
        a, b = session.gravity[prev], session.gravity[cur]
        m = cur - cur % 60
        out[m] = out.get(m, 0.0) + _norm(b.x - a.x, b.y - a.y, b.z - a.z)
        counts[m] = counts.get(m, 0) + 1
    return {m: v for m, v in out.items() if counts[m] >= MIN_SECONDS_PER_MINUTE}


def paired(xs: dict[int, float], ys: dict[int, float]) -> tuple[list[float], list[float]]:
    keys = sorted(set(xs) & set(ys))
    return [xs[k] for k in keys], [ys[k] for k in keys]


@dataclass
class Mapping:
    kind: str
    params: dict
    knots: list[tuple[float, float]] = field(default_factory=list)

    def predict(self, x: float) -> float:
        if self.kind == "proportional":
            return self.params["k"] * x
        if self.kind == "affine":
            return self.params["a"] + self.params["k"] * x
        pts = self.knots
        if x <= pts[0][0]:
            return pts[0][1]
        if x >= pts[-1][0]:
            return pts[-1][1]
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            if x0 <= x <= x1:
                return y0 if x1 == x0 else y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        return pts[-1][1]


def fit_proportional(x, y) -> Mapping | None:
    sxx = sum(v * v for v in x)
    if sxx <= 1e-18:
        return None
    return Mapping("proportional", {"k": sum(a * b for a, b in zip(x, y)) / sxx})


def fit_affine(x, y) -> Mapping | None:
    line = wls_line(x, y, [1.0] * len(x))
    return None if line is None else Mapping("affine", {"a": line[0], "k": line[1]})


def fit_isotonic(x, y) -> Mapping | None:
    """Monotone non-decreasing least squares (pool-adjacent-violators) on x-sorted pairs; the prediction
    interpolates linearly between block centroids."""
    if len(x) < 2:
        return None
    pairs = sorted(zip(x, y))
    blocks: list[list[float]] = []  # [sum_x, sum_y, count]
    for xi, yi in pairs:
        blocks.append([xi, yi, 1.0])
        while len(blocks) > 1 and blocks[-2][1] / blocks[-2][2] >= blocks[-1][1] / blocks[-1][2]:
            sx, sy, c = blocks.pop()
            blocks[-1][0] += sx
            blocks[-1][1] += sy
            blocks[-1][2] += c
    knots = [(b[0] / b[2], b[1] / b[2]) for b in blocks]
    return Mapping("isotonic", {"blocks": len(knots)}, knots)


FITTERS = {"proportional": fit_proportional, "affine": fit_affine, "isotonic": fit_isotonic}


# ═══════════════════════════════════ Error in years ═════════════════════════════════════════════════


def cosinor_age(mesor: float, amplitude: float, acrophase_rad: float, age: float, sex: str = "generic"):
    """The published Gompertz mapping, in the reference's own order of operations. None when undefined."""
    c = COEFFS[sex]
    xb = mesor * c["mesor"] + amplitude * c["amp"] + acrophase_rad * c["phi"] + age * c["age"] + c["rate"]
    survival = math.exp(M_N * math.exp(xb) / M_D)
    if survival <= 0.0:
        return None
    outer = BA_N * math.log(survival)
    if outer <= 0.0 or not math.isfinite(outer):
        return None
    return math.log(outer) / BA_D + BA_I


def acrophase_radians(hours: float) -> float:
    return -(hours / 24.0) * 2.0 * math.pi


def age_shift(alpha: float, beta: float, mesor=DEFAULT_MESOR_MG, amplitude=DEFAULT_AMPLITUDE_MG,
              acrophase_h=DEFAULT_ACROPHASE_H, age=DEFAULT_AGE) -> dict[str, float]:
    """Years the estimate moves when the input reads `alpha + beta · truth`: the offset lifts the MESOR,
    the scale stretches both MESOR and amplitude, the acrophase is untouched."""
    phi = acrophase_radians(acrophase_h)
    out = {}
    for sex in COEFFS:
        base = cosinor_age(mesor, amplitude, phi, age, sex)
        moved = cosinor_age(alpha + beta * mesor, beta * amplitude, phi, age, sex)
        out[sex] = math.nan if base is None or moved is None else moved - base
    return out


@dataclass
class Evaluation:
    kind: str
    n_train: int
    n_test: int
    r_train: float | None
    mae_mg: float
    bias_mg: float
    alpha: float  # test: prediction ≈ alpha + beta · reference
    beta: float
    age_shift: dict[str, float]

    @property
    def worst_age_error(self) -> float:
        vals = [abs(v) for v in self.age_shift.values() if not math.isnan(v)]
        return max(vals) if vals else math.inf


def evaluate_mappings(train_x, train_y, test_x, test_y, **op) -> list[Evaluation]:
    """Fit each model on the training minutes, judge it on the held-out minutes. Empty when the training
    signal carries no usable relation to the reference (r below `MIN_USABLE_R`)."""
    r = pearson(train_x, train_y)
    if r is None or r < MIN_USABLE_R or len(test_x) < 3:
        return []
    out = []
    for kind, fitter in FITTERS.items():
        m = fitter(train_x, train_y)
        if m is None:
            continue
        pred = [m.predict(v) for v in test_x]
        line = wls_line(test_y, pred, [1.0] * len(pred))
        if line is None:
            continue
        mae = mean([abs(p - t) for p, t in zip(pred, test_y)])
        bias = mean([p - t for p, t in zip(pred, test_y)])
        out.append(Evaluation(kind, len(train_x), len(test_x), r, mae, bias, line[0], line[1],
                              age_shift(line[0], line[1], **op)))
    return sorted(out, key=lambda e: e.mae_mg)


# ═════════════════════════════════════ Decision ═════════════════════════════════════════════════════


def decide(identified: dict[str, list[CandidateFit]], dyn_eval: list[Evaluation],
           grav_eval: list[Evaluation]) -> dict:
    """Plan phase 3, applied exactly as registered.

    Two findings are kept apart. Knowing WHAT `@41` is (a fixed function of the raw second) does not make
    it convertible to ENMO by a constant: a different motion measure relates to ENMO only through how the
    wearer moves. What decides usability is the held-out error in years, so:
    case 1 = definition fixed AND within the year budget; case 2 = within budget, definition not fixed;
    case 3 = outside the budget, whatever the definition."""
    verdict: dict = {}
    tops = [fits[0] for fits in identified.values() if fits]
    same = bool(tops) and len(tops) == len(identified) and len({t.name for t in tops}) == 1
    deterministic = False
    if same and all(t.r >= DETERMINISTIC_MIN_R for t in tops):
        m = mean([t.slope for t in tops])
        deterministic = m != 0 and all(abs(t.slope / m - 1.0) <= DETERMINISTIC_SLOPE_SPREAD for t in tops)
    definition = {"fixed": deterministic,
                  "candidate": tops[0].name if deterministic else None,
                  "slopes": [t.slope for t in tops] if deterministic else None}
    best = dyn_eval[0] if dyn_eval else None
    within = best is not None and best.worst_age_error <= MAX_AGE_ERROR_YEARS
    worst = best.worst_age_error if best else None
    if within and deterministic:
        verdict["dyn41"] = {"case": 1, "meaning": "definition fixed and within the year budget: one constant mapping",
                            "model": best.kind, "worst_age_error_years": worst, "definition": definition}
    elif within:
        verdict["dyn41"] = {"case": 2, "meaning": "within the year budget: per-device self-calibration",
                            "model": best.kind, "worst_age_error_years": worst, "definition": definition}
    else:
        verdict["dyn41"] = {"case": 3, "meaning": "not usable for an absolute age",
                            "worst_age_error_years": worst, "definition": definition}
    best_grav = grav_eval[0] if grav_eval else None
    verdict["whoop4_gravity_delta"] = {
        "pass": bool(best_grav and best_grav.worst_age_error <= MAX_AGE_ERROR_YEARS),
        "model": best_grav.kind if best_grav else None,
        "worst_age_error_years": best_grav.worst_age_error if best_grav else None,
        "note": "fitted on WHOOP 5/MG gravity; a transfer to a real 4.0 is unverified",
    }
    return verdict


# ═══════════════════════════════════════ Commands ═══════════════════════════════════════════════════


def shared_calibration(sessions: list[Session]) -> Calibration:
    """One calibration from the stationary epochs of every session. All sessions come from the same strap,
    and a night alone rarely shows enough orientations to pass the ±0.3 g cube check."""
    return autocalibrate([p for s in sessions for p in stationary_points(s)])


def summarize(session: Session, cal: Calibration | None = None) -> tuple[dict, Calibration, dict[int, float]]:
    """Per-session facts. `cal` overrides the session's own calibration for the ENMO reference; the
    session's own result is still reported."""
    own = autocalibrate(stationary_points(session))
    cal = own if cal is None or not cal.good else cal
    enmo_s = reference_enmo_seconds(session, cal)
    dyn_s = dyn41_seconds(session)
    info = {
        "session": session.name,
        "imu_seconds": len(session.accel),
        "gravity_seconds": len(session.gravity),
        "dyn41_seconds": len(dyn_s),
        "overlap_seconds": len(set(session.accel) & set(dyn_s)),
        "coverage_complete": session.coverage_complete,
        "clipped_samples": session.clipped_samples,
        "calibration": calibration_info(own),
        "calibration_used": "own" if cal is own else "shared",
    }
    return info, cal, enmo_s


def calibration_info(cal: Calibration) -> dict:
    return {
        "good": cal.good, "reason": cal.reason, "stationary_points": cal.points,
        "intercept_mg": [round(v * 1000, 2) for v in cal.intercept],
        "slope": [round(v, 5) for v in cal.slope],
        "error_before_mg": None if cal.init_error is None else round(cal.init_error * 1000, 2),
        "error_after_mg": None if cal.error is None else round(cal.error * 1000, 2),
    }


def cmd_inspect(args) -> int:
    session = load_session(Path(args.export))
    info, _, enmo_s = summarize(session)
    dyn_s = dyn41_seconds(session)
    enmo_m, dyn_m = minute_means(enmo_s), minute_means(dyn_s)
    x, y = paired(dyn_m, enmo_m)
    info["minutes_paired"] = len(x)
    if x:
        info["minute_means_mg"] = {"dyn41": round(mean(x), 2), "reference_enmo": round(mean(y), 2)}
    info["candidates"] = [vars(f) for f in identify_dyn41(session)]
    print(json.dumps(info, indent=2))
    return 0


def cmd_fit(args) -> int:
    op = dict(mesor=args.mesor, amplitude=args.amplitude, acrophase_h=args.acrophase, age=args.age)
    identified: dict[str, list[CandidateFit]] = {}
    sessions_info = []
    dyn_minutes = {"train": ([], []), "test": ([], [])}
    grav_minutes = {"train": ([], []), "test": ([], [])}
    loaded = [(role, load_session(Path(p))) for role, paths in (("train", args.train), ("test", args.test))
              for p in paths]
    shared = shared_calibration([s for _, s in loaded])
    for role, session in loaded:
        info, _, enmo_s = summarize(session, shared)
        info["role"] = role
        sessions_info.append(info)
        identified[session.name] = identify_dyn41(session)
        enmo_m = minute_means(enmo_s)
        x, y = paired(minute_means(dyn41_seconds(session)), enmo_m)
        dyn_minutes[role][0].extend(x)
        dyn_minutes[role][1].extend(y)
        gx, gy = paired(gravity_delta_minutes(session), enmo_m)
        grav_minutes[role][0].extend(gx)
        grav_minutes[role][1].extend(gy)
    dyn_eval = evaluate_mappings(*dyn_minutes["train"], *dyn_minutes["test"], **op)
    grav_eval = evaluate_mappings(*grav_minutes["train"], *grav_minutes["test"], **op)
    report = {
        "operating_point": op,
        "shared_calibration": calibration_info(shared),
        "sessions": sessions_info,
        "dyn41_candidates": {k: [vars(f) for f in v[:5]] for k, v in identified.items()},
        "dyn41_mappings": [vars(e) for e in dyn_eval],
        "gravity_delta_mappings": [vars(e) for e in grav_eval],
        "decision": decide(identified, dyn_eval, grav_eval),
    }
    text = json.dumps(report, indent=2, default=lambda o: None)
    if args.json:
        Path(args.json).write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_inspect = sub.add_parser("inspect", help="check one export: coverage, calibration, @41 candidates")
    p_inspect.add_argument("export")
    p_inspect.set_defaults(func=cmd_inspect)
    p_fit = sub.add_parser("fit", help="fit on --train, judge on --test, apply the decision rule")
    p_fit.add_argument("--train", nargs="+", required=True)
    p_fit.add_argument("--test", nargs="+", required=True)
    p_fit.add_argument("--json")
    p_fit.add_argument("--mesor", type=float, default=DEFAULT_MESOR_MG)
    p_fit.add_argument("--amplitude", type=float, default=DEFAULT_AMPLITUDE_MG)
    p_fit.add_argument("--acrophase", type=float, default=DEFAULT_ACROPHASE_H, help="hours")
    p_fit.add_argument("--age", type=float, default=DEFAULT_AGE)
    p_fit.set_defaults(func=cmd_fit)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
