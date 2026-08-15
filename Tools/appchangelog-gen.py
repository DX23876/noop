#!/usr/bin/env python3
"""Generate the in-app "What's New" entry (AppChangelog) from a release file's
front-matter, so the Kotlin and Swift entries stay byte-identical and the version bump is automatic.

A per-version notes file docs/releases/v<VER>.md may carry a YAML front-matter block:

    ---
    whatsnew:
      title: "Short headline for the in-app card"
      date: "July 2026"
      items:
        - "**Bold lead.** One-line description."
        - "**Another.** ..."
      title_locales:            # DEAD in this fork — see "Localizing the card" below
        de: "Kurze Überschrift"
        es: "..."
        fr: "..."
        pt-PT: "..."
        zh: "..."
    ---
    # NOOP v<VER>
    <the full release notes — the GitHub release body; the front-matter is stripped there>

Localizing the card. `title_locales` no longer reaches anything: it was consumed by the Android
title strings this script used to write, and that arm went with the Android tree. The Swift side
localizes differently — `WhatsNewView` renders the title and each item through
`LocalizedStringKey`, so the ENGLISH text is the catalog key. To ship a translated card, add the
title and every item to `Strand/Resources/Localizable.xcstrings` for all nine languages after
running this script; the i18n gate will fail the build if you add them for some and not others, and
say nothing at all if you skip them entirely (an absent key falls back to English, silently).
Leaving `title_locales` in the front matter is harmless and documents the intent, but it is the
catalog that decides what a Polish reader sees.

Running `Tools/appchangelog-gen.py docs/releases/v8.2.2.md` prepends the generated Release entry to
`releases` in AppChangelog.swift and bumps `currentVersion` to that
version. Idempotent: if the version is already the newest entry it only re-checks the constant. The
version comes from the filename (v8.2.2.md -> 8.2.2).

"""
import re
import sys
import pathlib


ROOT = pathlib.Path(__file__).resolve().parent.parent
SW = ROOT / "Strand/System/AppChangelog.swift"

#: The locale resource dirs the i18n gate treats as the focus set. `values` is the English source.

def frontmatter(md: pathlib.Path) -> dict:
    # Imported HERE, not at module scope: the pure helpers below carry the #878 key scheme and are
    # unit-tested, and a test runner should not need PyYAML installed to import them. Parsing the
    # front-matter is the only thing that actually needs it, and it still fails with the same message.
    try:
        import yaml
    except ImportError:
        sys.exit("appchangelog-gen: needs PyYAML (pip install pyyaml)")
    m = re.match(r"^---\n(.*?)\n---\n", md.read_text(), re.S)
    if not m:
        sys.exit(f"appchangelog-gen: no YAML front-matter in {md}")
    wn = (yaml.safe_load(m.group(1)) or {}).get("whatsnew")
    if not (wn and wn.get("title") and wn.get("date") and wn.get("items")):
        sys.exit(f"appchangelog-gen: front-matter needs whatsnew.{{title,date,items}} in {md}")
    return wn


def esc_sw(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


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


def apply(path, anchor, block, ver, const_re, const_new, title_line=None):
    """Insert `block` at `anchor`, or refresh an existing entry for `ver`, then bump the constant.

    `title_line` is the platform's rendered title assignment (Kotlin's `title = uiString(...)`, Swift's
    `title: "..."`). It is re-applied to an entry that already exists, because re-running after editing
    the headline is a normal thing to do during a release — and without this the two halves disagree:
    `write_title_strings` would mint and write the NEW key while the entry kept referencing the old one,
    so the card showed the previous headline and the new key sat orphaned in six locale files. Found by
    doing exactly that.
    """
    text = path.read_text()
    idx = text.index(anchor) + len(anchor)
    already = f'version = "{ver}"' in text[idx:idx + 400] or f'version: "{ver}"' in text[idx:idx + 400]
    if already:
        if title_line:
            pat = re.compile(rf'((?:version = "{re.escape(ver)}",|version: "{re.escape(ver)}",)\s*\n\s*)'
                             r'(title[ =:][^\n]*)')
            m = pat.search(text, idx)
            if not m:
                sys.exit(f"appchangelog-gen: found a v{ver} entry in {path.name} but not its title line")
            if m.group(2).rstrip(",") == title_line.rstrip(","):
                print(f"  {path.name}: v{ver} already the newest entry — title unchanged, refreshing constant")
            else:
                text = text[:m.start(2)] + title_line + text[m.end(2):]
                print(f"  {path.name}: v{ver} already present — title UPDATED to the current headline")
        else:
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
    apply(SW, "static let releases: [Release] = [\n", sw_block(ver, wn), ver,
          r'(static let currentVersion = ")[^"]*(")', rf'\g<1>{ver}\g<2>',
          title_line=f'title: "{esc_sw(wn["title"])}",')
    # The card's text is localized through the String Catalog, keyed by the English string (see
    # "Localizing the card" above). Nothing enforces that — an absent key falls back to English on
    # every device, silently — so the one place that knows these strings just landed says so.
    missing = 1 + len(wn.get("items", []))
    print(f"appchangelog-gen: {missing} string(s) for this entry are NOT in "
          f"Strand/Resources/Localizable.xcstrings yet — the card ships English until they are.")
    print("appchangelog-gen: done. Review the diff, then compile.")


if __name__ == "__main__":
    main()
