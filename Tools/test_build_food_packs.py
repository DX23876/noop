"""Tests for the Open Food Facts country pack builder."""
from __future__ import annotations

import csv
import hashlib
import io
import json
import tempfile
import unittest
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import build_food_packs as packs
import food_catalog_common as common

COLUMNS = ["code", "product_name", "generic_name", "brands", "countries_tags", "serving_size", "serving_quantity",
           "serving_quantity_unit", "nova_group", "pnns_groups_2", "energy_100g"] + sorted(set(packs.OFF_COLUMNS.values()))


def export(rows: list[dict[str, str]]) -> str:
    lines = ["\t".join(COLUMNS)]
    for row in rows:
        lines.append("\t".join(row.get(c, "") for c in COLUMNS))
    return "\n".join(lines) + "\n"


MUESLI = {"code": "4000000000017", "product_name": "Knusper Müsli", "brands": "Hofgut, Andere",
          "countries_tags": "en:germany,en:austria", "serving_size": "40 g", "serving_quantity": "40",
          "nova_group": "3", "pnns_groups_2": "Breakfast cereals", "energy-kcal_100g": "430", "proteins_100g": "9",
          "carbohydrates_100g": "62", "fat_100g": "15", "sodium_100g": "0.12", "vitamin-b6_100g": "0.0014"}
JUICE_KJ = {"code": "4000000000024", "product_name": "Apfelsaft", "countries_tags": "en:germany",
            "energy_100g": "184", "proteins_100g": "0.1", "carbohydrates_100g": "10.5", "fat_100g": "0"}
NO_FAT = {"code": "4000000000031", "product_name": "Unvollständig", "countries_tags": "en:germany",
          "energy-kcal_100g": "100", "proteins_100g": "1", "carbohydrates_100g": "20"}
FRENCH = {"code": "3000000000018", "product_name": "Yaourt", "countries_tags": "en:france",
          "energy-kcal_100g": "60", "proteins_100g": "4", "carbohydrates_100g": "5", "fat_100g": "3"}


class PackTests(unittest.TestCase):
    def build(self, rows, **kwargs):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        source = Path(tmp.name) / "products.csv"
        source.write_text(export(rows), encoding="utf-8")
        out = Path(tmp.name) / "out"
        manifest = packs.build(source, out, kwargs.get("only"), kwargs.get("min_products", 1),
                               built_at=datetime(2026, 11, 8, tzinfo=timezone.utc))
        return manifest, out

    def read_pack(self, out: Path, country: str) -> list[dict[str, str]]:
        with zipfile.ZipFile(out / f"off-{country}.zip") as archive:
            text = archive.read("products.tsv").decode("utf-8")
        return list(csv.DictReader(io.StringIO(text), delimiter="\t"))

    def test_products_land_in_every_country_they_are_sold_in(self):
        manifest, out = self.build([MUESLI, JUICE_KJ, NO_FAT, FRENCH])
        rows = {p["country"]: p["rows"] for p in manifest["packs"]}
        self.assertEqual(rows, {"austria": 1, "france": 1, "germany": 2})
        self.assertEqual({p["iso"] for p in manifest["packs"]}, {"AT", "FR", "DE"})

    def test_units_and_fallbacks(self):
        _, out = self.build([MUESLI, JUICE_KJ])
        by_id = {r["id"]: r for r in self.read_pack(out, "germany")}
        muesli = by_id["off:4000000000017"]
        self.assertEqual(list(muesli.keys()), common.COLUMNS)
        self.assertEqual(muesli["brand"], "Hofgut")
        self.assertEqual(muesli["sodium_mg"], "120")          # grams in the export, mg in the table
        self.assertEqual(muesli["vitamin_b6_mg"], "1.4")
        self.assertEqual(muesli["serving_g"], "40")
        self.assertEqual(muesli["nova"], "3")
        self.assertEqual(muesli["group"], "breakfast-cereals")
        self.assertEqual(by_id["off:4000000000024"]["energy_kcal"], "43.9771")  # 184 kJ / 4.184

    def test_incomplete_products_are_left_out(self):
        _, out = self.build([NO_FAT, MUESLI])
        self.assertEqual([r["id"] for r in self.read_pack(out, "germany")], ["off:4000000000017"])

    def test_country_filter_and_threshold(self):
        manifest, _ = self.build([MUESLI, JUICE_KJ, FRENCH], only={"germany", "france"}, min_products=2)
        self.assertEqual([p["country"] for p in manifest["packs"]], ["germany"])

    def test_manifest_hash_matches_the_file(self):
        manifest, out = self.build([MUESLI])
        for pack in manifest["packs"]:
            data = (out / pack["file"]).read_bytes()
            self.assertEqual(pack["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(pack["bytes"], len(data))
        meta = json.loads(zipfile.ZipFile(out / "off-germany.zip").read("pack.json"))
        self.assertEqual(meta["tableFormat"], common.TABLE_FORMAT)


class CountryTableTests(unittest.TestCase):
    def test_swift_country_table_matches(self):
        import re
        source = (Path(__file__).resolve().parent.parent
                  / "Packages/StrandCore/Sources/StrandCore/Food/FoodCountries.swift").read_text(encoding="utf-8")
        swift = dict(re.findall(r'"([A-Z]{2})": "([a-z0-9-]+)"', source))
        self.assertEqual(swift, {iso: tag for tag, iso in packs.ISO_CODES.items()})


if __name__ == "__main__":
    unittest.main()
