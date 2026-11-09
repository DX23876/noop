import io
import os
import shutil
import sqlite3
import tempfile
import unittest
from unittest import mock

import compare_analysis_snapshots as tool

# The fast path hashes each table with the sqlite3 command-line shell, which is not part of Python. Where
# it is missing, `compare` falls back to the row-by-row comparison and prints "(compared row by row)".
HAVE_SQLITE_SHELL = shutil.which("sqlite3") is not None
NEEDS_SHELL = ("needs the sqlite3 command-line shell for the .sha3sum fast path; "
               "the patched tests below still cover both messages without it")


class CompareAnalysisSnapshotsTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def db(self, name, statements):
        path = os.path.join(self.dir.name, name)
        conn = sqlite3.connect(path)
        for sql in statements:
            conn.execute(sql)
        conn.commit()
        conn.close()
        return path

    def run_compare(self, a, b, ignored=()):
        out = io.StringIO()
        return tool.compare(a, b, out=out, ignored=set(ignored)), out.getvalue()

    @unittest.skipUnless(HAVE_SQLITE_SHELL, NEEDS_SHELL)
    def test_identical_stores_match_by_hash(self):
        # Mixed case on purpose: the sqlite3 shell prints table names lower-cased.
        rows = ["CREATE TABLE dailyMetric(day TEXT, charge REAL)",
                "INSERT INTO dailyMetric VALUES('2026-10-01', 75.5)"]
        differing, text = self.run_compare(self.db("a.sqlite", rows), self.db("b.sqlite", rows))
        self.assertEqual(differing, 0)
        self.assertIn("same  dailyMetric\n", text)

    @unittest.skipUnless(HAVE_SQLITE_SHELL, NEEDS_SHELL)
    def test_rows_written_in_another_order_still_match(self):
        a = self.db("a.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-01', 75.5), ('2026-10-02', 60.0)"])
        b = self.db("b.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-02', 60.0), ('2026-10-01', 75.5)"])
        differing, text = self.run_compare(a, b)
        self.assertEqual(differing, 0)
        self.assertIn("another order", text)

    def test_equal_shell_hashes_report_same_without_a_row_comparison(self):
        rows = ["CREATE TABLE dailyMetric(day TEXT, charge REAL)",
                "INSERT INTO dailyMetric VALUES('2026-10-01', 75.5)"]
        a, b = self.db("a.sqlite", rows), self.db("b.sqlite", rows)
        with mock.patch.object(tool, "shell_hash", return_value="abc"), \
                mock.patch.object(tool, "rows_multiset", side_effect=AssertionError("rows were read")):
            differing, text = self.run_compare(a, b)
        self.assertEqual(differing, 0)
        self.assertIn("same  dailyMetric\n", text)

    def test_differing_shell_hashes_with_equal_rows_report_another_order(self):
        a = self.db("a.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-01', 75.5), ('2026-10-02', 60.0)"])
        b = self.db("b.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-02', 60.0), ('2026-10-01', 75.5)"])
        with mock.patch.object(tool, "shell_hash", side_effect=lambda path, _table: path):
            differing, text = self.run_compare(a, b)
        self.assertEqual(differing, 0)
        self.assertIn("same  daily (rows in another order)\n", text)

    def test_without_the_shell_rows_are_compared_one_by_one(self):
        a = self.db("a.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-01', 75.5), ('2026-10-02', 60.0)"])
        b = self.db("b.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-02', 60.0), ('2026-10-01', 75.5)"])
        with mock.patch.object(tool, "shell_hash", return_value=None):
            differing, text = self.run_compare(a, b)
        self.assertEqual(differing, 0)
        self.assertIn("same  daily (compared row by row)\n", text)

    def test_a_last_bit_change_is_a_difference(self):
        a = self.db("a.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-01', 75.44410652512397)"])
        b = self.db("b.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-01', 75.44410652512396)"])
        differing, text = self.run_compare(a, b)
        self.assertEqual(differing, 1)
        self.assertIn("1 row(s) only before, 1 only after", text)

    def test_an_ignored_write_time_column_does_not_count(self):
        a = self.db("a.sqlite", ["CREATE TABLE load(id TEXT, trimp REAL, computedAtTs INTEGER)",
                                 "INSERT INTO load VALUES('s1', 21.5, 1000)"])
        b = self.db("b.sqlite", ["CREATE TABLE load(id TEXT, trimp REAL, computedAtTs INTEGER)",
                                 "INSERT INTO load VALUES('s1', 21.5, 2000)"])
        self.assertEqual(self.run_compare(a, b)[0], 1)
        self.assertEqual(self.run_compare(a, b, ["load.computedAtTs"])[0], 0)
        self.assertEqual(self.run_compare(a, b, ["*.computedAtTs"])[0], 0)
        c = self.db("c.sqlite", ["CREATE TABLE load(id TEXT, trimp REAL, computedAtTs INTEGER)",
                                 "INSERT INTO load VALUES('s1', 21.9, 2000)"])
        self.assertEqual(self.run_compare(a, c, ["load.computedAtTs"])[0], 1, "values are still compared")

    def test_a_table_on_one_side_only_is_a_difference(self):
        a = self.db("a.sqlite", ["CREATE TABLE daily(day TEXT)"])
        b = self.db("b.sqlite", ["CREATE TABLE daily(day TEXT)", "CREATE TABLE extra(x)"])
        differing, text = self.run_compare(a, b)
        self.assertEqual(differing, 1)
        self.assertIn("extra: table exists after only", text)


if __name__ == "__main__":
    unittest.main()
