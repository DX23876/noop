"""CI entry point: a stable test roster, no skips and no non-success results."""
import sys
import unittest

import test_reference
import test_rr_reference


EXPECTED = {
    'RRReferenceTests.test_constant_interval_phase_is_not_fabricated',
    'RRReferenceTests.test_swift_gate_requires_exact_roster_and_zero_non_success',
    'RRReferenceTests.test_transport_crosscheck_preserves_equal_value_ambiguity',
    'RRReferenceTests.test_audit_counts_false_interval_inside_bracket',
    'RRReferenceTests.test_varying_rates_errors_and_partial_coverage',
    'RRReferenceTests.test_missing_and_additional_intervals_keep_original_indices',
    'RRReferenceTests.test_cleaned_rmssd_never_bridges_rejection_or_missing_interval',
    'RRReferenceTests.test_order_uses_ord_before_rr_value_and_retains_seq_duplicates',
    'RRReferenceTests.test_delivery_gap_splits_instead_of_concatenating_missing_time',
    'RRReferenceTests.test_identical_intervals_have_multiple_transport_assignments',
    'RRReferenceTests.test_insufficient_or_unrelated_sequences_are_not_accuracy_results',
    'RRReferenceTests.test_nonfinite_or_nonpositive_rr_refused',
    'ArchiveTests.test_crc_header_payload_and_length_are_all_required',
    'ArchiveTests.test_duplicates_and_conflicts',
    'ArchiveTests.test_gaps_partial_seconds_rate_and_config_split_runs',
    'ArchiveTests.test_signed_ecg_and_optical_values',
    'ArchiveTests.test_uninterpreted_header_disagreement_excluded',
    'TimingTests.test_constant_latency_does_not_change_variability',
    'TimingTests.test_downsample_does_not_introduce_adc_edge_impulses',
    'TimingTests.test_ecg_tracks_multiple_rates_variabilities_and_polarities',
    'TimingTests.test_flat_optical_signal_has_no_beats',
    'TimingTests.test_inversion_and_adc_offset_preserve_times',
    'TimingTests.test_local_threshold_tracks_amplitude_changes_without_ecg_guidance',
    'TimingTests.test_no_rmssd_across_a_missing_beat',
    'TimingTests.test_nonfinite_signal_refused',
    'TimingTests.test_one_to_one_matching_counts_extra_and_missing',
    'TimingTests.test_optical_tracks_multiple_rates_and_variabilities_at_25_and_50',
    'TimingTests.test_short_and_unsupported_rate_refused',
    'TimingTests.test_varying_latency_changes_optical_intervals',
}


def tests(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from tests(item)
        else:
            yield item


suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromModule(module)
                           for module in [test_reference, test_rr_reference])
actual = [item.id().split('.',1)[1] for item in tests(suite)]
if set(actual) != EXPECTED or len(actual) != len(EXPECTED):
    raise SystemExit(f'Test roster changed: missing={EXPECTED-set(actual)}, extra={set(actual)-EXPECTED}')
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() and not result.skipped
         and not result.expectedFailures and result.testsRun == len(EXPECTED) else 1)
