#!/usr/bin/env python3
"""Keep the sideload manifest's declared entitlements honest about what the app actually requests.

WHY THIS EXISTS. "What the app is allowed to do" is written down in two independent places:

  1. project.yml -> NOOPiOS -> entitlements.properties — the TRUTH. It becomes the code signature,
     and iOS enforces it.
  2. altstore-source.json -> apps[0].appPermissions.entitlements — a LABEL. AltStore, SideStore and
     Feather render it in the install sheet so a user sees what they are agreeing to before tapping
     Get. Nothing keeps it in step with (1).

They drifted. The fork's manifest declared only `com.apple.developer.healthkit` while the app has
always also requested `com.apple.security.application-groups` (the container the widget reads
through). Upstream declares both. The install sheet therefore under-reported the app's own
permissions — the opposite of the transparency this project sells — and, for any sideloader that
treats the field as more than decoration, a capability the app needs may never be provisioned.

It went unnoticed because nothing looks wrong: the app builds, signs, installs and runs. The release
workflow rewrites version/build/date/description/URL/size in this file on every release and never
touches `appPermissions`, so the stale value survived every release since the fork diverged.

STDLIB ONLY, on purpose: this runs on `ubuntu-latest` with the runner's bare `python3` (see
source-hygiene.yml), which is not guaranteed to carry PyYAML. The entitlements block is small and
its shape is stable, so a targeted scanner is enough — and `parse_project_entitlements` fails LOUDLY
rather than returning an empty set if the structure ever moves, because a guard that silently finds
nothing would pass forever and be worse than no guard at all.

Usage:  python3 Tools/check-sideload-manifest.py        # exit 0 = in step, 1 = drifted
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "project.yml"
MANIFEST = ROOT / "altstore-source.json"

# The iOS application target whose signature the sideload IPA carries.
TARGET = "NOOPiOS"

# Entitlements that are a PARAMETER of another capability rather than a capability of their own, and
# so are not listed separately in an install sheet. `com.apple.developer.healthkit.access` qualifies
# HealthKit (it is an access specification, empty here); upstream's manifest omits it for the same
# reason. Anything not on this list must appear in the manifest.
NOT_A_DISPLAYED_CAPABILITY = {
    "com.apple.developer.healthkit.access",
}


def parse_project_entitlements() -> set[str]:
    """The entitlement keys the iOS app target actually requests, from project.yml.

    Scans the `entitlements: -> properties:` block inside the target and collects its child keys.
    Deliberately narrow: it looks for `com.apple.*` keys at the properties block's own indent, so a
    nested value line (`- $(APP_GROUP_ID)`) is not mistaken for a key.
    """
    lines = PROJECT.read_text(encoding="utf-8").splitlines()

    # Locate the target block: `  NOOPiOS:` up to the next key at the same indent.
    start = next((i for i, l in enumerate(lines) if l.startswith(f"  {TARGET}:")), None)
    if start is None:
        sys.exit(f"check-sideload-manifest: target '{TARGET}:' not found in {PROJECT.name}")
    end = len(lines)
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if line.strip() and not line.startswith("   ") and line.startswith("  "):
            end = i
            break
    block = lines[start:end]

    # Inside it, the entitlements' `properties:` mapping.
    props = next((i for i, l in enumerate(block)
                  if l.strip() == "properties:" and _within_entitlements(block, i)), None)
    if props is None:
        sys.exit(f"check-sideload-manifest: no entitlements/properties block for {TARGET} "
                 f"in {PROJECT.name} — the file's structure changed, update this script")

    indent = len(block[props]) - len(block[props].lstrip())
    found: set[str] = set()
    for line in block[props + 1:]:
        if not line.strip():
            continue
        cur = len(line) - len(line.lstrip())
        if cur <= indent:            # dedented out of the mapping
            break
        key = line.strip().split(":", 1)[0].strip()
        if cur == indent + 2 and key.startswith("com.apple."):
            found.add(key)

    if not found:
        sys.exit(f"check-sideload-manifest: parsed the {TARGET} entitlements block but found no "
                 f"com.apple.* keys — refusing to pass on an empty result")
    return found


def _within_entitlements(block: list[str], idx: int) -> bool:
    """True when `block[idx]` ('properties:') belongs to an `entitlements:` mapping.

    `properties:` also appears under `info:`, which is a different list entirely — matching that one
    would compare the manifest against Info.plist keys and report nonsense.
    """
    for line in reversed(block[:idx]):
        stripped = line.strip()
        if stripped in ("entitlements:", "info:", "settings:"):
            return stripped == "entitlements:"
    return False


def manifest_entitlements() -> set[str]:
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    apps = data.get("apps") or []
    if not apps:
        sys.exit(f"check-sideload-manifest: no apps[] in {MANIFEST.name}")
    declared = apps[0].get("appPermissions", {}).get("entitlements")
    if declared is None:
        sys.exit(f"check-sideload-manifest: apps[0].appPermissions.entitlements missing from "
                 f"{MANIFEST.name} — the install sheet would list no permissions at all")
    return set(declared)


def main() -> int:
    requested = parse_project_entitlements()
    expected = {e for e in requested if e not in NOT_A_DISPLAYED_CAPABILITY}
    declared = manifest_entitlements()

    missing = expected - declared      # app asks for it, the install sheet hides it
    extra = declared - requested       # install sheet promises something the app never asks for

    if not missing and not extra:
        print(f"check-sideload-manifest: OK — {MANIFEST.name} declares exactly what {TARGET} "
              f"requests ({len(declared)} entitlement(s))")
        return 0

    print(f"FAIL {MANIFEST.name} and {PROJECT.name} disagree about {TARGET}'s entitlements:")
    for e in sorted(missing):
        print(f"  MISSING from the manifest: {e}")
        print(f"    The app requests this, so the install sheet under-reports what it is allowed "
              f"to do. Add it to apps[0].appPermissions.entitlements.")
    for e in sorted(extra):
        print(f"  DECLARED but not requested: {e}")
        print(f"    The install sheet promises a permission the app never asks for. Remove it, or "
              f"add the entitlement to {PROJECT.name} if it was meant to be there.")
    print(f"\n  requested by {TARGET}: {sorted(requested)}")
    print(f"  declared in manifest : {sorted(declared)}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
