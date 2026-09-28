#!/usr/bin/env python3
"""Pins `cosinor_calib.py` against references and synthetic data it must see through.

The filter is checked against numbers printed by the UK Biobank tool's own Java (`LowpassFilter(20, 100)`
compiled from OxWearables/biobankAccelerometerAnalysis @ 95e1d79), not against a re-reading of it. The
calibration, the `@41` identification and the mappings each have to recover SEVERAL injected values, and
pure noise must produce no mapping at all: one lucky match proves nothing (CLAUDE.md, derived signals).

Standard `unittest`, discovered by `tools-python.yml` alongside the other Tools/ suites.
"""

from __future__ import annotations

import math
import random
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cosinor_calib as cc  # noqa: E402

# `java Oracle` over LowpassFilter(20, 100): coefficients, a 12-sample impulse, then two 6-sample unit
# steps through the SAME filter object, so the state carried between calls is pinned too.
JAVA_B = [0.046582906636443676, 0.1863316265457747, 0.27949743981866204, 0.1863316265457747,
          0.046582906636443676]
JAVA_A = [1.0, -0.7820951980233377, 0.6799785269162995, -0.18267569775303233, 0.03011887504316925]
JAVA_IMPULSE = [0.046582906636443676, 0.22276389413610678, 0.42204463548136184, 0.3734456096956261,
                0.09096216022611278, -0.11240602647165217, -0.09425660156278788, 0.008084863267038736,
                0.04714207056576543, 0.017539206206808804, -0.014022455904599565, -0.014524975379625547]
JAVA_STEP1 = [0.04654208264960626, 0.2761017208139309, 0.6944711668006104, 1.0630825062103249,
              1.1535680277348117, 1.0432003764406284]
JAVA_STEP2 = [0.9500896712736562, 0.9577432157340873, 1.0041554864184838, 1.0215651410257016,
              1.0078243071111335, 0.9934873533781097]

T0 = 1_790_000_000  # a minute boundary: T0 % 60 == 20, so tests that need one use T0 - 20


def sphere_points(n):
    """Deterministic, evenly spread unit vectors (Fibonacci sphere)."""
    golden = math.pi * (3 - math.sqrt(5))
    out = []
    for i in range(n):
        z = 1 - 2 * (i + 0.5) / n
        r = math.sqrt(1 - z * z)
        out.append((r * math.cos(golden * i), r * math.sin(golden * i), z))
    return out


def to_raw(true_xyz, intercept, slope):
    """Invert calibration (true = intercept + raw · slope) and quantize the way the strap stores it."""
    return tuple(int(round(((true_xyz[k] - intercept[k]) / slope[k]) / cc.ACCEL_SCALE)) for k in range(3))


def make_session(seconds, true_sample, intercept=(0.0, 0.0, 0.0), slope=(1.0, 1.0, 1.0),
                 dyn=None, gravity=None, name="synth"):
    """Build a Session from `true_sample(ts, i) -> (x, y, z)` in g. `dyn(ts, ax, ay, az) -> g` sets `@41` for
    that second from its OWN raw (uncalibrated) samples; `gravity(ts)` sets the strap's 1 Hz vector."""
    records, csv_lines = [], ["stream,unix_s,v1,v2,v3,v4"]
    for ts in seconds:
        raw = [to_raw(true_sample(ts, i), intercept, slope) for i in range(cc.SAMPLE_RATE)]
        cols = [p[0] for p in raw] + [p[1] for p in raw] + [p[2] for p in raw] + [0] * (3 * cc.SAMPLE_RATE)
        records.append(cc.ImuRecord(ts, ts * 1000, cols))
    by_ts = {r.ts: r for r in records}
    for ts in seconds:
        gx, gy, gz = gravity(ts) if gravity else (0.0, 0.0, 1.0)
        value = ""
        if dyn is not None and ts in by_ts:
            c = by_ts[ts].columns
            n = cc.SAMPLE_RATE
            value = repr(dyn(ts, [v * cc.ACCEL_SCALE for v in c[:n]], [v * cc.ACCEL_SCALE for v in c[n:2 * n]],
                             [v * cc.ACCEL_SCALE for v in c[2 * n:3 * n]]))
        csv_lines.append(f"gravity,{ts},{gx},{gy},{gz},{value}")
    blob = cc.encode_imus(seconds[0] - seconds[0] % 1800, records)
    return cc.session_from_parts(name, [blob], "\n".join(csv_lines) + "\n", {"complete": True})


def moving_sample(seed):
    """Gravity along a slowly turning axis plus motion whose strength changes from second to second."""
    rng = random.Random(seed)
    amp = {}

    def sample(ts, i):
        if ts not in amp:
            amp[ts] = (rng.uniform(0.0, 0.6), rng.uniform(1.0, 4.0), rng.uniform(0, 2 * math.pi))
        a, f, ph = amp[ts]
        t = ts + i / cc.SAMPLE_RATE
        th = 0.02 * t
        g = (math.sin(th) * 0.3, math.cos(th) * 0.3, math.sqrt(1 - 0.09))
        m = a * math.sin(2 * math.pi * f * t + ph)
        return g[0] + m, g[1] + 0.5 * m, g[2] - 0.3 * m

    return sample


class FilterMatchesJava(unittest.TestCase):
    def test_coefficients(self):
        b, a = cc.butterworth4_lowpass(20, 100)
        for got, want in zip(b + a, JAVA_B + JAVA_A):
            self.assertAlmostEqual(got, want, places=14)

    def test_the_pipeline_uses_the_reference_filter(self):
        f = cc.LowpassFilter()  # the defaults `reference_enmo_seconds` runs with
        for got, want in zip(f.b + f.a, JAVA_B + JAVA_A):
            self.assertAlmostEqual(got, want, places=14)

    def test_state_carries_across_calls(self):
        f = cc.LowpassFilter(20, 100)
        impulse = [1.0] + [0.0] * 11
        for got, want in zip(f.filter(impulse), JAVA_IMPULSE):
            self.assertAlmostEqual(got, want, places=14)
        for got, want in zip(f.filter([1.0] * 6) + f.filter([1.0] * 6), JAVA_STEP1 + JAVA_STEP2):
            self.assertAlmostEqual(got, want, places=14)

    def test_passes_dc_and_halves_power_at_cutoff(self):
        b, a = cc.butterworth4_lowpass(20, 100)

        def gain(freq):
            w = 2 * math.pi * freq / 100
            num = sum(bk * complex(math.cos(-k * w), math.sin(-k * w)) for k, bk in enumerate(b))
            den = sum(ak * complex(math.cos(-k * w), math.sin(-k * w)) for k, ak in enumerate(a))
            return abs(num / den)

        self.assertAlmostEqual(gain(0), 1.0, places=9)
        self.assertAlmostEqual(gain(20), 1 / math.sqrt(2), places=6)
        self.assertLess(gain(45), 0.01)


class ImusFormat(unittest.TestCase):
    def records(self, n, start=T0):
        rng = random.Random(3)
        return [cc.ImuRecord(start + i, (start + i) * 1000 + 7,
                             [rng.randint(-32768, 32767) for _ in range(cc.SAMPLE_RATE * cc.AXES)]) for i in range(n)]

    def test_round_trip_across_blocks(self):
        recs = self.records(75)  # three blocks: 30 + 30 + 15
        back = cc.decode_imus(cc.encode_imus(T0 - T0 % 1800, recs))
        self.assertEqual([(r.ts, r.received_ms, r.columns) for r in back],
                         [(r.ts, r.received_ms, r.columns) for r in recs])

    def test_truncated_tail_keeps_earlier_blocks(self):
        blob = cc.encode_imus(0, self.records(45))
        self.assertEqual(len(cc.decode_imus(blob[:-10])), 30)

    def test_rejects_foreign_file(self):
        self.assertEqual(cc.decode_imus(b"NOTIMUS!" + bytes(40)), [])

    def test_history_csv(self):
        rows = cc.parse_history_csv("stream,unix_s,v1,v2,v3,v4\n"
                                    "heart_rate,5,61,,,\n"
                                    "gravity,5,0.1,0.2,0.97,0.0123\n"
                                    "gravity,6,0.1,0.2,0.97,\n")
        self.assertEqual(sorted(rows), [5, 6])
        self.assertAlmostEqual(rows[5].dyn, 0.0123)
        self.assertIsNone(rows[6].dyn)

    def test_zip_export_loads(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "noop-5mg-raw-x.zip"
            face_up = [0] * 200 + [4096] * 100 + [0] * 300  # az = 1 g, everything else 0
            blob = cc.encode_imus(0, [cc.ImuRecord(ts, 0, face_up) for ts in range(T0, T0 + 3)])
            with zipfile.ZipFile(path, "w") as z:
                z.writestr("imu/imu-a.imus", blob)
                z.writestr("history-sensors.csv", "stream,unix_s,v1,v2,v3,v4\ngravity,%d,0,0,1,0.01\n" % T0)
                z.writestr("imu-coverage.json", '{"complete": true}')
            loaded = cc.load_session(path)
        self.assertEqual(len(loaded.accel), 3)
        self.assertEqual(loaded.accel[T0][2][0], 1.0)
        self.assertTrue(loaded.coverage_complete)
        self.assertEqual(loaded.gravity[T0].dyn, 0.01)


class AutoCalibration(unittest.TestCase):
    def stationary_session(self, intercept, slope, n=80, seed=11):
        rng = random.Random(seed)
        dirs = sphere_points(n)
        seconds = list(range(T0 - T0 % 10, T0 - T0 % 10 + 10 * n))

        def sample(ts, i):
            d = dirs[(ts - seconds[0]) // 10]
            return tuple(d[k] + rng.gauss(0, 0.002) for k in range(3))

        return make_session(seconds, sample, intercept, slope)

    def test_recovers_several_injected_distortions(self):
        cases = [((0.02, -0.015, 0.03), (1.02, 0.98, 1.01)),
                 ((-0.04, 0.01, 0.0), (0.97, 1.03, 1.0)),
                 ((0.0, 0.035, -0.02), (1.0, 1.0, 0.95))]
        for intercept, slope in cases:
            with self.subTest(intercept=intercept, slope=slope):
                cal = cc.autocalibrate(cc.stationary_points(self.stationary_session(intercept, slope)))
                self.assertTrue(cal.good, cal.reason)
                for k in range(3):
                    self.assertAlmostEqual(cal.intercept[k], intercept[k], delta=0.002)
                    self.assertAlmostEqual(cal.slope[k], slope[k], delta=0.003)
                self.assertLess(cal.error, cal.init_error)

    def test_sessions_pool_their_orientations(self):
        # A night that only ever lies face-up and a walk that only ever hangs face-down each fail the cube
        # check alone; the same strap across both passes it and recovers the distortion.
        intercept, slope = (0.025, -0.02, 0.015), (1.015, 0.985, 1.02)
        dirs = sphere_points(120)
        halves = [[d for d in dirs if d[2] > 0], [d for d in dirs if d[2] <= 0]]
        sessions = []
        for n, half in enumerate(halves):
            rng = random.Random(40 + n)
            start = T0 - T0 % 10 + n * 86400
            secs = list(range(start, start + 10 * len(half)))
            sessions.append(make_session(
                secs, lambda ts, i, half=half, start=start, rng=rng:
                tuple(half[(ts - start) // 10][k] + rng.gauss(0, 0.002) for k in range(3)), intercept, slope))
        for s in sessions:
            self.assertFalse(cc.autocalibrate(cc.stationary_points(s)).good)
        shared = cc.shared_calibration(sessions)
        self.assertTrue(shared.good, shared.reason)
        for k in range(3):
            self.assertAlmostEqual(shared.intercept[k], intercept[k], delta=0.002)
            self.assertAlmostEqual(shared.slope[k], slope[k], delta=0.003)
        info, used, _ = cc.summarize(sessions[0], shared)
        self.assertEqual(info["calibration_used"], "shared")
        self.assertIs(used, shared)

    def test_refuses_without_enough_orientations(self):
        points = [(0.0, 0.05 * math.sin(i), 1.0) for i in range(80)]  # always face-up
        cal = cc.autocalibrate(points)
        self.assertFalse(cal.good)
        self.assertEqual(cal.slope, [1.0, 1.0, 1.0])

    def test_refuses_too_few_points(self):
        self.assertFalse(cc.autocalibrate(sphere_points(20)).good)

    def test_moving_epochs_are_not_stationary(self):
        session = make_session(list(range(T0 - T0 % 10, T0 - T0 % 10 + 40)), moving_sample(2))
        self.assertEqual(cc.stationary_points(session), [])


class ReferenceEnmo(unittest.TestCase):
    def test_still_reads_zero_and_constant_excess_reads_it(self):
        still = make_session(list(range(T0, T0 + 5)), lambda ts, i: (0.0, 0.0, 1.0))
        enmo = cc.reference_enmo_seconds(still, cc.IDENTITY)
        self.assertLess(max(enmo.values()), 0.3)
        heavy = make_session(list(range(T0, T0 + 5)), lambda ts, i: (0.0, 0.6, 1.1))
        enmo = cc.reference_enmo_seconds(heavy, cc.IDENTITY)
        want = 1000 * (math.sqrt(0.36 + 1.21) - 1)
        self.assertAlmostEqual(enmo[T0 + 4], want, delta=0.3)  # settled; the first second carries the step
        light = make_session(list(range(T0, T0 + 5)), lambda ts, i: (0.0, 0.0, 0.8))
        enmo = cc.reference_enmo_seconds(light, cc.IDENTITY)
        self.assertLess(enmo[T0 + 4], 0.3)  # |a| below 1 g is truncated to zero, not counted as 200 mg

    def test_filter_restarts_after_a_gap(self):
        # A documented deviation from the reference: the state of a heavy second must not ring into a
        # still second that follows a gap in the capture.
        seconds = [T0, T0 + 1, T0 + 10]
        session = make_session(seconds, lambda ts, i: (0.0, 0.0, 1.5) if ts < T0 + 10 else (0.0, 0.0, 1.0))
        self.assertEqual(cc.reference_enmo_seconds(session, cc.IDENTITY)[T0 + 10], 0.0)

    def test_minute_means_need_enough_seconds(self):
        m0 = T0 - T0 % 60
        per_s = {m0 + i: 10.0 for i in range(55)}
        per_s.update({m0 + 60 + i: 20.0 for i in range(30)})
        self.assertEqual(cc.minute_means(per_s), {m0: 10.0})


class Dyn41Identification(unittest.TestCase):
    CASES = [("enmo_trunc_mean", 1.0, 0), ("dyn_mean_selfgrav", 0.8, 0), ("vm_last_dev", 1.3, 1),
             ("dyn_rms_selfgrav", 2.0, -1)]

    def test_names_the_injected_definition_gain_and_lag(self):
        seconds = list(range(T0, T0 + 240))
        for name, gain, lag in self.CASES:
            with self.subTest(definition=name):
                session = make_session(seconds, moving_sample(7))
                truth = {ts: cc.candidate_values(*session.accel[ts], None)[name] for ts in seconds}
                # `@41` stamped at ts carries the definition evaluated over the raw second at ts - lag.
                session.gravity = {ts: cc.GravityRow(0.0, 0.0, 1.0, gain * truth[ts - lag])
                                   for ts in seconds if ts - lag in truth}
                top = cc.identify_dyn41(session)[0]
                self.assertEqual(top.name, name)
                self.assertEqual(top.lag_s, lag)
                self.assertAlmostEqual(top.slope, gain, delta=0.01)
                self.assertGreater(top.r, 0.999)


class Mappings(unittest.TestCase):
    def reference(self, n, seed):
        rng = random.Random(seed)
        return [rng.uniform(0, 300) for _ in range(n)]

    def test_affine_recovers_several_injected_maps(self):
        for alpha, beta in [(0.0, 1.0), (5.0, 0.8), (-3.0, 1.3), (12.0, 0.5)]:
            with self.subTest(alpha=alpha, beta=beta):
                ytr, yte = self.reference(200, 1), self.reference(150, 2)
                xtr = [(y - alpha) / beta for y in ytr]
                xte = [(y - alpha) / beta for y in yte]
                m = cc.fit_affine(xtr, ytr)
                self.assertAlmostEqual(m.params["a"], alpha, places=6)
                self.assertAlmostEqual(m.params["k"], beta, places=6)
                best = next(e for e in cc.evaluate_mappings(xtr, ytr, xte, yte) if e.kind == "affine")
                self.assertAlmostEqual(best.mae_mg, 0.0, places=6)
                self.assertLess(best.worst_age_error, 1e-6)

    def test_proportional_misses_an_offset_and_says_so(self):
        ytr, yte = self.reference(200, 3), self.reference(150, 4)
        xtr = [(y - 10.0) for y in ytr]
        xte = [(y - 10.0) for y in yte]
        prop = next(e for e in cc.evaluate_mappings(xtr, ytr, xte, yte) if e.kind == "proportional")
        self.assertGreater(prop.mae_mg, 1.0)

    def test_noise_yields_no_mapping(self):
        rng = random.Random(9)
        ytr, yte = self.reference(200, 5), self.reference(150, 6)
        xtr = [rng.uniform(0, 300) for _ in ytr]
        xte = [rng.uniform(0, 300) for _ in yte]
        self.assertEqual(cc.evaluate_mappings(xtr, ytr, xte, yte), [])

    def test_isotonic_is_monotone_and_follows_a_curve(self):
        x = [i * 0.5 for i in range(200)]
        y = [math.sqrt(v) * 20 for v in x]
        m = cc.fit_isotonic(x, y)
        ys = [k[1] for k in m.knots]
        self.assertEqual(ys, sorted(ys))
        for v in (3.0, 40.0, 90.0):
            self.assertAlmostEqual(m.predict(v), math.sqrt(v) * 20, delta=0.5)

    def test_gravity_delta_goes_to_the_later_minute(self):
        m0 = T0 - T0 % 60
        seconds = list(range(m0 - 1, m0 + 60))  # the first delta crosses into minute m0
        session = make_session(seconds, lambda ts, i: (0.0, 0.0, 1.0), gravity=lambda ts: (0.001 * (ts - m0), 0.0, 1.0))
        minutes = cc.gravity_delta_minutes(session)
        self.assertEqual(list(minutes), [m0])
        self.assertAlmostEqual(minutes[m0], 0.060, places=9)


class YearsAndDecision(unittest.TestCase):
    def test_gompertz_matches_the_reference(self):
        for sex, want in (("generic", 40.4054333204), ("female", 39.6765236784), ("male", 43.4054735692)):
            self.assertAlmostEqual(cc.cosinor_age(30, 25, -1.5, 40, sex), want, places=6)

    def test_sensitivity_table_in_the_plan(self):
        # (alpha, beta) → generic, male, rounded to 0.1 year as the plan prints them
        table = [((0, 0.8), 3.2, 3.3), ((0, 1.25), -4.0, -4.2), ((0, 2.0), -16.2, -16.6), ((10, 1.0), -2.9, -2.1)]
        for (alpha, beta), generic, male in table:
            shift = cc.age_shift(alpha, beta)
            self.assertEqual(round(shift["generic"], 1), generic)
            self.assertEqual(round(shift["male"], 1), male)

    def fit(self, name, r, slope):
        return cc.CandidateFit(name, 0, 100, r, 0.0, slope)

    def ev(self, worst):
        return cc.Evaluation("affine", 100, 100, 0.9, 1.0, 0.0, 0.0, 1.0, {"generic": worst})

    def test_case_1_needs_the_same_definition_everywhere_and_stable_slopes(self):
        ok = {"A": [self.fit("x", 0.995, 1.0)], "B": [self.fit("x", 0.993, 1.015)]}
        self.assertEqual(cc.decide(ok, [self.ev(0.5)], [])["dyn41"]["case"], 1)
        drift = {"A": [self.fit("x", 0.995, 1.0)], "B": [self.fit("x", 0.995, 1.05)]}
        self.assertEqual(cc.decide(drift, [self.ev(0.5)], [])["dyn41"]["case"], 2)
        mixed = {"A": [self.fit("x", 0.995, 1.0)], "B": [self.fit("y", 0.995, 1.0)]}
        self.assertEqual(cc.decide(mixed, [self.ev(0.5)], [])["dyn41"]["case"], 2)

    def test_a_fixed_definition_alone_is_not_enough(self):
        ok = {"A": [self.fit("x", 0.995, 1.0)], "B": [self.fit("x", 0.995, 1.0)]}
        verdict = cc.decide(ok, [self.ev(2.5)], [])["dyn41"]
        self.assertEqual(verdict["case"], 3)
        self.assertTrue(verdict["definition"]["fixed"])
        self.assertEqual(cc.decide(ok, [], [])["dyn41"]["case"], 3)

    def test_case_2_and_3_follow_the_year_budget(self):
        weak = {"A": [self.fit("x", 0.9, 1.0)]}
        self.assertEqual(cc.decide(weak, [self.ev(0.8)], [])["dyn41"]["case"], 2)
        self.assertEqual(cc.decide(weak, [self.ev(1.4)], [])["dyn41"]["case"], 3)
        self.assertEqual(cc.decide(weak, [], [])["dyn41"]["case"], 3)

    def test_whoop4_verdict(self):
        self.assertTrue(cc.decide({}, [], [self.ev(0.5)])["whoop4_gravity_delta"]["pass"])
        self.assertFalse(cc.decide({}, [], [self.ev(2.0)])["whoop4_gravity_delta"]["pass"])
        self.assertFalse(cc.decide({}, [], [])["whoop4_gravity_delta"]["pass"])


if __name__ == "__main__":
    unittest.main()
