#!/usr/bin/env python3
"""Generate the in-app "What's New" entry (AppChangelog) for BOTH platforms from a release file's
front-matter, so the Kotlin and Swift entries stay byte-identical and the version bump is automatic.

A per-version notes file docs/releases/v<VER>.md may carry a YAML front-matter block:

    ---
    whatsnew:
      title: "Short headline for the in-app card"
      date: "July 2026"
      items:
        - "**Bold lead.** One-line description."
        - "**Another.** ..."
    ---
    # NOOP v<VER>
    <the full release notes — the GitHub release body; the front-matter is stripped there>

Running `Tools/appchangelog-gen.py docs/releases/v8.2.2.md` prepends the generated Release entry to
`releases` in AppChangelog.kt AND AppChangelog.swift and bumps CURRENT_VERSION/currentVersion to that
version. Idempotent: if the version is already the newest entry it only re-checks the constant. The
version comes from the filename (v8.2.2.md -> 8.2.2).
"""
import re
import sys
import pathlib

try:
    import yaml
except ImportError:
    sys.exit("appchangelog-gen: needs PyYAML (pip install pyyaml)")

ROOT = pathlib.Path(__file__).resolve().parent.parent
KT = ROOT / "android/app/src/main/java/com/noop/ui/AppChangelog.kt"
SW = ROOT / "Strand/System/AppChangelog.swift"


def frontmatter(md: pathlib.Path) -> dict:
    m = re.match(r"^---\n(.*?)\n---\n", md.read_text(), re.S)
    if not m:
        sys.exit(f"appchangelog-gen: no YAML front-matter in {md}")
    wn = (yaml.safe_load(m.group(1)) or {}).get("whatsnew")
    if not (wn and wn.get("title") and wn.get("date") and wn.get("items")):
        sys.exit(f"appchangelog-gen: front-matter needs whatsnew.{{title,date,items}} in {md}")
    return wn


def esc_kt(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")


def esc_sw(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def kt_block(ver, wn):
    items = "\n".join(f'                "{esc_kt(i)}",' for i in wn["items"])
    return (
        "        Release(\n"
        f'            version = "{ver}",\n'
        f'            title = "{esc_kt(wn["title"])}",\n'
        f'            date = "{esc_kt(wn["date"])}",\n'
        "            items = listOf(\n"
        f"{items}\n"
        "            ),\n"
        "        ),\n"
    )


def sw_block(ver, wn):
    items = "\n".join(f'                "{esc_sw(i)}",' for i in wn["items"])
    return (
        "        Release(\n"
        f'            version: "{ver}",\n'
        f'            title: "{esc_sw(wn["title"])}",\n'
        f'            date: "{esc_sw(wn["date"])}",\n'
        "            items: [\n"
        f"{items}\n"
        "            ]\n"
        "        ),\n"
    )


def apply(path, anchor, block, ver, const_re, const_new):
    text = path.read_text()
    idx = text.index(anchor) + len(anchor)
    already = f'version = "{ver}"' in text[idx:idx + 400] or f'version: "{ver}"' in text[idx:idx + 400]
    if already:
        print(f"  {path.name}: v{ver} already the newest entry — leaving entries, refreshing constant")
    else:
        text = text[:idx] + block + text[idx:]
    text, n = re.subn(const_re, const_new, text, count=1)
    if n != 1:
        sys.exit(f"appchangelog-gen: could not bump the version constant in {path.name}")
    path.write_text(text)
    if not already:
        print(f"  {path.name}: inserted v{ver} entry + set constant")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: appchangelog-gen.py docs/releases/v<VER>.md")
    md = pathlib.Path(sys.argv[1])
    ver = md.stem.lstrip("vV")
    wn = frontmatter(md)
    print(f"appchangelog-gen: v{ver} — {wn['title']}")
    apply(KT, "val releases: List<Release> = listOf(\n", kt_block(ver, wn), ver,
          r'(const val CURRENT_VERSION = ")[^"]*(")', rf'\g<1>{ver}\g<2>')
    apply(SW, "static let releases: [Release] = [\n", sw_block(ver, wn), ver,
          r'(static let currentVersion = ")[^"]*(")', rf'\g<1>{ver}\g<2>')
    print("appchangelog-gen: done. Review the diff, then compile.")


if __name__ == "__main__":
    main()
