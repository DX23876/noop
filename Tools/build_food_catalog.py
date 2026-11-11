#!/usr/bin/env python3
"""Turn the German Nutrient Database (Bundeslebensmittelschlüssel, BLS 4.0) into NOOP's bundled food table.

Source: Max Rubner-Institut, https://blsdb.de/download, file `BLS_4_0_2025_DE.zip`, which holds
`BLS_4_0_Daten_2025_DE.xlsx` (7,140 foods, 138 components per 100 g of edible portion, German and English
names). Licence CC BY 4.0: free use, including in apps, with the Max Rubner-Institut named as publisher.

    python3 Tools/build_food_catalog.py --input <BLS_4_0_Daten_2025_DE.xlsx> [--output-dir <dir>]

Writes `food-bls.tsv` (the table, format in `food_catalog_common.py`) and `food-bls.json` (provenance, row
count, the input's SHA-256) into `Packages/StrandCore/Sources/StrandCore/Resources/`, which both apps ship.
The tool refuses to write when a component it maps is missing, so a renamed column fails here, not as a
catalogue that silently lost its iron values.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

import food_catalog_common as common

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_DIR = ROOT / "Packages/StrandCore/Sources/StrandCore/Resources"

SOURCE = "bls"
VERSION = "4.0"
LICENCE = "CC BY 4.0"
CITATION = ("Max Rubner-Institut (2025): Bundeslebensmittelschlüssel (BLS), Version 4.0, "
            "Deutsche Nährstoffdatenbank. Karlsruhe.")
DOI = "10.25826/Data20251217-134202-0"

# Canonical nutrient -> BLS component code. The unit is read from the column header and converted.
BLS_CODES: dict[str, str] = {
    "energy_kcal": "ENERCC", "protein_g": "PROT625", "carbs_g": "CHO", "fat_g": "FAT", "fiber_g": "FIBT",
    "sugar_g": "SUGAR", "sat_fat_g": "FASAT", "mono_fat_g": "FAMS", "poly_fat_g": "FAPU",
    "omega3_g": "FAPUN3", "epa_g": "F20:5CN3", "dha_g": "F22:6CN3", "alcohol_g": "ALC", "water_g": "WATER",
    "cholesterol_mg": "CHORL", "sodium_mg": "NA", "salt_g": "NACL", "potassium_mg": "K", "calcium_mg": "CA",
    "magnesium_mg": "MG", "phosphorus_mg": "P", "iron_mg": "FE", "zinc_mg": "ZN", "iodine_ug": "ID",
    "copper_mg": "CU", "manganese_mg": "MN", "vitamin_a_ug": "VITAA", "vitamin_d_ug": "VITD",
    "vitamin_e_mg": "VITE", "vitamin_k_ug": "VITK", "thiamin_mg": "THIA", "riboflavin_mg": "RIBF",
    "niacin_mg": "NIAEQ", "vitamin_b6_mg": "VITB6", "folate_ug": "FOL", "vitamin_b12_ug": "VITB12",
    "vitamin_c_mg": "VITC", "pantothenic_mg": "PANTAC", "biotin_ug": "BIOT",
}

_MASS_IN_GRAMS = {"g": 1.0, "mg": 1e-3, "µg": 1e-6, "μg": 1e-6, "ug": 1e-6}


def target_unit(key: str) -> str:
    return key.rsplit("_", 1)[1].replace("ug", "µg")


def conversion(source_unit: str, key: str) -> float:
    """The factor from the header's unit to the canonical one (kcal stays kcal; masses convert)."""
    target = target_unit(key)
    if target == "kcal":
        if source_unit != "kcal":
            raise ValueError(f"{key}: expected kcal, the column is in {source_unit}")
        return 1.0
    if source_unit not in _MASS_IN_GRAMS or target not in _MASS_IN_GRAMS:
        raise ValueError(f"{key}: cannot convert {source_unit} to {target}")
    return _MASS_IN_GRAMS[source_unit] / _MASS_IN_GRAMS[target]


_HEADER = re.compile(r"^(?P<code>\S+)\s.*\[(?P<unit>[^/\]]+)/100\s*g\]\s*$")


def value_columns(header: list[str]) -> dict[str, tuple[int, float]]:
    """Canonical key -> (column index, unit factor) for every mapped component; raises when one is missing."""
    by_code: dict[str, tuple[int, str]] = {}
    for index, title in enumerate(header):
        match = _HEADER.match(title.strip())
        if match:
            by_code[match.group("code")] = (index, match.group("unit").strip())
    missing = [code for code in BLS_CODES.values() if code not in by_code]
    if missing:
        raise ValueError(f"BLS columns missing: {', '.join(missing)}")
    return {key: (by_code[code][0], conversion(by_code[code][1], key)) for key, code in BLS_CODES.items()}


def build(rows) -> list[dict[str, object]]:
    rows = iter(rows)
    header = next(rows)
    try:
        code_col, name_col, name_en_col = header.index("BLS Code"), header.index("Lebensmittelbezeichnung"), \
            header.index("Food name")
    except ValueError as error:
        raise ValueError(f"BLS header changed: {error}") from None
    columns = value_columns(header)
    foods: list[dict[str, object]] = []
    seen: set[str] = set()
    for row in rows:
        if len(row) <= name_col or not row[code_col].strip():
            continue
        code = row[code_col].strip()
        if not re.fullmatch(r"[A-Z][0-9A-Z]{6}", code):
            raise ValueError(f"unexpected BLS code {code!r}")
        if code in seen:
            raise ValueError(f"duplicate BLS code {code}")
        seen.add(code)
        food: dict[str, object] = {
            "id": f"{SOURCE}:{code}", "source": SOURCE,
            "name": common.clean_text(row[name_col]),
            "name_en": common.clean_text(row[name_en_col]) if len(row) > name_en_col else "",
            "brand": "", "group": code[0], "nova": None, "serving_g": None, "serving_label": "",
        }
        for key, (index, factor) in columns.items():
            raw = common.parse_number(row[index]) if index < len(row) else None
            food[key] = common.plausible(key, raw * factor if raw is not None else None)
        if not food["name"]:
            raise ValueError(f"{code} has no name")
        foods.append(food)
    foods.sort(key=lambda f: str(f["id"]))
    return foods


def write(foods: list[dict[str, object]], output_dir: Path, input_sha256: str) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    table = output_dir / "food-bls.tsv"
    with table.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(common.tsv_header() + "\n")
        for food in foods:
            handle.write(common.tsv_row(food) + "\n")
    meta = {
        "tableFormat": common.TABLE_FORMAT, "source": SOURCE, "version": VERSION, "rows": len(foods),
        "licence": LICENCE, "citation": CITATION, "doi": DOI, "publisher": "Max Rubner-Institut",
        "url": "https://blsdb.de", "inputSha256": input_sha256,
        "tableSha256": hashlib.sha256(table.read_bytes()).hexdigest(),
    }
    (output_dir / "food-bls.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--input", required=True, type=Path, help="BLS_4_0_Daten_2025_DE.xlsx")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    args = parser.parse_args(argv)
    try:
        foods = build(common.xlsx_rows(str(args.input)))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    write(foods, args.output_dir, hashlib.sha256(args.input.read_bytes()).hexdigest())
    print(f"wrote {len(foods)} foods to {args.output_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
