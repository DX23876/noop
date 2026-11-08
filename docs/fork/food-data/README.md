# Food data sources

The food log (decision 2026-11-08) reads two catalogues. Both are named in the apps' Food data page.

## Bundeslebensmittelschlüssel (BLS) 4.0

- Publisher: Max Rubner-Institut, Karlsruhe. https://blsdb.de
- Citation: Max Rubner-Institut (2025): Bundeslebensmittelschlüssel (BLS), Version 4.0, Deutsche
  Nährstoffdatenbank. Karlsruhe. DOI 10.25826/Data20251217-134202-0
- Licence: Creative Commons Attribution 4.0 International (CC BY 4.0),
  https://creativecommons.org/licenses/by/4.0/
- What ships: `Packages/StrandCore/Sources/StrandCore/Resources/food-bls.tsv`, 39 of the 138 components per
  100 g, converted to the app's units by `Tools/build_food_catalog.py` (changes: selection of components,
  unit conversion, implausible values dropped). Source archive `BLS_4_0_2025_DE.zip`, data file SHA-256 in
  `food-bls.json`.

## Open Food Facts

- https://world.openfoodfacts.org
- Licence: the database under the Open Database License 1.0 (https://opendatacommons.org/licenses/odbl/1-0/),
  its contents under the Database Contents License 1.0 (https://opendatacommons.org/licenses/dbcl/1-0/).
- The country packs built by `Tools/build_food_packs.py` are derived databases and are published under ODbL 1.0
  as assets of this repository's `food-packs` release. Online search queries Open Food Facts directly.
- Product values are entered by volunteers; the app says so where it shows them.
