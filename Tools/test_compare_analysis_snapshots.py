import io
import os
import sqlite3
import tempfile
import unittest

import compare_analysis_snapshots as tool


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

    def test_identical_stores_match_by_hash(self):
        # Mixed case on purpose: the sqlite3 shell prints table names lower-cased.
        rows = ["CREATE TABLE dailyMetric(day TEXT, charge REAL)",
                "INSERT INTO dailyMetric VALUES('2026-10-01', 75.5)"]
        differing, text = self.run_compare(self.db("a.sqlite", rows), self.db("b.sqlite", rows))
        self.assertEqual(differing, 0)
        self.assertIn("same  dailyMetric\n", text)

    def test_rows_written_in_another_order_still_match(self):
        a = self.db("a.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-01', 75.5), ('2026-10-02', 60.0)"])
        b = self.db("b.sqlite", ["CREATE TABLE daily(day TEXT, charge REAL)",
                                 "INSERT INTO daily VALUES('2026-10-02', 60.0), ('2026-10-01', 75.5)"])
        differing, text = self.run_compare(a, b)
        self.assertEqual(differing, 0)
        self.assertIn("another order", text)

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
