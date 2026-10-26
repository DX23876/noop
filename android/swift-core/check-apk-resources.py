#!/usr/bin/env python3
"""Verify that each Swift core package's production resources reached the actual APK unchanged."""
from pathlib import Path
import re
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def core_resources():
    pending = [ROOT / "Packages/NoopCoreJNI"]
    seen = set()
    resources = {}
    while pending:
        package = pending.pop().resolve()
        if package in seen:
            continue
        seen.add(package)
        manifest = (package / "Package.swift").read_text()
        pending.extend(package / path for path in re.findall(r'\.package\(path:\s*"([^"]+)"\)', manifest))
        for directory in (package / "Sources").glob("*/Resources"):
            for source in directory.rglob("*"):
                if source.is_file():
                    asset = "assets/" + source.relative_to(directory).as_posix()
                    if asset in resources:
                        raise ValueError(f"duplicate core asset: {asset}")
                    resources[asset] = source
    return resources


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: check-apk-resources.py <apk> [<apk> ...]")
    resources = core_resources()
    if not resources:
        raise SystemExit("no core resources discovered; check package discovery")
    failed = False
    for name in sys.argv[1:]:
        with zipfile.ZipFile(name) as apk:
            for asset, source in sorted(resources.items()):
                if asset not in apk.namelist():
                    print(f"{Path(name).name}: missing {asset}", file=sys.stderr)
                    failed = True
                elif apk.read(asset) != source.read_bytes():
                    print(f"{Path(name).name}: stale {asset}", file=sys.stderr)
                    failed = True
        print(f"{Path(name).name}: checked {len(resources)} Swift core resources")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
