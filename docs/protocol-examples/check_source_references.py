#!/usr/bin/env python3
"""Check source references in protocol implementation documentation.

Format: use ``[Symbol](../relative/source.swift)`` for code symbols.
Format: the link text may use ``Type.member(args:)``; the final name is checked.
Format: use backticks for file-only paths; those are checked for existence only.
Run: ``python3 docs/protocol-examples/check_source_references.py [docs ...]``.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DOC = REPO_ROOT / "docs" / "PROTOCOL_IMPLEMENTATION.md"
LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
SOURCE_LINK_SUFFIXES = {".swift", ".kt", ".json", ".py", ".yml"}
BACKTICK_PATH_RE = re.compile(
    r"`([^`\n]*?/[^`\n]+\.(?:swift|kt|json|py))`", re.IGNORECASE
)
SYMBOL_TEXT_RE = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*"
    r"(?:\([^\n)]*\))?$"
)
IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def display_path(path: Path) -> str:
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def symbol_from_text(link_text: str) -> str | None:
    text = link_text.strip()
    if not SYMBOL_TEXT_RE.fullmatch(text):
        return None
    before_args = text.split("(", 1)[0]
    identifiers = IDENTIFIER_RE.findall(before_args)
    return identifiers[-1] if identifiers else None


def resolve_target(doc: Path, raw_target: str) -> tuple[Path, str] | None:
    target = raw_target.split("#", 1)[0]
    if not target or target.startswith(("/", "http://", "https://", "mailto:")):
        return None
    return (doc.parent / target).resolve(), target


def target_is_retired_platform_source(target: Path) -> bool:
    """Whether a reference names Android in an Apple-only checkout.

    The protocol document stays mergeable with upstream and therefore keeps both implementations in
    its matrix. This fork intentionally removes the complete Android tree; absence there is a scope
    decision rather than a stale link. Every retained Apple/Python reference remains strict.
    """
    try:
        relative = target.relative_to(REPO_ROOT)
    except ValueError:
        return False
    return bool(relative.parts) and relative.parts[0] == "android" and not (REPO_ROOT / "android").is_dir()


def check_doc(doc: Path) -> tuple[int, set[Path], list[str]]:
    text = doc.read_text(encoding="utf-8")
    checked = 0
    files: set[Path] = set()
    failures: list[str] = []
    doc_name = display_path(doc)

    for match in LINK_RE.finditer(text):
        link_text, raw_target = match.groups()
        resolved = resolve_target(doc, raw_target)
        if resolved is None:
            continue
        target, target_text = resolved
        if target.suffix.lower() not in SOURCE_LINK_SUFFIXES:
            continue
        if target_is_retired_platform_source(target):
            continue
        checked += 1
        files.add(target)
        line = line_number(text, match.start())
        symbol = symbol_from_text(link_text)
        symbol_field = f" [{symbol}]" if symbol else ""
        if not target.is_file():
            failures.append(
                f"FAIL {doc_name}:{line} {target_text}{symbol_field} file does not exist"
            )
            continue
        if symbol:
            source = target.read_text(encoding="utf-8", errors="replace")
            if re.search(rf"\b{re.escape(symbol)}\b", source) is None:
                failures.append(
                    f"FAIL {doc_name}:{line} {target_text} [{symbol}] symbol not found"
                )

    occupied = [(match.start(), match.end()) for match in LINK_RE.finditer(text)]
    for match in BACKTICK_PATH_RE.finditer(text):
        if any(start <= match.start() < end for start, end in occupied):
            continue
        raw_target = match.group(1)
        resolved = resolve_target(doc, raw_target)
        if resolved is None:
            continue
        target, target_text = resolved
        if target_is_retired_platform_source(target):
            continue
        checked += 1
        files.add(target)
        line = line_number(text, match.start())
        if not target.is_file():
            failures.append(
                f"FAIL {doc_name}:{line} {target_text} file does not exist"
            )

    return checked, files, failures


def main(argv: list[str]) -> int:
    docs = [Path(arg).resolve() for arg in argv] if argv else [DEFAULT_DOC]
    checked = 0
    files: set[Path] = set()
    failures: list[str] = []

    for doc in docs:
        if not doc.is_file():
            failures.append(
                f"FAIL {display_path(doc)}:1 {display_path(doc)} document does not exist"
            )
            continue
        doc_checked, doc_files, doc_failures = check_doc(doc)
        checked += doc_checked
        files.update(doc_files)
        failures.extend(doc_failures)

    for failure in failures:
        print(failure)
    print(f"checked {checked} references, {len(files)} files, {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
