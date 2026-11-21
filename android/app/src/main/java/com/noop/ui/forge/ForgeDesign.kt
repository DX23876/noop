package com.noop.ui.forge

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.systemBars
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.noop.ui.NoopPrefs

/**
 * Fork (DX23876), Forge parity 2026-11: the "New design (preview)" switch, the twin of iOS's `ForgeDesignPrefs`.
 * **On by default since 2026-11-18**, as on iOS: the owner decided the new design ships to everyone, and
 * [flipOnce] carries over the installs that had it off. The switch stays, so anyone can go back to the shipped
 * Forge tabs (Today, Trends, Training, Sleep, More). Same key as iOS, so the choice reads the same on both.
 *
 * `--ez new_design true|false` on the launch intent overrides it for emulator checks in a debug build, without
 * writing the switch, as `--new-design` does on iOS.
 */
object ForgeDesign {
    const val KEY = "noop.forgeDesign.preview"
    const val DEFAULT = true
    const val EXTRA = "new_design"

    /**
     * Marks that [flipOnce] has run on this install, iOS's `ForgeDesignPrefs.flippedKey`. Its own key, not the
     * switch: the switch cannot say whether an "off" was the old default or a decision, and that difference is
     * the whole point.
     */
    const val FLIPPED_KEY = "noop.forgeDesign.flipped"

    /**
     * Turn the new design on for everyone, exactly once per install (owner, 2026-11-18).
     *
     * [DEFAULT] alone would not do it: the read below is "the stored value, else the default", so flipping the
     * default moves only those who never touched the switch, while whoever had deliberately turned the preview
     * off would keep the old design and report on a screen nobody else is looking at. Clearing the stored value
     * once hands everyone back to the (now true) default.
     *
     * The marker is what keeps this from being a trap: without it the clear would run at every launch and nobody
     * could ever leave the new design again. With it, an "off" set AFTER the flip is a decision and survives.
     */
    internal fun flipOnce(prefs: android.content.SharedPreferences) {
        if (prefs.getBoolean(FLIPPED_KEY, false)) return
        prefs.edit().remove(KEY).putBoolean(FLIPPED_KEY, true).apply()
    }

    /** Marks that [retireTheOldDesign] has run on this install, iOS's `ForgeDesignPrefs.retiredKey`. */
    const val RETIRED_KEY = "noop.forgeDesign.retired"

    /**
     * Retire the old design: clear the switch once more, whatever it holds (owner, 2026-11-20).
     *
     * [flipOnce] deliberately respected an "off" set after 18 November, because an off set then was a
     * decision rather than the old default. The decision now is that there is no old design to choose: the
     * switch is gone from Lab, the dashboard styles under it are gone with it, and whoever had gone back
     * would otherwise sit for ever on screens nobody maintains, reporting faults from them. The code stays
     * where it is; only the way back is closed.
     *
     * Its own marker, for the same reason [flipOnce] has one.
     */
    internal fun retireTheOldDesign(prefs: android.content.SharedPreferences) {
        if (prefs.getBoolean(RETIRED_KEY, false)) return
        prefs.edit().remove(KEY).putBoolean(RETIRED_KEY, true).apply()
    }

    /** Observed by the shell, so flipping the switch in Lab redraws the tabs at once. */
    var preview by mutableStateOf(DEFAULT)
        private set

    fun load(context: Context, intent: Intent? = null) {
        val prefs = context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE)
        // Before the read: the new design goes to everyone, once per install, and the way back closes.
        flipOnce(prefs)
        retireTheOldDesign(prefs)
        // The launch extra is a debug-build override that leaves the stored switch alone, as iOS's `--new-design`:
        // a release build ignores it, so no other app can flip the wearer's choice through the launcher.
        val override = intent?.takeIf { com.noop.BuildConfig.DEBUG && it.hasExtra(EXTRA) }?.getBooleanExtra(EXTRA, DEFAULT)
        preview = override ?: prefs.getBoolean(KEY, DEFAULT)
        ForgeColorProfile.load(context)
        ScoreRingStyle.load(context)
        ForgeAccent.load(context)
        TodayWidgets.seedDemoIfRequested(context, intent)
        com.noop.ingest.DebugHealthConnectSeed.seedIfRequested(context, intent)
    }

    /** Set by a tab header's magnifier: the More page it opens puts the cursor in its search field, once. */
    var focusSearch by mutableStateOf(false)

    /** Set by Today's "What changed" card: the Health tab it selects opens Trends over itself, once. */
    var openTrends by mutableStateOf(false)

    fun set(context: Context, on: Boolean) {
        context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE).edit().putBoolean(KEY, on).apply()
        preview = on
    }

    /**
     * The tabs in the bar, in order. The new design follows iOS's `RootTabView` (Today, Training, Nutrition, Sleep,
     * Health); the coach sits in each page's header instead of a tab (owner, 2026-11-21: an iPhone shows five). The
     * shipped one keeps Trends and More. Pure, so the two rosters are tested.
     */
    @Suppress("UNUSED_PARAMETER")
    fun tabs(newDesign: Boolean, coachEnabled: Boolean): List<ForgeTab> =
        if (newDesign) listOf(ForgeTab.Today, ForgeTab.Training, ForgeTab.Nutrition, ForgeTab.Sleep, ForgeTab.Health)
        else listOf(ForgeTab.Today, ForgeTab.Trends, ForgeTab.Training, ForgeTab.Sleep, ForgeTab.More)
}

/**
 * In the new design everything the More tab held lives behind the profile button, as iOS's `RootTabView` puts it:
 * a tab header's profile (and Today's strap battery) open the More page over the tabs. Null in the shipped design,
 * where the profile opens Settings and More is a tab.
 */
val LocalForgeOpenMore = androidx.compose.runtime.compositionLocalOf<(() -> Unit)?> { null }

/** Opens the new design's Settings over the tabs, as iOS's profile photo does (`ForgeSettingsView`); null in the shipped design. */
val LocalForgeOpenSettings = androidx.compose.runtime.compositionLocalOf<(() -> Unit)?> { null }

/**
 * The More page over the tabs, with its own search, profile, strap and every page it lists.
 *
 * A layer of its own over the tabs, not a [ForgeOverlayPage]: the overlay host holds one page, and the pages More
 * opens (Analysis, Health & Body, Tools, Settings) are overlay pages themselves. As an overlay page More was
 * replaced by the first of them, which then lost its own caller and closed both, leaving the profile dead.
 */
@androidx.compose.runtime.Composable
internal fun ForgeMoreOverlay(viewModel: com.noop.ui.AppViewModel, onDismiss: () -> Unit) {
    androidx.compose.foundation.layout.Box(
        androidx.compose.ui.Modifier.fillMaxSize()
            // Takes every touch, so nothing reaches the tab underneath.
            .pointerInput(Unit) { awaitPointerEventScope { while (true) awaitPointerEvent().changes.forEach { it.consume() } } }
    ) {
        ForgeSceneBackdrop(ForgeBackdrop.Sky) {
            androidx.activity.compose.BackHandler(onBack = onDismiss)
            // The system bars' insets, as the tab's Scaffold supplied them: empty padding drew the title under the clock.
            ForgeMoreScreen(WindowInsets.systemBars.asPaddingValues(), viewModel)
        }
    }
}
