"""One gesture, one meaning, on both phones: pull down and every connected source is asked.

The gesture is older than the new design. The classic Today screen has synced the strap on a pull for
a long time, and the Apple side has a `.refreshable` hook in its screen scaffold. Neither survived the
move to the new design, on EITHER platform, and nobody noticed until a contributor sent a pull request
adding a sync button to one Android tab (DX23876/noop#56) - a second, platform-only affordance for a
thing the app already had a gesture for.

That is the shape this file exists to stop. What looks like a bit of interaction is a capability: on one
phone a wearer can fetch now, on the other they wait for an interval to pass. Nothing in a compile, a
unit test or a review catches it, because each side is correct on its own terms.

So the four tabs a connected source feeds carry the gesture on BOTH platforms, and both go through the
one shared rule set (`ConnectedSourceRefresh`) rather than each deciding for itself who may be asked,
how often, and what the one line says.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

#: The tabs a connected source feeds. Trends and More are not here: nothing fetches for them.
TABS = ("Today", "Training", "Sleep", "Health")


class PullToRefreshGuardTest(unittest.TestCase):
    def setUp(self):
        self.root = (ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeRoot.kt").read_text(encoding="utf-8")
        self.wrapper = (ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgePullToRefresh.kt").read_text(encoding="utf-8")

    def test_every_android_tab_a_source_feeds_carries_the_gesture(self):
        for tab in TABS:
            with self.subTest(tab=tab):
                self.assertRegex(
                    self.root, rf"ForgeTab\.{tab} ->[^\n]*ForgePullToRefresh|ForgePullToRefresh\(viewModel\) \{{ Forge{tab}",
                    f"the {tab} tab lost the pull gesture")

    def test_the_android_gesture_asks_the_shared_rules(self):
        self.assertIn("CoreSourceRefresh", self.wrapper,
                      "who may be asked and what the line says is the core's, not this screen's")
        # A gesture that cannot do anything must not pretend it can.
        self.assertIn("enabled = {", self.wrapper)

    def test_the_apple_tabs_carry_the_same_gesture(self):
        """The half that is easy to forget, because each platform is correct on its own.

        Asserted with `assertTrue`, not `assertIn`: a failing `assertIn` prints the whole haystack, and
        a thousand-line Swift file in a test report hides the one sentence that says what broke.
        """
        refresher = ROOT / "StrandiOS/Forge/ForgeConnectedRefresh.swift"
        self.assertTrue(refresher.exists(),
                        "the Apple side has no shared refresher; the gesture exists on one phone only")
        text = refresher.read_text(encoding="utf-8")
        self.assertTrue("ConnectedSourceRefresh" in text,
                        "the Apple gesture must read the same rules as the Android one")
        # The tab host is where it is decided which tabs offer the gesture, as `ForgeRoot.kt` is on the
        # other phone: a modifier nobody applies is not a gesture.
        host = (ROOT / "StrandiOS/App/RootTabView.swift").read_text(encoding="utf-8")
        for tab in TABS:
            with self.subTest(tab=tab):
                needle = f".forgeRefreshable(.{tab[0].lower() + tab[1:]})"
                self.assertTrue(needle in host, f"the {tab} tab does not carry the pull gesture")

    def test_the_running_import_is_visible_on_every_tab_with_the_gesture(self):
        """It hung on Today alone, and the page an import was started from is not the one you wait on."""
        self.assertTrue("ImportProgressBanner()" in self.wrapper,
                        "the import banner is not on the tabs the gesture reaches")
        today = (ROOT / "android/app/src/main/java/com/noop/ui/forge/ForgeToday.kt").read_text(encoding="utf-8")
        self.assertFalse("ImportProgressBanner()" in today,
                         "drawn twice on Today: once inline and once through the wrapper")
        # And both phones say that a pull is still asking, not just the system's spinner.
        self.assertTrue("forge_refresh_fetching" in self.wrapper)
        apple = (ROOT / "StrandiOS/Forge/ForgeConnectedRefresh.swift").read_text(encoding="utf-8")
        self.assertTrue("fetching" in apple, "the Apple side shows nothing while a pull is asking")

    def test_both_phones_name_the_same_three_outcomes(self):
        """Different words per language are fine; a different SET of things to say is not."""
        android = (ROOT / "android/app/src/main/res/values/strings.xml").read_text(encoding="utf-8")
        for key in ("forge_refresh_up_to_date", "forge_refresh_brought", "forge_refresh_failed"):
            self.assertIn(f'name="{key}"', android)
        apple = (ROOT / "StrandiOS/Forge/ForgeConnectedRefresh.swift")
        if apple.exists():
            text = apple.read_text(encoding="utf-8")
            for needle in ("up to date", "Fetched", "could not be reached"):
                self.assertTrue(needle in text,
                                f"the Apple line is missing {needle!r}, which the Android one says")


if __name__ == "__main__":
    unittest.main()
