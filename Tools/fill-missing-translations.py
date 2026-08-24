#!/usr/bin/env python3
"""Add MISSING translations to an Apple String Catalog, never overwriting existing ones.

Why this exists alongside `translate-de.py`: that script carries a full German dictionary and is the
source of truth for the keys it holds, but it only covers a few hundred of the catalog's 4 500+ keys,
and there is no equivalent for the other seven languages. Writing a full dictionary per language is
not practical; what IS needed regularly is "a batch of new keys just landed, give every language its
unit". That is exactly what this does — additively, idempotently, and for any language.

Rules, deliberately narrow:
  • A key that already has a localization for that language is left ALONE. Existing translations are
    never touched, so a re-run after a hand correction cannot silently revert it.
  • A key that is not in the catalog at all is SKIPPED and reported. The catalog's key set comes from
    the compiler's extraction, not from this file — inventing keys here would produce entries that no
    call site ever looks up, which reads as "translated" while showing English on device.
  • Printf specifiers must match the key's, or the entry is refused. A translation that drops a `%@`
    crashes formatting at runtime and is what `Tools/i18n_audit.py`'s format check exists to catch.

Usage:
  python3 Tools/fill-missing-translations.py                    # every language, both catalogs
  python3 Tools/fill-missing-translations.py --check            # report only, write nothing
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRANSLATIONS = ROOT / "Tools/translations"

# (catalog path, prefix of the per-language json in Tools/translations)
CATALOGS = [
    (ROOT / "Strand/Resources/Localizable.xcstrings", ""),
    (ROOT / "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings", "design-"),
    (ROOT / "StrandiOSWidgets/Localizable.xcstrings", ""),
]

LANGS = ["de", "es", "fr", "pt-PT", "pl", "it", "ru", "zh-Hans", "zh-Hant"]

# Same pattern the audit uses, so "passes this tool" and "passes the gate" cannot drift apart.
FORMAT = re.compile(r"%(?:(?:\d+)\$)?(@|(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp])")


def signature(value: str) -> list[str]:
    return sorted(FORMAT.findall(value))


def fill(catalog_path: Path, prefix: str, *, write: bool) -> tuple[int, list[str]]:
    if not catalog_path.exists():
        return 0, [f"missing catalog: {catalog_path}"]
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    strings = catalog.get("strings", {})
    added = 0
    problems: list[str] = []

    for lang in LANGS:
        source = TRANSLATIONS / f"{prefix}{lang}.json"
        if not source.exists():
            continue
        table = json.loads(source.read_text(encoding="utf-8"))
        for key, value in table.items():
            entry = strings.get(key)
            if entry is None:
                problems.append(f"{lang}: key not in catalog, skipped — {key[:70]!r}")
                continue
            localizations = entry.setdefault("localizations", {})
            if lang in localizations:
                continue
            if signature(key) != signature(value):
                problems.append(
                    f"{lang}: format specifiers differ from the key, refused — {key[:60]!r}")
                continue
            localizations[lang] = {"stringUnit": {"state": "translated", "value": value}}
            added += 1

    if write and added:
        catalog_path.write_text(
            json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return added, problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="report only, write nothing")
    args = parser.parse_args()

    total = 0
    all_problems: list[str] = []
    for catalog_path, prefix in CATALOGS:
        added, problems = fill(catalog_path, prefix, write=not args.check)
        total += added
        all_problems += problems
        print(f"{catalog_path.relative_to(ROOT)}: {added} unit(s) "
              f"{'would be added' if args.check else 'added'}")

    for problem in all_problems:
        print("  ! " + problem, file=sys.stderr)
    return 1 if all_problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
