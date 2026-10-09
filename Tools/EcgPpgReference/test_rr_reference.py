import unittest
import numpy as np
from check_swift_roster import check, EXPECTED

from rr_reference import (align_intervals, audit_block, cumulative_residuals,
                          delivery_blocks, exact_subsequence_mappings,
                          order_rows, paired_metrics, transport_identity_check)


class RRReferenceTests(unittest.TestCase):
    def pattern(self, base=900):
        return base + np.random.default_rng(712).uniform(-130, 130, 50)

    def test_varying_rates_errors_and_partial_coverage(self):
        for base in [600, 900, 1300]:
            ref = self.pattern(base)
            for error in [2, 7, 13]:
                obs = ref[12:36] + error
                pairs = align_intervals(ref, obs)
                self.assertEqual(pairs, [(i+12,i) for i in range(24)])
                metrics = paired_metrics(ref, obs, pairs)
                self.assertAlmostEqual(metrics['bias_ms'], error)
                self.assertAlmostEqual(metrics['mae_ms'], error)
                self.assertAlmostEqual(metrics['ecg_rmssd_ms'], metrics['band_rmssd_ms'])
                residual = cumulative_residuals(ref, obs, pairs)
                self.assertAlmostEqual(residual[0][-1], 24*error)

    def test_missing_and_additional_intervals_keep_original_indices(self):
        ref = self.pattern()
        obs = ref[5:45].tolist()
        obs[24:24] = [310.]
        del obs[12]
        expected = [(i+5, i if i<12 else i-1 if i<24 else i)
                    for i in range(40) if i!=12]
        pairs = align_intervals(ref, obs)
        self.assertEqual(pairs, expected)
        self.assertEqual(len(cumulative_residuals(ref, obs, pairs)), 3)
        self.assertEqual(paired_metrics(ref, obs, pairs)['successive_pairs'], len(pairs)-3)

    def test_cleaned_rmssd_never_bridges_rejection_or_missing_interval(self):
        for amplitude in [10, 30, 80]:
            ref = np.array([800,800+amplitude,800,900,800,800+amplitude,800.])
            pairs = [(i,i) for i in range(len(ref)) if i!=3]
            result = paired_metrics(ref, ref, pairs, accepted={0,1,2,4,5,6})
            self.assertEqual(result['successive_pairs'], 4)
            self.assertAlmostEqual(result['band_rmssd_ms'], amplitude)
            self.assertAlmostEqual(result['ecg_rmssd_ms'], amplitude)

    def test_order_uses_ord_before_rr_value_and_retains_seq_duplicates(self):
        rows = [dict(ts=10,ord=1,seq=0,rrMs=810),dict(ts=10,ord=0,seq=0,rrMs=920),
                dict(ts=10,ord=2,seq=1,rrMs=920)]
        for shift in [0,2,5]:
            shifted = [dict(r,ts=r['ts']+shift) for r in reversed(rows)]
            ordered = order_rows(shifted)
            self.assertEqual([r['rrMs'] for r in ordered], [920,810,920])
            self.assertEqual([r['seq'] for r in ordered], [0,0,1])

    def test_delivery_gap_splits_instead_of_concatenating_missing_time(self):
        for gap in [10,30,80]:
            rows = [dict(ts=i+(gap if i>=10 else 0),rrMs=1000) for i in range(20)]
            self.assertEqual(delivery_blocks(rows), [list(range(10)),list(range(10,20))])

    def test_identical_intervals_have_multiple_transport_assignments(self):
        for repeated in [751,809,922]:
            ref = [650,repeated,repeated,1000]
            obs = [650,repeated,1000]
            maps = exact_subsequence_mappings(ref,obs)
            self.assertEqual(maps, [[(0,0),(1,1),(3,2)],[(0,0),(2,1),(3,2)]])
            self.assertEqual(exact_subsequence_mappings(ref,[650,1234]), [])
        with self.assertRaisesRegex(ValueError,'indistinguishable'):
            exact_subsequence_mappings([800]*20,[800]*10)

    def test_insufficient_or_unrelated_sequences_are_not_accuracy_results(self):
        self.assertEqual(align_intervals([800]*30,[1400]*20), [])
        rows = [dict(ts=i,rrMs=800) for i in range(4)]
        report = audit_block(np.arange(8)*.8,rows,{'originalIndices':list(range(4))})
        self.assertEqual(report['status'],'insufficient_sequence_overlap')

    def test_nonfinite_or_nonpositive_rr_refused(self):
        for bad in [float('nan'), float('inf'),0,-500]:
            with self.assertRaises(ValueError):
                align_intervals([800,bad],[800,810])

    def test_transport_crosscheck_preserves_equal_value_ambiguity(self):
        for base in [650,850,1100]:
            history = [base + x for x in [0,40,90,65,55,45,45,60,120]]
            observed = history[:6] + history[7:]
            times = np.r_[0,np.cumsum(history)/1000]
            rows = [dict(ts=i,rrMs=rr,ord=0,seq=0) for i,rr in enumerate(history)]
            other = [dict(ts=i+2,rrMs=rr,ord=0,seq=0) for i,rr in enumerate(observed)]
            h = audit_block(times,rows,{'originalIndices':list(range(9))})
            out = transport_identity_check(times,rows,other,h,{'originalIndices':list(range(8))})
            self.assertEqual(out['possible_assignments'],2)
            self.assertEqual(out['matched'],8)
            self.assertEqual(out['missing'],1)
            self.assertEqual(out['matched_rejected'],0)
            for alternative in out['alternatives']:
                self.assertAlmostEqual(alternative['metrics']['mae_ms'],0)
                self.assertEqual(alternative['metrics']['successive_pairs'],6)

    def test_audit_counts_false_interval_inside_bracket(self):
        rr = self.pattern()
        observed = rr.tolist()
        observed[25:25]=[310.]
        rows = [dict(ts=i,rrMs=v,ord=0,seq=0) for i,v in enumerate(observed)]
        result = audit_block(np.r_[0,np.cumsum(rr)/1000],rows,
                             {'originalIndices':list(range(len(rows)))})
        self.assertEqual(result['matched'],len(rr))
        self.assertEqual(result['extra'],1)
        self.assertEqual(result['missing'],0)

    def test_swift_gate_requires_exact_roster_and_zero_non_success(self):
        lines = [f"Test Case '-[Module.{item.replace('.', ' ')}]' passed (0.1 seconds)."
                 for item in sorted(EXPECTED)]
        check('\n'.join(lines))
        for bad in [lines[:-1], lines+lines[:1], [],
                    [line.replace('passed','skipped',1) for line in lines],
                    [line.replace('passed','failed',1) for line in lines]]:
            with self.assertRaises(ValueError):
                check('\n'.join(bad))

    def test_constant_interval_phase_is_not_fabricated(self):
        for base in [600,900,1200]:
            rows = [dict(ts=i,rrMs=base,ord=0,seq=0) for i in range(12)]
            result = audit_block(np.arange(31)*base/1000,rows,{'originalIndices':list(range(12))})
            self.assertEqual(result['status'],'ambiguous_sequence_phase')
