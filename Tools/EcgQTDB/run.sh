#!/bin/sh
# Measures EcgAnalysis against the cardiologist annotations of the PhysioNet QT Database (q1c).
# Usage: Tools/EcgQTDB/run.sh [work-dir]   (needs python3, curl and swiftc; about 70 MB of data)
# Data: PhysioNet QT Database 1.0.0, ODC Attribution License, fetched from the open S3 mirror
# (physionet.org itself is slow). Nothing is written inside the repository.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${1:-"${TMPDIR:-/tmp}/noop-qtdb"}
mkdir -p "$work/qtdb" "$work/windows"
if [ ! -f "$work/qtdb/sel100.q1c" ]; then
  base=https://physionet-open.s3.amazonaws.com/qtdb/1.0.0
  curl -sS -o "$work/qtdb/RECORDS" "$base/RECORDS"
  for r in $(cat "$work/qtdb/RECORDS"); do
    for e in hea dat q1c; do printf 'url = "%s/%s.%s"\noutput = "%s/qtdb/%s.%s"\n' "$base" "$r" "$e" "$work" "$r" "$e"; done
  done > "$work/list.cfg"
  curl -sS --parallel --parallel-max 16 -K "$work/list.cfg"
fi
if [ ! -x "$work/venv/bin/python" ]; then
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q wfdb
fi
"$work/venv/bin/python" -I "$here/prepare.py" "$work/qtdb" "$work/windows"
swiftc -O -o "$work/run" "$repo/Packages/StrandAnalytics/Sources/StrandAnalytics/EcgAnalysis.swift" "$here/main.swift"
"$work/run" "$work/windows" > "$work/ours.csv"
"$work/venv/bin/python" -I "$here/score.py" "$work/windows/meta.json" "$work/ours.csv"
