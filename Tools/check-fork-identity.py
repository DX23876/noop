#!/usr/bin/env python3
"""Stop this fork's own surfaces from sending a user to upstream.

WHY THIS EXISTS. NOOP AI is a fork, and it credits upstream everywhere — that is correct and must
stay. What is NOT correct is a link that a *user* follows to get the app, or a release tool whose
default target is somebody else's repository. Those had accumulated silently:

  * Settings -> "Project home & source — GitHub: code, releases, issues and the wiki" opened
    github.com/ryanbr/noop, sitting directly under an update check that queries DX23876/noop.
  * A What's-New card instructed readers to add upstream's altstore-source.json in AltStore, which
    installs upstream's app over this one.
  * Test Centre filed its bug reports into upstream's issue tracker.
  * docs/HOMEBREW.md sent macOS users to upstream's releases page for their download.
  * Tools/release.sh defaulted to GH_REPO=ryanbr/noop, so a local run aimed `gh release create` at a
    repository the maintainer does not own; refresh-stats-badges.py published upstream's stars and
    issue counts as this project's.

Every one of them looked fine in review — the text around them is about NOOP, and upstream's name
appears legitimately a few hundred times in this tree. What separates a defect from a credit is not
the name, it is the ROLE: a link a user acts on versus a reference a reader reads.

WHAT IS CHECKED (deliberately narrow, so the gate stays believable):
  1. Swift STRING LITERALS — what the app opens or requests. Comments are stripped first: an upstream
     issue reference in a doc comment is scholarship, not a wrong link.
  2. Markdown LINK TARGETS in README.md and docs/ that point at upstream's downloads — releases,
     archives, raw files. A link to upstream's repo root, an issue or a PR is attribution and passes.
  3. Default assignments in Tools/ (GH_REPO=, REPO=, API=, ORG=) — where a script goes when nobody
     tells it otherwise.

Everything else — prose, comments, tests, ATTRIBUTION.md, NOTICE, docs/ANDROID.md, the upstream
remote in sync-upstream.yml — is out of scope by design. Deliberate exceptions live in
Tools/fork_identity_allowlist.txt so they are written down and reviewed, not guessed by a regex.

STDLIB ONLY: runs on `ubuntu-latest` with the runner's bare `python3` (see source-hygiene.yml).

Usage:  python3 Tools/check-fork-identity.py        # exit 0 = clean, 1 = a surface points upstream
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "Tools" / "fork_identity_allowlist.txt"

FORK_REPO = "DX23876/noop"

# Upstream's coordinates, and the two hosts its release infrastructure lives on.
UPSTREAM = re.compile(r"ryanbr/noop|noop\.fans|NoopApp")

SWIFT_DIRS = ["Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "NOOPWatch",
              "NOOPWatchComplications", "Packages"]
# Tests assert on the URLs the app builds; the assertion follows the app, so checking the app itself
# is enough and a test's literal is not a user-facing surface.
SWIFT_SKIP = re.compile(r"(^|/)(StrandTests|StrandiOSTests|Tests)/")

DOC_ROOTS = [ROOT / "README.md", ROOT / "docs"]
# Files whose whole subject is upstream, or whose upstream references are the record itself.
DOC_SKIP = {"ATTRIBUTION.md", "NOTICE", "ANDROID.md", "CROSS_PLATFORM.md"}

# A markdown link target that hands the reader an artifact rather than a citation.
DOWNLOAD_PATH = re.compile(
    r"(?:ryanbr/noop/(?:releases|archive|raw|blob)|raw\.githubusercontent\.com/ryanbr)"
)

# `GH_REPO="${GH_REPO:-ryanbr/noop}"`, `API="https://api.github.com/repos/ryanbr/noop"`, …
TOOL_DEFAULT = re.compile(
    r'^\s*(?:export\s+)?(GH_REPO|REPO|API|ORG|FORGE_ORG|FORGE_REPO|UPSTREAM_REPO)\s*=\s*(.+)$'
)

SWIFT_STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def blank_comments(source: str) -> str:
    """Replace comment characters with spaces, preserving every offset and newline.

    A regex cannot do this, and getting it wrong makes the guard blind to exactly the literals that
    matter: `//` appears inside every `https://` URL, so a `//[^\\n]*` sweep eats the rest of the line
    — literal and all — and the scan then reports a clean file. That is how the first draft of this
    guard passed a Settings link pointed straight at upstream. So: walk the source once, tracking
    whether we are inside a string (respecting backslash escapes) before treating any `/` as the start
    of a comment. Nesting is honoured because Swift nests block comments.
    """
    out = list(source)
    i, n = 0, len(source)
    in_string = False
    depth = 0  # block-comment nesting
    while i < n:
        char = source[i]
        if depth:
            if source.startswith("/*", i):
                depth += 1
                out[i] = out[i + 1] = " "
                i += 2
                continue
            if source.startswith("*/", i):
                depth -= 1
                out[i] = out[i + 1] = " "
                i += 2
                continue
            if char != "\n":
                out[i] = " "
            i += 1
            continue
        if in_string:
            if char == "\\":
                i += 2
                continue
            if char == '"' or char == "\n":
                in_string = False
            i += 1
            continue
        if char == '"':
            in_string = True
            i += 1
            continue
        if source.startswith("//", i):
            while i < n and source[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if source.startswith("/*", i):
            depth = 1
            out[i] = out[i + 1] = " "
            i += 2
            continue
        i += 1
    return "".join(out)

# path -> [message, …], so a per-file allowance can be applied after the scan rather than during it.
findings: dict[str, list[str]] = {}


def read_allowlist() -> dict[str, int]:
    """Deliberate exceptions: `<repo-relative-path> [count]`, one per line (# comments ignored).

    A bare path exempts the whole file (a script whose entire subject is upstream infrastructure). A
    path with a count allows up to that many findings and fails on the next one — the same ratcheting
    shape as Tools/doc_comment_lint_baseline.txt, and for the same reason: a file-keyed allowance
    survives edits, where a line-keyed one goes stale on the first insertion and trains people to
    regenerate it without reading. Ratchet counts DOWN as sites are fixed, never up.
    """
    if not ALLOWLIST.exists():
        return {}
    entries: dict[str, int] = {}
    for line in ALLOWLIST.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        entries[parts[0]] = int(parts[1]) if len(parts) > 1 else -1  # -1 = whole file
    return entries


def report(path: pathlib.Path, line: int, message: str) -> None:
    rel = str(path.relative_to(ROOT))
    findings.setdefault(rel, []).append(f"{rel}:{line}: {message}")


def line_of(text: str, index: int) -> int:
    return text[:index].count("\n") + 1


def check_swift(allowed: dict[str, int]) -> int:
    scanned = 0
    for directory in SWIFT_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            rel = str(path.relative_to(ROOT))
            if SWIFT_SKIP.search(rel) or allowed.get(rel) == -1:
                continue
            scanned += 1
            # Blank the comments out rather than deleting them, so offsets — and therefore the
            # reported line numbers — still match the real file.
            stripped = blank_comments(path.read_text(encoding="utf-8"))
            for match in SWIFT_STRING.finditer(stripped):
                if UPSTREAM.search(match.group()):
                    report(
                        path,
                        line_of(stripped, match.start()),
                        f"string literal points at upstream: {match.group()[:110]} "
                        f"— this build's own surfaces belong to {FORK_REPO}",
                    )
    return scanned


def doc_files(allowed: dict[str, int]) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for root in DOC_ROOTS:
        candidates = [root] if root.is_file() else sorted(root.rglob("*.md"))
        for path in candidates:
            if path.name in DOC_SKIP or allowed.get(str(path.relative_to(ROOT))) == -1:
                continue
            files.append(path)
    return files


def check_docs(allowed: dict[str, int]) -> int:
    for path in doc_files(allowed):
        text = path.read_text(encoding="utf-8")
        for match in DOWNLOAD_PATH.finditer(text):
            report(
                path,
                line_of(text, match.start()),
                f"points readers at an upstream download ({match.group()}) — link this fork's "
                "release instead; upstream ships a different app",
            )
    return len(doc_files(allowed))


def check_tools(allowed: dict[str, int]) -> int:
    scanned = 0
    for pattern in ("*.sh", "*.py"):
        for path in sorted((ROOT / "Tools").glob(pattern)):
            rel = str(path.relative_to(ROOT))
            if allowed.get(rel) == -1 or path.name == pathlib.Path(__file__).name:
                continue
            scanned += 1
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                match = TOOL_DEFAULT.match(line)
                if match and UPSTREAM.search(match.group(2)):
                    report(
                        path,
                        number,
                        f"default target is upstream: {match.group(1)}={match.group(2).strip()[:70]} "
                        "— a run with no override then acts on somebody else's repository",
                    )
    return scanned


def main() -> int:
    allowed = read_allowlist()
    swift = check_swift(allowed)
    docs = check_docs(allowed)
    tools = check_tools(allowed)

    # A file with an allowance passes while it stays at or under it, and prints an IMPROVED line when
    # it drops below — the allowance is meant to ratchet down as history is cleaned up, never up.
    regressions: list[str] = []
    for rel, messages in sorted(findings.items()):
        allowance = allowed.get(rel, 0)
        if allowance == -1 or len(messages) <= allowance:
            if 0 <= allowance and len(messages) < allowance:
                print(f"IMPROVED {rel}: {len(messages)} left, allowlist says {allowance} — lower it.")
            continue
        regressions.extend(messages)

    if regressions:
        for finding in regressions:
            print(f"::error::{finding}")
        print(
            f"\ncheck-fork-identity: {len(regressions)} surface(s) send a user or a script to "
            "upstream.\nPoint them at this fork, or — if the reference is deliberate — add the file "
            "to Tools/fork_identity_allowlist.txt with a reason.",
            file=sys.stderr,
        )
        return 1
    print(
        f"check-fork-identity: OK — no surface points at upstream "
        f"({swift} Swift, {docs} doc, {tools} tool file(s) scanned, {len(allowed)} allowlisted)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
