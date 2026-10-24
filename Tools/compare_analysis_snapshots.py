#!/usr/bin/env python3
"""Compare two analysed copies of one NOOP store, table by table (Android plan B4).

Both inputs are copies of the same real store that two builds re-analysed (see
`StrandTests/RealDataAnalysisSnapshotTests.swift`). A restructuring that must not change any stored value
passes only when every table holds the same rows in both.

Each table is first hashed with the sqlite3 shell's `.sha3sum`, which is fast but follows rowid order. A
table whose hashes differ is then compared as a multiset of rows (every column, rowid excluded), so a row
deleted and re-inserted in another order still counts as equal. Values are compared exactly: the two
builds run on the same machine, so the same inputs must give the same bits.

Usage: compare_analysis_snapshots.py BEFORE.sqlite AFTER.sqlite [--show N]
Exit status 0 when every table matches, 1 when any differs, 2 on a usage or file error.
"""

import argparse
import collections
import sqlite3
import subprocess
import sys


def open_readonly(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def table_names(conn):
    rows = conn.execute(
        "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    return [r[0] for r in rows]


def shell_hash(path, table):
    """The sqlite3 shell's SHA3 of one table, or None when the shell cannot produce it."""
    try:
        out = subprocess.run(["sqlite3", "-readonly", path, f".sha3sum {table}"],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    # A LIKE pattern can match more tables than the one asked for; keep the line naming it. The shell
    # prints the name lower-cased, and SQLite table names are case-insensitive anyway.
    for line in out.splitlines():
        digest, _, name = line.partition("|")
        if name.lower() == table.lower() or (not name and digest):
            return digest
    return None


def rows_multiset(conn, table):
    columns = [r[1] for r in conn.execute(f'PRAGMA table_info("{table}")')]
    quoted = ", ".join(f'"{c}"' for c in columns)
    return columns, collections.Counter(conn.execute(f'SELECT {quoted} FROM "{table}"'))


def compare(before, after, show=5, out=sys.stdout):
    a, b = open_readonly(before), open_readonly(after)
    names_a, names_b = set(table_names(a)), set(table_names(b))
    differing = 0
    for name in sorted(names_a | names_b):
        if name not in names_a or name not in names_b:
            where = "after only" if name not in names_a else "before only"
            print(f"DIFF  {name}: table exists {where}", file=out)
            differing += 1
            continue
        hash_a, hash_b = shell_hash(before, name), shell_hash(after, name)
        if hash_a is not None and hash_a == hash_b:
            print(f"same  {name}", file=out)
            continue
        cols_a, rows_a = rows_multiset(a, name)
        cols_b, rows_b = rows_multiset(b, name)
        if cols_a != cols_b:
            print(f"DIFF  {name}: columns differ {cols_a} vs {cols_b}", file=out)
            differing += 1
            continue
        only_a, only_b = rows_a - rows_b, rows_b - rows_a
        if not only_a and not only_b:
            how = "rows in another order" if hash_a and hash_b else "compared row by row"
            print(f"same  {name} ({how})", file=out)
            continue
        differing += 1
        print(f"DIFF  {name}: {sum(only_a.values())} row(s) only before, "
              f"{sum(only_b.values())} only after", file=out)
        for label, extra in (("before", only_a), ("after", only_b)):
            for row in sorted(extra, key=repr)[:show]:
                print(f"        {label}: {dict(zip(cols_a, row))}", file=out)
    print(f"{differing} table(s) differ", file=out)
    return differing


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--show", type=int, default=5, help="differing rows printed per side and table")
    args = parser.parse_args(argv)
    try:
        return 1 if compare(args.before, args.after, args.show) else 0
    except sqlite3.Error as error:
        print(f"compare_analysis_snapshots: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
