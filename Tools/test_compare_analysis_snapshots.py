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

    def run_compare(self, a, b):
        out = io.StringIO()
        return tool.compare(a, b, out=out), out.getvalue()

    def test_identical_stores_match(self):
        rows = ["CREATE TABLE daily(day TEXT, charge REAL)", "INSERT INTO daily VALUES('2026-10-01', 75.5)"]
        differing, text = self.run_compare(self.db("a.sqlite", rows), self.db("b.sqlite", rows))
        self.assertEqual(differing, 0)
        self.assertIn("same  daily", text)

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

    def test_a_table_on_one_side_only_is_a_difference(self):
        a = self.db("a.sqlite", ["CREATE TABLE daily(day TEXT)"])
        b = self.db("b.sqlite", ["CREATE TABLE daily(day TEXT)", "CREATE TABLE extra(x)"])
        differing, text = self.run_compare(a, b)
        self.assertEqual(differing, 1)
        self.assertIn("extra: table exists after only", text)


if __name__ == "__main__":
    unittest.main()
