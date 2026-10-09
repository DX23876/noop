"""Offline RR sequence audit using the app's exported source selection and cleaner.

Private inputs/outputs must remain outside Git. Seconds select coarse capture blocks;
within a block we align ordered interval patterns and verify cumulative durations.
No second-by-second nearest timestamp matching, RR repair, or rhythm classification.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

import numpy as np

from reference import read_archive, complete_runs, signals, ecg_beats, rmssd


def align_intervals(reference, observed, scale_ms=20., gap_penalty=4., require_unique=False):
    """Local monotone sequence alignment; return matched original interval indices.

    2 - |RR error|/scale reward; a skipped interval costs gap_penalty. Fixed defaults
    are deliberately independent of timestamps and heart rate. This locates a partial
    sequence, NOT an independent accuracy oracle. Always inspect the error trace and
    cumulative residuals and check other scale settings. Constant sequences are ambiguous.
    """
    ref, obs = np.asarray(reference, float), np.asarray(observed, float)
    if (not np.all(np.isfinite(ref)) or not np.all(np.isfinite(obs))
            or np.any(ref <= 0) or np.any(obs <= 0)):
        raise ValueError('RR intervals must be finite and positive')
    score = np.zeros((len(ref)+1, len(obs)+1))
    trace = np.zeros(score.shape, dtype=np.uint8)
    for i in range(1, len(ref)+1):
        for j in range(1, len(obs)+1):
            options = [0., score[i-1, j-1]+2-abs(ref[i-1]-obs[j-1])/scale_ms,
                       score[i-1, j]-gap_penalty, score[i, j-1]-gap_penalty]
            step = int(np.argmax(options))
            score[i, j], trace[i, j] = options[step], step
    maximum = float(np.max(score))
    if require_unique and maximum > 0 and np.count_nonzero(np.abs(score-maximum)<1e-9)>1:
        raise ValueError('Indistinguishable interval sequence phases')
    i, j = np.unravel_index(np.argmax(score), score.shape)
    pairs = []
    while trace[i, j]:
        step = trace[i, j]
        if step == 1:
            pairs.append((int(i-1), int(j-1)))
            i, j = i-1, j-1
        elif step == 2:
            i -= 1
        else:
            j -= 1
    return list(reversed(pairs))


def exact_subsequence_mappings(reference, observed, max_solutions=64):
    """All order-preserving exact-value maps; never choose between equal-RR beats by fit.

    This is a transport identity cross-check, not ECG truth. Input must be bounded
    to an independently established overlap; non-subsequences return no solutions.
    Refuse combinatorial ambiguity rather than silently truncate it.
    """
    solutions = []
    def visit(start, j, chosen):
        if j == len(observed):
            solutions.append(chosen)
            if len(solutions) > max_solutions:
                raise ValueError('Too many indistinguishable RR orderings')
            return
        for i in range(start, len(reference)-(len(observed)-j)+1):
            if reference[i] == observed[j]:
                visit(i+1, j+1, chosen+[(i,j)])
    visit(0, 0, [])
    return solutions


def order_rows(rows):
    # Same order as Reads.rrIntervals. ord/seq are batch-local, not globally unique.
    return sorted(rows, key=lambda r: (r['ts'], -1 if r.get('ord') is None else r['ord'],
                                      r['rrMs'], r.get('seq', 0)))


def delivery_blocks(rows, discontinuity_seconds=3.):
    """Coarse clock discontinuities split trains; they do NOT date individual beats.

    Accumulating successive RR since the block start detects missing spans even if
    several small discrepancies accumulate. A clock jump has the same signature and
    cannot be diagnosed as sensor failure from this table alone.
    """
    blocks = []
    for index, row in enumerate(rows):
        if not blocks:
            blocks.append([])
        block = blocks[-1]
        if block:
            cumulative = sum(rows[k]['rrMs'] for k in block[1:])/1000 + row['rrMs']/1000
            elapsed = row['ts']-rows[block[0]]['ts']
            if abs(elapsed-cumulative) > discontinuity_seconds:
                blocks.append([])
        blocks[-1].append(index)
    return blocks


def paired_metrics(reference, observed, pairs, accepted=None):
    """Use the SAME intervals; no RMSSD difference crosses a skip or rejected row."""
    ref, obs = np.asarray(reference), np.asarray(observed)
    usable = pairs if accepted is None else [(i, j) for i, j in pairs if j in accepted]
    error = np.array([obs[j]-ref[i] for i, j in usable])
    dr, db = [], []
    for (i0, j0), (i1, j1) in zip(usable, usable[1:]):
        if i1 == i0+1 and j1 == j0+1:
            dr.append(ref[i1]-ref[i0]); db.append(obs[j1]-obs[j0])
    rms = lambda x: float(np.sqrt(np.mean(np.square(x)))) if len(x) else None
    return dict(intervals=len(usable), successive_pairs=len(dr),
                ecg_rmssd_ms=rms(dr), band_rmssd_ms=rms(db),
                bias_ms=float(np.mean(error)) if len(error) else None,
                mae_ms=float(np.mean(np.abs(error))) if len(error) else None,
                error_sd_ms=float(np.std(error, ddof=1)) if len(error)>1 else None,
                max_abs_error_ms=float(np.max(np.abs(error))) if len(error) else None,
                errors_over_10ms=int(np.count_nonzero(np.abs(error)>10)),
                errors_over_20ms=int(np.count_nonzero(np.abs(error)>20)))


def cumulative_residuals(reference, observed, pairs):
    """Verify each contiguous match run by cumulative durations, without a rate fit.

    A skipped interval starts a new run. Its unknown delivery duration is never
    silently glued to its neighbours. Report resets and total coverage separately.
    First interval starts at phase zero; centring removes only one constant per run.
    """
    runs, current, previous = [], [], None
    for i, j in pairs:
        if previous is not None and (i != previous[0]+1 or j != previous[1]+1):
            runs.append(current); current = []
        current.append(float(observed[j]-reference[i])); previous = (i, j)
    if current:
        runs.append(current)
    return [np.cumsum([0.]+errors).tolist() for errors in runs]


def audit_block(reference_times, rows, analysis, scale_ms=20.):
    rr = np.diff(reference_times)*1000
    band = np.array([r['rrMs'] for r in rows], float)
    if min(len(rr),len(band)) < 6:
        return dict(status='insufficient_sequence_overlap', matched=0)
    try:
        pairs = align_intervals(rr, band, scale_ms, require_unique=True)
    except ValueError as error:
        if str(error) != 'Indistinguishable interval sequence phases':
            raise
        return dict(status='ambiguous_sequence_phase')
    if len(pairs) < 6:
        return dict(status='insufficient_sequence_overlap', matched=len(pairs))
    first_i, first_j = pairs[0]; last_i, last_j = pairs[-1]
    # Extrapolate only the unpaired edges with ordered cumulative RR durations.
    # This counts unexplained intervals INSIDE the ECG extent as extras. True
    # outside-recording intervals are not false detections.
    phase = reference_times[first_i] - np.sum(band[:first_j])/1000
    ends = phase + np.cumsum(band)/1000
    inside = set(j for j in range(first_j) if ends[j] > reference_times[0]+1e-9)
    inside.update(range(first_j, last_j+1))
    tail_end = reference_times[last_i+1]
    for j in range(last_j+1, len(band)):
        tail_end += band[j]/1000
        if tail_end <= reference_times[-1]+1e-9:
            inside.add(j)
    accepted = set(analysis['originalIndices'])
    matched_js = {j for _, j in pairs}
    ambiguous = sum(1 for a,b in zip(rows,rows[1:])
                    if a['ts']==b['ts'] and a.get('ord')==b.get('ord'))
    residual = cumulative_residuals(rr, band, pairs)
    return dict(status='ok', reference_intervals=len(rr), matched=len(pairs),
                missing=len(rr)-len(pairs), extra=len(inside-matched_js),
                sensitivity=len(pairs)/len(rr), ordered_ties=ambiguous,
                first_reference_interval=first_i, last_reference_interval=last_i,
                matched_source_indices=sorted(matched_js),
                metrics=paired_metrics(rr, band, pairs),
                cleaned_metrics=paired_metrics(rr, band, pairs, accepted),
                matched_rejected=len(matched_js-accepted),
                app_analysis_for_delivery_block=analysis,
                cumulative_residual_runs_ms=residual,
                cumulative_span_ms=[max(r)-min(r) for r in residual],
                trace=[dict(reference_index=i, source_index=j,
                            ecg_ms=float(rr[i]), band_ms=float(band[j]),
                            error_ms=float(band[j]-rr[i]), accepted=j in accepted)
                       for i,j in pairs])


def transport_identity_check(reference_times, history_rows, other_rows, history_audit, other_analysis):
    """Cross-check two stored labels of the same RR train without choosing equal beats.

    Only supports a shared block start and an exact-value prefix ending at the last
    established history interval. Any differing value requires manual investigation;
    this is not a fallback that labels arbitrary nearby values as transport copies.
    """
    trace = history_audit.get('trace', [])
    if not trace or [t['source_index'] for t in trace] != list(range(len(trace))):
        return dict(status='unsupported_overlap')
    hist = [r['rrMs'] for r in history_rows[:len(trace)]]
    other = [r['rrMs'] for r in other_rows]
    maps = []
    length = 0
    for count in range(min(len(hist),len(other)), 5, -1):
        candidates = exact_subsequence_mappings(hist, other[:count])
        candidates = [m for m in candidates if m[0][0]==0 and m[-1][0]==len(hist)-1]
        if candidates:
            maps, length = candidates, count
            break
    if not maps:
        return dict(status='no_exact_transport_identity_bracket')
    rr = np.diff(reference_times)*1000
    mapped = [[(trace[i]['reference_index'],j) for i,j in pairs] for pairs in maps]
    accepted = set(other_analysis['originalIndices'])
    return dict(status='exact_value_transport_bracket', matched=length,
                missing=len(rr)-length, extra_within_bracket=0,
                sensitivity=length/len(rr), possible_assignments=len(maps),
                matched_rejected=len(set(range(length))-accepted),
                alternatives=[dict(pairs=m, metrics=paired_metrics(rr,other,m),
                                   cleaned_metrics=paired_metrics(rr,other,m,accepted),
                                   cumulative_residual_runs_ms=cumulative_residuals(rr,other,m))
                              for m in mapped])


def swift_analyze(executable, batches):
    result = subprocess.run([str(executable), '--analyze'], input=json.dumps(batches),
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('export', type=Path, help='JSON from actual Swift store read')
    parser.add_argument('--swift-tool', type=Path, required=True)
    parser.add_argument('--start', type=int, required=True)
    parser.add_argument('--end', type=int, required=True)
    args = parser.parse_args()
    exported = json.loads(args.export.read_text())
    records, integrity = read_archive(args.archive, args.start, args.end)
    runs = complete_runs(records)
    if len(runs) != 1 or len(runs[0]) < 10:
        raise SystemExit('Supply one complete shared R16/R20 run of at least 10 seconds')
    seconds = runs[0]
    r, _ = ecg_beats(signals(records, seconds)[0])
    r = r[(r>=1) & (r<len(seconds)-2)]
    sources = {str(channel): order_rows([row for row in exported['raw']
               if row.get('channel')==channel and row.get('suspect')!=1]) for channel in [5,7]}
    sources['AI12'] = exported['selected']  # DO NOT recreate or reorder the app resolver.
    output = dict(complete_seconds=len(seconds), reference_intervals=len(r)-1,
                  ecg_full_rmssd_ms=rmssd(np.diff(r)*1000), integrity=dict(integrity), sources={})
    # Context check uses all selected intervals in the relevant epoch segment.
    # These are source-selection segments, not necessarily sleep-window boundaries.
    selected_segment = [row for row in sources['AI12'] if row['ts']//300==seconds[0]//300]
    output['selected_segment_analysis'] = swift_analyze(args.swift_tool,
        [[row['rrMs'] for row in selected_segment]])[0]
    stored_blocks = {}
    for name, rows in sources.items():
        candidates = []
        for block in delivery_blocks(rows):
            selected = [rows[k] for k in block]
            # Clock only bounds possible capture overlap; allow ±5 s WHOOP drift.
            if selected[-1]['ts'] < seconds[0]-5 or selected[0]['ts'] > seconds[-1]+5:
                continue
            candidates.append(selected)
        analyses = swift_analyze(args.swift_tool, [[r['rrMs'] for r in b] for b in candidates])
        stored_blocks[name] = list(zip(candidates,analyses))
        results = []
        for block, analysis in zip(candidates, analyses):
            result = audit_block(r, block, analysis)
            result['block_start_relative_second'] = block[0]['ts']-seconds[0]
            result['block_intervals'] = len(block)
            if result['status']=='ok':
                result['alignment_scale_stable'] = all(
                    audit_block(r, block, analysis, scale).get('trace')==result['trace']
                    for scale in [10.,30.])
                matched_values = [item['band_ms'] for item in result['trace']]
                result['app_analysis_matched_only'] = swift_analyze(args.swift_tool,[matched_values])[0]
                if not result['alignment_scale_stable']:
                    result['status'] = 'ambiguous_alignment_do_not_use_as_point_estimate'
            results.append(result)
        output['sources'][name] = results
    # An independent cross-check for the two stored labels. Ambiguous equal-value
    # identity is retained as a range, never selected by the smaller ECG error.
    if len(stored_blocks['5'])==1 and len(stored_blocks['7'])==1:
        hist, _ = stored_blocks['5'][0]
        other, other_analysis = stored_blocks['7'][0]
        output['standard_transport_identity_check'] = transport_identity_check(
            r, hist, other, output['sources']['5'][0], other_analysis)
    print(json.dumps(output, indent=2, allow_nan=False))


if __name__=='__main__':
    main()
