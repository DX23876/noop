#!/usr/bin/env python3
"""Measure the fork's code health the same way every time.

The code-health report (docs/fork/code-health/<date>.md) compares each run against the previous one.
That comparison is only worth something if both runs measured identically, so every number in the
report comes from this script rather than from an ad-hoc shell session. The judgement parts of the
report (what matters, what to do first) are written by hand; the tables are pasted in verbatim with
`--fill`.

What is measured, all against the committed tree of `--ref` (default `main`), never the working copy,
so the same commit always yields the same numbers:

1. Largest product Swift files and largest types (class/struct/enum/actor, every extension summed).
2. Hotspots: code lines x own commits in the window (`git log <ref> --not upstream/main --no-merges`).
3. SwiftUI fan-out: ObservableObject classes (@Published count, observing types) and @Observable
   classes (observed via @Environment / @Bindable / @State / plain stored property in a View).
4. Largest SwiftUI views (types whose inheritance clause names `View`).
5. Upstream friction: files the fork changed relative to upstream/main that upstream keeps changing,
   and files the fork deleted that upstream still changes (modify/delete conflicts).
6. Test gaps: files and types of at least 500 code lines whose type names no test file mentions.
7. Risk markers per file: `try!`, `as!`, `fatalError(`.
8. Doc drift: files and type names in backticks under docs/ that no longer exist in the code
   (CHANGELOG, release notes, these reports and decisions.md excluded: they are historical).

The window ends at the commit date of `--ref` (not at "now"), so re-running an old commit reproduces
its numbers.

Heuristics, stated once so nobody mistakes them for a compiler: Swift is scanned with a small lexer
that blanks comments and string literals (including interpolation and raw strings) and then matches
braces. Regex literals are not understood. A "code line" is a line with at least one character outside
a comment. Type identity is by name, so two same-named nested types in different parents are kept apart
only by their qualified parent path. Test coverage is "the type name appears in a test file", which says
a test exists, not that it is any good. Changing any of these rules is a method change: bump
METHOD_VERSION so the trend table marks the next run as not comparable.

Usage:
    python3 Tools/code_health.py --json docs/fork/code-health/2026-10-10.json \
        --markdown <scratch>/appendix.md
    python3 Tools/code_health.py --json ... --fill docs/fork/code-health/2026-10-10.md

Standard library only. Needs git and an `upstream` remote; without one the upstream sections are
reported as unavailable instead of guessed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import posixpath
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path, PurePosixPath

METHOD_VERSION = 2
WINDOW_DAYS = 60
BIG_LINES = 500
TOP_N = 25
TRIM_LINES = 100
APPENDIX_MARKER = "<!-- code-health:appendix -->"

# Top-level directories that are never product code. Test directories are recognised by name instead
# (see is_test_path) so a new test target does not need listing here.
NON_PRODUCT_ROOTS = {"Tools", "Vendor", "docs", "marketing", "Config", ".github", ".githooks"}
BUILD_PARTS = {"build", ".build", "DerivedData", "Vendor"}

# Paths the fork removed on purpose. A modify/delete conflict there is expected and only counted, not
# listed. Every entry cites the decisions.md row that made the removal deliberate.
DELIBERATE_DELETIONS = [
    ("android/", "2026-07-23 iOS/macOS-only; stop necessarily tracking upstream"),
    ("Tools/parity_", "2026-07-23 Cross-platform parity contract is retired"),
    ("Tools/PARITY_HARNESS.md", "2026-07-23 Cross-platform parity contract is retired"),
    ("Tools/tests/test_parity_", "2026-07-23 Cross-platform parity contract is retired"),
]

COUNTED_ONLY = {"android", "deliberate"}

DECISION_SIGNALS = ["reverted", "retired", "rejected", "deferred", "superseded", "supersedes",
                    "dropped", "replaced", "withdrawn", "revisit", "no longer", "instead of"]

TYPE_KINDS = ("class", "struct", "enum", "actor", "extension", "protocol")
NOT_A_NAME = {"func", "var", "let", "subscript", "init", "deinit", "override", "final", "static",
              "private", "fileprivate", "internal", "public", "open", "case", "where"}


# ---------------------------------------------------------------------------------------------- git

def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                          text=True, errors="replace").stdout


def ref_exists(ref: str, cwd: Path) -> bool:
    return subprocess.run(["git", "rev-parse", "--verify", "--quiet", ref + "^{commit}"], cwd=cwd,
                          capture_output=True).returncode == 0


def read_blobs(ref: str, paths: list[str], cwd: Path) -> dict[str, str]:
    """Read many files from a commit in one `git cat-file --batch` round trip."""
    if not paths:
        return {}
    request = "".join(f"{ref}:{p}\n" for p in paths).encode()
    raw = subprocess.run(["git", "cat-file", "--batch"], cwd=cwd, input=request, check=True,
                         capture_output=True).stdout
    out: dict[str, str] = {}
    pos = 0
    for path in paths:
        nl = raw.index(b"\n", pos)
        header = raw[pos:nl].decode()
        pos = nl + 1
        if header.endswith("missing"):
            continue
        size = int(header.rsplit(" ", 1)[1])
        out[path] = raw[pos:pos + size].decode("utf-8", errors="replace")
        pos += size + 1
    return out


def parse_name_only_log(text: str) -> Counter:
    """Count commits per path from `git log --format=%x00 --name-only` output."""
    counts: Counter = Counter()
    for chunk in text.split("\x00"):
        for path in {line.strip() for line in chunk.splitlines() if line.strip()}:
            counts[path] += 1
    return counts


def parse_name_status(text: str) -> dict[str, str]:
    status: dict[str, str] = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            status[parts[-1]] = parts[0][0]
    return status


def parse_numstat(text: str) -> dict[str, int]:
    churn: dict[str, int] = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            added, removed, path = parts
            churn[path] = (int(added) if added.isdigit() else 0) + (int(removed) if removed.isdigit() else 0)
    return churn


# ------------------------------------------------------------------------------------- path classes

def is_test_path(path: str) -> bool:
    return any(part == "Tests" or part.endswith("Tests") for part in PurePosixPath(path).parts[:-1])


def is_product_swift(path: str) -> bool:
    if not path.endswith(".swift") or is_test_path(path):
        return False
    parts = PurePosixPath(path).parts
    if len(parts) < 2 or parts[0] in NON_PRODUCT_ROOTS or any(p in BUILD_PARTS for p in parts):
        return False
    if parts[0] == "Packages":
        return len(parts) > 3 and parts[2] == "Sources"
    return True


def deliberate_reason(path: str) -> str | None:
    for prefix, reason in DELIBERATE_DELETIONS:
        if path.startswith(prefix):
            return reason
    return None


# --------------------------------------------------------------------------------------- swift lexer

STRING_OPEN_RE = re.compile(r'(#*)("""|")')


def scan_swift(src: str) -> tuple[str, set[int]]:
    """Blank comments and string literals; return (masked source, 1-based code line numbers).

    The masked text keeps every newline and every character position, so offsets and line numbers
    computed on it are valid for the original file. String contents count as code (a multi-line
    literal is part of an expression), comments do not.
    """
    out = list(src)
    code_lines: set[int] = set()
    n = len(src)
    i = 0
    line = 1
    # Stack of contexts. ("code", paren_depth) is ordinary code; the bottom one never closes. A string
    # context is ("str", hashes, multiline). Interpolation pushes a fresh code context whose paren depth
    # tells us which ")" ends it.
    stack: list[tuple] = [("code", 0)]

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        ch = src[i]
        top = stack[-1]
        if ch == "\n":
            if top[0] == "str" and not top[2]:  # unterminated single-line literal: drop it
                stack.pop()
            line += 1
            i += 1
            continue
        if top[0] == "code":
            interpolated = len(stack) > 1
            if src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                blank(i, j)
                i = j
                continue
            if src.startswith("/*", i):
                depth, j = 0, i
                while j < n:
                    if src.startswith("/*", j):
                        depth += 1
                        j += 2
                    elif src.startswith("*/", j):
                        depth -= 1
                        j += 2
                        if depth == 0:
                            break
                    else:
                        if src[j] == "\n":
                            line += 1
                        j += 1
                blank(i, j)
                i = j
                continue
            m = STRING_OPEN_RE.match(src, i)
            if m:
                hashes = len(m.group(1))
                multiline = m.group(2) == '"""'
                code_lines.add(line)
                blank(i, m.end())
                stack.append(("str", hashes, multiline))
                i = m.end()
                continue
            if not ch.isspace():
                code_lines.add(line)
            if interpolated:
                if ch == "(":
                    stack[-1] = ("code", top[1] + 1)
                elif ch == ")":
                    if top[1] == 0:
                        stack.pop()
                        out[i] = " "
                        i += 1
                        continue
                    stack[-1] = ("code", top[1] - 1)
                out[i] = " "
            i += 1
            continue
        # inside a string literal
        _, hashes, multiline = top
        if not ch.isspace():
            code_lines.add(line)
        escape = "\\" + "#" * hashes
        if src.startswith(escape, i):
            k = i + len(escape)
            if k < n and src[k] == "(":
                blank(i, k + 1)
                stack.append(("code", 0))
                i = k + 1
                continue
            blank(i, min(k + 1, n))
            i = k + 1 if k < n and src[k] != "\n" else k
            continue
        closer = ('"""' if multiline else '"') + "#" * hashes
        if src.startswith(closer, i):
            blank(i, i + len(closer))
            stack.pop()
            i += len(closer)
            continue
        out[i] = " "
        i += 1
    return "".join(out), code_lines


# ------------------------------------------------------------------------------- type declarations

DECL_RE = re.compile(r"\b(class|struct|enum|actor|extension|protocol)\s+([A-Za-z_][\w.]*)")
OBSERVABLE_RE = re.compile(
    r"@Observable\b(?:\s*@\w+(?:\([^)]*\))?|\s+(?:final|public|internal|private|fileprivate|open|"
    r"nonisolated|package))*\s+class\s+([A-Za-z_]\w*)")


def line_of(offsets: list[int], pos: int) -> int:
    lo, hi = 0, len(offsets)
    while lo < hi:
        mid = (lo + hi) // 2
        if offsets[mid] <= pos:
            lo = mid + 1
        else:
            hi = mid
    return lo  # 1-based


def line_offsets(text: str) -> list[int]:
    offs = [0]
    for m in re.finditer("\n", text):
        offs.append(m.end())
    return offs


def find_decls(masked: str) -> list[dict]:
    """Every type-like declaration with its brace span, nested ones qualified by their parent."""
    raw = []
    for m in DECL_RE.finditer(masked):
        kind, name = m.group(1), m.group(2)
        if name in NOT_A_NAME:
            continue
        line_start = masked.rfind("\n", 0, m.start()) + 1
        if re.search(r"\bimport\b", masked[line_start:m.start()]):
            continue
        j = m.end()
        open_pos = None
        while j < len(masked):
            c = masked[j]
            if c == "{":
                open_pos = j
                break
            if c in "};=":
                break
            j += 1
        if open_pos is None:
            continue
        depth, k = 0, open_pos
        while k < len(masked):
            if masked[k] == "{":
                depth += 1
            elif masked[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        raw.append({"kind": kind, "name": name, "start": m.start(), "open": open_pos, "end": k,
                    "inherits": inheritance(masked[m.end():open_pos])})
    raw.sort(key=lambda d: d["start"])
    for d in raw:
        parents = [p for p in raw if p is not d and p["open"] < d["start"] and d["end"] <= p["end"]
                   and p["kind"] != "protocol"]
        parent = max(parents, key=lambda p: p["open"], default=None)
        d["parent"] = parent
    for d in raw:
        chain, p = [d["name"]], d["parent"]
        while p is not None:
            chain.append(p["name"])
            p = p["parent"]
        d["qualified"] = ".".join(reversed(chain))
    return raw


def inheritance(clause: str) -> list[str]:
    """`<T: P>: A, B where T: Q` -> ["A", "B"]."""
    clause = clause.strip()
    if clause.startswith("<"):
        depth = 0
        for idx, c in enumerate(clause):
            depth += (c == "<") - (c == ">")
            if depth == 0:
                clause = clause[idx + 1:].strip()
                break
    if not clause.startswith(":"):
        return []
    clause = re.split(r"\bwhere\b", clause[1:], maxsplit=1)[0]
    return [t.strip() for t in re.split(r"[,&]", clause) if t.strip()]


def inherits_name(decl: dict, name: str) -> bool:
    return any(re.fullmatch(rf"(?:\w+\.)?{name}", t.split("<")[0].strip()) for t in decl["inherits"])


# --------------------------------------------------------------------------------------- analysis

class SwiftFile:
    def __init__(self, path: str, src: str):
        self.path = path
        self.masked, self.code_line_set = scan_swift(src)
        self.offsets = line_offsets(self.masked)
        self.physical = src.count("\n") + (0 if src.endswith("\n") or not src else 1)
        self.code = len(self.code_line_set)
        self.decls = find_decls(self.masked)

    def span_lines(self, a: int, b: int) -> tuple[int, int]:
        la, lb = line_of(self.offsets, a), line_of(self.offsets, b)
        return sum(1 for ln in range(la, lb + 1) if ln in self.code_line_set), lb - la + 1

    def enclosing(self, pos: int) -> dict | None:
        best = None
        for d in self.decls:
            if d["open"] < pos <= d["end"] and (best is None or d["open"] > best["open"]):
                best = d
        return best


def analyse_types(files: list[SwiftFile]) -> dict[str, dict]:
    types: dict[str, dict] = {}
    for f in files:
        for d in f.decls:
            code, phys = f.span_lines(d["start"], d["end"])
            t = types.setdefault(d["qualified"], {"name": d["qualified"], "kind": None, "code": 0,
                                                  "physical": 0, "blocks": 0, "files": set(),
                                                  "main_file": None, "is_view": False,
                                                  "observable_object": False})
            t["code"] += code
            t["physical"] += phys
            t["blocks"] += 1
            t["files"].add(f.path)
            if d["kind"] != "extension":
                t["kind"] = d["kind"]
                t["main_file"] = f.path
            if inherits_name(d, "View"):
                t["is_view"] = True
            if inherits_name(d, "ObservableObject"):
                t["observable_object"] = True
    for t in types.values():
        t["kind"] = t["kind"] or "extension-only"
        t["main_file"] = t["main_file"] or sorted(t["files"])[0]
        t["files"] = sorted(t["files"])
    return types


def word_set(texts) -> set[str]:
    words: set[str] = set()
    for t in texts:
        words.update(re.findall(r"[A-Za-z_]\w*", t))
    return words


OBSERVER_RE = re.compile(
    r"@(ObservedObject|StateObject|EnvironmentObject)\b[^\n;]*?\bvar\s+\w+\s*"
    r"(?::\s*([\w.]+)|=\s*([\w.]+)\s*\()")
ENV_TYPE_RE = re.compile(r"@Environment\(\s*([\w.]+)\.self\s*\)")
BINDABLE_RE = re.compile(r"@Bindable\b[^\n;]*?\bvar\s+\w+\s*:\s*([\w.]+)")
STATE_RE = re.compile(r"@State\b[^\n;]*?\bvar\s+\w+\s*(?::\s*([\w.]+)\??|=\s*([\w.]+)\s*\()")
PLAIN_PROP_RE = re.compile(r"(?<![@\w])(?:let|var)\s+\w+\s*:\s*([\w.]+)\??\s*(?=[\n=;{]|$)")


def analyse_fanout(files: list[SwiftFile], types: dict[str, dict]) -> tuple[list, list]:
    simple = lambda q: q.rsplit(".", 1)[-1]
    oo = {simple(n): t for n, t in types.items() if t["observable_object"] and t["kind"] == "class"}
    observable: dict[str, dict] = {}
    for f in files:
        for m in OBSERVABLE_RE.finditer(f.masked):
            observable[m.group(1)] = {"name": m.group(1), "file": f.path}

    published = Counter()
    observable_vars = Counter()
    for f in files:
        for d in f.decls:
            name = d["name"]
            body = f.masked[d["open"] + 1:d["end"]]
            if name in oo and d["kind"] in ("class", "extension"):
                published[name] += len(re.findall(r"@Published\b", body))
            if name in observable and d["kind"] == "class":
                observable_vars[name] += stored_vars(body)

    oo_obs: dict[str, dict] = defaultdict(lambda: {"observers": set(), "sites": 0})
    ob_obs: dict[str, dict] = defaultdict(lambda: {"env": 0, "bindable": 0, "state": 0, "property": 0,
                                                   "observers": set()})
    for f in files:
        for m in OBSERVER_RE.finditer(f.masked):
            target = simple(m.group(2) or m.group(3))
            if target in oo:
                enc = f.enclosing(m.start())
                oo_obs[target]["observers"].add(enc["qualified"] if enc else f.path)
                oo_obs[target]["sites"] += 1
        for regex, key in ((ENV_TYPE_RE, "env"), (BINDABLE_RE, "bindable"), (STATE_RE, "state")):
            for m in regex.finditer(f.masked):
                target = simple(next(g for g in m.groups() if g))
                if target in observable:
                    enc = f.enclosing(m.start())
                    ob_obs[target][key] += 1
                    ob_obs[target]["observers"].add(enc["qualified"] if enc else f.path)
        for d in f.decls:
            if not types.get(d["qualified"], {}).get("is_view"):
                continue
            body = f.masked[d["open"] + 1:d["end"]]
            for m in PLAIN_PROP_RE.finditer(body):
                target = simple(m.group(1))
                prefix = body[max(0, m.start() - 40):m.start()]
                if target in observable and not re.search(r"@(Bindable|State|Environment)\b[^\n]*$", prefix):
                    ob_obs[target]["property"] += 1
                    ob_obs[target]["observers"].add(d["qualified"])

    oo_rows = []
    for name, t in oo.items():
        oo_rows.append({"name": name, "file": t["main_file"], "published": published[name],
                        "observers": len(oo_obs[name]["observers"]), "sites": oo_obs[name]["sites"],
                        "code": t["code"]})
    oo_rows.sort(key=lambda r: (-r["observers"] * max(r["published"], 1), -r["published"], r["name"]))
    ob_rows = []
    for name, info in observable.items():
        o = ob_obs[name]
        ob_rows.append({"name": name, "file": info["file"], "vars_estimate": observable_vars[name],
                        "observers": len(o["observers"]), "env": o["env"], "bindable": o["bindable"],
                        "state": o["state"], "property": o["property"]})
    ob_rows.sort(key=lambda r: (-r["observers"], r["name"]))
    return oo_rows, ob_rows


def stored_vars(body: str) -> int:
    """Top-level `var`s of a class body that are stored (no accessor block) and not ignored by
    Observation. Nested bodies collapse to a marker first, so a `var` inside a method is not counted
    and a computed `var x: T { ... }` is recognised by the marker on its line."""
    flat = body
    while True:
        nxt = re.sub(r"\{[^{}]*\}", "\u00a7", flat)
        if nxt == flat:
            break
        flat = nxt
    return sum(1 for ln in flat.splitlines()
               if re.search(r"(?<![\w.])var\s+\w+", ln) and "\u00a7" not in ln
               and "@ObservationIgnored" not in ln)


RISK_PATTERNS = {"try!": re.compile(r"\btry!"), "as!": re.compile(r"\bas!"),
                 "fatalError": re.compile(r"\bfatalError\s*\(")}


def analyse_risk(files: list[SwiftFile]) -> list[dict]:
    rows = []
    for f in files:
        counts = {k: len(p.findall(f.masked)) for k, p in RISK_PATTERNS.items()}
        if sum(counts.values()):
            rows.append({"file": f.path, **counts, "total": sum(counts.values())})
    rows.sort(key=lambda r: (-r["total"], r["file"]))
    return rows


# ------------------------------------------------------------------------------------- doc drift

FILE_REF_RE = re.compile(r"^[\w./@+-]*[\w-]\.(swift|kt|kts|md|py|yml|yaml|json|sh|xcstrings|plist|gradle|"
                         r"xcconfig|entitlements|txt|html|js|css)$")
# Two humps at least (`TodayView`, not `Settings`): a single capitalised word in backticks is far more
# often a UI label or a value than a type.
TYPE_REF_RE = re.compile(r"^[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*(?:\.[A-Za-z_]\w*)*(?:\(\))?$")


def doc_spans(text: str) -> list[tuple[int, str]]:
    spans = []
    in_fence = False
    for ln, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in re.finditer(r"(?<!`)`([^`\n]+)`(?!`)", line):
            spans.append((ln, m.group(1).strip()))
    return spans


# Historical by design, like a CHANGELOG: its rows name what was removed, so every such mention would
# read as drift. Excluded from method version 2 on.
HISTORICAL_DOCS = {"docs/fork/decisions.md"}


def is_doc_in_scope(path: str) -> bool:
    if not path.startswith("docs/") or not path.endswith(".md") or path in HISTORICAL_DOCS:
        return False
    parts = PurePosixPath(path).parts
    name = parts[-1].upper()
    return not (name.startswith("CHANGELOG") or "releases" in parts or "code-health" in parts)


def classify_file_ref(ref: str, doc_path: str, main_paths: set[str], main_basenames: set[str],
                      upstream_paths: set[str], is_ignored=lambda path: False) -> str | None:
    """None if the file exists or is not a repository path; else 'android', 'deliberate' (removed by a
    logged decision, see DELIBERATE_DELETIONS), 'deleted-in-fork' or 'missing'. Not repository paths: placeholders (`vX.Y.Z.md`, `<name>.md`), paths whose first
    directory exists in neither tree (`groue/GRDB.swift` is a GitHub repo), and git-ignored files that
    are local on purpose (`Config/BundleIdSecrets.xcconfig`)."""
    ref = re.sub(r":\d+(-\d+)?$", "", ref)
    if "X.Y.Z" in ref or "<" in ref:
        return None
    if ref.endswith((".kt", ".kts", ".gradle")):
        return "android"
    if "/" in ref and not ref.startswith("."):
        top = ref.split("/", 1)[0]
        if not any(p.startswith(top + "/") for p in main_paths | upstream_paths):
            return None
    if "/" in ref:
        candidates = {ref.removeprefix("./"), posixpath.normpath(posixpath.join(posixpath.dirname(doc_path), ref))}
        if candidates & main_paths or any(p.endswith("/" + ref) for p in main_paths):
            return None
        hit_up = candidates & upstream_paths or {p for p in upstream_paths if p.endswith("/" + ref)}
    else:
        if ref in main_basenames:
            return None
        hit_up = {p for p in upstream_paths if PurePosixPath(p).name == ref}
    if any(p.startswith("android/") for p in hit_up):
        return "android"
    if hit_up and all(deliberate_reason(p) for p in hit_up):
        return "deliberate"
    if hit_up:
        return "deleted-in-fork"
    return None if is_ignored(ref) else "missing"


def analyse_doc_drift(docs: dict[str, str], swift_words: set[str], declared: set[str],
                      main_paths: set[str], upstream_paths: set[str], kotlin_words: set[str],
                      is_ignored=lambda path: False) -> list[dict]:
    main_basenames = {PurePosixPath(p).name for p in main_paths}
    # Directory names and file stems (`StrandiOS`, `NOOPWatch`, `LiquidTodayView`) exist even when no
    # Swift identifier carries them.
    path_names = {part for p in main_paths for part in PurePosixPath(p).parts[:-1]}
    path_names |= {PurePosixPath(p).stem for p in main_paths}
    findings = []
    for doc_path in sorted(docs):
        owner = "upstream" if doc_path in upstream_paths and not doc_path.startswith("docs/fork/") else "fork"
        seen = set()
        for ln, span in doc_spans(docs[doc_path]):
            if span in seen:
                continue
            if FILE_REF_RE.match(re.sub(r":\d+(-\d+)?$", "", span)) and " " not in span:
                verdict = classify_file_ref(span, doc_path, main_paths, main_basenames, upstream_paths,
                                            is_ignored)
                if verdict:
                    seen.add(span)
                    findings.append({"doc": doc_path, "line": ln, "ref": span, "kind": "file",
                                     "verdict": verdict, "owner": owner})
                continue
            m = TYPE_REF_RE.match(span)
            if not m:
                continue
            name = span.split(".")[0].removesuffix("()")
            if name in declared or name in swift_words or name in path_names:
                continue
            seen.add(span)
            verdict = "android" if name in kotlin_words else "missing"
            findings.append({"doc": doc_path, "line": ln, "ref": span, "kind": "type",
                             "verdict": verdict, "owner": owner})
    return findings


# ------------------------------------------------------------------------------------- decisions

def parse_decisions(text: str) -> list[dict]:
    entries = []
    for ln, line in enumerate(text.splitlines(), 1):
        row = re.match(r"^\|\s*(\d{4}-\d{2}-\d{2})\s*\|(.*)\|\s*$", line)
        head = re.match(r"^###\s+(\d{4}-\d{2}-\d{2})\s*[—–-]+\s*(.*)$", line)
        if row:
            cells = [c.strip() for c in row.group(2).split("|")]
            text_ = cells[0]
            why = " | ".join(cells[1:])
            entries.append({"line": ln, "date": row.group(1), "kind": "row", "decision": text_, "why": why})
        elif head:
            entries.append({"line": ln, "date": head.group(1), "kind": "section", "decision": head.group(2),
                            "why": ""})
    for e in entries:
        blob = (e["decision"] + " " + e["why"]).lower()
        e["signals"] = [s for s in DECISION_SIGNALS if s in blob]
    return entries


# ----------------------------------------------------------------------------------------- trend

def headline(result: dict) -> dict[str, int]:
    """The trend metrics. Computed once from the full measurement and stored in the JSON, so the
    trimmed lists in the file never have to reproduce them."""
    files = result["files"]
    up = result.get("upstream") or {}
    return {
        "Produkt-Swift-Dateien": len(files),
        "Codezeilen gesamt": sum(f["code"] for f in files),
        f"Dateien ab {BIG_LINES} Codezeilen": sum(1 for f in files if f["code"] >= BIG_LINES),
        "Dateien ab 1000 Codezeilen": sum(1 for f in files if f["code"] >= 1000),
        "Größte Datei (Codezeilen)": max((f["code"] for f in files), default=0),
        f"Typen ab {BIG_LINES} Codezeilen": sum(1 for t in result["types"] if t["code"] >= BIG_LINES),
        "Größter Typ (Codezeilen)": max((t["code"] for t in result["types"]), default=0),
        "Eigene Commits im Fenster": result["fork_commits"],
        "Hotspot-Score Top 10 (Summe)": sum(h["score"] for h in result["hotspots"][:10]),
        "ObservableObject-Klassen": len(result["observable_objects"]),
        "@Published gesamt": sum(r["published"] for r in result["observable_objects"]),
        "@Observable-Klassen": len(result["observable_classes"]),
        "Max. Beobachter eines ObservableObject": max((r["observers"] for r in result["observable_objects"]),
                                                      default=0),
        "Testlücken (Dateien)": len(result["test_gaps"]["files"]),
        "Testlücken (Typen)": len(result["test_gaps"]["types"]),
        "try!": sum(r["try!"] for r in result["risk"]),
        "as!": sum(r["as!"] for r in result["risk"]),
        "fatalError": sum(r["fatalError"] for r in result["risk"]),
        "Doku-Drift Fork": sum(1 for d in result["doc_drift"]
                               if d["owner"] == "fork" and d["verdict"] not in COUNTED_ONLY),
        "Doku-Drift upstream": sum(1 for d in result["doc_drift"]
                                   if d["owner"] == "upstream" and d["verdict"] not in COUNTED_ONLY),
        "Doku-Drift bewusst entfernt (nur gezählt)": sum(1 for d in result["doc_drift"]
                                                        if d["verdict"] in COUNTED_ONLY),
        "Reibung: geänderte Dateien mit upstream-Aktivität": len(up.get("friction", [])),
        "Reibung: modify/delete (nicht bewusst)": len(up.get("modify_delete", [])),
        "Reibung: modify/delete (bewusst entfernt)": sum(up.get("deliberate_counts", {}).values()),
    }


def find_previous(out_json: Path) -> Path | None:
    if not out_json.parent.is_dir():
        return None
    older = sorted(p for p in out_json.parent.glob("*.json")
                   if re.fullmatch(r"\d{4}-\d{2}-\d{2}", p.stem) and p.stem < out_json.stem)
    return older[-1] if older else None


# -------------------------------------------------------------------------------------- markdown

def md_table(headers: list[str], rows: list[list]) -> str:
    def cell(v):
        return str(v).replace("|", "\\|")
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    lines += ["| " + " | ".join(cell(v) for v in r) + " |" for r in rows]
    return "\n".join(lines)


def render_markdown(result: dict, previous: dict | None) -> str:
    meta = result["meta"]
    out = ["## Anhang: Rohzahlen", "",
           f"Gemessen mit `Tools/code_health.py`, Methodenversion {meta['method_version']}, auf "
           f"`{meta['ref']}` @ `{meta['ref_sha'][:9]}` (Commit-Datum {meta['ref_date']}). Fenster: "
           f"{meta['window_days']} Tage bis zu diesem Datum. Codezeilen = Zeilen mit Code außerhalb von "
           f"Kommentaren; die Zuordnung zu Typen ist eine Heuristik (siehe Skriptkopf).", ""]

    out += ["### Trend", ""]
    now = result["headline"]
    if previous is None:
        out += ["Kein früherer Bericht in diesem Ordner. Dieser Lauf ist die Baseline.", ""]
    elif previous["meta"]["method_version"] != meta["method_version"]:
        out += [f"Vorheriger Lauf ({previous['meta']['run_date']}) nutzte Methodenversion "
                f"{previous['meta']['method_version']}. Nicht vergleichbar, daher kein Trend.", ""]
    else:
        before = previous["headline"]
        rows = []
        for k, v in now.items():
            b = before.get(k)
            delta = "neu" if b is None else (f"{v - b:+d}" if v != b else "±0")
            rows.append([k, "k. A." if b is None else b, v, delta])
        out += [f"Vergleich mit {previous['meta']['run_date']} (`{previous['meta']['ref_sha'][:9]}`).", "",
                md_table(["Kennzahl", "vorher", "jetzt", "Δ"], rows), ""]
    if previous is None or previous["meta"]["method_version"] != meta["method_version"]:
        out += [md_table(["Kennzahl", "Wert"], [[k, v] for k, v in now.items()]), ""]

    out += ["### 1a. Größte Dateien", "",
            md_table(["Datei", "Codezeilen", "Zeilen"],
                     [[f"`{f['path']}`", f["code"], f["physical"]] for f in result["files"][:TOP_N]]), ""]
    out += ["### 1b. Größte Typen (alle Extensions summiert)", "",
            md_table(["Typ", "Art", "Codezeilen", "Zeilen", "Blöcke", "Dateien", "Hauptdatei"],
                     [[f"`{t['name']}`", t["kind"], t["code"], t["physical"], t["blocks"], len(t["files"]),
                       f"`{t['main_file']}`"] for t in result["types"][:TOP_N]]), ""]
    out += [f"### 2. Hotspots (Codezeilen × eigene Commits in {meta['window_days']} Tagen)", "",
            md_table(["Datei", "Codezeilen", "Commits", "Score"],
                     [[f"`{h['path']}`", h["code"], h["commits"], h["score"]]
                      for h in result["hotspots"][:TOP_N]]), ""]
    out += ["### 3a. ObservableObject: Fan-out", "",
            "Beobachter = verschiedene Typen mit `@ObservedObject`, `@StateObject` oder `@EnvironmentObject` "
            "auf diese Klasse. Sortiert nach Beobachter × @Published.", "",
            md_table(["Klasse", "@Published", "Beobachter", "Stellen", "Codezeilen", "Datei"],
                     [[f"`{r['name']}`", r["published"], r["observers"], r["sites"], r["code"], f"`{r['file']}`"]
                      for r in result["observable_objects"]]), ""]
    out += ["### 3b. @Observable-Klassen", "",
            "`var` = gespeicherte `var`-Properties auf oberster Ebene (Schätzung der beobachtbaren Fläche). "
            "Spalten zählen `@Environment(T.self)`, `@Bindable`, `@State` und einfache Properties in Views.", "",
            md_table(["Klasse", "var (Schätzung)", "Beobachter", "Environment", "Bindable", "State", "Property",
                      "Datei"],
                     [[f"`{r['name']}`", r["vars_estimate"], r["observers"], r["env"], r["bindable"], r["state"],
                       r["property"], f"`{r['file']}`"] for r in result["observable_classes"]]), ""]
    out += ["### 4. Größte SwiftUI-Views", "",
            md_table(["View", "Codezeilen", "Zeilen", "Dateien", "Hauptdatei"],
                     [[f"`{v['name']}`", v["code"], v["physical"], len(v["files"]), f"`{v['main_file']}`"]
                      for v in result["views"][:TOP_N]]), ""]

    up = result.get("upstream")
    out += ["### 5. Upstream-Reibung", ""]
    if not up:
        out += ["Kein `upstream/main` gefunden, nicht gemessen.", ""]
    else:
        out += [f"Gesamte Abweichung `upstream/main` (`{up['upstream_sha'][:9]}`) gegen `{meta['ref']}`, "
                f"gekreuzt mit upstream-Commits im selben Fenster. {up['upstream_commits']} upstream-Commits "
                f"im Fenster. Merge-Base `{up['merge_base'][:9]}` ({up['merge_base_date']}).", "",
                "**Im Fork geänderte Dateien, die upstream weiter ändert**", "",
                md_table(["Datei", "upstream-Commits", "Diff-Zeilen zu upstream", "eigene Commits"],
                         [[f"`{r['path']}`", r["upstream_commits"], r["diff_lines"], r["fork_commits"]]
                          for r in up["friction"][:TOP_N]]), "",
                "**Im Fork gelöscht, upstream ändert weiter (modify/delete)**", ""]
        if up["modify_delete"]:
            out += [md_table(["Datei", "upstream-Commits"],
                             [[f"`{r['path']}`", r["upstream_commits"]] for r in up["modify_delete"]]), ""]
        else:
            out += ["Keine außerhalb der bewusst entfernten Pfade.", ""]
        if up["deliberate_counts"]:
            out += ["Bewusst entfernt, nur gezählt:", "",
                    md_table(["Pfad", "Dateien mit upstream-Commits", "Entscheidung"],
                             [[f"`{p}`", c, up["deliberate_reasons"][p]]
                              for p, c in sorted(up["deliberate_counts"].items())]), ""]

    gaps = result["test_gaps"]
    out += [f"### 6. Testlücken (ab {BIG_LINES} Codezeilen, Name in keiner Testdatei)", "",
            "**Typen**", "",
            md_table(["Typ", "Art", "Codezeilen", "Hauptdatei"],
                     [[f"`{t['name']}`", t["kind"], t["code"], f"`{t['main_file']}`"] for t in gaps["types"]])
            if gaps["types"] else "Keine.", "",
            "**Dateien** (keiner der dort deklarierten Typnamen kommt in Tests vor)", "",
            md_table(["Datei", "Codezeilen"], [[f"`{f['path']}`", f["code"]] for f in gaps["files"]])
            if gaps["files"] else "Keine.", ""]
    out += ["### 7. Risikomarker", "",
            md_table(["Datei", "try!", "as!", "fatalError", "Summe"],
                     [[f"`{r['file']}`", r["try!"], r["as!"], r["fatalError"], r["total"]]
                      for r in result["risk"]]) if result["risk"] else "Keine.", ""]
    drift = result["doc_drift"]
    listed = [d for d in drift if d["verdict"] not in COUNTED_ONLY]
    android = Counter(d["owner"] for d in drift if d["verdict"] == "android")
    deliberate = Counter(d["owner"] for d in drift if d["verdict"] == "deliberate")
    out += ["### 8. Doku-Drift (Backticks in `docs/`, ohne CHANGELOG, releases, code-health und decisions.md)", "",
            "`missing` = existiert weder im Fork noch upstream; `deleted-in-fork` = existiert nur upstream. "
            f"Nur gezählt: Android-Verweise (Fork-Doku {android.get('fork', 0)}, upstream-Doku "
            f"{android.get('upstream', 0)}) und Verweise auf andere bewusst entfernte Pfade (Fork-Doku "
            f"{deliberate.get('fork', 0)}, upstream-Doku {deliberate.get('upstream', 0)}).", ""]
    for owner, title in (("fork", "Fork-Doku"), ("upstream", "upstream-Doku")):
        rows = [[f"`{d['doc']}:{d['line']}`", f"`{d['ref']}`", d["kind"], d["verdict"]]
                for d in listed if d["owner"] == owner]
        out += [f"**{title}** ({len(rows)})", "",
                md_table(["Fundstelle", "Verweis", "Art", "Befund"], rows) if rows else "Keine.", ""]
    return "\n".join(out).rstrip() + "\n"


# ------------------------------------------------------------------------------------------- main

def measure(repo: Path, ref: str, upstream_ref: str, window_days: int, run_date: str) -> dict:
    ref_sha = git("rev-parse", ref, cwd=repo).strip()
    ref_date = git("log", "-1", "--format=%cI", ref, cwd=repo).strip()
    since = (dt.datetime.fromisoformat(ref_date) - dt.timedelta(days=window_days)).isoformat()
    all_paths = git("ls-tree", "-r", "--name-only", ref, cwd=repo).splitlines()
    main_paths = set(all_paths)

    product = sorted(p for p in all_paths if is_product_swift(p))
    tests = sorted(p for p in all_paths if p.endswith(".swift") and is_test_path(p))
    others = sorted(p for p in all_paths if p.endswith(".swift") and p not in set(product) | set(tests))
    blobs = read_blobs(ref, product + tests + others, repo)

    files = [SwiftFile(p, blobs.get(p, "")) for p in product]
    by_path = {f.path: f for f in files}
    types = analyse_types(files)

    test_words = word_set(scan_swift(blobs.get(p, ""))[0] for p in tests)
    all_swift_masked = [f.masked for f in files] + [scan_swift(blobs.get(p, ""))[0] for p in tests + others]
    swift_words = word_set(all_swift_masked)
    declared = {m.group(2).split(".")[-1] for t in all_swift_masked for m in DECL_RE.finditer(t)}
    declared |= {m.group(1) for t in all_swift_masked
                 for m in re.finditer(r"\btypealias\s+([A-Za-z_]\w*)", t)}

    has_upstream = ref_exists(upstream_ref, repo)
    fork_range = [ref, "--not", upstream_ref] if has_upstream else [ref]
    fork_log = git("log", *fork_range, "--no-merges", f"--since={since}", "--format=%x00", "--name-only",
                   cwd=repo)
    fork_commits = parse_name_only_log(fork_log)
    fork_commit_total = int(git("rev-list", "--count", *fork_range, "--no-merges", f"--since={since}",
                                cwd=repo).strip())

    hotspots = sorted(({"path": f.path, "code": f.code, "commits": fork_commits.get(f.path, 0),
                        "score": f.code * fork_commits.get(f.path, 0)} for f in files),
                      key=lambda h: (-h["score"], h["path"]))
    hotspots = [h for h in hotspots if h["score"] > 0]

    type_rows = sorted(types.values(), key=lambda t: (-t["code"], t["name"]))
    views = [t for t in type_rows if t["is_view"]]
    oo_rows, ob_rows = analyse_fanout(files, types)

    gap_types = [t for t in type_rows if t["code"] >= BIG_LINES and t["kind"] != "extension-only"
                 and t["name"].rsplit(".", 1)[-1] not in test_words]
    gap_files = []
    for f in sorted(files, key=lambda f: (-f.code, f.path)):
        if f.code < BIG_LINES:
            continue
        names = {d["name"] for d in f.decls} | {PurePosixPath(f.path).stem}
        if not names & test_words:
            gap_files.append({"path": f.path, "code": f.code})

    upstream = None
    kotlin_words: set[str] = set()
    upstream_paths: set[str] = set()
    if has_upstream:
        up_sha = git("rev-parse", upstream_ref, cwd=repo).strip()
        up_paths_list = git("ls-tree", "-r", "--name-only", upstream_ref, cwd=repo).splitlines()
        upstream_paths = set(up_paths_list)
        kt = [p for p in up_paths_list if p.endswith((".kt", ".kts"))]
        kotlin_words = word_set(read_blobs(upstream_ref, kt, repo).values())
        up_log = git("log", upstream_ref, "--no-merges", f"--since={since}", "--format=%x00", "--name-only",
                     cwd=repo)
        up_commits = parse_name_only_log(up_log)
        up_commit_total = int(git("rev-list", "--count", upstream_ref, "--no-merges", f"--since={since}",
                                  cwd=repo).strip())
        status = parse_name_status(git("diff", "--no-renames", "--name-status", upstream_ref, ref, cwd=repo))
        churn = parse_numstat(git("diff", "--no-renames", "--numstat", upstream_ref, ref, cwd=repo))
        friction = sorted(({"path": p, "upstream_commits": up_commits[p], "diff_lines": churn.get(p, 0),
                            "fork_commits": fork_commits.get(p, 0)}
                           for p, s in status.items() if s == "M" and up_commits.get(p)),
                          key=lambda r: (-r["upstream_commits"], -r["diff_lines"], r["path"]))
        modify_delete, deliberate_counts, deliberate_reasons = [], Counter(), {}
        for p, s in sorted(status.items()):
            if s != "D" or not up_commits.get(p):
                continue
            reason = deliberate_reason(p)
            if reason:
                prefix = next(pre for pre, _ in DELIBERATE_DELETIONS if p.startswith(pre))
                deliberate_counts[prefix] += 1
                deliberate_reasons[prefix] = reason
            else:
                modify_delete.append({"path": p, "upstream_commits": up_commits[p]})
        modify_delete.sort(key=lambda r: (-r["upstream_commits"], r["path"]))
        mb = git("merge-base", ref, upstream_ref, cwd=repo).strip()
        upstream = {"upstream_sha": up_sha, "upstream_commits": up_commit_total, "merge_base": mb,
                    "merge_base_date": git("log", "-1", "--format=%cs", mb, cwd=repo).strip(),
                    "friction": friction, "modify_delete": modify_delete,
                    "deliberate_counts": dict(deliberate_counts), "deliberate_reasons": deliberate_reasons}

    doc_paths = [p for p in all_paths if is_doc_in_scope(p)]
    docs = read_blobs(ref, doc_paths, repo)
    def is_ignored(path: str) -> bool:
        return subprocess.run(["git", "check-ignore", "-q", "--no-index", path], cwd=repo,
                              capture_output=True).returncode == 0

    drift = analyse_doc_drift(docs, swift_words, declared, main_paths, upstream_paths, kotlin_words,
                              is_ignored)

    decisions_text = read_blobs(ref, ["docs/fork/decisions.md"], repo).get("docs/fork/decisions.md", "")

    def type_json(t):
        return {k: t[k] for k in ("name", "kind", "code", "physical", "blocks", "files", "main_file", "is_view")}

    result = {
        "meta": {"method_version": METHOD_VERSION, "run_date": run_date, "ref": ref, "ref_sha": ref_sha,
                 "ref_date": ref_date, "window_days": window_days, "window_since": since,
                 "upstream_ref": upstream_ref if has_upstream else None,
                 "product_roots": sorted({PurePosixPath(p).parts[0] if not p.startswith("Packages/")
                                          else "/".join(PurePosixPath(p).parts[:3]) for p in product}),
                 "test_files": len(tests)},
        "files": [{"path": f.path, "code": f.code, "physical": f.physical}
                  for f in sorted(files, key=lambda f: (-f.code, f.path))],
        "types": [type_json(t) for t in type_rows],
        "views": [type_json(t) for t in views],
        "fork_commits": fork_commit_total,
        "hotspots": hotspots,
        "observable_objects": oo_rows,
        "observable_classes": ob_rows,
        "test_gaps": {"types": [type_json(t) for t in gap_types], "files": gap_files},
        "risk": analyse_risk(files),
        "upstream": upstream,
        "doc_drift": drift,
        "decisions": parse_decisions(decisions_text),
    }
    result["headline"] = headline(result)
    return trim(result)


def trim(result: dict) -> dict:
    """Keep the committed JSON small. The headline already holds every trend number; the lists only
    need what the appendix shows plus some headroom for a later look."""
    keep = lambda rows: [r for r in rows if r["code"] >= TRIM_LINES]
    result["files"] = keep(result["files"])
    result["types"] = keep(result["types"])
    result["views"] = keep(result["views"])
    result["hotspots"] = result["hotspots"][:100]
    if result["upstream"]:
        result["upstream"]["friction"] = result["upstream"]["friction"][:100]
    result["decisions"] = [{k: d[k] for k in ("line", "date", "kind", "signals")}
                           | {"decision": d["decision"][:160]} for d in result["decisions"]]
    return result


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--ref", default="main")
    ap.add_argument("--upstream", default="upstream/main")
    ap.add_argument("--date", default=dt.date.today().isoformat(), help="run date, names the output files")
    ap.add_argument("--json", required=True, help="where to write the full measurement")
    ap.add_argument("--markdown", help="write the appendix tables here")
    ap.add_argument("--fill", help=f"replace the line {APPENDIX_MARKER} in this report with the appendix")
    ap.add_argument("--previous", help="earlier JSON to compare against (default: newest older one)")
    args = ap.parse_args(argv)

    repo = Path(args.repo)
    result = measure(repo, args.ref, args.upstream, WINDOW_DAYS, args.date)
    out_json = Path(args.json)
    prev_path = Path(args.previous) if args.previous else find_previous(out_json)
    previous = json.loads(prev_path.read_text()) if prev_path and prev_path.exists() else None
    result["meta"]["previous"] = str(prev_path) if previous else None

    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(result, indent=1, ensure_ascii=False, sort_keys=False) + "\n")
    appendix = render_markdown(result, previous)
    if args.markdown:
        Path(args.markdown).write_text(appendix)
    if args.fill:
        report = Path(args.fill)
        text = report.read_text()
        if APPENDIX_MARKER not in text:
            print(f"error: {report} has no line {APPENDIX_MARKER}", file=sys.stderr)
            return 1
        report.write_text(text.replace(APPENDIX_MARKER, appendix.rstrip("\n"), 1))
    print(json.dumps({"json": str(out_json), "previous": result["meta"]["previous"],
                      "headline": result["headline"]}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
