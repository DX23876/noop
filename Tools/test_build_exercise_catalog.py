#!/usr/bin/env python3
"""Unit tests for the exercise-catalogue generator.

The generator decides what a recorded number MEANS — whether a set is weighed, counted or timed, and
which muscle it credits. Those are judgements, not copies, so they are pinned here rather than being
re-read out of a 1,324-entry JSON file by eye.
"""
import unittest

import build_exercise_catalog as generator


def record(**overrides):
    base = {
        "id": "0001",
        "name": "barbell bench press",
        "category": "chest",
        "body_part": "chest",
        "equipment": "barbell",
        "target": "pectorals",
        "secondary_muscles": ["triceps"],
        "instruction_steps": {"en": ["Lie down.", "Press."]},
        "media_id": "abc123",
    }
    base.update(overrides)
    return base


class MeasurementModeTests(unittest.TestCase):
    def test_load_bearing_equipment_is_weighed(self):
        self.assertEqual(generator.measurement_mode("barbell row", "barbell", "back"), "weight_reps")
        self.assertEqual(generator.measurement_mode("cable fly", "cable", "chest"), "weight_reps")

    def test_the_body_stays_the_load_on_a_prop(self):
        # Upstream lists the prop as "equipment"; it supports the body rather than loading it.
        for prop in ("stability ball", "bosu ball", "roller", "wheel roller"):
            self.assertEqual(generator.measurement_mode("crunch", prop, "waist"), "bodyweight_reps", prop)
        self.assertEqual(generator.measurement_mode("push-up", "body weight", "chest"), "bodyweight_reps")

    def test_added_and_assisted_load_keep_their_own_meaning(self):
        self.assertEqual(generator.measurement_mode("weighted dip", "weighted", "upper arms"),
                         "weighted_bodyweight")
        self.assertEqual(generator.measurement_mode("assisted pull-up", "assisted", "back"),
                         "assisted_bodyweight")

    def test_counted_implements_are_never_given_an_invented_weight(self):
        for implement in ("rope", "tire", "hammer"):
            self.assertEqual(generator.measurement_mode("swing", implement, "shoulders"),
                             "repetitions", implement)

    def test_timed_work_is_recognised_by_machine_or_by_name(self):
        self.assertEqual(generator.measurement_mode("cycling", "stationary bike", "cardio"), "duration")
        self.assertEqual(generator.measurement_mode("burpee", "body weight", "cardio"), "duration")
        self.assertEqual(generator.measurement_mode("hamstring stretch", "body weight", "upper legs"),
                         "duration")
        self.assertEqual(generator.measurement_mode("front plank", "body weight", "waist"), "duration")


class MuscleMappingTests(unittest.TestCase):
    def test_a_generic_shoulder_target_is_refined_by_the_exercise_name(self):
        self.assertEqual(generator.primary_muscle("delts", "dumbbell lateral raise"), "side_delts")
        self.assertEqual(generator.primary_muscle("delts", "cable rear delt fly"), "rear_delts")
        self.assertEqual(generator.primary_muscle("delts", "barbell shoulder press"), "front_delts")

    def test_conditioning_claims_no_muscle_and_unknown_targets_are_reported(self):
        self.assertIsNone(generator.primary_muscle("cardiovascular system", "elliptical"))
        self.assertEqual(generator.primary_muscle("left earlobe", "nonsense"), "__unknown__")

    def test_secondary_muscles_drop_what_noop_cannot_draw(self):
        mapped = generator.secondary_muscles({"secondary_muscles": ["core", "wrists", "ankles"]}, "chest")
        self.assertEqual(mapped, ["abdominals"])

    def test_an_unmapped_secondary_muscle_is_surfaced_rather_than_guessed(self):
        mapped = generator.secondary_muscles({"secondary_muscles": ["spleen"]}, "chest")
        self.assertTrue(mapped and mapped[0].startswith("__unknown__"))


class TitleCaseTests(unittest.TestCase):
    def test_ordinary_words_are_capitalized(self):
        self.assertEqual(generator.title_case("barbell bench press"), "Barbell Bench Press")
        self.assertEqual(generator.title_case("airbike"), "Airbike")

    def test_minor_words_stay_lowercase_unless_first_or_last(self):
        self.assertEqual(generator.title_case("chest and front of shoulder stretch"),
                         "Chest and Front of Shoulder Stretch")
        self.assertEqual(generator.title_case("with hands against wall"), "With Hands Against Wall")

    def test_each_hyphenated_part_is_capitalized(self):
        self.assertEqual(generator.title_case("sit-up"), "Sit-Up")
        self.assertEqual(generator.title_case("assisted wide-grip chest dip"),
                         "Assisted Wide-Grip Chest Dip")

    def test_leading_punctuation_and_digits_are_left_in_place(self):
        self.assertEqual(generator.title_case("arms overhead full sit-up (male)"),
                         "Arms Overhead Full Sit-Up (Male)")
        self.assertEqual(generator.title_case("3/4 sit-up"), "3/4 Sit-Up")

    def test_a_known_upstream_typo_survives_unchanged(self):
        # Casing only, never spelling — a mechanical fix must not also silently correct upstream data.
        self.assertEqual(generator.title_case("all fours squad stretch"), "All Fours Squad Stretch")


class BuildTests(unittest.TestCase):
    def test_a_clean_record_normalizes_into_noops_domain(self):
        exercises, issues = generator.build([record()])
        self.assertEqual(issues, [])
        entry = exercises[0]
        self.assertEqual(entry["id"], "exdb:0001")
        self.assertEqual(entry["canonicalId"], "exdb:0001")
        self.assertEqual(entry["sourceId"], "0001")
        self.assertEqual(entry["source"], "exercise_db")
        self.assertEqual(entry["title"], "Barbell Bench Press")
        self.assertEqual(entry["primaryMuscleId"], "chest")
        self.assertEqual(entry["equipmentIds"], ["barbell"])
        self.assertEqual(entry["mode"], "weight_reps")
        self.assertEqual(entry["contentVersion"], generator.CONTENT_VERSION)
        self.assertIn("MIT", entry["attribution"])
        # An identifier, never a file: the media is not ours to ship.
        self.assertEqual(entry["mediaId"], "abc123")

    def test_unmapped_equipment_and_duplicate_ids_fail_the_build(self):
        _, issues = generator.build([record(equipment="hovercraft")])
        self.assertTrue(any("unmapped equipment" in issue for issue in issues), issues)
        _, issues = generator.build([record(), record(name="another")])
        self.assertTrue(any("duplicate exercise id" in issue for issue in issues), issues)

    def test_missing_instructions_are_reported(self):
        _, issues = generator.build([record(instruction_steps={"en": []})])
        self.assertTrue(any("no English instructions" in issue for issue in issues), issues)

    def test_an_alias_ships_only_while_it_stays_unique(self):
        unique, _ = generator.build([record()])
        self.assertEqual(unique[0]["aliases"], ["bench press"])

        # Two pieces of equipment, one stripped name: the alias would be ambiguous, so neither keeps it.
        colliding, _ = generator.build([
            record(),
            record(id="0002", name="dumbbell bench press", equipment="dumbbell"),
        ])
        self.assertEqual([entry["aliases"] for entry in colliding], [[], []])


if __name__ == "__main__":
    unittest.main()
