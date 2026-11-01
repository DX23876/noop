"""Android without Room (docs/fork/android/CORE-ONLY-PLAN.md): the generated DAO matches its declarations."""
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("gen_core_dao", ROOT / "Tools" / "gen_core_dao.py")
gen = importlib.util.module_from_spec(spec)
sys.modules["gen_core_dao"] = gen
spec.loader.exec_module(gen)


class GeneratedDaoTest(unittest.TestCase):
    def test_the_generated_dao_is_up_to_date(self):
        self.assertEqual(gen.OUT.read_text(encoding="utf-8"), gen.generate(),
                         "CoreWhoopDao.kt is out of date: run python3 Tools/gen_core_dao.py")

    def test_every_declared_method_is_implemented(self):
        methods = gen.parse_methods()
        text = gen.OUT.read_text(encoding="utf-8")
        missing = [m.name for m in methods if f" fun {m.name}(" not in text]
        self.assertEqual(missing, [])
        self.assertGreater(len(methods), 200, "the DAO parser lost methods")

    def test_every_entity_names_its_table_and_key(self):
        entities = [c for c in gen.parse_classes().values() if c.table]
        self.assertGreaterEqual(len(entities), 30)
        for c in entities:
            self.assertTrue(c.primary_keys, f"{c.name} has no primary key")

    def test_room_is_not_a_build_dependency_any_more(self):
        gradle = (ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8")
        self.assertNotIn('ksp("androidx.room', gradle)
        self.assertNotIn("androidx.room:room-compiler", gradle)


if __name__ == "__main__":
    unittest.main()
