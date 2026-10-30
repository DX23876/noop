#!/usr/bin/env python3
"""Writes the MuscleMap body outlines the Android app draws (fork, Android parity plan 2.3).

The iOS Training screens draw their muscle figures with the MuscleMap package (MIT, Melih Colpan), whose SVG
outlines live as Swift string literals in `Packages/MuscleMap/Sources/MuscleMap/Data/*Paths.swift`. The Android app
draws the same outlines from `android/app/src/main/assets/musclemap/body.json`, generated here from those files so
the two figures cannot drift: `test_musclemap_android_asset.py` fails when the committed asset no longer matches.

The outlines write arc flags packed against the next number (`a910 910 0 0136.94-.25`, flags 0 and 1, then 36.94),
which SVG allows and iOS's parser reads. Android's `PathParser` reads `0136.94` as one number, shifting every argument
after it, which drew a bulge across the back of the head. The asset therefore spells every path out with one space
between arguments (`normalized`), the same outline in a form both parsers read alike.

Usage: python3 Tools/musclemap_android_asset.py   (rewrites the asset and its licence beside it)
"""
import json
import pathlib
import re
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "Packages/MuscleMap/Sources/MuscleMap/Data"
ASSET_DIR = ROOT / "android/app/src/main/assets/musclemap"
ASSET = ASSET_DIR / "body.json"
LICENSE = ROOT / "Packages/MuscleMap/LICENSE"

# `BodyViewBox` in BodyPathData.swift: origin x, origin y, width, height.
VIEW_BOXES = {
    "male": {"front": [0, 95, 727, 1280], "back": [718, 95, 727, 1280]},
    "female": {"front": [0, 0, 650, 1450], "back": [823, 0, 650, 1450]},
}
FILES = {
    "male": {"front": "MaleFrontPaths.swift", "back": "MaleBackPaths.swift"},
    "female": {"front": "FemaleFrontPaths.swift", "back": "FemaleBackPaths.swift"},
}


def slug_raw_values():
    """`BodySlug` case name to raw value (`case lowerBack = "lower-back"`; a bare case is its own name)."""
    text = (DATA / "Muscle.swift").read_text(encoding="utf-8")
    body = text[text.index("enum BodySlug"):]
    raw = {}
    for name, value in re.findall(r'^\s*case (\w+)(?: = "([^"]+)")?\s*$', body, re.M):
        raw[name] = value or name
    return raw


_TOKEN = re.compile(r"[MmZzLlHhVvCcSsQqTtAa]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
_ARGS = {"m": 2, "l": 2, "h": 1, "v": 1, "c": 6, "s": 4, "q": 4, "t": 2, "a": 7, "z": 0}


def normalized(d):
    """An SVG path with each argument spelled out: arc flags split from what follows, one space between numbers."""
    out, i, command = [], 0, None
    while i < len(d):
        if d[i] in " ,\t\n":
            i += 1
            continue
        if d[i].isalpha():
            command = d[i]
            out.append(command)
            i += 1
            if command in "Zz":
                continue
            index = 0
        else:
            if command is None:
                raise ValueError("path starts with a number: " + d[:20])
            if command in "Zz":
                raise ValueError("number after a close: " + d[i:i + 20])
        # The arguments of this command and of any implicit repeats of it.
        while i < len(d):
            while i < len(d) and d[i] in " ,\t\n":
                i += 1
            if i >= len(d) or d[i].isalpha():
                break
            if command in "Aa" and index % 7 in (3, 4):
                if d[i] not in "01":
                    raise ValueError("arc flag is not 0 or 1: " + d[i:i + 20])
                out.append(d[i])
                i += 1
            else:
                match = _TOKEN.match(d, i)
                if not match or match.group(0).isalpha():
                    raise ValueError("unreadable number: " + d[i:i + 20])
                out.append(match.group(0))
                i = match.end()
            index += 1
        if command not in "Zz" and index % _ARGS[command.lower()]:
            raise ValueError("argument count does not fit " + command + ": " + d[:40])
    return " ".join(out)


def parts(path, raw):
    """Each `BodyPartPathData(slug:, common:, left:, right:)` in file order, outlines as SVG path strings."""
    text = path.read_text(encoding="utf-8")
    out = []
    for block in re.split(r"BodyPartPathData\(", text)[1:]:
        slug = re.match(r"\s*slug: \.(\w+)", block).group(1)
        entry = {"slug": raw[slug]}
        for side in ("common", "left", "right"):
            match = re.search(side + r": \[(.*?)\]", block, re.S)
            if match:
                entry[side] = [normalized(d) for d in re.findall(r'"([^"]+)"', match.group(1))]
        out.append(entry)
    return out


def generate():
    raw = slug_raw_values()
    doc = {"_source": "Packages/MuscleMap (MIT, Copyright (c) 2026 Melih Colpan), see LICENSE beside this file",
           "_generator": "Tools/musclemap_android_asset.py"}
    for gender, sides in FILES.items():
        doc[gender] = {side: {"viewBox": VIEW_BOXES[gender][side], "parts": parts(DATA / name, raw)}
                       for side, name in sides.items()}
    return json.dumps(doc, separators=(",", ":"), ensure_ascii=False) + "\n"


def main():
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    ASSET.write_text(generate(), encoding="utf-8")
    shutil.copyfile(LICENSE, ASSET_DIR / "LICENSE")


if __name__ == "__main__":
    main()
