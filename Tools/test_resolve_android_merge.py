#!/usr/bin/env python3
"""Pins `resolve-android-merge.py` (Android plan D-6): which android/ paths a merge must lose again, and which
conflicts it leaves for a person."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("ram", ROOT / "Tools/resolve-android-merge.py")
ram = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ram)

ENTRIES = ["android/fork-debug.keystore", "android/app/src/main/java/com/noop/analytics/"]


class ResolveAndroidMergeTests(unittest.TestCase):

    def test_a_listed_file_and_everything_under_a_listed_directory_count(self):
        self.assertTrue(ram.is_deleted("android/fork-debug.keystore", ENTRIES))
        self.assertTrue(ram.is_deleted("android/app/src/main/java/com/noop/analytics/New.kt", ENTRIES))
        self.assertFalse(ram.is_deleted("android/fork-debug.keystore.bak", ENTRIES))
        self.assertFalse(ram.is_deleted("android/app/src/main/java/com/noop/analyticsx/A.kt", ENTRIES))

    def test_a_file_upstream_added_under_a_deleted_directory_is_removed_although_it_merged_cleanly(self):
        remove, by_hand = ram.plan(
            index_paths={"android/app/src/main/java/com/noop/analytics/Added.kt", "android/build.gradle.kts"},
            unmerged=set(), entries=ENTRIES)
        self.assertEqual(["android/app/src/main/java/com/noop/analytics/Added.kt"], remove)
        self.assertEqual([], by_hand)

    def test_a_delete_modify_conflict_on_a_listed_path_is_ours_and_others_are_left_by_hand(self):
        remove, by_hand = ram.plan(
            index_paths=set(),
            unmerged={"android/fork-debug.keystore", "android/app/build.gradle.kts", "Strand/App/AppModel.swift"},
            entries=ENTRIES)
        self.assertEqual(["android/fork-debug.keystore"], remove)
        self.assertEqual(["android/app/build.gradle.kts"], by_hand,
                         "only android/ conflicts are this script's report; Swift ones are resolved as usual")

    def test_comments_and_blank_lines_are_ignored_and_paths_outside_android_are_refused(self):
        self.assertEqual(["android/x"], ram.read_entries("# note\n\nandroid/x\n"))
        with self.assertRaises(ValueError):
            ram.read_entries("Strand/App/AppModel.swift\n")

    def test_the_shipped_list_parses_and_names_only_paths_absent_from_the_tree(self):
        """A listed path still in the index would mean the deletion it records never landed."""
        entries = ram.read_entries((ROOT / "Tools/android_fork_deleted_paths.txt").read_text())
        self.assertIn("android/fork-debug.keystore", entries)
        for entry in entries:
            self.assertFalse((ROOT / entry).exists() and not entry.endswith("/"),
                             f"{entry} is listed as deleted but exists in the tree")


if __name__ == "__main__":
    unittest.main()
