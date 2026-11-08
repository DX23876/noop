#!/usr/bin/env python3
"""Build NOOP's downloadable product packs, one per country, from the Open Food Facts export.

Source: the Open Food Facts CSV export (`en.openfoodfacts.org.products.csv.gz`, tab-separated, about
0.9 GB compressed), https://world.openfoodfacts.org/data. Licence: the database is ODbL 1.0, its contents
DbCL 1.0. Each pack is a derived database and is published under ODbL 1.0 as well, with attribution.

    python3 Tools/build_food_packs.py --input <products.csv[.gz]> --output-dir <dir>
        [--countries germany,austria] [--min-products 500]

A product goes into the pack of every country it is sold in (`countries_tags`), and only when its energy,
protein, carbohydrate and fat per 100 g are known: a pack is for logging, and a product without those
four would log as nothing. Each pack is `off-<country>.zip` holding `products.tsv` (the shared table in
`food_catalog_common.py`) and `pack.json`; `manifest.json` lists every pack with its size and SHA-256, which
the app checks before it uses a download. Nothing here is fetched: CI downloads the export first
(`.github/workflows/food-packs.yml`).
"""
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import io
import json
import re
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import food_catalog_common as common

SOURCE = "off"
LICENCE = "ODbL 1.0 (database), DbCL 1.0 (contents)"
ATTRIBUTION = "Product data from Open Food Facts (openfoodfacts.org), ODbL 1.0."

# Canonical nutrient -> Open Food Facts column. The export stores every mass per 100 g in GRAMS (energy in
# kcal); `grams_to` below converts. Alcohol is left out on purpose: the export holds it as % vol, not g.
OFF_COLUMNS: dict[str, str] = {
    "energy_kcal": "energy-kcal_100g", "protein_g": "proteins_100g", "carbs_g": "carbohydrates_100g",
    "fat_g": "fat_100g", "fiber_g": "fiber_100g", "sugar_g": "sugars_100g",
    "sat_fat_g": "saturated-fat_100g", "mono_fat_g": "monounsaturated-fat_100g",
    "poly_fat_g": "polyunsaturated-fat_100g", "omega3_g": "omega-3-fat_100g",
    "epa_g": "eicosapentaenoic-acid_100g", "dha_g": "docosahexaenoic-acid_100g",
    "cholesterol_mg": "cholesterol_100g", "sodium_mg": "sodium_100g", "salt_g": "salt_100g",
    "potassium_mg": "potassium_100g", "calcium_mg": "calcium_100g", "magnesium_mg": "magnesium_100g",
    "phosphorus_mg": "phosphorus_100g", "iron_mg": "iron_100g", "zinc_mg": "zinc_100g",
    "iodine_ug": "iodine_100g", "copper_mg": "copper_100g", "manganese_mg": "manganese_100g",
    "vitamin_a_ug": "vitamin-a_100g", "vitamin_d_ug": "vitamin-d_100g", "vitamin_e_mg": "vitamin-e_100g",
    "vitamin_k_ug": "vitamin-k_100g", "thiamin_mg": "vitamin-b1_100g", "riboflavin_mg": "vitamin-b2_100g",
    "niacin_mg": "vitamin-pp_100g", "vitamin_b6_mg": "vitamin-b6_100g", "folate_ug": "vitamin-b9_100g",
    "vitamin_b12_ug": "vitamin-b12_100g", "vitamin_c_mg": "vitamin-c_100g",
    "pantothenic_mg": "pantothenic-acid_100g", "biotin_ug": "biotin_100g",
}
REQUIRED = ("energy_kcal", "protein_g", "carbs_g", "fat_g")
_TO_UNIT = {"g": 1.0, "mg": 1e3, "ug": 1e6}

# Open Food Facts country tag -> ISO 3166-1 alpha-2, so the app can show the country in the wearer's language.
# A country missing here still gets a pack; the app then shows the tag's English name.
ISO_CODES: dict[str, str] = {
    "germany": "DE", "austria": "AT", "switzerland": "CH", "france": "FR", "belgium": "BE",
    "netherlands": "NL", "luxembourg": "LU", "italy": "IT", "spain": "ES", "portugal": "PT",
    "united-kingdom": "GB", "ireland": "IE", "united-states": "US", "canada": "CA", "mexico": "MX",
    "brazil": "BR", "argentina": "AR", "chile": "CL", "colombia": "CO", "peru": "PE",
    "denmark": "DK", "sweden": "SE", "norway": "NO", "finland": "FI", "iceland": "IS",
    "poland": "PL", "czech-republic": "CZ", "slovakia": "SK", "hungary": "HU", "romania": "RO",
    "bulgaria": "BG", "greece": "GR", "croatia": "HR", "slovenia": "SI", "serbia": "RS",
    "bosnia-and-herzegovina": "BA", "lithuania": "LT", "latvia": "LV", "estonia": "EE", "ukraine": "UA",
    "russia": "RU", "turkey": "TR", "israel": "IL", "morocco": "MA", "tunisia": "TN", "algeria": "DZ",
    "egypt": "EG", "south-africa": "ZA", "india": "IN", "japan": "JP", "south-korea": "KR",
    "china": "CN", "taiwan": "TW", "hong-kong": "HK", "singapore": "SG", "thailand": "TH",
    "malaysia": "MY", "indonesia": "ID", "philippines": "PH", "vietnam": "VN", "australia": "AU",
    "new-zealand": "NZ", "saudi-arabia": "SA", "united-arab-emirates": "AE", "reunion": "RE",
    "guadeloupe": "GP", "martinique": "MQ", "french-guiana": "GF", "new-caledonia": "NC",
    "french-polynesia": "PF", "cyprus": "CY", "malta": "MT", "albania": "AL", "north-macedonia": "MK",
    "moldova": "MD", "belarus": "BY", "kazakhstan": "KZ", "lebanon": "LB", "jordan": "JO",
}

_COUNTRY_TAG = re.compile(r"^en:([a-z0-9-]+)$")


def countries(tags: str) -> list[str]:
    return sorted({m.group(1) for t in tags.split(",") if (m := _COUNTRY_TAG.match(t.strip()))})


def grams_to(key: str, grams: float | None) -> float | None:
    if grams is None:
        return None
    unit = key.rsplit("_", 1)[1]
    return grams if unit == "kcal" else grams * _TO_UNIT[unit]


def product(row: dict[str, str]) -> dict[str, object] | None:
    """One export row as a table row, or None when it cannot be logged."""
    code = (row.get("code") or "").strip()
    name = common.clean_text(row.get("product_name") or row.get("generic_name"))
    if not re.fullmatch(r"[0-9]{6,14}", code) or not name:
        return None
    food: dict[str, object] = {
        "id": f"{SOURCE}:{code}", "source": SOURCE, "name": name, "name_en": "",
        "brand": common.clean_text((row.get("brands") or "").split(",")[0]),
        "group": common.clean_text(row.get("pnns_groups_2")).lower().replace(" ", "-")
                 if (row.get("pnns_groups_2") or "unknown") != "unknown" else "",
        "nova": None, "serving_g": None, "serving_label": common.clean_text(row.get("serving_size")),
    }
    nova = common.parse_number(row.get("nova_group"))
    if nova is not None and nova in (1, 2, 3, 4):
        food["nova"] = int(nova)
    serving = common.parse_number(row.get("serving_quantity"))
    if serving is not None and 0 < serving <= 5_000 and (row.get("serving_quantity_unit") or "g").strip() in ("g", ""):
        food["serving_g"] = serving
    for key, column in OFF_COLUMNS.items():
        food[key] = common.plausible(key, grams_to(key, common.parse_number(row.get(column))))
    if food["energy_kcal"] is None:
        kilojoules = common.parse_number(row.get("energy_100g"))
        food["energy_kcal"] = common.plausible("energy_kcal", kilojoules / 4.184 if kilojoules is not None else None)
    if any(food[key] is None for key in REQUIRED):
        return None
    return food


def open_export(path: Path) -> io.TextIOBase:
    raw = gzip.open(path, "rt", encoding="utf-8", newline="") if path.suffix == ".gz" \
        else path.open("r", encoding="utf-8", newline="")
    return raw


def build(input_path: Path, output_dir: Path, only: set[str] | None, min_products: int,
          built_at: datetime | None = None) -> dict[str, object]:
    csv.field_size_limit(sys.maxsize)
    output_dir.mkdir(parents=True, exist_ok=True)
    built_at = built_at or datetime.now(timezone.utc)
    with tempfile.TemporaryDirectory() as scratch:
        writers: dict[str, io.TextIOBase] = {}
        counts: dict[str, int] = {}
        seen: set[str] = set()
        with open_export(input_path) as handle:
            reader = csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE)
            for row in reader:
                food = product(row)
                if food is None or food["id"] in seen:
                    continue
                seen.add(str(food["id"]))
                for country in countries(row.get("countries_tags") or ""):
                    if only is not None and country not in only:
                        continue
                    writer = writers.get(country)
                    if writer is None:
                        writer = open(Path(scratch) / f"{country}.tsv", "w", encoding="utf-8", newline="\n")
                        writer.write(common.tsv_header() + "\n")
                        writers[country] = writer
                        counts[country] = 0
                    writer.write(common.tsv_row(food) + "\n")
                    counts[country] += 1
        for writer in writers.values():
            writer.close()
        packs = []
        for country in sorted(counts):
            if counts[country] < min_products:
                continue
            meta = {
                "tableFormat": common.TABLE_FORMAT, "source": SOURCE, "country": country,
                "iso": ISO_CODES.get(country, ""), "rows": counts[country], "licence": LICENCE,
                "attribution": ATTRIBUTION, "builtAt": built_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
            archive_path = output_dir / f"off-{country}.zip"
            with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
                archive.write(Path(scratch) / f"{country}.tsv", "products.tsv")
                archive.writestr("pack.json", json.dumps(meta, indent=2) + "\n")
            data = archive_path.read_bytes()
            packs.append({**{k: meta[k] for k in ("country", "iso", "rows", "builtAt")},
                          "file": archive_path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {"tableFormat": common.TABLE_FORMAT, "source": SOURCE, "licence": LICENCE,
                "attribution": ATTRIBUTION, "builtAt": built_at.strftime("%Y-%m-%dT%H:%M:%SZ"), "packs": packs}
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--countries", default="", help="comma-separated Open Food Facts country tags; default all")
    parser.add_argument("--min-products", type=int, default=500)
    args = parser.parse_args(argv)
    only = {c.strip() for c in args.countries.split(",") if c.strip()} or None
    manifest = build(args.input, args.output_dir, only, args.min_products)
    for pack in manifest["packs"]:
        print(f"{pack['country']}: {pack['rows']} products, {pack['bytes'] / 1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
