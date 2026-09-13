#!/usr/bin/env python3
"""Build Strand/Resources/Localizable.xcstrings (English US base) from the
.stringsdata files xcodebuild emits during a build. Each extracted key becomes
an `en` localization whose value is the key itself (the authored English text).

One-off tooling used to seed the String Catalog; safe to re-run.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

CATALOG = Path("Strand/Resources/Localizable.xcstrings")
TRANSLATIONS = Path("Tools/translations")
LANGS = ["de", "es", "fr", "pt-PT", "pl", "it", "ru", "zh-Hans", "zh-Hant"]
FORMAT = re.compile(r"%(?:(?:\d+)\$)?(@|(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp])")


def signature(value: str) -> list[str]:
    return sorted(FORMAT.findall(value))


def find_stringsdata(roots: list[Path]) -> list[Path]:
    out: list[Path] = []
    for derived in roots:
        for root, _dirs, files in os.walk(derived):
            # Xcode's standard DerivedData nests the project under Strand-<hash>. An explicitly
            # supplied -derivedDataPath is already project-scoped and has no such directory name.
            if len(roots) == 1 and roots[0] == Path.home() / "Library/Developer/Xcode/DerivedData" \
                    and "Strand-" not in root:
                continue
            for f in files:
                if f.endswith(".stringsdata"):
                    out.append(Path(root) / f)
    return out


def load_stringsdata(path: Path) -> dict:
    """stringsdata is an Apple binary property list variant; plutil reads it
    reliably where plistlib does not. Convert to JSON and parse that."""
    try:
        raw = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(path)],
            capture_output=True, check=True,
        ).stdout
        return json.loads(raw)
    except Exception:
        return {}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-data", action="append", type=Path,
                        help="project-scoped DerivedData path; may be supplied more than once")
    parser.add_argument("--only-new-keys", action="store_true",
                        help="leave existing catalog entries byte-for-byte alone")
    parser.add_argument("--fill-translations", action="store_true",
                        help="fill new keys from Tools/translations when matching entries exist")
    args = parser.parse_args()
    roots = args.derived_data or [Path.home() / "Library/Developer/Xcode/DerivedData"]
    keys: dict[str, str] = {}  # key -> comment
    for sd in find_stringsdata(roots):
        data = load_stringsdata(sd)
        tables = data.get("tables", {})
        entries = tables.get("Localizable")
        if not entries:
            continue
        for e in entries:
            key = e.get("key")
            if not key:
                continue
            comment = e.get("comment") or ""
            # Keep the first non-empty comment we see for a key.
            if key not in keys or (not keys[key] and comment):
                keys[key] = comment

    if not keys:
        print("No Localizable strings found in stringsdata.", file=sys.stderr)
        return 1

    # Merge into any existing catalog so translations added for other languages
    # (and hand-written comments) are preserved — only the English base is seeded.
    existing: dict = {}
    if CATALOG.exists():
        try:
            existing = json.loads(CATALOG.read_text())
        except Exception:
            existing = {}
    strings: dict[str, dict] = dict(existing.get("strings", {}))
    existing_keys = set(strings)
    translation_tables = {}
    if args.fill_translations:
        for lang in LANGS:
            path = TRANSLATIONS / f"{lang}.json"
            translation_tables[lang] = json.loads(path.read_text(encoding="utf-8"))

    added = 0
    for key in sorted(keys):
        if args.only_new_keys and key in strings:
            continue
        entry = strings.get(key, {})
        localizations = entry.setdefault("localizations", {})
        if "en" not in localizations:
            localizations["en"] = {
                "stringUnit": {"state": "translated", "value": key}
            }
            added += 1
        for lang, table in translation_tables.items():
            value = table.get(key)
            if value is not None and signature(key) == signature(value):
                localizations[lang] = {
                    "stringUnit": {"state": "translated", "value": value}
                }
        comment = keys[key]
        if comment and "comment" not in entry:
            entry["comment"] = comment
        strings[key] = entry

    catalog = {
        "sourceLanguage": existing.get("sourceLanguage", "en"),
        "strings": strings,
        "version": existing.get("version", "1.0"),
    }

    if args.only_new_keys:
        additions = {key: strings[key] for key in sorted(set(strings) - existing_keys)}
        if additions:
            raw = CATALOG.read_text(encoding="utf-8")
            marker = '\n  },\n  "version"'
            close = raw.rfind(marker)
            if close < 0:
                print("Could not find the strings-object boundary in the catalog.", file=sys.stderr)
                return 1
            block = json.dumps(additions, indent=2, ensure_ascii=False,
                               separators=(",", " : "))
            inner = "\n".join("  " + line for line in block.splitlines()[1:-1])
            prefix = raw[:close]
            comma = "," if existing_keys else ""
            CATALOG.write_text(prefix + comma + "\n" + inner + raw[close:], encoding="utf-8")
    else:
        CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    print(f"Catalog now has {len(strings)} strings ({added} newly seeded).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
