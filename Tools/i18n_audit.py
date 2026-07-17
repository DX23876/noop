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
import xml.etree.ElementTree as ET
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
    # <plurals> count too: converting a hand-rolled singular/plural PAIR into one <plurals> would
    # otherwise DROP those keys out of this gate's view entirely, so a locale could silently lose them —
    # fixing the plural model must not open a coverage hole (see #540 for the same class of blind spot).
    base_keys = set(re.findall(r'<(?:string|plurals) name="([^"]+)"', base_path.read_text(encoding="utf-8")))
    exempt = {"app_name"}  # brand name, deliberately identical everywhere
    gaps: dict[str, set[str]] = {}
    for lang in LANGS:
        lang_path = ROOT / f"android/app/src/main/res/values-{lang}/strings.xml"
        if not lang_path.exists():
            gaps[lang] = {"<entire values-%s/ directory is missing>" % lang}
            continue
        lang_keys = set(re.findall(r'<(?:string|plurals) name="([^"]+)"', lang_path.read_text(encoding="utf-8")))
        missing = (base_keys - exempt) - lang_keys
        if missing:
            gaps[lang] = missing
    return gaps


ANDROID_FORMAT_PATTERN = re.compile(r"%[1-9]\d*\$[-+0 #,(]*\d*(?:\.\d+)?([sdif])")


def android_format_gaps() -> dict[str, list[str]]:
    """Resource keys whose translated Formatter arguments differ from English."""
    paths = {
        "en": ROOT / "android/app/src/main/res/values/strings.xml",
        **{lang: ROOT / f"android/app/src/main/res/values-{lang}/strings.xml" for lang in LANGS},
    }
    def signature(value: str) -> list[str]:
        return sorted(ANDROID_FORMAT_PATTERN.findall(value))

    values: dict[str, dict[str, str]] = {}
    plural_items: dict[str, dict[str, list[str]]] = {}
    for lang, path in paths.items():
        if not path.exists():
            continue
        root = ET.parse(path).getroot()
        entries = {node.attrib["name"]: node.text or "" for node in root.findall("string")}
        items_by_key: dict[str, list[str]] = {}
        # <plurals> carry their format args on the <item> CHILDREN, so a plain findall("string") leaves
        # every plural's placeholders unchecked.
        #
        # Compare ONE REPRESENTATIVE form across languages, never the concatenated set: the signature is a
        # MULTISET, so folding would make it depend on how many quantity categories a language HAS —
        # Polish (one/few/many/other) would read as a format mismatch against English (one/other) purely
        # for having more forms, and this gate would reject the very thing <plurals> exist to support.
        # `other` is the CLDR fallback every language defines, so it is the stable representative.
        # A dropped placeholder in a NON-representative form is caught by the intra-plural check below.
        for node in root.findall("plurals"):
            items = node.findall("item")
            texts = [i.text or "" for i in items]
            rep = next((i.text or "" for i in items if i.attrib.get("quantity") == "other"),
                       texts[0] if texts else "")
            entries[node.attrib["name"]] = rep
            items_by_key[node.attrib["name"]] = texts
        values[lang] = entries
        plural_items[lang] = items_by_key

    gaps: dict[str, list[str]] = {}
    for lang in LANGS:
        if lang not in values:
            continue
        mismatched = [
            key for key, source in values["en"].items()
            if signature(source) != signature(values[lang].get(key, ""))
        ]
        # Every quantity form of ONE plural must carry the same placeholders as its siblings. This is a
        # within-language invariant, so it stays correct no matter how many categories the language has —
        # it catches the "translator dropped %1$d from just the `one` form" case that the representative
        # comparison above cannot see.
        for key, texts in plural_items.get(lang, {}).items():
            if len({tuple(signature(x)) for x in texts}) > 1 and key not in mismatched:
                mismatched.append(key)
        if mismatched:
            gaps[lang] = mismatched
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

SWIFT_CALL_START_PATTERN = re.compile(
    r"\b(?:Text|Button|Label|Toggle|Menu|Picker|ProgressView|SectionHeader)\s*\(\s*\""
    r"|"
    r"\.(?:navigationTitle|confirmationDialog|alert)\s*\(\s*\""
)

# A placeholder generated by Swift's LocalizedStringKey interpolation. The
# precise conversion depends on the interpolated value's static type, so the
# source-side audit deliberately accepts any valid String Catalog placeholder
# at that position instead of trying to reproduce compiler type inference.
CATALOG_PLACEHOLDER_PATTERN = r"%(?:(?:\d+)\$)?(?:@|[-+0 #']*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp])"


def swift_string_literals(text: str):
    """Yield (match offset, literal contents) for localized SwiftUI calls.

    A regex that stops at the next quote breaks on interpolation expressions
    such as ``Text("\\(String(format: "%.1f", value)) bpm")``. This small
    scanner understands balanced ``\\(...)`` expressions and quoted strings
    inside them, while leaving the literal in source form for catalog lookup.
    """
    for match in SWIFT_CALL_START_PATTERN.finditer(text):
        start = match.end() - 1
        i = start + 1
        interpolation_depth = 0
        while i < len(text):
            ch = text[i]
            if interpolation_depth == 0:
                if ch == '"':
                    yield match.start(), text[start + 1:i]
                    break
                if ch == "\\" and i + 1 < len(text):
                    if text[i + 1] == "(":
                        interpolation_depth = 1
                    i += 2
                    continue
                i += 1
                continue

            # Inside an interpolation expression, ignore parentheses in a
            # nested Swift string and otherwise balance the expression.
            if ch == '"':
                i += 1
                while i < len(text):
                    if text[i] == "\\" and i + 1 < len(text):
                        i += 2
                    elif text[i] == '"':
                        i += 1
                        break
                    else:
                        i += 1
                continue
            if ch == "(":
                interpolation_depth += 1
            elif ch == ")":
                interpolation_depth -= 1
            i += 1


def swift_catalog_pattern(literal: str) -> re.Pattern[str] | None:
    """Turn a Swift source literal into a regex for its compiled catalog key."""
    parts: list[str] = []
    cursor = 0
    i = 0
    found_interpolation = False
    while i < len(literal):
        if literal.startswith("\\(", i):
            found_interpolation = True
            static = swift_unescape(literal[cursor:i]).replace("%", "%%")
            parts.append(re.escape(static))
            depth = 1
            i += 2
            in_string = False
            while i < len(literal) and depth:
                ch = literal[i]
                if in_string:
                    if ch == "\\" and i + 1 < len(literal):
                        i += 2
                        continue
                    if ch == '"':
                        in_string = False
                elif ch == '"':
                    in_string = True
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                i += 1
            parts.append(CATALOG_PLACEHOLDER_PATTERN)
            cursor = i
        else:
            i += 1
    if not found_interpolation:
        return None
    parts.append(re.escape(swift_unescape(literal[cursor:]).replace("%", "%%")))
    return re.compile("^" + "".join(parts) + "$")


def swift_unescape(value: str) -> str:
    """Decode the Swift escapes that can appear in catalog source text."""
    value = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), value)
    replacements = {
        r'\"': '"',
        r"\'": "'",
        r"\n": "\n",
        r"\r": "\r",
        r"\t": "\t",
        r"\\": "\\",
    }
    for escaped, decoded in replacements.items():
        value = value.replace(escaped, decoded)
    return value


def swift_catalog_lookup(cat: dict, literal: str) -> dict | None:
    """Find a direct or compiler-normalized String Catalog entry."""
    direct = catalog_lookup(cat, swift_unescape(literal))
    if direct is not None:
        return direct
    pattern = swift_catalog_pattern(literal)
    if pattern is None:
        return None
    for key, entry in cat.get("strings", {}).items():
        if pattern.fullmatch(key):
            return entry
    return None


APPLE_FORMAT_PATTERN = re.compile(
    r"%(?:(?:\d+)\$)?(@|(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp])"
)


def _string_units(entry: dict, lang: str) -> list[dict]:
    """Every stringUnit a localization carries — plain value OR plural variations.

    An xcstrings localization is either

        localizations.<lang>.stringUnit

    or, once the string has plural forms,

        localizations.<lang>.variations.plural.<category>.stringUnit

    (device variations nest the same way, and the two can combine). Reading only the FIRST shape makes
    every pluralised entry look untranslated to this gate — so converting a hand-rolled ternary into real
    plural variations would red-flag the string in every language. Walk both shapes.
    """
    loc = (entry.get("localizations", {}) or {}).get(lang) or {}
    units: list[dict] = []
    unit = loc.get("stringUnit")
    if isinstance(unit, dict):
        units.append(unit)

    def walk(node: object) -> None:
        if not isinstance(node, dict):
            return
        for key, value in node.items():
            if key == "stringUnit" and isinstance(value, dict):
                units.append(value)
            elif isinstance(value, dict):
                walk(value)

    walk(loc.get("variations") or {})
    return units


def _is_translated(entry: dict, lang: str) -> bool:
    """True when the localization exists AND every one of its stringUnits is translated — so a plural
    with one category still marked `new` is correctly reported as a gap, not silently accepted."""
    units = _string_units(entry, lang)
    return bool(units) and all(u.get("state") == "translated" for u in units)


def apple_format_gaps(cat: dict, lang: str) -> list[str]:
    """Catalog keys whose localized printf arguments differ from the source."""
    def signature(value: str) -> list[str]:
        return sorted(APPLE_FORMAT_PATTERN.findall(value))

    mismatched = []
    for key, entry in cat.get("strings", {}).items():
        if entry.get("shouldTranslate") is False:
            continue
        # Compare EVERY form independently against the key, never a folded concatenation: folding would
        # make the signature depend on how many plural categories the language HAS (ru/pl carry four,
        # zh one), so a correct translation would read as a format mismatch purely for having more forms.
        values = [u.get("value", "") for u in _string_units(entry, lang)] or [""]
        if any(signature(key) != signature(v) for v in values):
            mismatched.append(key)
    return mismatched


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
                for offset, literal in swift_string_literals(text):
                    if not is_probably_ui_text(literal):
                        continue
                    entry = swift_catalog_lookup(cat, literal)
                    line_no = text.count("\n", 0, offset) + 1
                    rel = str(path.relative_to(ROOT))
                    if entry is None:
                        hardcoded.append((rel, line_no, literal))
                        continue
                    if entry.get("shouldTranslate") is False:
                        continue
                    for lang in LANGS:
                        if not _is_translated(entry, lang):
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
                for _offset, literal in swift_string_literals(text):
                    if not is_probably_ui_text(literal):
                        continue
                    if swift_catalog_lookup(cat, literal) is None:
                        ios.add((rel, literal))
    return android, ios


def ci_check(base_ref: str) -> int:
    """Strict CI gate: the #453 backlog is closed, so every focus language and
    every audited UI literal must remain complete. ``base_ref`` remains in the
    CLI for workflow compatibility but coverage is now a standing invariant,
    not a diff-scoped allowance.
    """
    failed = False

    print("--- Android: no hardcoded UI copy and complete focus locales ---")
    android_literals = scan_android()
    if android_literals:
        failed = True
        print(f"FAIL {len(android_literals)} hardcoded literal(s):")
        for path, line, literal in android_literals[:30]:
            print(f"  {path}:{line}: {literal!r}")
    else:
        print("  OK no hardcoded literals")
    android_gaps = android_strings_xml_gaps()
    android_formats = android_format_gaps()
    for lang in LANGS:
        gaps = android_gaps.get(lang)
        if gaps:
            failed = True
            print(f"FAIL values-{lang}/strings.xml missing {len(gaps)} key(s): {sorted(gaps)[:30]}")
        else:
            print(f"  OK values-{lang}/strings.xml")
        format_gaps = android_formats.get(lang)
        if format_gaps:
            failed = True
            print(f"FAIL values-{lang}/strings.xml has {len(format_gaps)} format mismatch(es): {format_gaps[:30]}")

    print("\n--- Apple: no un-extracted UI copy and complete focus locales ---")
    ios_literals, _source_gaps = scan_ios()
    if ios_literals:
        failed = True
        print(f"FAIL {len(ios_literals)} literal(s) absent from their target catalog:")
        for path, line, literal in ios_literals[:30]:
            print(f"  {path}:{line}: {literal!r}")
    else:
        print("  OK no un-extracted literals")
    for _dirs, catalog_path in CATALOGS:
        cat = load_catalog(catalog_path)
        for lang in LANGS:
            missing = sum(
                1 for v in cat.get("strings", {}).values()
                if v.get("shouldTranslate") is not False and not _is_translated(v, lang)
            )
            if missing:
                failed = True
                print(f"FAIL {catalog_path.relative_to(ROOT)} {lang}: missing={missing}")
            else:
                print(f"  OK {catalog_path.relative_to(ROOT)} {lang}")
            format_gaps = apple_format_gaps(cat, lang)
            if format_gaps:
                failed = True
                print(f"FAIL {catalog_path.relative_to(ROOT)} {lang}: {len(format_gaps)} format mismatch(es): {format_gaps[:10]}")

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
    ap.add_argument("--ci", metavar="BASE_REF", help="strict coverage gate (BASE_REF is retained for workflow compatibility); see ci_check() docstring")
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
