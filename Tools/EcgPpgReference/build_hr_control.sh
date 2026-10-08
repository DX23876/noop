#!/bin/sh
# Compile the actual HR-only estimator; output belongs in a caller-selected work directory.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
work=${1:?Usage: sh build_hr_control.sh /path/to/local/work-directory}
mkdir -p "$work/module-cache"
swiftc -O -module-cache-path "$work/module-cache" \
  "$repo/Packages/WhoopProtocol/Sources/WhoopProtocol/PpgHr.swift" \
  "$here/main.swift" -o "$work/ppg-hr-control"
