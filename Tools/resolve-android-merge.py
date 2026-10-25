#!/usr/bin/env python3
"""Take the fork's deletions under android/ after an upstream merge (Android plan D-6).

ryanbr's tree carries android/, and the fork keeps it with a few paths deleted on purpose
(`Tools/android_fork_deleted_paths.txt`). A merge brings those paths back two ways: upstream modified one
(a delete/modify conflict) or added a file beneath a deleted directory (merged cleanly, so nothing stops).
This script finds both and, with --apply, removes them from the index and the working tree. It prints the
remaining unmerged android/ paths, which are real conflicts to resolve by hand.

    git merge upstream/main
    Tools/resolve-android-merge.py            # dry run: what would be removed, what is left
    Tools/resolve-android-merge.py --apply
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIST = ROOT / "Tools/android_fork_deleted_paths.txt"


def read_entries(text: str) -> list[str]:
    """The listed paths, without comments and blank lines."""
    entries = []
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            if not line.startswith("android/"):
                raise ValueError(f"{line}: only paths under android/ belong in this list")
            entries.append(line)
    return entries


def is_deleted(path: str, entries: list[str]) -> bool:
    """Whether `path` is a listed file or lies under a listed directory."""
    return any(path == e or (e.endswith("/") and path.startswith(e)) for e in entries)


def plan(index_paths: set[str], unmerged: set[str], entries: list[str]) -> tuple[list[str], list[str]]:
    """(paths to remove, unmerged android/ paths left to resolve by hand)."""
    remove = sorted(p for p in index_paths | unmerged if is_deleted(p, entries))
    by_hand = sorted(p for p in unmerged if p.startswith("android/") and not is_deleted(p, entries))
    return remove, by_hand


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def main() -> int:
    apply = "--apply" in sys.argv[1:]
    entries = read_entries(LIST.read_text())
    index_paths = set(git("ls-files", "--", "android").splitlines())
    unmerged = set(git("diff", "--name-only", "--diff-filter=U").splitlines())
    remove, by_hand = plan(index_paths, unmerged, entries)
    for path in remove:
        print(f"{'removed' if apply else 'would remove'}: {path}")
        if apply:
            git("rm", "-q", "--cached", "--ignore-unmatch", "--", path)
            (ROOT / path).unlink(missing_ok=True)
    if not remove:
        print("no fork-deleted android/ path came back")
    for path in by_hand:
        print(f"resolve by hand: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
