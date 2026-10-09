"""Validate focused XCTest logs: exact successful roster, no missing/skipped tests.

Usage: check_swift_roster.py STORE_LOG ANALYTICS_LOG
Run on macOS (same XCTest format as the Swift package CI).
"""
from pathlib import Path
import re
import sys

EXPECTED = {
    'ReadOnlyStoreTests.testMissingFileIsNotCreated',
    'ReadOnlyStoreTests.testDoesNotMigrateOrAdoptAnOldSchema',
    'ReadOnlyStoreTests.testWALAndSharedResolverAgreeForVariableDriftAndWindowWidths',
    'ReadOnlyStoreTests.testStandardObservationCanBePromotedOutOfItsChannelWithoutLosingHistory',
    'HRVCleanProvenanceTests.testOriginalIndicesTrackRepeatedValuesAndVaryingOutliers',
    'HRVCleanProvenanceTests.testShortAndEmptySeriesRetainActualProvenanceWhenAnalysisIsNil',
    'HRVCleanProvenanceTests.testSmallTimingErrorsAreNotMistakenForOutlierRejection',
}

def check(logs):
    entries = re.findall(r"Test Case '-\[\w+\.(\w+) (test\w+)\]' (passed|failed|skipped)", logs)
    focused = [(f'{cls}.{name}',status) for cls,name,status in entries
               if cls in ('ReadOnlyStoreTests','HRVCleanProvenanceTests')]
    names = [name for name,_ in focused]
    if (set(names)!=EXPECTED or len(names)!=len(EXPECTED)
            or any(status!='passed' for _,_,status in entries)):
        raise ValueError(f'Expected all seven focused XCTest successes, no other non-success. '
                         f'Missing: {EXPECTED-set(names)}; observed: {focused}. '
                         'Only macOS XCTest output is supported; absent/unrecognized output fails.')

if __name__=='__main__':
    if len(sys.argv)!=3:
        raise SystemExit(__doc__)
    check('\n'.join(Path(p).read_text() for p in sys.argv[1:]))
    print('All seven focused XCTest cases passed; no non-success result.')
