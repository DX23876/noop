#!/usr/bin/env python3
"""Hold every copy of "which release is current" against the one that decides it.

WHY THIS EXISTS. `project.yml -> MARKETING_VERSION` is the single source of truth: the release
workflow reads it, and the in-app update check compares against it. But the version — and the asset
and tag names derived from it — is written down in six more places that nothing keeps in step:

  1. altstore-source.json — what AltStore/SideStore offer, and the URL they download from.
  2. Strand/System/AppChangelog.swift -> currentVersion — which "What's New" sheet the app shows.
  3. README.md / docs/*.md — the filenames and release links a human is told to download.
  4. The release workflows — how the tag and the asset names are actually built.

They drifted, all in the same direction, and none of it was visible from a green CI:

  * README.md and docs/IOS.md sent people to the 9.3.3 DX Beta release and its `-dx-beta` asset
    names for three weeks after 10.1.0 shipped under plain `-dx` tags. A new user followed the
    install guide, could not make it work, and went back to upstream's build.
  * fork-release.yml still tagged a bare `vX.Y.Z` and uploaded `NOOP-ios-unsigned-v<V>.ipa`, while
    publish-ios-release.yml — the workflow that actually shipped 10.1.0 — used `v<V>-dx` and
    `-dx` asset names. A release cut from the first would collide with the upstream tags
    sync-upstream.yml fetches into this repo, and its AltStore step, looking for an asset name that
    no longer exists, would warn and skip SILENTLY, leaving the published source on the old version.

THE RULE THIS ENFORCES (docs/FORK_GUIDE.md): the numeric version stays numeric everywhere Apple
reads it; the `-dx` marker lives in the tag and in asset filenames, and nowhere else. It is a
NAMESPACE — upstream tags `vX.Y.Z` into the same space this repo fetches from.

STDLIB ONLY, on purpose: runs on `ubuntu-latest` with the runner's bare `python3` (see
source-hygiene.yml), which is not guaranteed to carry PyYAML. Every parser here fails LOUDLY rather
than returning nothing if the file's shape moves, because a guard that silently finds nothing to
check would pass forever and be worse than no guard at all.

Usage:  python3 Tools/check-release-refs.py        # exit 0 = in step, 1 = drifted
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "project.yml"
MANIFEST = ROOT / "altstore-source.json"
CHANGELOG = ROOT / "Strand" / "System" / "AppChangelog.swift"

# The fork's GitHub coordinates. The manifest's downloadURL must point here — an upstream URL would
# hand every sideloader the base app instead of this one (see Tools/check-fork-identity.py).
GH_REPO = "DX23876/noop"

# Documentation that describes the CURRENT release. Archived release notes are excluded: a note for
# 9.3.3 naming its own 9.3.3 asset is correct and must stay readable.
DOC_ROOTS = [ROOT / "README.md", ROOT / "docs"]
DOC_EXCLUDED_DIRS = {ROOT / "docs" / "releases", ROOT / "docs" / "fork" / "releases"}

WORKFLOWS = [
    ROOT / ".github" / "workflows" / name
    for name in ("fork-release.yml", "fork-testing-build.yml", "publish-ios-release.yml")
]

# A concrete asset filename in prose: NOOP-ios-unsigned-v10.1.0-dx.ipa and its two siblings.
DOC_ASSET_RE = re.compile(
    r"NOOP-(?:ios-unsigned|ios-full-unsigned|macos)-v(\d+\.\d+\.\d+)(-dx-beta|-dx)?"
)
# A link to a release page or a release asset: .../releases/tag/v10.1.0-dx
DOC_TAG_RE = re.compile(r"releases/(?:tag|download)/v(\d+\.\d+\.\d+)(-dx-beta|-dx)?")

# The same two names as a workflow builds them — from a shell variable (`v${VER}`) or a printf
# placeholder (`v%s`) rather than a literal version.
WF_TOKEN = r"(?:\$\{[A-Za-z_][A-Za-z0-9_]*\}|%s|\d+\.\d+\.\d+)"
WF_ASSET_RE = re.compile(
    r"NOOP-(?:ios-unsigned|ios-full-unsigned|macos)-v" + WF_TOKEN + r"(-dx)?"
)
# A tag ASSIGNMENT built from a version token: TAG="v${NEW}", echo "tag=v${VERSION}-dx".
# A fixed tag (fork-testing-build.yml's rolling `testing-latest`) carries no version and is not
# matched — it cannot collide with upstream's namespace, so the rule does not apply to it.
WF_TAG_RE = re.compile(r"(?i)\btag=\"?v(" + WF_TOKEN + r")(-dx)?")

failures: list[str] = []


def fail(where: str, message: str) -> None:
    failures.append(f"{where}: {message}")


def read_project() -> tuple[str, str]:
    """MARKETING_VERSION and CURRENT_PROJECT_VERSION, or a hard error."""
    text = PROJECT.read_text(encoding="utf-8")
    version = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', text)
    build = re.search(r'CURRENT_PROJECT_VERSION:\s*"(\d+)"', text)
    if not version or not build:
        sys.exit(
            "check-release-refs: project.yml carries no MARKETING_VERSION / "
            "CURRENT_PROJECT_VERSION — the parser needs updating, not disabling."
        )
    return version.group(1), build.group(1)


def check_manifest(version: str, build: str) -> None:
    """altstore-source.json offers this version, from this fork's release asset."""
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    try:
        app = data["apps"][0]
        newest = app["versions"][0]
    except (KeyError, IndexError):
        sys.exit("check-release-refs: altstore-source.json has no apps[0].versions[0].")

    expected_url = (
        f"https://github.com/{GH_REPO}/releases/download/"
        f"v{version}-dx/NOOP-ios-unsigned-v{version}-dx.ipa"
    )
    # Both shapes matter: newer sideloaders read versions[0], older ones the top-level fields. A
    # release that updates only one leaves half the clients on the previous build.
    for label, value in (
        ("apps[0].version", app.get("version")),
        ("apps[0].versions[0].version", newest.get("version")),
    ):
        if value != version:
            fail("altstore-source.json", f"{label} is {value!r}, project.yml says {version!r}")
    for label, value in (
        ("apps[0].buildVersion", app.get("buildVersion")),
        ("apps[0].versions[0].buildVersion", newest.get("buildVersion")),
    ):
        if value != build:
            fail("altstore-source.json", f"{label} is {value!r}, project.yml says {build!r}")
    for label, value in (
        ("apps[0].downloadURL", app.get("downloadURL")),
        ("apps[0].versions[0].downloadURL", newest.get("downloadURL")),
    ):
        if value != expected_url:
            fail("altstore-source.json", f"{label} is {value!r}, expected {expected_url!r}")
    for label, value in (
        ("apps[0].size", app.get("size")),
        ("apps[0].versions[0].size", newest.get("size")),
    ):
        if not isinstance(value, int) or value <= 0:
            fail("altstore-source.json", f"{label} is {value!r} — a real byte count is required")


def check_changelog(version: str) -> None:
    """The What's New sheet announces the version that shipped."""
    text = CHANGELOG.read_text(encoding="utf-8")
    match = re.search(r'static let currentVersion\s*=\s*"([^"]+)"', text)
    if not match:
        sys.exit("check-release-refs: AppChangelog.currentVersion not found — parser needs updating.")
    if match.group(1) != version:
        fail(
            "Strand/System/AppChangelog.swift",
            f"currentVersion is {match.group(1)!r}, project.yml says {version!r}",
        )


def doc_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for root in DOC_ROOTS:
        if root.is_file():
            files.append(root)
            continue
        for path in sorted(root.rglob("*.md")):
            if any(excluded in path.parents for excluded in DOC_EXCLUDED_DIRS):
                continue
            files.append(path)
    return files


def check_docs(version: str) -> None:
    """Every asset name and release link a reader is told to use names THIS release."""
    for path in doc_files():
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(ROOT)
        for regex, kind in ((DOC_ASSET_RE, "asset"), (DOC_TAG_RE, "release link")):
            for match in regex.finditer(text):
                line = text[: match.start()].count("\n") + 1
                found, suffix = match.group(1), match.group(2) or ""
                if found != version:
                    fail(f"{rel}:{line}", f"{kind} names {found}, current release is {version}")
                elif suffix != "-dx":
                    fail(
                        f"{rel}:{line}",
                        f"{kind} {match.group(0)!r} — this fork's tags and assets carry -dx",
                    )


def check_workflows() -> None:
    """The workflows build tag and asset names in the fork's namespace, not upstream's."""
    for path in WORKFLOWS:
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(ROOT)
        for match in WF_ASSET_RE.finditer(text):
            if match.group(1) != "-dx":
                line = text[: match.start()].count("\n") + 1
                fail(f"{rel}:{line}", f"asset name {match.group(0)!r} is missing the -dx marker")
        for match in WF_TAG_RE.finditer(text):
            if match.group(2) != "-dx":
                line = text[: match.start()].count("\n") + 1
                fail(
                    f"{rel}:{line}",
                    f"tag {match.group(0)!r} is missing -dx — a bare vX.Y.Z collides with the "
                    "upstream tags sync-upstream.yml fetches",
                )


def check_build_recipe() -> None:
    """The README's build recipe runs bootstrap-nomic.sh BEFORE xcodegen.

    Order is not cosmetic: the script installs the llama.xcframework the iOS target links and the
    model into a directory XcodeGen enumerates at generation time. Reversed, the build succeeds and
    ships a coach runtime with no model; omitted, it cannot link at all. The README shipped without
    the step, so following it as written could not produce a working iOS build.
    """
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    bootstrap = text.find("Tools/bootstrap-nomic.sh")
    xcodegen = text.find("xcodegen generate")
    if bootstrap == -1:
        fail("README.md", "the build recipe never runs Tools/bootstrap-nomic.sh")
    elif xcodegen != -1 and bootstrap > xcodegen:
        fail("README.md", "Tools/bootstrap-nomic.sh is listed after `xcodegen generate`")


def main() -> int:
    version, build = read_project()
    check_manifest(version, build)
    check_changelog(version)
    check_docs(version)
    check_workflows()
    check_build_recipe()

    if failures:
        for failure in failures:
            print(f"::error::{failure}")
        print(
            f"\ncheck-release-refs: {len(failures)} reference(s) disagree with "
            f"project.yml (MARKETING_VERSION {version}, build {build}).",
            file=sys.stderr,
        )
        return 1
    print(f"check-release-refs: OK — every reference agrees on {version} (build {build})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
