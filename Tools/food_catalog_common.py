"""Shared pieces of the food catalogue builders (`build_food_catalog.py`, `build_food_packs.py`).

Both builders write the same tab-separated table, which the app turns into its own search database
(`FoodCatalogImporter` in `Packages/StrandCore`). Only the app writes SQLite, so the search index and the
text normalisation it relies on exist once, in Swift, for iOS and Android alike.

Standard library only: the Tools CI job installs nothing for these suites.
"""
from __future__ import annotations

import re
import zipfile
import xml.etree.ElementTree as ET
from typing import Iterator

# Format of the table. Bumped when a column changes meaning; the app refuses a table it does not know.
TABLE_FORMAT = 1

# The canonical nutrients, per 100 g of edible portion, in the unit after the last underscore.
# MUST match `FoodNutrient` in Packages/StrandCore/Sources/StrandCore/Food/FoodNutrient.swift, in the same
# order (test_build_food_catalog checks it against the Swift source).
NUTRIENTS: list[str] = [
    "energy_kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g",
    "sat_fat_g", "mono_fat_g", "poly_fat_g", "omega3_g", "epa_g", "dha_g",
    "alcohol_g", "water_g", "cholesterol_mg", "sodium_mg", "salt_g",
    "potassium_mg", "calcium_mg", "magnesium_mg", "phosphorus_mg", "iron_mg", "zinc_mg",
    "iodine_ug", "copper_mg", "manganese_mg",
    "vitamin_a_ug", "vitamin_d_ug", "vitamin_e_mg", "vitamin_k_ug",
    "thiamin_mg", "riboflavin_mg", "niacin_mg", "vitamin_b6_mg", "folate_ug", "vitamin_b12_ug",
    "vitamin_c_mg", "pantothenic_mg", "biotin_ug",
]

# Descriptive columns before the nutrients. `group` is the source's own food group code (the BLS code's
# letter, an Open Food Facts PNNS group); `nova` is the NOVA processing class 1 to 4 where known.
META_COLUMNS: list[str] = ["id", "source", "name", "name_en", "brand", "group", "nova", "serving_g", "serving_label"]
COLUMNS: list[str] = META_COLUMNS + NUTRIENTS

# Plausibility bounds per 100 g. A value outside them is dropped (unknown) rather than shipped.
MAX_PER_100G = {"energy_kcal": 950.0, "_mass_g": 100.5}


def format_number(value: float | None) -> str:
    """A compact, locale-free decimal: at most four significant decimals, no trailing zeros."""
    if value is None:
        return ""
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def clean_text(value: str | None) -> str:
    """One line of text for a TSV cell: tabs and line breaks become spaces, runs of spaces collapse."""
    if not value:
        return ""
    return re.sub(r"\s+", " ", value).strip()


def plausible(key: str, value: float | None) -> float | None:
    """Drops values no food can have (negative, more than 100 g of one part in 100 g, absurd energy)."""
    if value is None or value != value or value < 0:
        return None
    if key == "energy_kcal":
        return value if value <= MAX_PER_100G["energy_kcal"] else None
    if key.endswith("_g") and value > MAX_PER_100G["_mass_g"]:
        return None
    return value


def tsv_header() -> str:
    return "\t".join(COLUMNS)


def tsv_row(row: dict[str, object]) -> str:
    cells = []
    for column in COLUMNS:
        value = row.get(column)
        if isinstance(value, float) or (isinstance(value, int) and column in NUTRIENTS + ["serving_g"]):
            cells.append(format_number(float(value)))
        elif value is None:
            cells.append("")
        else:
            cells.append(clean_text(str(value)))
    return "\t".join(cells)


# MARK: - Minimal .xlsx reader (the BLS ships Excel only)

_NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def _column_index(reference: str) -> int:
    letters = re.match(r"[A-Z]+", reference)
    if not letters:
        raise ValueError(f"bad cell reference {reference!r}")
    index = 0
    for char in letters.group(0):
        index = index * 26 + ord(char) - 64
    return index - 1


def xlsx_rows(path: str, sheet: int = 1) -> Iterator[list[str]]:
    """Every row of one worksheet as a list of cell texts, streamed. Empty cells are empty strings."""
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        shared: list[str] = []
        if "xl/sharedStrings.xml" in names:
            with archive.open("xl/sharedStrings.xml") as handle:
                for _, element in ET.iterparse(handle):
                    if element.tag.endswith("}si"):
                        shared.append("".join(t.text or "" for t in element.iter() if t.tag.endswith("}t")))
                        element.clear()
        with archive.open(f"xl/worksheets/sheet{sheet}.xml") as handle:
            for _, element in ET.iterparse(handle):
                if not element.tag.endswith("}row"):
                    continue
                cells: dict[int, str] = {}
                for cell in element.findall("m:c", _NS):
                    kind = cell.get("t")
                    value = cell.find("m:v", _NS)
                    if kind == "inlineStr":
                        text = "".join(t.text or "" for t in cell.iter() if t.tag.endswith("}t"))
                    elif value is None or value.text is None:
                        continue
                    elif kind == "s":
                        text = shared[int(value.text)]
                    else:
                        text = value.text
                    cells[_column_index(cell.get("r", "A1"))] = text
                element.clear()
                yield [cells.get(i, "") for i in range(max(cells) + 1)] if cells else []


def parse_number(text: str | None) -> float | None:
    """A number from a data cell; blank, dashes and placeholders are unknown."""
    if text is None:
        return None
    text = text.strip().replace(",", ".")
    if text in ("", "-", "--", "n.a.", "NA", "nan"):
        return None
    try:
        return float(text)
    except ValueError:
        return None
