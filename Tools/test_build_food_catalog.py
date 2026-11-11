"""Tests for the BLS food table builder and the table format both apps read."""
from __future__ import annotations

import csv
import io
import json
import re
import tempfile
import unittest
import zipfile
from pathlib import Path

import build_food_catalog as bls
import food_catalog_common as common

ROOT = Path(__file__).resolve().parent.parent
SWIFT_NUTRIENTS = ROOT / "Packages/StrandCore/Sources/StrandCore/Food/FoodNutrient.swift"
BUNDLED_TABLE = ROOT / "Packages/StrandCore/Sources/StrandCore/Resources/food-bls.tsv"
BUNDLED_META = ROOT / "Packages/StrandCore/Sources/StrandCore/Resources/food-bls.json"

UNITS = {"ENERCC": "kcal", "VITB6": "µg", "CU": "µg", "MN": "µg", "ID": "µg", "VITAA": "µg", "VITD": "µg",
         "VITK": "µg", "FOL": "µg", "VITB12": "µg", "BIOT": "µg", "NA": "mg", "K": "mg", "CA": "mg", "MG": "mg",
         "P": "mg", "FE": "mg", "ZN": "mg", "CHORL": "mg", "VITE": "mg", "THIA": "mg", "RIBF": "mg",
         "NIAEQ": "mg", "VITC": "mg", "PANTAC": "mg"}


def header(drop: str | None = None) -> list[str]:
    columns = ["BLS Code", "Lebensmittelbezeichnung", "Food name"]
    for code in bls.BLS_CODES.values():
        if code == drop:
            continue
        unit = UNITS.get(code, "g")
        columns += [f"{code} Name [{unit}/100g]", f"{code} Datenherkunft", f"{code} Referenz"]
    return columns + ["Hinweis"]


def food_row(cols: list[str], code: str, name: str, values: dict[str, str]) -> list[str]:
    row = [""] * len(cols)
    row[0], row[1], row[2] = code, name, name + " (en)"
    for index, title in enumerate(cols):
        component = title.split(" ")[0]
        if title.endswith("/100g]") and component in values:
            row[index] = values[component]
    return row


class BuildTests(unittest.TestCase):
    def test_converts_units_and_keeps_unknowns_blank(self):
        cols = header()
        rows = [cols, food_row(cols, "C133000", "Hafer Flocken",
                               {"ENERCC": "348", "PROT625": "13,22", "VITB6": "950", "CU": "420", "FAT": ""})]
        foods = bls.build(rows)
        self.assertEqual(len(foods), 1)
        oat = foods[0]
        self.assertEqual(oat["id"], "bls:C133000")
        self.assertEqual(oat["group"], "C")
        self.assertEqual(oat["name_en"], "Hafer Flocken (en)")
        self.assertAlmostEqual(oat["protein_g"], 13.22)
        self.assertAlmostEqual(oat["vitamin_b6_mg"], 0.95)   # µg in the BLS, mg in the table
        self.assertAlmostEqual(oat["copper_mg"], 0.42)
        self.assertIsNone(oat["fat_g"])

    def test_refuses_a_missing_component(self):
        cols = header(drop="FE")
        with self.assertRaisesRegex(ValueError, "FE"):
            bls.build([cols, food_row(cols, "C133000", "Hafer", {"ENERCC": "1"})])

    def test_refuses_duplicate_codes(self):
        cols = header()
        row = food_row(cols, "C133000", "Hafer", {"ENERCC": "1"})
        with self.assertRaisesRegex(ValueError, "duplicate"):
            bls.build([cols, row, row])

    def test_drops_implausible_values(self):
        cols = header()
        foods = bls.build([cols, food_row(cols, "Q101000", "Öl", {"ENERCC": "1200", "FAT": "120", "PROT625": "-1"})])
        self.assertIsNone(foods[0]["energy_kcal"])
        self.assertIsNone(foods[0]["fat_g"])
        self.assertIsNone(foods[0]["protein_g"])

    def test_reads_an_xlsx_and_writes_table_and_meta(self):
        cols = header()
        rows = [cols, food_row(cols, "F101000", "Erdbeere roh", {"ENERCC": "32", "VITC": "62"})]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bls.xlsx"
            write_xlsx(path, rows)
            foods = bls.build(common.xlsx_rows(str(path)))
            bls.write(foods, Path(tmp) / "out", "abc")
            with open(Path(tmp) / "out/food-bls.tsv", encoding="utf-8") as handle:
                table = list(csv.DictReader(handle, delimiter="\t"))
            meta = json.loads((Path(tmp) / "out/food-bls.json").read_text(encoding="utf-8"))
        self.assertEqual(list(table[0].keys()), common.COLUMNS)
        self.assertEqual(table[0]["vitamin_c_mg"], "62")
        self.assertEqual(table[0]["fat_g"], "")
        self.assertEqual(meta["rows"], 1)
        self.assertEqual(meta["licence"], "CC BY 4.0")


class FormatTests(unittest.TestCase):
    def test_numbers_are_compact_and_locale_free(self):
        self.assertEqual(common.format_number(13.0), "13")
        self.assertEqual(common.format_number(0.123456), "0.1235")
        self.assertEqual(common.format_number(None), "")
        self.assertEqual(common.format_number(-0.00001), "0")

    def test_swift_nutrient_list_matches(self):
        source = SWIFT_NUTRIENTS.read_text(encoding="utf-8")
        body = source.split("enum FoodNutrient", 1)[1].split("\n}\n", 1)[0]
        swift = re.findall(r'case \w+ = "([a-z0-9_]+)"', body)
        self.assertEqual(swift, common.NUTRIENTS)

    def test_bundled_table_matches_its_meta(self):
        meta = json.loads(BUNDLED_META.read_text(encoding="utf-8"))
        lines = BUNDLED_TABLE.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines[0], common.tsv_header())
        self.assertEqual(len(lines) - 1, meta["rows"])
        self.assertEqual(meta["tableFormat"], common.TABLE_FORMAT)
        self.assertTrue(all(line.count("\t") == len(common.COLUMNS) - 1 for line in lines))


def write_xlsx(path: Path, rows: list[list[str]]) -> None:
    """A minimal workbook with inline strings, enough for `xlsx_rows`."""
    def column(index: int) -> str:
        name = ""
        index += 1
        while index:
            index, remainder = divmod(index - 1, 26)
            name = chr(65 + remainder) + name
        return name
    out = io.StringIO()
    out.write('<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/'
              'spreadsheetml/2006/main"><sheetData>')
    for r, row in enumerate(rows, start=1):
        out.write(f'<row r="{r}">')
        for c, value in enumerate(row):
            if value == "":
                continue
            text = value.replace("&", "&amp;").replace("<", "&lt;")
            out.write(f'<c r="{column(c)}{r}" t="inlineStr"><is><t>{text}</t></is></c>')
        out.write("</row>")
    out.write("</sheetData></worksheet>")
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("xl/worksheets/sheet1.xml", out.getvalue())


if __name__ == "__main__":
    unittest.main()
