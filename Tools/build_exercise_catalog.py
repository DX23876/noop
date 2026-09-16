#!/usr/bin/env python3
"""Normalize the upstream ExerciseDB v1 dataset into NOOP's shipped exercise catalogue.

Source of truth for the data: hasaneyldrm/exercises-dataset, pinned to one immutable commit. Its
`LICENSE` places the code, dataset structure and instruction text under the MIT licence, and its
`NOTICE.md` states the same for the exercise DATA (names, categories, body parts, equipment, targets,
muscle groups and instructions). The MEDIA in `images/` and `videos/` is © Gym visual and is expressly
NOT licensed by cloning that repository, so this tool copies no media: it keeps only the upstream
`media_id` string, which the separately gated media provider would need if a licence is ever obtained.

What this tool is for (the plan's "development tool"): it validates what review cannot see reliably —
duplicate ids, unknown muscle or equipment identifiers, contradictions between measurement mode and
equipment, alias collisions, and missing provenance — and refuses to write a catalogue that fails.

    python3 Tools/build_exercise_catalog.py --input <exercises.json> [--output <resource.json>]

The output is an `ExerciseCatalogArchive` (the same envelope the app already imports), so the bundled
catalogue and a wearer-supplied one are one format, not two.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "Packages/StrandTraining/Sources/StrandTraining/Resources/exercise-catalog.json"

UPSTREAM_REPOSITORY = "hasaneyldrm/exercises-dataset"
UPSTREAM_REVISION = "7455efae41b330c265e7cd4b78dfa848e7ce5ebd"
UPSTREAM_DATA_PATH = "data/exercises.json"
LICENCE = "MIT"
ATTRIBUTION = ("Exercise data: ExerciseDB v1 via hasaneyldrm/exercises-dataset, MIT licence. "
               "Exercise media is not included and is not covered by that licence.")
# Bumped whenever the normalization changes what a stored definition means, so the app can re-seed.
# 2: titles are title-cased instead of shipping upstream's all-lowercase names verbatim.
# 3: lateral/rotational core work targets the obliques; upstream "shins" credits the tibialis.
CONTENT_VERSION = 3

# NOOP's muscle vocabulary is `TrainingMuscleCatalog`; every id below must exist there.
KNOWN_MUSCLES = {
    "chest", "upper_chest", "lower_chest", "serratus", "front_delts", "side_delts", "rear_delts",
    "rotator_cuff", "triceps", "biceps", "forearms", "lats", "upper_back", "rhomboids", "traps",
    "upper_traps", "lower_traps", "lower_back", "abdominals", "upper_abs", "lower_abs", "obliques",
    "quadriceps", "inner_quadriceps", "outer_quadriceps", "hamstrings", "glutes", "hip_flexors",
    "adductors", "abductors", "calves", "tibialis", "neck",
}

# `TrainingEquipmentCatalog.known`, in its canonical spelling.
KNOWN_EQUIPMENT = {
    "barbell", "ez-bar", "trap-bar", "smith-machine", "dumbbell", "kettlebell", "cable", "machine",
    "band", "bench", "pull-up-bar", "dip-bar", "squat-rack", "weight-belt", "box", "medicine-ball",
    "sled", "rings", "bodyweight", "stability-ball", "bosu-ball", "foam-roller", "ab-wheel", "rope",
    "tire", "hammer",
}

# Upstream `target` → NOOP primary muscle. "delts" is deliberately absent: it is refined by name below,
# because a generic shoulder target covers presses, lateral raises and reverse flyes alike.
TARGET_TO_MUSCLE = {
    "abs": "abdominals",
    "pectorals": "chest",
    "biceps": "biceps",
    "glutes": "glutes",
    "triceps": "triceps",
    "upper back": "upper_back",
    "lats": "lats",
    "calves": "calves",
    "quads": "quadriceps",
    "forearms": "forearms",
    "hamstrings": "hamstrings",
    "spine": "lower_back",
    "traps": "traps",
    "adductors": "adductors",
    "serratus anterior": "serratus",
    "abductors": "abductors",
    "levator scapulae": "neck",
    # No NOOP muscle: a cardio machine trains no single muscle, and inventing one would colour the
    # muscle map with work it cannot attribute.
    "cardiovascular system": None,
}

SECONDARY_TO_MUSCLE = {
    "shoulders": "side_delts", "deltoids": "side_delts", "rear deltoids": "rear_delts",
    "hamstrings": "hamstrings", "forearms": "forearms", "triceps": "triceps", "biceps": "biceps",
    "quadriceps": "quadriceps", "calves": "calves", "glutes": "glutes", "core": "abdominals",
    "abdominals": "abdominals", "lower abs": "lower_abs", "obliques": "obliques",
    "chest": "chest", "upper chest": "upper_chest", "hip flexors": "hip_flexors",
    "lower back": "lower_back", "rhomboids": "rhomboids", "trapezius": "traps", "traps": "traps",
    "upper back": "upper_back", "back": "upper_back", "lats": "lats", "latissimus dorsi": "lats",
    "brachialis": "biceps", "rotator cuff": "rotator_cuff", "soleus": "calves",
    "sternocleidomastoid": "neck", "groin": "adductors", "inner thighs": "adductors",
    "serratus anterior": "serratus", "spine": "lower_back",
    "shins": "tibialis",
    # Deliberately unmapped: NOOP's catalogue has no muscle for these, and a stabilizer the app cannot
    # draw is better dropped than forced onto a neighbouring muscle.
    "ankles": None, "feet": None, "hands": None, "wrists": None,
    "grip muscles": None, "ankle stabilizers": None, "wrist flexors": None, "wrist extensors": None,
}

EQUIPMENT_MAP = {
    "body weight": ["bodyweight"],
    "dumbbell": ["dumbbell"],
    "cable": ["cable"],
    "barbell": ["barbell"],
    "olympic barbell": ["barbell"],
    "ez barbell": ["ez-bar"],
    "trap bar": ["trap-bar"],
    "smith machine": ["smith-machine"],
    "leverage machine": ["machine"],
    "sled machine": ["sled"],
    "band": ["band"],
    "resistance band": ["band"],
    "kettlebell": ["kettlebell"],
    "medicine ball": ["medicine-ball"],
    # Props: they support or resist the body without being the load, so the body stays the load and the
    # implement is recorded beside it.
    "stability ball": ["stability-ball", "bodyweight"],
    "bosu ball": ["bosu-ball", "bodyweight"],
    "roller": ["foam-roller", "bodyweight"],
    "wheel roller": ["ab-wheel", "bodyweight"],
    "rope": ["rope"],
    "tire": ["tire"],
    "hammer": ["hammer"],
    # Added external load carried by the wearer: the belt is the usual implement and the measurement
    # mode below is what actually changes the meaning of the recorded number.
    "weighted": ["bodyweight", "weight-belt"],
    # An assisted machine takes load away; the mode records that, the implement stays a machine.
    "assisted": ["machine"],
    "upper body ergometer": ["machine"],
    "skierg machine": ["machine"],
    "stationary bike": ["machine"],
    "elliptical machine": ["machine"],
    "stepmill machine": ["machine"],
}

CARDIO_MACHINES = {"upper body ergometer", "skierg machine", "stationary bike",
                   "elliptical machine", "stepmill machine"}
# The body is the load; the implement only supports it.
BODYWEIGHT_PROPS = {"stability ball", "bosu ball", "roller", "wheel roller"}
# External implements that are counted rather than weighed: nobody logs kilograms for a tyre flip.
COUNTED_IMPLEMENTS = {"rope", "tire", "hammer"}
# Mirrors `TrainingEquipmentCatalog.loadBearing`, so the catalogue and the app agree on what a weight is.
LOAD_BEARING = {"barbell", "ez-bar", "trap-bar", "smith-machine", "dumbbell", "kettlebell", "cable",
                "machine", "band", "medicine-ball", "sled"}
DURATION_NAME_HINTS = ("stretch", "plank", "hold", "hang", "isometric", "wall sit", "dead hang")
UNILATERAL_NAME_HINTS = ("single arm", "one arm", "single leg", "one leg", "single-arm", "one-arm",
                         "single-leg", "one-leg")


def measurement_mode(name: str, equipment: str, body_part: str) -> str:
    lowered = name.lower()
    if equipment == "assisted":
        return "assisted_bodyweight"
    if equipment == "weighted":
        return "weighted_bodyweight"
    if equipment in CARDIO_MACHINES or body_part == "cardio":
        return "duration"
    if any(hint in lowered for hint in DURATION_NAME_HINTS):
        return "duration"
    if equipment in COUNTED_IMPLEMENTS:
        return "repetitions"
    if equipment == "body weight" or equipment in BODYWEIGHT_PROPS:
        return "bodyweight_reps"
    return "weight_reps"


def primary_muscle(target: str, name: str) -> str | None:
    if target != "delts":
        return TARGET_TO_MUSCLE.get(target, "__unknown__")
    lowered = name.lower()
    if any(word in lowered for word in ("lateral", "side", "upright")):
        return "side_delts"
    if any(word in lowered for word in ("rear", "reverse", "face pull")):
        return "rear_delts"
    return "front_delts"


# Upstream has no oblique target: side bends, twists and oblique crunches all arrive as "abs". Where the
# name says the movement is lateral or rotational AND upstream itself lists the obliques as involved, the
# obliques are the main target and the rest of the abdominals the secondary one. Requiring upstream's own
# oblique credit keeps a name match alone ("lunge with twist") from moving work onto a muscle upstream
# never named.
OBLIQUE_NAME_HINTS = ("oblique", "twist", "side bend", "side crunch", "windmill", "heel touch",
                      "side plank")


def refine_core(primary: str | None, secondary: list[str], name: str) -> tuple[str | None, list[str]]:
    if primary != "abdominals" or "obliques" not in secondary:
        return primary, secondary
    if not any(hint in name.lower() for hint in OBLIQUE_NAME_HINTS):
        return primary, secondary
    return "obliques", ["abdominals" if muscle == "obliques" else muscle for muscle in secondary]


def secondary_muscles(record: dict, primary: str | None) -> list[str]:
    values: list[str] = []
    for raw in record.get("secondary_muscles") or []:
        key = str(raw).strip().lower()
        if key not in SECONDARY_TO_MUSCLE:
            return ["__unknown__:" + key]
        mapped = SECONDARY_TO_MUSCLE[key]
        if mapped and mapped != primary and mapped not in values:
            values.append(mapped)
    # A generic shoulder target credits the other two heads as secondary, so a press still shows the
    # shoulder it trains without claiming all three as primary.
    if primary in {"front_delts", "side_delts", "rear_delts"}:
        for head in ("front_delts", "side_delts", "rear_delts"):
            if head != primary and head not in values and primary == "front_delts":
                values.append(head)
    return values


def normalize_name(value: str) -> str:
    folded = re.sub(r"[^a-z0-9]+", " ", value.lower())
    return folded.strip()


# Common connector words stay lowercase unless they open or close the title — the usual title-case
# convention, and the same list a human editor would apply by hand.
MINOR_WORDS = {"a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or",
               "the", "to", "vs", "with"}


def title_case(value: str) -> str:
    """Upstream titles ship all-lowercase ("barbell bench press", "airbike"). `str.title()` is not used
    here because it capitalizes the letter after ANY non-letter, mangling an apostrophe ("farmer's" ->
    "Farmer'S"). This capitalizes only the first letter found in each hyphen-separated part, so digits,
    parentheses and apostrophes are left exactly where they are, and "sit-up" -> "Sit-Up".
    """
    words = value.split(" ")
    last = len(words) - 1

    def capitalize_part(part: str) -> str:
        return re.sub(r"[a-z]", lambda m: m.group(0).upper(), part, count=1)

    out = []
    for index, word in enumerate(words):
        lower = word.lower()
        if 0 < index < last and lower in MINOR_WORDS:
            out.append(lower)
        else:
            out.append("-".join(capitalize_part(part) for part in lower.split("-")))
    return " ".join(out)


def build(records: list[dict]) -> tuple[list[dict], list[str]]:
    issues: list[str] = []
    exercises: list[dict] = []
    seen_ids: set[str] = set()
    alias_counts: dict[str, int] = {}

    # First pass: how often a name minus its leading equipment word occurs. Only an alias that stays
    # unique may ship, so an import can never be silently attached to the wrong variant.
    for record in records:
        name = str(record.get("name", "")).strip()
        equipment = str(record.get("equipment", "")).strip().lower()
        stripped = normalize_name(name)
        prefix = normalize_name(equipment)
        if prefix and stripped.startswith(prefix + " "):
            alias_counts[stripped[len(prefix) + 1:]] = alias_counts.get(stripped[len(prefix) + 1:], 0) + 1

    for record in records:
        upstream_id = str(record.get("id", "")).strip()
        name = str(record.get("name", "")).strip()
        equipment_raw = str(record.get("equipment", "")).strip().lower()
        body_part = str(record.get("body_part", "")).strip().lower()
        target = str(record.get("target", "")).strip().lower()

        if not upstream_id or not name:
            issues.append(f"{upstream_id or '?'}: missing id or name")
            continue
        identifier = f"exdb:{upstream_id}"
        if identifier in seen_ids:
            issues.append(f"{identifier}: duplicate exercise id")
            continue
        seen_ids.add(identifier)

        equipment_ids = EQUIPMENT_MAP.get(equipment_raw)
        if equipment_ids is None:
            issues.append(f"{identifier}: unmapped equipment '{equipment_raw}'")
            continue
        for item in equipment_ids:
            if item not in KNOWN_EQUIPMENT:
                issues.append(f"{identifier}: unknown equipment id '{item}'")

        primary = primary_muscle(target, name)
        if primary == "__unknown__":
            issues.append(f"{identifier}: unmapped target '{target}'")
            continue
        if primary is not None and primary not in KNOWN_MUSCLES:
            issues.append(f"{identifier}: unknown muscle id '{primary}'")

        secondary = secondary_muscles(record, primary)
        unknown_secondary = [s for s in secondary if s.startswith("__unknown__")]
        if unknown_secondary:
            issues.append(f"{identifier}: unmapped secondary muscle '{unknown_secondary[0].split(':', 1)[1]}'")
            continue
        primary, secondary = refine_core(primary, secondary, name)

        mode = measurement_mode(name, equipment_raw, body_part)
        if mode == "bodyweight_reps" and any(item in LOAD_BEARING for item in equipment_ids):
            issues.append(f"{identifier}: bodyweight repetitions with a loaded implement")
        if mode == "weight_reps" and not any(item in LOAD_BEARING for item in equipment_ids):
            issues.append(f"{identifier}: weight and repetitions without a loaded implement")

        steps = [str(step).strip() for step in (record.get("instruction_steps") or {}).get("en", [])]
        steps = [step for step in steps if step]
        if not steps:
            issues.append(f"{identifier}: no English instructions")

        aliases: list[str] = []
        stripped = normalize_name(name)
        prefix = normalize_name(equipment_raw)
        if prefix and stripped.startswith(prefix + " "):
            candidate = stripped[len(prefix) + 1:]
            if alias_counts.get(candidate, 0) == 1 and candidate != stripped:
                aliases.append(candidate)

        media_id = str(record.get("media_id", "")).strip() or None

        exercises.append({
            "id": identifier,
            "title": title_case(name),
            "mode": mode,
            "primaryMuscleId": primary,
            "secondaryMuscleIds": sorted(set(secondary)),
            "equipmentIds": sorted(set(equipment_ids)),
            "instructions": steps,
            "isUnilateral": any(hint in name.lower() for hint in UNILATERAL_NAME_HINTS),
            "source": "exercise_db",
            "sourceId": upstream_id,
            # An identifier only. No image or animation is copied here; a wearer-triggered download
            # resolves it later, gated behind the disclosure in `ExerciseMediaProvider`.
            "mediaId": media_id,
            "canonicalId": identifier,
            "aliases": aliases,
            "contentVersion": CONTENT_VERSION,
            "attribution": ATTRIBUTION,
        })
    return exercises, issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="upstream data/exercises.json")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--check", action="store_true", help="validate without writing")
    args = parser.parse_args()

    raw = Path(args.input).read_bytes()
    checksum = hashlib.sha256(raw).hexdigest()
    records = json.loads(raw)
    if not isinstance(records, list):
        print("the upstream file must be an array of exercises", file=sys.stderr)
        return 2

    exercises, issues = build(records)
    print(f"normalized {len(exercises)} of {len(records)} upstream records")
    if issues:
        print(f"{len(issues)} validation issue(s):", file=sys.stderr)
        for issue in issues[:40]:
            print("  " + issue, file=sys.stderr)
        return 1

    archive = {
        "formatVersion": 1,
        "provider": "exercisedb-v1",
        "sourceRevision": f"{UPSTREAM_REPOSITORY}@{UPSTREAM_REVISION}:{UPSTREAM_DATA_PATH}",
        "sourceChecksum": checksum,
        "rights": {
            "provider": UPSTREAM_REPOSITORY,
            "licence": LICENCE,
            "attribution": ATTRIBUTION,
            "allowsOfflineCache": True,
            "allowsRedistribution": True,
        },
        "exercises": exercises,
    }
    if args.check:
        print("check only, nothing written")
        return 0
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(archive, ensure_ascii=False, separators=(",", ":")) + "\n",
                      encoding="utf-8")
    print(f"wrote {output} ({output.stat().st_size} bytes)")
    print(f"upstream sha256 {checksum}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
