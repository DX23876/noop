"""Synthetic-only validation. Never load a user's archive in automated tests."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

import numpy as np

from reference import (at_25_hz, compare, complete_runs, crc16, ecg_beats,
                       match_beats, optical_beats, read_archive, rmssd, signals, valid_frame)


def frame(version, second, count=None):
    f = bytearray({16: 1584, 20: 2140}[version])
    f[0], f[8], f[9] = 0xAA, 47, version
    struct.pack_into('<H', f, 2, len(f)-8)
    struct.pack_into('<I', f, 15, second)
    if version == 16:
        struct.pack_into('<H', f, 32, 500 if count is None else count)
    else:
        f[26] = 50 if count is None else count
    return seal(f)


def seal(f):
    f = bytearray(f)
    struct.pack_into('<H', f, 6, crc16(f[:6]))
    struct.pack_into('<I', f, len(f)-4, zlib.crc32(f[8:-4]))
    return bytes(f)


def synthetic(bpm, modulation, fs, duration=35, inverted=False, delay=0.22):
    times = [0.37]
    while times[-1] < duration:
        times.append(times[-1] + 60/bpm + modulation*np.sin(len(times)*0.9))
    times = np.array(times[:-1])
    t = np.arange(int(fs*duration))/fs
    optical = np.zeros_like(t)
    for beat in times:
        z = np.maximum(0, t-beat-delay)
        optical += (z/0.045)**3*np.exp(-z/0.045)
    optical += 0.03*np.sin(2*np.pi*0.15*t)
    if inverted:
        optical = -optical
    return times, optical


class ArchiveTests(unittest.TestCase):
    def test_crc_header_payload_and_length_are_all_required(self):
        original = frame(16, 100)
        self.assertTrue(valid_frame(original))
        for offset in [0, 2, 6, 40, len(original)-1]:
            broken = bytearray(original)
            broken[offset] ^= 1
            self.assertFalse(valid_frame(broken))
        self.assertFalse(valid_frame(original+b'\0'))
        self.assertFalse(valid_frame(original[:-1]))
        self.assertFalse(valid_frame(b''))

    def test_signed_ecg_and_optical_values(self):
        r16, r20 = bytearray(frame(16, 100)), bytearray(frame(20, 100))
        values = [-131072, -1, 0, 1, 131071]
        for i, value in enumerate(values):
            packed = value & 0x3FFFF
            r16[34+i*3:37+i*3] = bytes([packed >> 16, (packed >> 8) & 255, packed & 255])
        struct.pack_into('<5i', r20, 47, -524288, -1, 0, 1, 524287)
        ecg, optical, _ = signals({(16,100):seal(r16),(20,100):seal(r20)}, [100])
        np.testing.assert_array_equal(ecg[:5], values)
        np.testing.assert_array_equal(optical[:5], [-524288, -1, 0, 1, 524287])

    def test_gaps_partial_seconds_rate_and_config_split_runs(self):
        records = {(v,s):frame(v,s) for v in (16,20) for s in range(100,110)}
        records.pop((20,102))
        records[(16,104)] = frame(16,104,245)
        records[(20,106)] = frame(20,106,25)
        for s in [108,109]:
            f = bytearray(records[(20,s)])
            f[27] = 2
            records[(20,s)] = seal(f)
        self.assertEqual(complete_runs(records), [[100,101],[103],[105],[107],[108,109]])

    def test_uninterpreted_header_disagreement_excluded(self):
        f = bytearray(frame(20,100)); f[19] = 1
        self.assertEqual(complete_runs({(16,100):frame(16,100),(20,100):seal(f)}), [])

    def test_duplicates_and_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'synthetic.jsonl'
            line = json.dumps({'frameHex':frame(16,100).hex()})+'\n'
            path.write_text(line*2)
            records, counts = read_archive(path,100,100)
            self.assertEqual(len(records),1)
            self.assertEqual(counts['exact_duplicates'],1)
            path.write_text(line+json.dumps({'frameHex':frame(16,100,245).hex()})+'\n')
            with self.assertRaises(ValueError):
                read_archive(path,100,100)


class TimingTests(unittest.TestCase):
    def test_one_to_one_matching_counts_extra_and_missing(self):
        r = np.arange(20, dtype=float)
        p = np.delete(r+0.23,5)
        p = np.sort(np.append(p,8.26))
        pairs = match_beats(r,p,0.23)
        self.assertEqual(len(pairs),19)
        self.assertEqual(len({j for _,j in pairs}),19)

    def test_no_rmssd_across_a_missing_beat(self):
        r = np.arange(12, dtype=float)
        p = np.delete(r+0.23,5)
        result = compare(r,p,12)
        self.assertEqual(result['missed'],1)
        self.assertEqual(result['false'],0)
        self.assertEqual(result['successive_interval_pairs'],4)
        self.assertAlmostEqual(result['pp_rmssd_ms'],0,places=8)
        self.assertGreater(result['raw_pp_rmssd_ms'],100)

    def test_constant_latency_does_not_change_variability(self):
        rr = 0.8+0.06*np.sin(np.arange(50)*0.9)
        r = np.cumsum(rr)
        for lag in (0.12,0.23,0.45):
            result = compare(r,r+lag,r[-1]+2)
            self.assertAlmostEqual(result['rr_rmssd_ms'],result['pp_rmssd_ms'],places=8)
            self.assertAlmostEqual(result['lag_median_ms'],lag*1000,places=8)

    def test_varying_latency_changes_optical_intervals(self):
        r = np.arange(40,dtype=float)
        for amplitude in (0.005,0.015,0.030):
            p = r+0.23+amplitude*np.sin(np.arange(40)*0.9)
            result = compare(r,p,40)
            self.assertEqual(result['rr_rmssd_ms'],0)
            self.assertGreater(result['pp_rmssd_ms'],amplitude*300)
            self.assertLess(result['pp_rmssd_ms'],amplitude*700)

    def test_ecg_tracks_multiple_rates_variabilities_and_polarities(self):
        for bpm in (45,75,130,175):
            for modulation in (0.015,0.060):
                r,_ = synthetic(bpm,modulation,500)
                t = np.arange(35*500)/500
                x = sum(np.exp(-0.5*((t-b)/0.012)**2) for b in r)
                for sign in (-1,1):
                    detected,_ = ecg_beats(sign*x)
                    core = r[(r>1)&(r<33)]
                    pairs = match_beats(core,detected,0,tolerance=0.005)
                    self.assertEqual(len(pairs),len(core))

    def test_optical_tracks_multiple_rates_and_variabilities_at_25_and_50(self):
        for bpm in (45,75,120):
            for modulation in (0.015,0.060,0.100):
                for fs in (25,50):
                    with self.subTest(bpm=bpm,modulation=modulation,fs=fs):
                        r,x = synthetic(bpm,modulation,fs)
                        beats,_ = optical_beats(x,fs)
                        for method in ('rise_foot', 'adaptive_foot'):
                            p = beats[method]
                            # Tangent foot is a shape-defined fiducial, not physical onset.
                            core = r[(r>2)&(r<32)]
                            pairs = match_beats(core,p,0.23,tolerance=0.09)
                            self.assertEqual(len(pairs),len(core))
                            measured = np.array([p[j] for _,j in pairs])
                            self.assertLess(abs(rmssd(np.diff(core)*1000)-rmssd(np.diff(measured)*1000)),4.0)

    def test_inversion_and_adc_offset_preserve_times(self):
        _,x = synthetic(73,0.050,50)
        baseline,_ = optical_beats(x)
        for transformed in (-x,x+400000,-x+400000):
            actual,_ = optical_beats(transformed)
            for method in ('rise_foot', 'adaptive_foot'):
                np.testing.assert_allclose(baseline[method],actual[method],atol=1e-7)

    def test_local_threshold_tracks_amplitude_changes_without_ecg_guidance(self):
        for bpm in (55,85,115):
            r,x = synthetic(bpm,0.050,50)
            t = np.arange(len(x))/50
            x *= np.where(t < 12, 0.15, 1.0)
            beats,_ = optical_beats(x)
            # Stay away from the amplitude step: the offline threshold looks
            # four seconds ahead/behind; the transition is not a steady regime.
            core = r[(r>2)&(r<7)]
            adaptive = match_beats(core,beats['adaptive_foot'],0.23,tolerance=0.09)
            fixed = match_beats(core,beats['rise_foot'],0.23,tolerance=0.09)
            self.assertEqual(len(adaptive),len(core))
            self.assertLess(len(fixed),len(core))

    def test_downsample_does_not_introduce_adc_edge_impulses(self):
        _,x = synthetic(67,0.050,50)
        np.testing.assert_allclose(at_25_hz(x),at_25_hz(x+400000),atol=1e-8)

    def test_flat_optical_signal_has_no_beats(self):
        beats,_ = optical_beats(np.full(1500,400000.0))
        self.assertTrue(all(len(x)==0 for x in beats.values()))

    def test_nonfinite_signal_refused(self):
        x = np.zeros(1500); x[30] = np.nan
        with self.assertRaises(ValueError):
            optical_beats(x)

    def test_short_and_unsupported_rate_refused(self):
        for x,fs in [(np.zeros(50),50),(np.zeros(500),24)]:
            with self.assertRaises(ValueError):
                optical_beats(x,fs)


if __name__ == '__main__':
    unittest.main()
