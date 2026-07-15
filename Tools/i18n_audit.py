#!/usr/bin/env python3
"""Audit user-facing text for translation gaps across both platforms.

Two independent problems, both covered here:

1. Hardcoded literals — a `Text("Charge")`-style call that never goes through
   any localization mechanism at all (Kotlin has no auto-extraction like
   SwiftUI's LocalizedStringKey, so any literal in a Compose Text/title/label
   call is unlocalized by construction). Reported as HARDCODED.
2. Catalog drift — a string IS wired through localization (a SwiftUI
   LocalizedStringKey, or an Android stringResource key) but a target
   language's translation is missing from the String Catalog / strings.xml.
   Reported as MISSING_<LANG>.

Target languages: de, es, fr (the focus set). English is the source language
and is not checked for itself.

Read-only. Prints a report; does not modify any file. Re-runnable, and the
same logic is meant to be wired into a CI check later (see i18n-coverage.yml)
so this stops being a manual step.

Usage: python3 Tools/i18n_audit.py [--platform ios|android|all] [--full]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ["de", "es", "fr"]

# Strings that are legitimately identical across all languages (symbols,
# format-only placeholders, brand name, units) — mirrors the exclude
# reasoning already established in Tools/translate-de.py. Extend as needed;
# false positives here just mean noise in the report, not a wrong fix.
UNIVERSAL = {
    "", "-", "–", "—", "·", "•", "✓", "→", "↔",
    "NOOP", "bpm", "BPM", "HRV", "SpO2", "SpO₂", "OK", "ID",
}


def is_probably_ui_text(s: str) -> bool:
    """Filter out obvious non-UI-text matches (identifiers, tags, formats)."""
    if s in UNIVERSAL:
        return False
    if not re.search(r"[A-Za-z]", s):
        return False  # pure symbols/numbers/format specifiers
    # snake_case / dotted / slashed identifiers (testTags, routes, keys) —
    # real UI copy almost always has a space or is a capitalized single word.
    if re.fullmatch(r"[a-z][a-z0-9_./]*", s) and " " not in s:
        return False
    if s.startswith("http://") or s.startswith("https://"):
        return False
    return True


# ---------------------------------------------------------------------------
# Android: hardcoded Compose literals
# ---------------------------------------------------------------------------

ANDROID_DIRS = [
    ROOT / "android/app/src/main/java/com/noop/ui",
    ROOT / "android/app/src/main/java/com/noop/widget",
]

# First positional/named string-literal argument to a UI-text-bearing call.
ANDROID_PATTERN = re.compile(
    r"\b(?:Text|Snackbar|AlertDialog|TopAppBar)\s*\(\s*\"((?:[^\"\\]|\\.)*)\""
    r"|"
    r"\b(?:title|label|text|contentDescription|placeholder)\s*=\s*\"((?:[^\"\\]|\\.)*)\""
)


def scan_android() -> list[tuple[str, int, str]]:
    findings = []
    for base in ANDROID_DIRS:
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.kt")):
            text = path.read_text(encoding="utf-8", errors="replace")
            for m in ANDROID_PATTERN.finditer(text):
                literal = m.group(1) or m.group(2)
                if literal is None or not is_probably_ui_text(literal):
                    continue
                line_no = text.count("\n", 0, m.start()) + 1
                findings.append((str(path.relative_to(ROOT)), line_no, literal))
    return findings


def android_strings_xml_gaps() -> dict[str, set[str]]:
    """Keys present in the base values/strings.xml but missing from an
    existing values-<lang>/strings.xml. (Doesn't invent missing locale dirs —
    see the audit summary for languages with NO directory at all.)"""
    base_path = ROOT / "android/app/src/main/res/values/strings.xml"
    base_keys = set(re.findall(r'<string name="([^"]+)"', base_path.read_text(encoding="utf-8")))
    exempt = {"app_name"}  # brand name, deliberately identical everywhere
    gaps: dict[str, set[str]] = {}
    for lang in LANGS:
        lang_path = ROOT / f"android/app/src/main/res/values-{lang}/strings.xml"
        if not lang_path.exists():
            gaps[lang] = {"<entire values-%s/ directory is missing>" % lang}
            continue
        lang_keys = set(re.findall(r'<string name="([^"]+)"', lang_path.read_text(encoding="utf-8")))
        missing = (base_keys - exempt) - lang_keys
        if missing:
            gaps[lang] = missing
    return gaps


# ---------------------------------------------------------------------------
# Apple: catalog drift + un-extracted literals
# ---------------------------------------------------------------------------

CATALOGS = [
    (
        [ROOT / "Packages/StrandDesign/Sources/StrandDesign"],
        ROOT / "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings",
    ),
    (
        [ROOT / "NOOPWatch"],
        ROOT / "NOOPWatch/Localizable.xcstrings",
    ),
    (
        [ROOT / "NOOPWatchComplications"],
        ROOT / "NOOPWatchComplications/Localizable.xcstrings",
    ),
    (
        [ROOT / "Strand", ROOT / "StrandiOS", ROOT / "StrandiOSShared", ROOT / "StrandiOSWidgets"],
        ROOT / "Strand/Resources/Localizable.xcstrings",
    ),
]

SWIFT_CALL_PATTERN = re.compile(
    r"\b(?:Text|Button|Label|Toggle|Menu|Picker|ProgressView|SectionHeader)\s*\(\s*\"((?:[^\"\\]|\\.)*)\""
    r"|"
    r"\.(?:navigationTitle|confirmationDialog|alert)\s*\(\s*\"((?:[^\"\\]|\\.)*)\""
)


def load_catalog(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def catalog_lookup(cat: dict, key: str) -> dict | None:
    return cat.get("strings", {}).get(key)


def scan_ios() -> tuple[list[tuple[str, int, str]], dict[str, list[str]]]:
    hardcoded: list[tuple[str, int, str]] = []  # not in any catalog at all
    lang_gaps: dict[str, list[str]] = {lang: [] for lang in LANGS}

    for dirs, catalog_path in CATALOGS:
        cat = load_catalog(catalog_path)
        for base in dirs:
            if not base.exists():
                continue
            for path in sorted(base.rglob("*.swift")):
                text = path.read_text(encoding="utf-8", errors="replace")
                for m in SWIFT_CALL_PATTERN.finditer(text):
                    literal = m.group(1) or m.group(2)
                    if literal is None or not is_probably_ui_text(literal):
                        continue
                    entry = catalog_lookup(cat, literal)
                    line_no = text.count("\n", 0, m.start()) + 1
                    rel = str(path.relative_to(ROOT))
                    if entry is None:
                        hardcoded.append((rel, line_no, literal))
                        continue
                    if entry.get("shouldTranslate") is False:
                        continue
                    loc = entry.get("localizations", {})
                    for lang in LANGS:
                        state = (loc.get(lang) or {}).get("stringUnit", {}).get("state")
                        if state != "translated":
                            lang_gaps[lang].append(f"{catalog_path.relative_to(ROOT)} :: {literal!r}")
    for lang in lang_gaps:
        lang_gaps[lang] = sorted(set(lang_gaps[lang]))
    return hardcoded, lang_gaps


def git_show(ref: str, rel_path: str) -> str | None:
    """File content at `ref`, or None if the path didn't exist there."""
    result = subprocess.run(
        ["git", "show", f"{ref}:{rel_path}"],
        cwd=ROOT, capture_output=True, text=True,
    )
    return result.stdout if result.returncode == 0 else None


def literals_at_ref(ref: str) -> tuple[set[tuple[str, str]], set[tuple[str, str]]]:
    """(android, ios) sets of (relative_path, literal) hardcoded findings as they
    stood at `ref`, using the CURRENT file list (a file added by the PR simply
    reads as empty at the base ref, which correctly counts its literals as new)."""
    android: set[tuple[str, str]] = set()
    for base in ANDROID_DIRS:
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.kt")):
            rel = str(path.relative_to(ROOT))
            text = git_show(ref, rel) or ""
            for m in ANDROID_PATTERN.finditer(text):
                literal = m.group(1) or m.group(2)
                if literal is None or not is_probably_ui_text(literal):
                    continue
                android.add((rel, literal))

    ios: set[tuple[str, str]] = set()
    for dirs, catalog_path in CATALOGS:
        cat_text = git_show(ref, str(catalog_path.relative_to(ROOT)))
        cat = json.loads(cat_text) if cat_text else {"strings": {}}
        for base in dirs:
            if not base.exists():
                continue
            for path in sorted(base.rglob("*.swift")):
                rel = str(path.relative_to(ROOT))
                text = git_show(ref, rel) or ""
                for m in SWIFT_CALL_PATTERN.finditer(text):
                    literal = m.group(1) or m.group(2)
                    if literal is None or not is_probably_ui_text(literal):
                        continue
                    if catalog_lookup(cat, literal) is None:
                        ios.add((rel, literal))
    return android, ios


def ci_check(base_ref: str) -> int:
    """Regression gate for CI: fails only on NEW problems this PR introduces,
    never on the pre-existing backlog (see Tools/i18n_audit.py module docstring
    and the linked GitHub tracking issue for that backlog). Two kinds of gate:

    1. Standing invariant, always enforced regardless of diff: `de` stays 100%
       covered on both platforms, because it already is today (verified below) —
       any PR that adds an English string without its German counterpart trips
       this immediately, which is exactly the class of bug #326/#342/#448 kept
       recurring.
    2. Diff-scoped: no NEW hardcoded-and-never-localized literal versus the PR's
       base — lets the existing ~1500-item backlog sit untouched while stopping
       it from growing.
    """
    failed = False

    print("--- Standing invariant: de must stay fully covered ---")
    android_gaps = android_strings_xml_gaps().get("de")
    if android_gaps:
        failed = True
        print(f"FAIL android values-de/strings.xml missing {len(android_gaps)} key(s): {sorted(android_gaps)}")
    else:
        print("  OK android values-de/strings.xml")
    for _dirs, catalog_path in CATALOGS:
        cat = load_catalog(catalog_path)
        missing = [
            k for k, v in cat.get("strings", {}).items()
            if v.get("shouldTranslate") is not False
            and (v.get("localizations", {}).get("de") or {}).get("stringUnit", {}).get("state") != "translated"
        ]
        if missing:
            failed = True
            print(f"FAIL {catalog_path.relative_to(ROOT)} missing de for {len(missing)} key(s): {missing[:10]}")
        else:
            print(f"  OK {catalog_path.relative_to(ROOT)}")

    print(f"\n--- Diff-scoped: no new hardcoded literals versus {base_ref} ---")
    base_android, base_ios = literals_at_ref(base_ref)
    head_android = {(f, lit) for f, _line, lit in scan_android()}
    head_ios = {(f, lit) for f, _line, lit in scan_ios()[0]}
    new_android = sorted(head_android - base_android)
    new_ios = sorted(head_ios - base_ios)
    if new_android:
        failed = True
        print(f"FAIL {len(new_android)} new Android hardcoded literal(s) — wrap in stringResource():")
        for f, lit in new_android[:30]:
            print(f"  {f}: {lit!r}")
    else:
        print("  OK no new Android hardcoded literals")
    if new_ios:
        failed = True
        print(f"FAIL {len(new_ios)} new Swift literal(s) not in their String Catalog — build once so Xcode extracts them:")
        for f, lit in new_ios[:30]:
            print(f"  {f}: {lit!r}")
    else:
        print("  OK no new un-extracted Swift literals")

    print("\n--- Informational only (existing backlog, not gated yet) ---")
    for lang in ("es", "fr"):
        android_lang_gaps = android_strings_xml_gaps().get(lang)
        print(f"  android {lang}: {len(android_lang_gaps) if android_lang_gaps else 0} gap(s)")
    for _dirs, catalog_path in CATALOGS:
        cat = load_catalog(catalog_path)
        for lang in ("es", "fr"):
            missing = sum(
                1 for v in cat.get("strings", {}).values()
                if v.get("shouldTranslate") is not False
                and (v.get("localizations", {}).get(lang) or {}).get("stringUnit", {}).get("state") != "translated"
            )
            print(f"  {catalog_path.relative_to(ROOT)} {lang}: missing={missing}")

    return 1 if failed else 0


def catalog_summary() -> None:
    print("\n--- Apple catalogs: translated-key coverage (existing keys, any source) ---")
    for _dirs, catalog_path in CATALOGS:
        cat = load_catalog(catalog_path)
        strings = cat.get("strings", {})
        total = len(strings)
        line = f"{catalog_path.relative_to(ROOT)} ({total} keys):"
        for lang in LANGS:
            missing = 0
            for v in strings.values():
                if v.get("shouldTranslate") is False:
                    continue
                state = (v.get("localizations", {}).get(lang) or {}).get("stringUnit", {}).get("state")
                if state != "translated":
                    missing += 1
            line += f"  {lang} missing={missing}"
        print(" ", line)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=["ios", "android", "all"], default="all")
    ap.add_argument("--full", action="store_true", help="print every finding, not just counts")
    ap.add_argument("--ci", metavar="BASE_REF", help="regression-gate mode: exit 1 on new drift vs BASE_REF (e.g. origin/main); see ci_check() docstring")
    args = ap.parse_args()

    if args.ci:
        return ci_check(args.ci)

    if args.platform in ("android", "all"):
        print("=== Android: hardcoded UI literals (never localized) ===")
        findings = scan_android()
        print(f"{len(findings)} hardcoded literal(s) found under android/app/.../ui|widget")
        if args.full:
            for rel, line_no, literal in findings:
                print(f"  {rel}:{line_no}: {literal!r}")
        else:
            for rel, line_no, literal in findings[:25]:
                print(f"  {rel}:{line_no}: {literal!r}")
            if len(findings) > 25:
                print(f"  ... and {len(findings) - 25} more (use --full)")

        print("\n=== Android: values-<lang>/strings.xml key gaps ===")
        gaps = android_strings_xml_gaps()
        if not gaps:
            print("  none (de/es/fr all present and complete, or no locale dir exists)")
        for lang, keys in gaps.items():
            print(f"  {lang}: {len(keys)} gap(s)")
            if args.full:
                for k in sorted(keys):
                    print(f"    {k}")

    if args.platform in ("ios", "all"):
        print("\n=== Apple: hardcoded/un-extracted Swift literals (not in any catalog) ===")
        hardcoded, lang_gaps = scan_ios()
        print(f"{len(hardcoded)} literal(s) not present in their target's String Catalog")
        if args.full:
            for rel, line_no, literal in hardcoded:
                print(f"  {rel}:{line_no}: {literal!r}")
        else:
            for rel, line_no, literal in hardcoded[:25]:
                print(f"  {rel}:{line_no}: {literal!r}")
            if len(hardcoded) > 25:
                print(f"  ... and {len(hardcoded) - 25} more (use --full)")

        print("\n=== Apple: catalog keys present but not translated, per language ===")
        for lang in LANGS:
            entries = lang_gaps[lang]
            print(f"  {lang}: {len(entries)} gap(s)")
            if args.full:
                for e in entries:
                    print(f"    {e}")

        catalog_summary()

    return 0


if __name__ == "__main__":
    sys.exit(main())
