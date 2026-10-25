#!/usr/bin/env python3
"""The fork's design tokens for every platform (Android plan E-1).

The Apple design system (`Packages/StrandDesign`) is the one source. This reads its fixed values, the colours
written as `Color(hex:)` or `Color(light:dark:)`, the `CGFloat` dimensions and the `Font.system(size:weight:)`
type scale, writes them to `Packages/StrandDesign/tokens.json`, and from that generates the Kotlin constants the
Android screens use (`android/app/src/main/java/com/noop/ui/forge/ForgeTokens.kt`). Nothing on the Apple side is
generated, so no value the iOS app shows can change through this.

    python3 Tools/design_tokens.py           # regenerate both files
    python3 Tools/design_tokens.py --check   # exit 1 when either file no longer matches the Swift source

A token is "<Scope>.<name>", the Swift type that declares it and the constant's name. Values built from other
tokens, system colours or gradients are not tokens here; the screens compose them from these.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Packages/StrandDesign/Sources/StrandDesign"
TOKENS = ROOT / "Packages/StrandDesign/tokens.json"
KOTLIN = ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeTokens.kt"

SCOPE = re.compile(r"^(?:public\s+)?(?:enum|struct|extension|final class|class)\s+([A-Za-z_][A-Za-z0-9_]*)")
STATIC = r"^\s+(?:public\s+)?static\s+let\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[A-Za-z.]+\s*)?=\s*"
HEX_COLOR = re.compile(STATIC + r'Color\(hex:\s*"#?([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})"\)')
PAIR_COLOR = re.compile(STATIC + r'Color\(light:\s*"#?([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})",\s*'
                                 r'dark:\s*"#?([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})"\)')
DIMENSION = re.compile(r"^\s+(?:public\s+)?static\s+let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*CGFloat\s*=\s*(-?[0-9]+(?:\.[0-9]+)?)\b")
FONT = re.compile(STATIC + r"(?:Font)?\.system\(size:\s*([0-9]+(?:\.[0-9]+)?)\s*,\s*weight:\s*\.([a-z]+)"
                           r"(?:\s*,\s*design:\s*\.([a-z]+))?\s*\)")
# Apple's text styles at the default (Large) content size, in points; a style scales with the user's text size on
# both platforms, as sp does on Android. `headline` is semibold by default, every other style regular.
TEXT_STYLES = {"largeTitle": 34, "title": 28, "title2": 22, "title3": 20, "headline": 17, "body": 17,
               "callout": 16, "subheadline": 15, "footnote": 13, "caption": 12, "caption2": 11}
STYLE_FONT = re.compile(STATIC + r"Font\.(?:system\(\.([A-Za-z0-9]+)(?:\s*,\s*design:\s*\.([a-z]+))?\s*\)|"
                                 r"([A-Za-z0-9]+))(?:\.weight\(\.([a-z]+)\))?")
WEIGHTS = {"ultraLight": 100, "thin": 200, "light": 300, "regular": 400, "medium": 500, "semibold": 600,
           "bold": 700, "heavy": 800, "black": 900}


def rgba(hex_value: str) -> str:
    """RRGGBB or RRGGBBAA, upper case, always with alpha."""
    value = hex_value.upper()
    return value if len(value) == 8 else value + "FF"


def source_lines(text: str) -> list[str]:
    """The lines the iOS build compiles, with chained `.modifier` continuation lines joined to their statement.
    In an `#if os(iOS)` block the iOS branch counts and its `#else` does not; other conditions are kept."""
    out: list[str] = []
    stack: list[str] = []   # per open #if: "ios", "not-ios" or "other"
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#if"):
            stack.append("ios" if re.search(r"os\(iOS\)", stripped) and "!" not in stripped
                         else "not-ios" if re.search(r"os\((macOS|watchOS)\)", stripped) else "other")
            continue
        if stripped.startswith("#else") and stack:
            stack[-1] = {"ios": "not-ios", "not-ios": "ios"}.get(stack[-1], "other")
            continue
        if stripped.startswith("#endif") and stack:
            stack.pop()
            continue
        if "not-ios" in stack:
            continue
        if stripped.startswith(".") and out:
            out[-1] += stripped
        else:
            out.append(line)
    return out


def extract() -> dict:
    colors, dimensions, fonts = {}, {}, {}
    for path in sorted(SOURCES.glob("*.swift")):
        scope = None
        for line in source_lines(path.read_text()):
            m = SCOPE.match(line)
            if m:
                scope = m.group(1)
                continue
            if scope is None:
                continue
            if m := PAIR_COLOR.match(line):
                colors[f"{scope}.{m.group(1)}"] = {"light": rgba(m.group(2)), "dark": rgba(m.group(3))}
            elif m := HEX_COLOR.match(line):
                colors[f"{scope}.{m.group(1)}"] = {"light": rgba(m.group(2)), "dark": rgba(m.group(2))}
            elif m := DIMENSION.match(line):
                dimensions[f"{scope}.{m.group(1)}"] = float(m.group(2))
            elif m := FONT.match(line):
                fonts[f"{scope}.{m.group(1)}"] = {"size": float(m.group(2)), "weight": WEIGHTS.get(m.group(3), 400),
                                                 "rounded": m.group(4) == "rounded"}
            elif (m := STYLE_FONT.match(line)) and (m.group(2) or m.group(4)) in TEXT_STYLES:
                style = m.group(2) or m.group(4)
                default = 600 if style == "headline" else 400
                fonts[f"{scope}.{m.group(1)}"] = {"size": float(TEXT_STYLES[style]),
                                                 "weight": WEIGHTS.get(m.group(5) or "", default),
                                                 "rounded": m.group(3) == "rounded"}
    return {"colors": dict(sorted(colors.items())), "dimensions": dict(sorted(dimensions.items())),
            "fonts": dict(sorted(fonts.items()))}


def tokens_json(tokens: dict) -> str:
    return json.dumps(tokens, indent=2) + "\n"


def argb(rgba_hex: str) -> str:
    """RRGGBBAA to the 0xAARRGGBB Long Compose takes."""
    return f"0x{rgba_hex[6:8]}{rgba_hex[0:6]}"


def number(value: float) -> str:
    return f"{value:g}f"


def kotlin(tokens: dict) -> str:
    scopes: dict[str, list[str]] = {}
    for key, value in tokens["colors"].items():
        scope, name = key.split(".", 1)
        scopes.setdefault(scope, []).append(
            f"        val {name} = ForgeColor(light = {argb(value['light'])}, dark = {argb(value['dark'])})")
    for key, value in tokens["dimensions"].items():
        scope, name = key.split(".", 1)
        scopes.setdefault(scope, []).append(f"        const val {name}: Float = {number(value)}")
    for key, value in tokens["fonts"].items():
        scope, name = key.split(".", 1)
        scopes.setdefault(scope, []).append(
            f"        val {name} = ForgeFont(size = {number(value['size'])}, weight = {value['weight']}, "
            f"rounded = {'true' if value['rounded'] else 'false'})")
    lines = [
        "// Generated by Tools/design_tokens.py from Packages/StrandDesign (the Apple design system). Do not edit;",
        "// change the Swift token and run the script. A test fails when this file no longer matches the Swift source.",
        "package com.noop.ui.forge",
        "",
        "/** A colour for the light and the dark appearance, as 0xAARRGGBB. */",
        "data class ForgeColor(val light: Long, val dark: Long)",
        "",
        "/** A type-scale entry: size in sp, weight 100 to 900, and whether the Apple side uses the rounded design. */",
        "data class ForgeFont(val size: Float, val weight: Int, val rounded: Boolean)",
        "",
        "/** The fork's design tokens, grouped by the Swift type that declares them. Dimensions are in dp. */",
        "@Suppress(\"unused\", \"ObjectPropertyName\")",
        "object ForgeTokens {",
    ]
    for scope in sorted(scopes):
        lines.append(f"    object {scope} {{")
        lines.extend(scopes[scope])
        lines.append("    }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    tokens = extract()
    expected = {TOKENS: tokens_json(tokens), KOTLIN: kotlin(tokens)}
    if "--check" in sys.argv[1:]:
        stale = [p for p, text in expected.items() if not p.is_file() or p.read_text() != text]
        for p in stale:
            print(f"design_tokens: {p.relative_to(ROOT)} no longer matches the Swift design system; "
                  f"run python3 Tools/design_tokens.py", file=sys.stderr)
        return 1 if stale else 0
    for p, text in expected.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    print(f"design_tokens: {len(tokens['colors'])} colours, {len(tokens['dimensions'])} dimensions, "
          f"{len(tokens['fonts'])} type styles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
