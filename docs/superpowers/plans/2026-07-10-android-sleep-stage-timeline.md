# Android Sleep Stage-Timeline Rows (iOS #988 port) — Implementation Plan

**Design doc (source of truth):** `docs/superpowers/specs/2026-07-10-android-sleep-stage-timeline-design.md`
**Date:** 2026-07-10

## Goal

Replace the Android Sleep hero card's flat hypnogram strip + double legend with WHOOP-style
**per-stage timeline rows** (AWAKE · LIGHT · DEEP · REM), mirroring iOS #988
(`Strand/Screens/SleepView.swift:640-1290`). Real-stage nights get four tappable rows whose solid
segments sit on the shared onset→wake axis (display-smoothed at 90 s), with `MotionStrip` and the
clock-label axis underneath and a fixed-height per-stage insight slot. Fallback (minutes-only)
nights keep the flat strip + `StageBreakdownRows` footer. The dot `StageLegend` row dies.

## Architecture

Everything lives in the two files that already own this UI:

- `android/app/src/main/java/com/noop/ui/SleepScreen.kt`
  - **Pure logic** (internal top-level functions, JVM-unit-testable — same pattern as the existing
    `parsePersistedSegments` + `SleepStageSegmentsTest`):
    - `StageInterval` — one contiguous stage run in seconds-from-onset.
    - `stageIntervalsFromWeights(segments, spanSec)` — reconstructs intervals from the hero's
      ordered `realSegments: List<Pair<String, Float>>` (name, minutes) by cumulative fractions.
    - `displaySmoothed(intervals, minDurationSec)` — straight port of Swift
      `Hypnogram.displaySmoothed` (`Packages/StrandDesign/Sources/StrandDesign/Hypnogram.swift:92-136`).
    - `canonicalStage(name)` + `stageRowSpans(intervals, rowStage, spanSec)` — per-row
      `(fracStart, fracWidth)` spans.
  - **UI**: `StageTimeline` (state + stack), `StageTimelineRow` (header + track), `StageRowTrack`
    (single-Canvas hatched track + segments — PERF: no per-segment `Box`es), `StageInsight`
    (fixed-height caption), `ClockLabelRow` (extracted from `HypnogramWithAxis`), hero card body
    rewrite, `StageLegend` deletion.
- `android/app/src/main/java/com/noop/ui/Theme.kt` — new `Metrics` constants.
- Tests in `android/app/src/test/java/com/noop/ui/` (JUnit4, plain JVM, `org.junit.Assert`).

**Data flow (unchanged upstream):** `selectNight` → model `groupSegments` →
`realSegments = segments.map { it.stage to (it.end - it.start) / 60f }` (`SleepScreen.kt:2912`) →
`HeroDisplay.realSegments` → `Hero(display, …, motionEpochs)`. We consume `realSegments` exactly as
the strip does today; totals/percentages stay on the raw `Stages` numbers — smoothing is render-only.

## Commands

```bash
# Run one test class (from repo root):
cd android && ./gradlew :app:testFullDebugUnitTest --tests "com.noop.ui.StageDisplaySmoothingTest"
# Compile check (UI tasks):
cd android && ./gradlew :app:compileFullDebugKotlin
# Full unit suite:
cd android && ./gradlew :app:testFullDebugUnitTest
```

Note: this repo uses git worktrees and a shared stash stack — never bare `git stash`.

---

## Task 1: Interval reconstruction (pure logic + tests)

`realSegments` is an ordered list of `(stageName, minutes)` pairs. Rows need absolute positions, so
walk cumulative fractions across the night span (design §Real-stage nights, item 3).

### Step 1: Write the failing test

Create `android/app/src/test/java/com/noop/ui/StageTimelineIntervalsTest.kt`:

```kotlin
package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [stageIntervalsFromWeights], the pure helper behind the Sleep hero's per-stage
 * timeline rows (iOS #988 port). Reconstructs (stage, startSec, endSec) intervals from the hero's
 * ordered `realSegments` weight pairs by walking cumulative fractions across the night span.
 */
class StageTimelineIntervalsTest {

    @Test
    fun walksCumulativeFractions() {
        // 30 + 60 + 30 = 120 min of weights across a 7200 s span → fractions 1/4, 1/2, 1/4.
        val ivs = stageIntervalsFromWeights(
            listOf("light" to 30f, "deep" to 60f, "rem" to 30f),
            spanSec = 7200.0,
        )
        assertEquals(3, ivs.size)
        assertEquals(0.0, ivs[0].startSec, 1e-9)
        assertEquals(1800.0, ivs[0].endSec, 1e-9)
        assertEquals("deep", ivs[1].stage)
        assertEquals(1800.0, ivs[1].startSec, 1e-9)
        assertEquals(5400.0, ivs[1].endSec, 1e-9)
        assertEquals(7200.0, ivs[2].endSec, 1e-9)
    }

    @Test
    fun intervalsAreContiguousAndCoverSpan() {
        val ivs = stageIntervalsFromWeights(
            listOf("wake" to 5f, "light" to 90f, "deep" to 45f, "light" to 100f, "rem" to 40f),
            spanSec = 28_800.0,
        )
        assertEquals(0.0, ivs.first().startSec, 1e-9)
        assertEquals(28_800.0, ivs.last().endSec, 1e-6)
        for (i in 1 until ivs.size) assertEquals(ivs[i - 1].endSec, ivs[i].startSec, 1e-9)
    }

    @Test
    fun skipsNonFiniteAndNonPositiveWeights() {
        val ivs = stageIntervalsFromWeights(
            listOf("light" to 30f, "deep" to Float.NaN, "rem" to -5f, "light" to 0f, "deep" to 30f),
            spanSec = 3600.0,
        )
        assertEquals(2, ivs.size)
        assertEquals("light", ivs[0].stage)
        assertEquals("deep", ivs[1].stage)
        // The two surviving 30 min weights split the span in half.
        assertEquals(1800.0, ivs[0].endSec, 1e-9)
        assertEquals(3600.0, ivs[1].endSec, 1e-9)
    }

    @Test
    fun emptyOrDegenerateInputReturnsEmpty() {
        assertTrue(stageIntervalsFromWeights(emptyList(), 3600.0).isEmpty())
        assertTrue(stageIntervalsFromWeights(listOf("light" to 30f), 0.0).isEmpty())
        assertTrue(stageIntervalsFromWeights(listOf("light" to 30f), -10.0).isEmpty())
        assertTrue(stageIntervalsFromWeights(listOf("light" to 30f), Double.NaN).isEmpty())
        assertTrue(stageIntervalsFromWeights(listOf("light" to 0f, "deep" to Float.NaN), 3600.0).isEmpty())
    }

    @Test
    fun durationSecIsEndMinusStart() {
        val ivs = stageIntervalsFromWeights(listOf("light" to 30f, "deep" to 30f), 3600.0)
        assertEquals(1800.0, ivs[0].durationSec, 1e-9)
    }
}
```

### Step 2: Run it — confirm it fails

```bash
cd android && ./gradlew :app:testFullDebugUnitTest --tests "com.noop.ui.StageTimelineIntervalsTest"
```

Expected: **compilation failure** (`stageIntervalsFromWeights` / `StageInterval` unresolved). That is
the red step.

### Step 3: Implement

In `android/app/src/main/java/com/noop/ui/SleepScreen.kt`, find
`internal data class PersistedSegment` (currently line 3151) and the `parsePersistedSegments`
function that follows it. Insert **after** that function:

```kotlin
// MARK: - Stage timeline logic (iOS #988 port — pure, unit-tested)

/** One contiguous run of a single sleep stage, in seconds from the night's onset. */
internal data class StageInterval(val stage: String, val startSec: Double, val endSec: Double) {
    val durationSec: Double get() = endSec - startSec
}

/**
 * Reconstruct absolute (stage, startSec, endSec) intervals from the hero's ordered
 * `realSegments` weight pairs (name, minutes) by walking cumulative fractions across [spanSec]
 * (design 2026-07-10, §Real-stage nights item 3). Non-finite / non-positive weights are skipped —
 * they carry no drawable width. Returns [] when nothing is drawable.
 */
internal fun stageIntervalsFromWeights(
    segments: List<Pair<String, Float>>,
    spanSec: Double,
): List<StageInterval> {
    if (segments.isEmpty() || !spanSec.isFinite() || spanSec <= 0.0) return emptyList()
    val weights = segments.map { (_, wt) -> if (wt.isFinite() && wt > 0f) wt.toDouble() else 0.0 }
    val total = weights.sum()
    if (total <= 0.0) return emptyList()
    val out = ArrayList<StageInterval>(segments.size)
    var cum = 0.0
    segments.forEachIndexed { i, (name, _) ->
        val w = weights[i]
        if (w <= 0.0) return@forEachIndexed
        val start = spanSec * (cum / total)
        cum += w
        out.add(StageInterval(name, start, spanSec * (cum / total)))
    }
    return out
}
```

### Step 4: Run the test — confirm it passes

Same command as Step 2. All 5 tests green.

### Step 5: Commit

```bash
git add -A && git commit -m "feat: sleep stage-interval reconstruction from hero weight pairs (#988 port)"
```

---

## Task 2: `displaySmoothed` port (pure logic + tests)

Straight port of Swift `Hypnogram.displaySmoothed`
(`Packages/StrandDesign/Sources/StrandDesign/Hypnogram.swift:92-136`): coalesce adjacent same-stage
runs, then repeatedly absorb the **shortest** sub-threshold fragment into its **longer** neighbour,
re-coalescing each pass. Rows use a 90 s floor (design item 2).

### Step 1: Write the failing test

Create `android/app/src/test/java/com/noop/ui/StageDisplaySmoothingTest.kt`:

```kotlin
package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [displaySmoothed], the Kotlin port of Swift `Hypnogram.displaySmoothed`
 * (Packages/StrandDesign/Sources/StrandDesign/Hypnogram.swift). Fixtures mirror the Swift
 * semantics: coalesce adjacent same-stage runs, then absorb the SHORTEST sub-threshold fragment
 * into its LONGER neighbour until every block clears the floor. Render-only smoothing.
 */
class StageDisplaySmoothingTest {

    private fun iv(stage: String, start: Double, end: Double) = StageInterval(stage, start, end)

    @Test
    fun guardsTwoOrFewerIntervalsUntouched() {
        val two = listOf(iv("light", 0.0, 30.0), iv("deep", 30.0, 60.0))
        assertEquals(two, displaySmoothed(two, 90.0))   // Swift: guard sorted.count > 2
    }

    @Test
    fun coalescesAdjacentSameStageRuns() {
        val out = displaySmoothed(
            listOf(
                iv("light", 0.0, 300.0),
                iv("light", 300.0, 600.0),   // same stage, zero-length seam → merged
                iv("deep", 600.0, 900.0),
            ),
            minDurationSec = 90.0,
        )
        assertEquals(2, out.size)
        assertEquals(iv("light", 0.0, 600.0), out[0])
        assertEquals(iv("deep", 600.0, 900.0), out[1])
    }

    @Test
    fun absorbsFlickerIntoLongerNeighbour() {
        // A 30 s deep flicker between 600 s light (longer) and 300 s rem → absorbed into light.
        val out = displaySmoothed(
            listOf(
                iv("light", 0.0, 600.0),
                iv("deep", 600.0, 630.0),
                iv("rem", 630.0, 930.0),
            ),
            minDurationSec = 90.0,
        )
        assertEquals(2, out.size)
        assertEquals(iv("light", 0.0, 630.0), out[0])
        assertEquals(iv("rem", 630.0, 930.0), out[1])
    }

    @Test
    fun absorptionReCoalescesBridgedRuns() {
        // light | 30s wake | light → wake absorbed, then the two light runs coalesce into ONE block.
        val out = displaySmoothed(
            listOf(
                iv("light", 0.0, 600.0),
                iv("wake", 600.0, 630.0),
                iv("light", 630.0, 1200.0),
            ),
            minDurationSec = 90.0,
        )
        assertEquals(1, out.size)
        assertEquals(iv("light", 0.0, 1200.0), out[0])
    }

    @Test
    fun edgeFragmentAbsorbsIntoOnlyNeighbour() {
        val out = displaySmoothed(
            listOf(
                iv("wake", 0.0, 30.0),      // leading flicker: only neighbour is `light`
                iv("light", 30.0, 900.0),
                iv("deep", 900.0, 1800.0),
            ),
            minDurationSec = 90.0,
        )
        assertEquals(2, out.size)
        assertEquals(iv("light", 0.0, 900.0), out[0])
    }

    @Test
    fun combOfEpochFlickersCollapses() {
        // 30 s-epoch comb (the original complaint): alternating light/deep flickers inside a light
        // night collapse to a single light block — no sub-90 s block survives.
        val comb = buildList {
            add(iv("light", 0.0, 1200.0))
            var t = 1200.0
            repeat(6) {
                add(iv("deep", t, t + 30.0)); t += 30.0
                add(iv("light", t, t + 30.0)); t += 30.0
            }
            add(iv("light", t, t + 1200.0))
        }
        val out = displaySmoothed(comb, 90.0)
        assertTrue(out.all { it.durationSec >= 90.0 })
        assertEquals(1, out.size)
        assertEquals("light", out[0].stage)
        assertEquals(0.0, out[0].startSec, 1e-9)
        assertEquals(comb.last().endSec, out[0].endSec, 1e-9)
    }

    @Test
    fun zeroFloorReturnsCoalescedInputUnsmoothed() {
        val raw = listOf(iv("light", 0.0, 10.0), iv("deep", 10.0, 20.0), iv("rem", 20.0, 30.0))
        assertEquals(raw, displaySmoothed(raw, 0.0))   // smoothingSeconds: 0 → raw timeline
    }

    @Test
    fun totalsPreserved() {
        val raw = listOf(
            iv("light", 0.0, 600.0), iv("deep", 600.0, 660.0),
            iv("rem", 660.0, 1500.0), iv("wake", 1500.0, 1530.0), iv("light", 1530.0, 3000.0),
        )
        val out = displaySmoothed(raw, 90.0)
        assertEquals(0.0, out.first().startSec, 1e-9)
        assertEquals(3000.0, out.last().endSec, 1e-9)
        for (i in 1 until out.size) assertEquals(out[i - 1].endSec, out[i].startSec, 1e-9)
    }
}
```

### Step 2: Run it — confirm it fails

```bash
cd android && ./gradlew :app:testFullDebugUnitTest --tests "com.noop.ui.StageDisplaySmoothingTest"
```

Expected: compile failure (`displaySmoothed` unresolved).

### Step 3: Implement

In `SleepScreen.kt`, directly after `stageIntervalsFromWeights` (Task 1), add:

```kotlin
/**
 * Display-time smoothing — a straight port of Swift `Hypnogram.displaySmoothed` (WHOOP-style,
 * Packages/StrandDesign/Sources/StrandDesign/Hypnogram.swift:92). The on-device stager emits
 * 30 s-epoch runs, so a real night arrives as 60–100 fragments; brief flickers are absorbed into
 * their surroundings AT DISPLAY TIME. Render-only: totals, percentages and stored data are
 * computed from the raw segments elsewhere and are untouched. Pass minDurationSec = 0 for raw.
 */
internal fun displaySmoothed(
    intervals: List<StageInterval>,
    minDurationSec: Double,
): List<StageInterval> {
    if (intervals.size <= 2 || minDurationSec <= 0.0) return intervals   // Swift: guard count > 2

    // Coalesce adjacent same-stage runs (also bridges the zero-length seams between epochs).
    fun coalesce(ivs: List<StageInterval>): MutableList<StageInterval> {
        val out = mutableListOf<StageInterval>()
        for (iv in ivs) {
            val last = out.lastOrNull()
            if (last != null && last.stage == iv.stage && iv.startSec - last.endSec < 1.0) {
                out[out.size - 1] = StageInterval(last.stage, last.startSec, iv.endSec)
            } else {
                out.add(iv)
            }
        }
        return out
    }

    var ivs = coalesce(intervals)
    // Repeatedly absorb the shortest sub-threshold fragment into its longer neighbour,
    // re-coalescing after each pass, until every remaining block clears the threshold.
    while (ivs.size > 1) {
        val idx = ivs.indices
            .filter { ivs[it].durationSec < minDurationSec }
            .minByOrNull { ivs[it].durationSec } ?: break
        val victim = ivs[idx]
        val prev = if (idx > 0) ivs[idx - 1] else null
        val next = if (idx < ivs.size - 1) ivs[idx + 1] else null
        when {
            prev != null && next != null ->
                // Absorb into the longer neighbour so the dominant surrounding stage wins.
                if (prev.durationSec >= next.durationSec) {
                    ivs[idx - 1] = StageInterval(prev.stage, prev.startSec, victim.endSec)
                } else {
                    ivs[idx + 1] = StageInterval(next.stage, victim.startSec, next.endSec)
                }
            prev != null -> ivs[idx - 1] = StageInterval(prev.stage, prev.startSec, victim.endSec)
            next != null -> ivs[idx + 1] = StageInterval(next.stage, victim.startSec, next.endSec)
            else -> break
        }
        ivs.removeAt(idx)
        ivs = coalesce(ivs)
    }
    return ivs
}
```

### Step 4: Run the test — confirm it passes

Same command. All 8 tests green. Also re-run Task 1's class to confirm nothing regressed.

### Step 5: Commit

```bash
git add -A && git commit -m "feat: port Hypnogram.displaySmoothed to Kotlin for the sleep timeline rows"
```

---

## Task 3: Per-row span extraction (pure logic + tests)

Each row needs the (fracStart, fracWidth) spans of ONE stage. Segment names come from the stager as
lowercase (`"wake"`, `"light"`, …) while rows are labeled `"Awake"` etc.; the existing
`stageColorFor` (SleepScreen.kt:1405) already treats `"awake"`/`"wake"` as aliases — match that.

### Step 1: Write the failing test

Create `android/app/src/test/java/com/noop/ui/StageRowSpansTest.kt`:

```kotlin
package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [canonicalStage] + [stageRowSpans]: the (fracStart, fracWidth) spans of one
 * stage's intervals within the night, feeding a single StageRowTrack canvas per timeline row.
 */
class StageRowSpansTest {

    private val ivs = listOf(
        StageInterval("wake", 0.0, 360.0),
        StageInterval("light", 360.0, 1800.0),
        StageInterval("deep", 1800.0, 2520.0),
        StageInterval("light", 2520.0, 3240.0),
        StageInterval("Awake", 3240.0, 3600.0),
    )

    @Test
    fun extractsFractionalSpansForOneStage() {
        val spans = stageRowSpans(ivs, "Light", 3600.0)
        assertEquals(2, spans.size)
        assertEquals(0.1f, spans[0].first, 1e-6f)
        assertEquals(0.4f, spans[0].second, 1e-6f)
        assertEquals(0.7f, spans[1].first, 1e-6f)
        assertEquals(0.2f, spans[1].second, 1e-6f)
    }

    @Test
    fun awakeAndWakeAreAliases() {
        // Row label "Awake" must catch both the "wake" and "Awake" segments (stageColorFor parity).
        val spans = stageRowSpans(ivs, "Awake", 3600.0)
        assertEquals(2, spans.size)
        assertEquals(0.0f, spans[0].first, 1e-6f)
        assertEquals(0.9f, spans[1].first, 1e-6f)
    }

    @Test
    fun matchIsCaseAndWhitespaceInsensitive() {
        assertEquals("deep", canonicalStage("  Deep "))
        assertEquals("awake", canonicalStage("WAKE"))
        assertEquals("awake", canonicalStage("Awake"))
        assertEquals("rem", canonicalStage("REM"))
        assertEquals(1, stageRowSpans(ivs, "DEEP", 3600.0).size)
    }

    @Test
    fun absentStageOrDegenerateSpanIsEmpty() {
        assertTrue(stageRowSpans(ivs, "REM", 3600.0).isEmpty())
        assertTrue(stageRowSpans(ivs, "Deep", 0.0).isEmpty())
    }
}
```

### Step 2: Run it — confirm it fails

```bash
cd android && ./gradlew :app:testFullDebugUnitTest --tests "com.noop.ui.StageRowSpansTest"
```

### Step 3: Implement

In `SleepScreen.kt`, directly after `displaySmoothed` (Task 2), add:

```kotlin
/** Canonical stage key: trims, lowercases, and folds the "wake"/"awake" alias (stageColorFor parity). */
internal fun canonicalStage(name: String): String {
    val n = name.trim().lowercase()
    return if (n == "wake") "awake" else n
}

/**
 * The (startFraction, widthFraction) spans of [rowStage]'s intervals within the night — one entry
 * per solid segment in that stage's timeline row track. Fractions of [spanSec]; the draw side
 * applies the min-width floor and canvas clamping.
 */
internal fun stageRowSpans(
    intervals: List<StageInterval>,
    rowStage: String,
    spanSec: Double,
): List<Pair<Float, Float>> {
    if (spanSec <= 0.0 || !spanSec.isFinite()) return emptyList()
    val key = canonicalStage(rowStage)
    return intervals
        .filter { canonicalStage(it.stage) == key }
        .map { iv -> (iv.startSec / spanSec).toFloat() to (iv.durationSec / spanSec).toFloat() }
}
```

### Step 4: Run the test — confirm it passes

Same command; then run all three new classes together:

```bash
cd android && ./gradlew :app:testFullDebugUnitTest --tests "com.noop.ui.Stage*"
```

### Step 5: Commit

```bash
git add -A && git commit -m "feat: per-stage row span extraction for the sleep timeline rows"
```

---

## Task 4: `Metrics` constants (Theme.kt)

### Step 1: Implement

In `android/app/src/main/java/com/noop/ui/Theme.kt`, find (currently lines 400-401):

```kotlin
    val stageStripHeight = 34.dp
    val motionStripHeight = 40.dp   // #407 — the subordinate movement/restlessness trace under the hypnogram
```

Insert directly after those two lines:

```kotlin
    // iOS #988 port — WHOOP-style per-stage sleep timeline rows (design 2026-07-10).
    val stageRowTrackHeight = 20.dp  // hatched night track + solid stage segments
    val stageRowCorner = 10.dp       // row background rounding
    val stageRowPadH = 10.dp         // row inner horizontal padding — MotionStrip/axis share it so epochs align
    val stageRowPadV = 8.dp          // row inner vertical padding
    val stageSegMinWidth = 2.dp      // width floor so a brief fragment reads as a block, not a hairline
    val stageSegCorner = 1.5.dp      // solid segment rounding
    val stageInsightHeight = 36.dp   // fixed insight slot height — selection never reflows the card
```

### Step 2: Verify it compiles

```bash
cd android && ./gradlew :app:compileFullDebugKotlin
```

### Step 3: Commit

```bash
git add -A && git commit -m "feat: Metrics constants for the sleep stage-timeline rows"
```

---

## Task 5: Timeline composables (UI)

All in `android/app/src/main/java/com/noop/ui/SleepScreen.kt`. No unit tests (Compose UI); the
verification gate is `compileDebugKotlin` + Task 7's manual checklist.

### Step 1: Add one import

In the import block (alphabetical; near `import androidx.compose.ui.geometry.Size`, line ~61), add:

```kotlin
import androidx.compose.ui.graphics.drawscope.clipRect
```

(Everything else the new code uses — `clip`, `border`, `clickable`, `CornerRadius`, `Offset`,
`Size`, `semantics`, `contentDescription`, `roundToInt`, `Locale` — is already imported.)

### Step 2: Extract `ClockLabelRow` from `HypnogramWithAxis`

`HypnogramWithAxis` (line ~1245) ends with an onset · midpoint · wake label `Row` guarded by
`if (showsAxis && onsetTs != null && wakeTs != null) { … }`. Replace the **entire contents of that
`if` block** — the `val onset = clockTimeLabel(onsetTs)` / `val mid = …` / `val wake = …`
declarations and the whole `Row(modifier = Modifier.fillMaxWidth()) { … }` that follows them —
with a single call:

```kotlin
            ClockLabelRow(onsetTs, wakeTs)
```

Then add the extracted composable **immediately after** `HypnogramWithAxis`'s closing brace,
moving the old body verbatim:

```kotlin
/**
 * The onset · midpoint · wake clock-label row under a night timeline. Extracted from
 * [HypnogramWithAxis] so the #988 stage-timeline rows share the exact same axis rendering.
 */
@Composable
private fun ClockLabelRow(onsetTs: Long, wakeTs: Long) {
    val onset = clockTimeLabel(onsetTs)
    val mid = clockTimeLabel((onsetTs + wakeTs) / 2L)
    val wake = clockTimeLabel(wakeTs)
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(
            onset,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.Start,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        Text(
            mid,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
            overflow = TextOverflow.Ellipsis,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        Text(
            wake,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.End,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
    }
}
```

### Step 3: Add the timeline composables

Insert the following block **after** `ClockLabelRow` (before the `MotionStrip` doc comment):

```kotlin
/** 90 s display floor for the stage rows — rows tolerate fine texture, so 90 s, not the staircase's 300 s. */
private const val STAGE_ROW_SMOOTH_SEC = 90.0

/**
 * iOS #988 port — the WHOOP-style per-stage timeline stack that replaces the flat hypnogram strip
 * for real-stage nights. Four tappable rows in WHOOP order (AWAKE · LIGHT · DEEP · REM), each a
 * hatched full-night track with solid segments on the shared onset→wake axis; MotionStrip and the
 * clock-label axis sit under the rows on the SAME timeline; a fixed-height insight slot closes the
 * stack. The rows ARE the legend — no dot row, no footer. Mirrors SleepView.stageTimeline.
 */
@Composable
private fun StageTimeline(
    realSegments: List<Pair<String, Float>>,
    s: Stages,
    onsetTs: Long?,
    wakeTs: Long?,
    motionEpochs: List<Double>,
) {
    // Night span: the session window when we have one (the clock axis uses the same span), else
    // the segments' own summed minutes — the fractions are identical either way.
    val weightSec = realSegments.sumOf { (_, wt) -> if (wt.isFinite() && wt > 0f) wt.toDouble() * 60.0 else 0.0 }
    val spanSec = if (onsetTs != null && wakeTs != null && wakeTs > onsetTs) {
        (wakeTs - onsetTs).toDouble()
    } else {
        weightSec
    }
    val intervals = remember(realSegments, spanSec) {
        displaySmoothed(stageIntervalsFromWeights(realSegments, spanSec), STAGE_ROW_SMOOTH_SEC)
    }
    // Tap-to-highlight; keyed on the night's segments so navigating nights clears the selection.
    var selectedStage by remember(realSegments) { mutableStateOf<String?>(null) }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        listOf(
            Triple("Awake", s.awake, Palette.sleepAwake),
            Triple("Light", s.light, Palette.sleepLight),
            Triple("Deep", s.deep, Palette.sleepDeep),
            Triple("REM", s.rem, Palette.sleepREM),
        ).forEach { (label, minutes, color) ->
            StageTimelineRow(
                label = label,
                minutes = minutes,
                total = s.total,
                color = color,
                spans = stageRowSpans(intervals, label, spanSec),
                selected = selectedStage == label,
                dimmed = selectedStage != null && selectedStage != label,
                onTap = { selectedStage = if (selectedStage == label) null else label },
            )
        }
        // #407 — MotionStrip component + data path untouched; relocated UNDER the rows on the SAME
        // timeline. Same inner insets as the rows' tracks so epochs don't skew against the segments.
        Box(modifier = Modifier.padding(horizontal = Metrics.stageRowPadH)) {
            MotionStrip(motionEpochs)
        }
        if (onsetTs != null && wakeTs != null) {
            Box(modifier = Modifier.padding(horizontal = Metrics.stageRowPadH)) {
                ClockLabelRow(onsetTs, wakeTs)
            }
        }
        StageInsight(selectedStage, s)
    }
}

/**
 * One per-stage timeline row: STAGE overline + coloured % + right-aligned duration over a hatched
 * full-night track with the stage's solid segments. Selected row gets a hairlineStrong stroke;
 * when ANOTHER row is selected this row's segments and % dim to tertiary. One collapsed a11y node —
 * "Awake: 49 min, 10 percent of the night". Mirrors SleepView.stageTimelineRow.
 */
@Composable
private fun StageTimelineRow(
    label: String,
    minutes: Double,
    total: Double,
    color: Color,
    spans: List<Pair<Float, Float>>,
    selected: Boolean,
    dimmed: Boolean,
    onTap: () -> Unit,
) {
    val percent = if (total > 0.0) (minutes / total * 100.0).roundToInt() else 0
    val segColor = if (dimmed) Palette.textTertiary.copy(alpha = 0.55f) else color
    val pctColor = if (dimmed) Palette.textTertiary else color
    val shape = RoundedCornerShape(Metrics.stageRowCorner)
    Column(
        verticalArrangement = Arrangement.spacedBy(Metrics.space6),
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.textPrimary.copy(alpha = 0.045f))
            .then(if (selected) Modifier.border(1.5.dp, Palette.hairlineStrong, shape) else Modifier)
            .clickable(onClickLabel = "Highlights this stage on the sleep chart", onClick = onTap)
            .padding(horizontal = Metrics.stageRowPadH, vertical = Metrics.stageRowPadV)
            .semantics(mergeDescendants = true) {
                contentDescription = "$label: ${durationText(minutes)}, $percent percent of the night"
            },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                label.uppercase(Locale.getDefault()),
                style = NoopType.overline,
                color = Palette.textPrimary,
                maxLines = 1,
            )
            Spacer(modifier = Modifier.width(Metrics.space8))
            Text("$percent%", style = NoopType.captionNumber, color = pctColor, maxLines = 1)
            Spacer(modifier = Modifier.weight(1f))
            Text(
                durationText(minutes),
                style = NoopType.captionNumber,
                color = Palette.textPrimary,
                maxLines = 1,
            )
        }
        StageRowTrack(spans = spans, color = segColor)
    }
}

/**
 * The row's track, drawn in a SINGLE Canvas (PERF: a fragmented night must not become hundreds of
 * composables — Charts.kt hoist convention): a recessed full-night base with faint diagonal
 * hatching ("no segment here" reads as "elsewhere in the night", not missing data), then the
 * stage's solid rounded segments with a width floor, clamped so floored widths stay on-canvas
 * (same #36 lesson as HypnogramWithAxis).
 */
@Composable
private fun StageRowTrack(spans: List<Pair<Float, Float>>, color: Color) {
    Canvas(modifier = Modifier.fillMaxWidth().height(Metrics.stageRowTrackHeight)) {
        val w = size.width
        val h = size.height
        if (w <= 0f || h <= 0f) return@Canvas

        val trackRadius = CornerRadius(Metrics.stageSegCorner.toPx(), Metrics.stageSegCorner.toPx())
        drawRoundRect(color = Palette.surfaceInset, size = Size(w, h), cornerRadius = trackRadius)
        clipRect(0f, 0f, w, h) {
            val step = 6.dp.toPx()
            var x = -h
            while (x < w) {
                drawLine(
                    color = Palette.hairline,
                    start = Offset(x, h),
                    end = Offset(x + h, 0f),
                    strokeWidth = 1f,
                )
                x += step
            }
        }

        val minW = Metrics.stageSegMinWidth.toPx()
        val segRadius = CornerRadius(Metrics.stageSegCorner.toPx(), Metrics.stageSegCorner.toPx())
        spans.forEach { (fracStart, fracWidth) ->
            if (!fracStart.isFinite() || !fracWidth.isFinite() || fracWidth <= 0f) return@forEach
            val segW = maxOf(w * fracWidth, minW).coerceAtMost(w)
            val x0 = (w * fracStart).coerceIn(0f, w - segW)
            drawRoundRect(
                color = color,
                topLeft = Offset(x0, 0f),
                size = Size(segW, h),
                cornerRadius = segRadius,
            )
        }
    }
}

/**
 * Fixed-height per-stage insight slot under the axis: with a stage selected, that stage tonight;
 * otherwise the quiet "tap a row" hint. Fixed height so selection never reflows the card. The
 * 30-day typical-range compare is a follow-up — no such repo call exists on Android yet (design
 * §Real-stage nights item 6).
 */
@Composable
private fun StageInsight(selectedStage: String?, s: Stages) {
    val text = when (selectedStage) {
        "Awake" -> stageInsightLine("Awake", s.awake, s.total)
        "Light" -> stageInsightLine("Light", s.light, s.total)
        "Deep" -> stageInsightLine("Deep", s.deep, s.total)
        "REM" -> stageInsightLine("REM", s.rem, s.total)
        else -> "Tap a stage to highlight it across the night."
    }
    Box(
        modifier = Modifier.fillMaxWidth().height(Metrics.stageInsightHeight),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 2)
    }
}

private fun stageInsightLine(label: String, minutes: Double, total: Double): String {
    val percent = if (total > 0.0) (minutes / total * 100.0).roundToInt() else 0
    return "$label tonight: ${durationText(minutes)} — $percent% of the night."
}
```

### Step 4: Compile

```bash
cd android && ./gradlew :app:compileFullDebugKotlin
```

Fix only mechanical issues (missing import, typo). If `NoopType.overline` needs the tracking
applied separately, copy exactly what `StageBreakdownRow` (line ~1180) does — it uses
`NoopType.overline` directly.

### Step 5: Commit

```bash
git add -A && git commit -m "feat: StageTimeline row composables for the sleep hero (iOS #988 port)"
```

---

## Task 6: Hero card body rewrite + `StageLegend` deletion

### Step 1: Rewrite the card body

In `SleepScreen.kt`, inside `Hero` (line ~772), find the block starting at
`val s = display.stages` (line ~811) through the end of that `ChartCard`'s trailing lambda
(the `}` after the `"No stage breakdown for this night."` `Text`, line ~862). Today it reads:

```kotlin
            val s = display.stages
            // After a bed/wake edit the session window is the source of truth for time-in-bed,
            // so the subtitle tracks the edit even before the stage minutes are recomputed. Uses the
            // EFFECTIVE onset so a hand-edited bedtime is reflected. (#160 / PR #395)
            val inBedMin = session?.let { (it.endTs - it.effectiveStartTs) / 60.0 } ?: s.total
            ChartCard(
                title = "Stage breakdown",
                subtitle = "${durationText(inBedMin)} in bed · ${display.efficiencyText} efficiency" +
                    (if (display.realSegments != null) " · approx. stages (on-device)" else ""),
                trailing = durationText(s.asleep),
                tint = Palette.restColor,
                footer = {
                    // WHOOP-style stage rows in the NOOP pip language: swatch + UPPERCASE stage +
                    // coloured % + a segmented PipBar of the share-of-night + right-aligned duration.
                    // Same minutes/percentages the old "label · value" footer carried — no new numbers.
                    // Mirrors the macOS SleepView.stageBreakdownRows. (PipBar)
                    StageBreakdownRows(s)
                },
            ) {
                // True per-epoch segments when the stager persisted them; else the reconstructed
                // architecture: light → deep → light → rem → light → awake.
                val segments = display.realSegments ?: stageSegments(s)
                if (segments.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        // Hero strip with the band-min-thickness floor (so a short Awake reads as a
                        // bar, not a tick) + an onset · midpoint · wake time axis when the session
                        // gives clock times. Mirrors the Swift Hypnogram(showsTimeAxis:).
                        HypnogramWithAxis(
                            stages = segments,
                            onsetTs = session?.effectiveStartTs,
                            wakeTs = session?.endTs,
                        )
                        // #407 — subordinate movement/restlessness trace UNDER the hypnogram, on the SAME
                        // timeline, for the SAME main-night GROUP blocks the hero resolved (selectNight's
                        // group). Honest empty state when no fragment has persisted motion (older rows).
                        MotionStrip(motionEpochs)
                        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                            StageLegend("Deep", Palette.sleepDeep)
                            StageLegend("Light", Palette.sleepLight)
                            StageLegend("REM", Palette.sleepREM)
                            StageLegend("Awake", Palette.sleepAwake)
                        }
                    }
                } else {
                    Text(
                        "No stage breakdown for this night.",
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                    )
                }
            }
```

Replace it with:

```kotlin
            val s = display.stages
            // After a bed/wake edit the session window is the source of truth for time-in-bed,
            // so the subtitle tracks the edit even before the stage minutes are recomputed. Uses the
            // EFFECTIVE onset so a hand-edited bedtime is reflected. (#160 / PR #395)
            val inBedMin = session?.let { (it.endTs - it.effectiveStartTs) / 60.0 } ?: s.total
            val subtitle = "${durationText(inBedMin)} in bed · ${display.efficiencyText} efficiency" +
                (if (display.realSegments != null) " · approx. stages (on-device)" else "")
            // iOS #988 port: true per-epoch segments (≥ 2 — a single run has no transitions to lay
            // out) get the per-stage timeline rows; the rows ARE the legend, so no footer. Anything
            // else keeps the honest proportional strip + StageBreakdownRows footer.
            val real = display.realSegments?.takeIf { it.size >= 2 }
            if (real != null) {
                ChartCard(
                    title = "Stage breakdown",
                    subtitle = subtitle,
                    trailing = durationText(s.asleep),
                    tint = Palette.restColor,
                    footer = {},
                ) {
                    StageTimeline(
                        realSegments = real,
                        s = s,
                        onsetTs = session?.effectiveStartTs,
                        wakeTs = session?.endTs,
                        motionEpochs = motionEpochs,
                    )
                }
            } else {
                ChartCard(
                    title = "Stage breakdown",
                    subtitle = subtitle,
                    trailing = durationText(s.asleep),
                    tint = Palette.restColor,
                    footer = { StageBreakdownRows(s) },
                ) {
                    // Reconstructed architecture (light → deep → light → rem → light → awake) as the
                    // flat proportional strip. No MotionStrip and no fake steps here: invented
                    // architecture has no genuine timeline to anchor to (mirrors the iOS else-branch).
                    val segments = stageSegments(s)
                    if (segments.isNotEmpty()) {
                        HypnogramWithAxis(
                            stages = segments,
                            onsetTs = session?.effectiveStartTs,
                            wakeTs = session?.endTs,
                        )
                    } else {
                        Text(
                            "No stage breakdown for this night.",
                            style = NoopType.subhead,
                            color = Palette.textTertiary,
                        )
                    }
                }
            }
```

Behavioral notes (all from the design doc):
- The `display == null` → "No stage data recorded for this night." branch above this block is untouched.
- The subtitle marker logic is byte-identical to today (appends iff `display.realSegments != null`),
  so a 1-segment on-device night falling into the fallback branch still reads "approx. stages (on-device)".
- `MotionStrip` renders only in the timeline branch (inside `StageTimeline`, Task 5) — the
  proportional fallback bar has no timeline for epochs to anchor to.

### Step 2: Delete `StageLegend`

Delete the whole `StageLegend` composable (line ~1898, the `@Composable private fun
StageLegend(label: String, color: Color) { … }` block). It was only called from the four lines
removed in Step 1 — verify before deleting:

```bash
grep -rn "StageLegend(" android/app/src/
```

Expected: no hits outside the definition itself. Leave `Metrics.legendSwatch` alone (check usages —
if `grep -rn "legendSwatch" android/app/src/main` shows only Theme.kt after the deletion, remove the
constant too and note it in the commit).

### Step 3: Compile + full unit suite

```bash
cd android && ./gradlew :app:compileFullDebugKotlin && ./gradlew :app:testFullDebugUnitTest
```

Everything green, including the pre-existing `SleepStageSegmentsTest`.

### Step 4: Commit

```bash
git add -A && git commit -m "feat: sleep hero uses per-stage timeline rows for real-stage nights (iOS #988 parity)"
```

---

## Task 7: Verification

### Automated

```bash
cd android && ./gradlew :app:testFullDebugUnitTest && ./gradlew :app:compileFullDebugKotlin
```

### Manual (emulator or device, debug build)

1. **Real-stage night** (a night the on-device stager persisted — any recent strap night):
   - Four rows in order AWAKE · LIGHT · DEEP · REM; percents/durations match the old footer's numbers.
   - Segments read as clean blocks (no 30 s comb); track hatching visible where the stage is absent.
   - MotionStrip sits under the rows, epochs visually aligned with segment edges (check first/last
     epoch against onset/wake); clock labels onset · midpoint · wake under it.
   - Tap DEEP: other rows' segments and % dim, DEEP row gets a stroke, insight slot shows
     "Deep tonight: …". Tap again: selection clears, hint returns, card height does NOT change.
   - Navigate to another night and back: selection cleared.
2. **Fallback night** (imported night, e.g. a Health Connect / minutes-only import): flat strip +
   `StageBreakdownRows` footer, "approx. stages (on-device)" absent, **no** MotionStrip, no dot legend.
3. **Honest empties**: night with no stage data → "No stage data recorded for this night."; real
   night with no persisted motion → MotionStrip's "No movement detail for this night." note.
4. **Long-press / a11y**: with TalkBack, each row reads as one node — "Awake: 49 min, 10 percent of
   the night", action hint "Highlights this stage on the sleep chart".
5. **Theme**: check Classic and default palettes (row bg is a `textPrimary` alpha, must work on both).

### Wrap up

- `git log --oneline` — one commit per task, conventional prefixes.
- Update the design doc only if implementation deviated (note the deviation inline).
