package com.noop.ui
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material.icons.filled.Campaign
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SaveAlt
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Vibration
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.BuildConfig
import com.noop.analytics.Baselines
import com.noop.analytics.DayCycleMode
import com.noop.analytics.HrZoneSet
import com.noop.analytics.HrZones
import com.noop.analytics.ProfileWeightSync
import com.noop.analytics.UserProfile
import com.noop.analytics.Zones
import com.noop.R
import com.noop.ble.PuffinExperiment
import com.noop.ble.WhoopBleClient
import com.noop.protocol.Whoop5Config
import com.noop.protocol.EcgRawDataGateReport
import com.noop.ble.WhoopModel
import com.noop.data.DataBackup
import com.noop.ingest.RawSensorExport
import com.noop.ingest.WhoopCsvExporter
import com.noop.testcentre.TestCentre
import com.noop.testcentre.TestDomain
import com.noop.update.UpdateCheck
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlin.math.roundToInt
import com.noop.analytics.ClockFormatPreference

// MARK: - Profile store (SharedPreferences-backed; the macOS ProfileStore equivalent)

/**
 * The user's body profile — age / sex / weight / height plus an optional manual
 * HR-max override. Persisted to SharedPreferences so the values survive restarts
 * and other screens (HealthScreen, Coach zones) can read the same source of truth.
 *
 * Mirrors the macOS `ProfileStore` fields and ranges exactly. `hrMaxOverride == 0`
 * means "auto" — fall back to the Tanaka estimate from [age].
 */
class ProfileStore(private val prefs: SharedPreferences) {

    /**
     * Current age in whole years (#146), DERIVED from [dateOfBirthMillis] so it advances on its own
     * instead of going stale until the user bumps a number. Read-only; change age via [setAge] (the
     * +/- stepper) or [dateOfBirthMillis] directly. Every existing reader (Fitness Age / Vitality /
     * Tanaka) keeps reading `profile.age` unchanged.
     */
    val age: Int
        get() = yearsFromDob(dateOfBirthMillis).coerceIn(AGE_MIN, AGE_MAX)

    /**
     * Date of birth as epoch millis — the canonical source of truth for [age] (#146). The getter
     * lazily migrates a pre-#146 stored age (or a restored legacy `age`, see [applyBackup]) into an
     * anchored DOB the first time it's read, then persists it so the derivation is stable. The setter
     * mirrors the derived Int age under the legacy [KEY_AGE] so the `.noopbak` backup whitelist keeps
     * exporting an age with no change to the cross-platform contract.
     */
    var dateOfBirthMillis: Long
        get() {
            if (prefs.contains(KEY_DOB)) return prefs.getLong(KEY_DOB, 0L)
            val legacyAge = (if (prefs.contains(KEY_AGE)) prefs.getInt(KEY_AGE, 30) else 30)
                .coerceIn(AGE_MIN, AGE_MAX)
            val dob = dobForAge(legacyAge)
            prefs.edit().putLong(KEY_DOB, dob).putInt(KEY_AGE, legacyAge).apply()
            return dob
        }
        set(v) = prefs.edit()
            .putLong(KEY_DOB, v)
            .putInt(KEY_AGE, yearsFromDob(v).coerceIn(AGE_MIN, AGE_MAX))
            .apply()

    /** Set age by anchoring a date of birth `years` before today (the +/- stepper and backup restore
     *  both go through here, so age always flows from a DOB). Clamped to [AGE_MIN]..[AGE_MAX]. */
    fun setAge(years: Int) { dateOfBirthMillis = dobForAge(years.coerceIn(AGE_MIN, AGE_MAX)) }

    /** Fork (DX23876): the wearer's first name for More and the greetings, as iOS `ProfileStore.name`. Local only,
     *  never in a backup (iOS keeps it out of the `.noopbak` whitelist too); blank means none. */
    var name: String
        get() = prefs.getString(KEY_NAME, "") ?: ""
        set(v) { val t = v.trim(); prefs.edit().apply { if (t.isEmpty()) remove(KEY_NAME) else putString(KEY_NAME, t) }.apply() }

    /** "male" | "female" | "nonbinary" — matches the macOS tag values. */
    var sex: String
        get() = prefs.getString(KEY_SEX, "male") ?: "male"
        set(v) = prefs.edit().putString(KEY_SEX, v).apply()

    var weightKg: Double
        get() = prefs.getFloat(KEY_WEIGHT, 75f).toDouble().coerceIn(WEIGHT_MIN, WEIGHT_MAX)
        set(v) = prefs.edit().putFloat(KEY_WEIGHT, v.coerceIn(WEIGHT_MIN, WEIGHT_MAX).toFloat()).apply()

    /**
     * Opt-in "Use weight from Health Connect", OFF by default. When ON, every Health Connect import
     * copies the newest Health Connect weight into [weightKg] ([HealthConnectWeightSync]) and Settings
     * locks the weight stepper. Android only: Apple platforms have no Health Connect. Deliberately NOT
     * in the `.noopbak` whitelist, like the other install-specific toggles: a restored device needs its
     * own Health Connect grant before this means anything, and there is no Swift twin to keep equal.
     */
    var useHealthConnectWeight: Boolean
        get() = prefs.getBoolean(KEY_USE_HC_WEIGHT, false)
        set(v) = prefs.edit().putBoolean(KEY_USE_HC_WEIGHT, v).apply()

    /**
     * ISO day of the Health Connect reading last copied into [weightKg]; null before the first sync.
     * Provenance for the Settings caption only, never a value input. Not backed up, as above.
     */
    var healthConnectWeightDay: String?
        get() = prefs.getString(KEY_HC_WEIGHT_DAY, null)
        set(v) = prefs.edit().apply {
            if (v == null) remove(KEY_HC_WEIGHT_DAY) else putString(KEY_HC_WEIGHT_DAY, v)
        }.apply()

    var heightCm: Double
        get() = prefs.getFloat(KEY_HEIGHT, 178f).toDouble().coerceIn(HEIGHT_MIN, HEIGHT_MAX)
        set(v) = prefs.edit().putFloat(KEY_HEIGHT, v.coerceIn(HEIGHT_MIN, HEIGHT_MAX).toFloat()).apply()

    /**
     * Waist circumference in cm; 0 = unset (the Fitness Age VO₂max estimate is hidden until a waist
     * is entered). Optional — it only unlocks the VO₂max read-out and never moves the headline Fitness
     * Age (the engine's body term cancels). No coercion floor (0 has to remain a sentinel for "unset");
     * the upper bound is clamped so a fat-fingered entry can't run away.
     */
    var waistCm: Double
        get() = prefs.getFloat(KEY_WAIST, 0f).toDouble().coerceIn(0.0, WAIST_MAX)
        set(v) = prefs.edit().putFloat(KEY_WAIST, v.coerceIn(0.0, WAIST_MAX).toFloat()).apply()

    /** Manual max-heart-rate override in bpm; 0 = automatic (Tanaka). */
    var hrMaxOverride: Int
        get() = prefs.getInt(KEY_HRMAX, 0).coerceIn(0, 230)
        set(v) = prefs.edit().putInt(KEY_HRMAX, v.coerceIn(0, 230)).apply()

    /**
     * Step-calibration divisor (#139/#132): counter ticks per real step for the @57 motion
     * counter. 1.0 = raw pass-through (default — no behavior change). Clamped 0.5–30.0
     * (WHOOP 5/MG motion-counter overcount can reach ~24×, so the ceiling has to be high).
     */
    var stepTicksPerStep: Double
        get() = prefs.getFloat(KEY_STEP_SCALE, 1f).toDouble().coerceIn(STEP_SCALE_MIN, STEP_SCALE_MAX)
        set(v) = prefs.edit()
            .putFloat(KEY_STEP_SCALE, v.coerceIn(STEP_SCALE_MIN, STEP_SCALE_MAX).toFloat())
            .apply()

    /**
     * The analytics [UserProfile] for this store — the ONE place the mapping lives.
     *
     * Every field matters somewhere and a missing one fails silently rather than loudly. Dropping
     * [waistCm] does not blank VO₂max, it swaps the estimator: `FitnessAgeEngine.compute` returns a
     * waist-based Nes value only when a waist is supplied, and `fitnessAgeRows` otherwise falls back to
     * the Uth HR-ratio formula and writes THAT under the same "vo2max_est" key. Two passes built two
     * profiles, one of them lost the waist, and the card alternated between the two estimators with no
     * visible cause — a fit user with a low resting HR saw it swing by ~14 (#1493). Build the profile
     * here so a caller cannot omit a field by writing one out longhand.
     */
    fun toUserProfile(): UserProfile = UserProfile(
        weightKg = weightKg,
        heightCm = heightCm,
        age = age.toDouble(),
        sex = sex,
        stepTicksPerStep = stepTicksPerStep,
        waistCm = waistCm,
    )

    // ── Steps ESTIMATE calibration (WHOOP 4.0; StepsEstimateEngine) ─────────────────────────────
    // Mirror of the macOS ProfileStore fields: the engine writes the auto-fit each analytics pass and
    // the Settings/Steps screen reads them. [stepsManualCoefficient] is the ONLY user-settable field
    // (0 = auto-fit / null to the engine; > 0 = manual override fed into calibrate()); the other three
    // are fitted outputs surfaced read-only.
    /** Fitted (or manually-set) steps-per-unit-of-motion coefficient last persisted by the engine. */
    var stepsCalibrationCoefficient: Double
        get() = prefs.getFloat(KEY_STEPS_COEFF, 0f).toDouble()
        set(v) = prefs.edit().putFloat(KEY_STEPS_COEFF, v.toFloat()).apply()

    /** How many calibration days fed the last auto-fit (0 when purely manual / not yet fit). */
    var stepsCalibrationSampleDays: Int
        get() = prefs.getInt(KEY_STEPS_SAMPLE_DAYS, 0)
        set(v) = prefs.edit().putInt(KEY_STEPS_SAMPLE_DAYS, v).apply()

    /** 0–1 trust in the last fit (1.0 for a manual coefficient). */
    var stepsCalibrationConfidence: Double
        get() = prefs.getFloat(KEY_STEPS_CONFIDENCE, 0f).toDouble()
        set(v) = prefs.edit().putFloat(KEY_STEPS_CONFIDENCE, v.toFloat()).apply()

    /** True when the persisted coefficient came from the user's manual override, not an auto-fit. */
    var stepsCalibrationManual: Boolean
        get() = prefs.getBoolean(KEY_STEPS_MANUAL_FLAG, false)
        set(v) = prefs.edit().putBoolean(KEY_STEPS_MANUAL_FLAG, v).apply()

    /** User-set manual coefficient. 0 = auto-fit (null to the engine); > 0 = manual override. */
    var stepsManualCoefficient: Double
        get() = prefs.getFloat(KEY_STEPS_MANUAL_COEFF, 0f).toDouble().coerceAtLeast(0.0)
        set(v) = prefs.edit().putFloat(KEY_STEPS_MANUAL_COEFF, v.coerceAtLeast(0.0).toFloat()).apply()

    /** The manual override to feed into `StepsEstimateEngine.calibrate(points, manualOverride)`:
     *  null when 0 (auto-fit), the positive value otherwise. */
    val stepsManualOverride: Double? get() = stepsManualCoefficient.takeIf { it > 0 }

    /**
     * #1816: true when the strap has banked ANY motion (gravity samples → `dayMotionIntensity > 0`)
     * in the calibration scan window. Written by the analytics engine on every pass so it tracks a
     * fresh strap's first sync without a separate query. The Today tile reads this to decide whether
     * "Need N more days where your phone also counted steps" is the honest caption or a lie: a step
     * estimate is `motion * coefficient`, so with the motion half missing neither the estimate nor the
     * fit moves however many phone-counted days the user collects. The caption that names only the
     * phone half is actively misleading. Twin of the Swift `ProfileStore.stepsHasBankedMotion`.
     */
    var stepsHasBankedMotion: Boolean
        get() = prefs.getBoolean(KEY_STEPS_HAS_MOTION, false)
        set(v) = prefs.edit().putBoolean(KEY_STEPS_HAS_MOTION, v).apply()

    /** The auto (Tanaka) HR-max for the current age. */
    val hrMaxAuto: Int get() = Zones.hrMaxTanaka(age)

    /** Effective HR-max: the manual override if set, else the Tanaka estimate. */
    val hrMax: Int get() = if (hrMaxOverride > 0) hrMaxOverride else hrMaxAuto

    /**
     * Five personalized inclusive zone starts in BPM, or null for the conventional %HRmax zones.
     * Persisted under [KEY_HR_ZONE_THRESHOLDS]; a stored value failing the shared invariant is treated
     * as absent. Mirrors macOS `Profile.hrZoneThresholds`.
     */
    var hrZoneThresholds: List<Int>?
        get() {
            val values = prefs.getString(KEY_HR_ZONE_THRESHOLDS, null)
                ?.split(",")?.mapNotNull(String::toIntOrNull) ?: return null
            return values.takeIf { validZoneThresholds(it) }
        }
        set(values) {
            if (values == null || !validZoneThresholds(values)) {
                prefs.edit().remove(KEY_HR_ZONE_THRESHOLDS).apply()
            } else {
                prefs.edit().putString(KEY_HR_ZONE_THRESHOLDS, values.joinToString(",")).apply()
            }
        }

    /** The single display-zone model used by live HR, workout splits, and haptic coaching. */
    val hrZoneSet: HrZoneSet
        get() = HrZones.zones(maxHR = hrMax.toDouble(), customLowerBounds = hrZoneThresholds?.map(Int::toDouble))

    val hasCustomHrZones: Boolean get() = hrZoneThresholds != null

    /** Enable by seeding the editor with conventional boundaries; disabling restores the defaults. */
    fun setCustomHrZonesEnabled(enabled: Boolean) {
        hrZoneThresholds = if (enabled) HrZones.defaultLowerBounds(hrMax.toDouble()) else null
    }

    /** Move one boundary while preserving strict ordering, with neighbour-aware clamps. */
    fun stepHrZoneThreshold(index: Int, up: Boolean) {
        val current = hrZoneThresholds?.toMutableList() ?: return
        if (index !in current.indices) return
        val floor = if (index == 0) HrZones.customBPMRange.first else current[index - 1] + 1
        val ceiling = if (index == current.lastIndex) HrZones.customBPMRange.last else current[index + 1] - 1
        if (floor > ceiling) return   // no room between neighbours -> no-op (coerceIn throws on empty range)
        current[index] = (current[index] + if (up) 1 else -1).coerceIn(floor, ceiling)
        hrZoneThresholds = current
    }

    // ── Backup settings snapshot/apply (#1000) ──────────────────────────────────────────────────
    // The profile half of a `.noopbak`'s `settings.json`. Canonical key strings mirror
    // `BackupSettingsCodec.WHITELIST` (and the Apple `BackupSettings.whitelist`) exactly — note
    // canonical `profile.hrMax` maps onto this store's `hr_max_override` pref. Lives on ProfileStore
    // because only it knows its private pref keys; `contains` checks keep never-set fields OUT of the
    // snapshot so restoring on another device doesn't stamp defaults over that device's real values.

    /** The user-SET profile fields, keyed canonically, for the backup exporter. */
    fun backupSnapshot(): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        // #146: age is now derived from a DOB; export the current derived Int under the legacy
        // `profile.age` key (the whitelist carries an Int, not a Date). A never-touched profile
        // (neither key set) still stays out of the snapshot.
        if (prefs.contains(KEY_DOB) || prefs.contains(KEY_AGE)) out["profile.age"] = age
        if (prefs.contains(KEY_SEX)) out["profile.sex"] = sex
        if (prefs.contains(KEY_WEIGHT)) out["profile.weightKg"] = weightKg
        if (prefs.contains(KEY_HEIGHT)) out["profile.heightCm"] = heightCm
        if (prefs.contains(KEY_WAIST)) out["profile.waistCm"] = waistCm
        if (prefs.contains(KEY_HRMAX)) out["profile.hrMax"] = hrMaxOverride
        if (prefs.contains(KEY_HR_ZONE_THRESHOLDS)) {
            hrZoneThresholds?.let { out["profile.hrZoneThresholds"] = it.joinToString(",") }
        }
        return out
    }

    /**
     * Apply a restored backup's profile fields (canonical keys, already whitelist-filtered by
     * `BackupSettingsCodec.decode`). Missing keys leave the current values alone; every write goes
     * through the property setters, so the usual range clamps apply.
     */
    fun applyBackup(values: Map<String, Any>) {
        // #146: a restore carries only an Int age. Route it through setAge so the restored age
        // re-anchors this device's DOB (clearing any stale local DOB) and then advances on its own —
        // the deterministic twin of the Apple side clearing `profile.dateOfBirth` on apply.
        (values["profile.age"] as? Number)?.let { setAge(it.toInt()) }
        (values["profile.sex"] as? String)?.let { sex = it }
        (values["profile.weightKg"] as? Number)?.let { weightKg = it.toDouble() }
        (values["profile.heightCm"] as? Number)?.let { heightCm = it.toDouble() }
        (values["profile.waistCm"] as? Number)?.let { waistCm = it.toDouble() }
        (values["profile.hrMax"] as? Number)?.let { hrMaxOverride = it.toInt() }
        (values["profile.hrZoneThresholds"] as? String)?.let {
            hrZoneThresholds = it.split(",").mapNotNull(String::toIntOrNull)
        }
    }

    /** Whether nobody has said who this is yet. The demo seed asks before it writes a synthetic person,
     *  so a wearer who once started a demo build keeps their own figures.
     *
     *  It asks about the height and the cohort, not the age or the weight: [dateOfBirthMillis] WRITES a
     *  date of birth and its mirrored age the first time anybody reads it, and the Health Connect weight
     *  sync copies a weight across, so those keys are set on a profile nobody has touched. Nothing
     *  derives a height or a cohort. */
    fun isUnset(): Boolean = !prefs.contains(KEY_HEIGHT) && !prefs.contains(KEY_SEX)

    companion object {
        internal const val PREFS = "noop_profile"
        /** Date of birth as epoch millis — the #146 source of truth for [age]. */
        private const val KEY_DOB = "date_of_birth"
        /** Pre-#146 age key, now kept mirrored from the DOB so the `.noopbak` whitelist (Int age)
         *  keeps round-tripping unchanged. */
        private const val KEY_AGE = "age"
        private const val KEY_SEX = "sex"
        private const val KEY_NAME = "profile_name"
        private const val KEY_WEIGHT = "weight_kg"
        private const val KEY_USE_HC_WEIGHT = "use_health_connect_weight"
        private const val KEY_HC_WEIGHT_DAY = "health_connect_weight_day"
        /** Keys a background Health Connect import may rewrite while Settings is open. */
        internal val HEALTH_CONNECT_WEIGHT_KEYS = setOf(KEY_WEIGHT, KEY_USE_HC_WEIGHT, KEY_HC_WEIGHT_DAY)
        private const val KEY_HEIGHT = "height_cm"
        private const val KEY_WAIST = "waist_cm"
        private const val KEY_HRMAX = "hr_max_override"
        private const val KEY_HR_ZONE_THRESHOLDS = "hr_zone_thresholds"

        /** The shared five-boundary invariant (parity with `HRZones.validCustomLowerBounds`). */
        fun validZoneThresholds(values: List<Int>): Boolean =
            values.size == 5 &&
                values.all { it in HrZones.customBPMRange } &&
                values.zipWithNext().all { (a, b) -> a < b }
        private const val KEY_STEP_SCALE = "step_ticks_per_step"
        private const val KEY_STEPS_COEFF = "steps_calibration_coefficient"
        private const val KEY_STEPS_SAMPLE_DAYS = "steps_calibration_sample_days"
        private const val KEY_STEPS_CONFIDENCE = "steps_calibration_confidence"
        private const val KEY_STEPS_MANUAL_FLAG = "steps_calibration_manual"
        private const val KEY_STEPS_MANUAL_COEFF = "steps_manual_coefficient"
        private const val KEY_STEPS_HAS_MOTION = "steps_has_banked_motion"

        private const val AGE_MIN = 13
        private const val AGE_MAX = 100
        private const val WEIGHT_MIN = 30.0
        private const val WEIGHT_MAX = 250.0
        private const val HEIGHT_MIN = 120.0
        private const val HEIGHT_MAX = 230.0
        private const val WAIST_MAX = 200.0
        private const val STEP_SCALE_MIN = 0.5
        private const val STEP_SCALE_MAX = 30.0

        /**
         * Variable step for the calibration stepper so high values stay reachable: fine near the
         * 1.0 default (where most people land), coarse up at the 20s+ a 5/MG needs. A flat 0.1 step
         * from 0.5 to 30 would be ~295 taps — unusable. Mirrors macOS `ProfileStore.stepScaleIncrement`.
         *  - `< 2.0` → 0.1   (precision around the default)
         *  - `2.0–5.0` → 0.5
         *  - `>= 5.0` → 1.0   (ballpark the ~24× overcount in ~19 taps)
         */
        fun stepScaleIncrement(value: Double): Double = when {
            value < 2.0 -> 0.1
            value < 5.0 -> 0.5
            else -> 1.0
        }

        // ── #146 age <-> date-of-birth ──────────────────────────────────────────────────────────
        /** Whole years between the DOB and today (floor — a birthday not yet reached doesn't count).
         *  Uses the device's default zone so the rollover matches the user's local calendar. Mirrors
         *  the Apple `ProfileStore.years(from:to:)`. */
        fun yearsFromDob(dobMillis: Long): Int {
            val zone = java.time.ZoneId.systemDefault()
            val dob = java.time.Instant.ofEpochMilli(dobMillis).atZone(zone).toLocalDate()
            return java.time.temporal.ChronoUnit.YEARS.between(dob, java.time.LocalDate.now(zone)).toInt()
        }

        /** A date of birth `age` whole years before today (anchored to today's month/day, so the
         *  derived age is exactly `age`). Mirrors the Apple `ProfileStore.dateOfBirth(forAge:)`. */
        fun dobForAge(age: Int): Long {
            val zone = java.time.ZoneId.systemDefault()
            return java.time.LocalDate.now(zone).minusYears(age.toLong())
                .atStartOfDay(zone).toInstant().toEpochMilli()
        }

        /**
         * One increment/decrement of the calibration divisor, snapped to the increment grid and
         * clamped to [STEP_SCALE_MIN]..[STEP_SCALE_MAX]. Decrement uses the increment for the
         * *target* band so the up/down sequence is symmetric at band boundaries (e.g. 5.0 −1 → 4.0,
         * 4.0 +0.5 → 4.5). Mirrors macOS `ProfileStore.steppedStepScale`.
         */
        fun steppedStepScale(value: Double, up: Boolean): Double {
            val delta = if (up) stepScaleIncrement(value) else stepScaleIncrement(value - 0.0001)
            val next = Math.round((value + if (up) delta else -delta) / delta) * delta
            return next.coerceIn(STEP_SCALE_MIN, STEP_SCALE_MAX)
        }

        fun from(context: Context): ProfileStore =
            ProfileStore(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
