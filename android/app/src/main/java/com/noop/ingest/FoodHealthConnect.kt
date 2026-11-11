package com.noop.ingest

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.MealType
import androidx.health.connect.client.records.NutritionRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.health.connect.client.units.Energy
import androidx.health.connect.client.units.Mass
import com.noop.core.CoreFood
import com.noop.core.SwiftCore
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * Fork (DX23876), decision 2026-11-08: the food log and Health Connect. Writes one [NutritionRecord] per entry and
 * deletes it with the entry, as `FoodHealthSync` does with Apple Health; reads other apps' nutrition as daily
 * totals, one app per day, into the shared core (`food.importHealth`). Records this app wrote are skipped on
 * read, so a meal logged here is never counted twice.
 */
object FoodHealthConnect {
    const val PREF_WRITE = "food.health.write.enabled"
    const val PREF_PREFERRED_SOURCE = "nutrition.preferredHealthSource"
    private const val WINDOW_DAYS = 30L

    val READ: Set<String> = setOf(HealthPermission.getReadPermission(NutritionRecord::class))
    val WRITE: Set<String> = setOf(HealthPermission.getWritePermission(NutritionRecord::class))

    private fun client(context: Context): HealthConnectClient? =
        if (HealthConnectClient.getSdkStatus(context) == HealthConnectClient.SDK_AVAILABLE) HealthConnectClient.getOrCreate(context) else null

    private suspend fun granted(context: Context): Set<String> =
        runCatching { client(context)?.permissionController?.getGrantedPermissions() ?: emptySet() }.getOrDefault(emptySet())

    private fun writeEnabled(context: Context) =
        com.noop.ui.NoopPrefs.of(context).getBoolean(PREF_WRITE, true)

    private fun mealType(meal: String?): Int = when (meal) {
        "breakfast" -> MealType.MEAL_TYPE_BREAKFAST
        "lunch" -> MealType.MEAL_TYPE_LUNCH
        "dinner" -> MealType.MEAL_TYPE_DINNER
        "snack" -> MealType.MEAL_TYPE_SNACK
        else -> MealType.MEAL_TYPE_UNKNOWN
    }

    internal fun record(entry: CoreFood.Entry, zone: ZoneId = ZoneId.systemDefault()): NutritionRecord {
        val t = entry.totals
        fun g(key: String) = t[key]?.let { Mass.grams(it) }
        fun mg(key: String) = t[key]?.let { Mass.grams(it / 1_000.0) }
        fun ug(key: String) = t[key]?.let { Mass.grams(it / 1_000_000.0) }
        val start = Instant.ofEpochSecond(entry.loggedAt)
        val offset = zone.rules.getOffset(start)
        return NutritionRecord(
            startTime = start, startZoneOffset = offset, endTime = start.plusSeconds(60), endZoneOffset = offset,
            name = entry.name, mealType = mealType(entry.meal),
            energy = t["energy_kcal"]?.let { Energy.kilocalories(it) },
            protein = g("protein_g"), totalCarbohydrate = g("carbs_g"), totalFat = g("fat_g"), dietaryFiber = g("fiber_g"),
            sugar = g("sugar_g"), saturatedFat = g("sat_fat_g"), monounsaturatedFat = g("mono_fat_g"),
            polyunsaturatedFat = g("poly_fat_g"), cholesterol = mg("cholesterol_mg"), sodium = mg("sodium_mg"),
            potassium = mg("potassium_mg"), calcium = mg("calcium_mg"), magnesium = mg("magnesium_mg"),
            phosphorus = mg("phosphorus_mg"), iron = mg("iron_mg"), zinc = mg("zinc_mg"), iodine = ug("iodine_ug"),
            copper = mg("copper_mg"), manganese = mg("manganese_mg"), vitaminA = ug("vitamin_a_ug"),
            vitaminD = ug("vitamin_d_ug"), vitaminE = mg("vitamin_e_mg"), vitaminK = ug("vitamin_k_ug"),
            thiamin = mg("thiamin_mg"), riboflavin = mg("riboflavin_mg"), niacin = mg("niacin_mg"),
            vitaminB6 = mg("vitamin_b6_mg"), folate = ug("folate_ug"), vitaminB12 = ug("vitamin_b12_ug"),
            vitaminC = mg("vitamin_c_mg"), pantothenicAcid = mg("pantothenic_mg"), biotin = ug("biotin_ug"),
            metadata = Metadata(clientRecordId = "noop-food-${entry.id}"),
        )
    }

    /** Writes new entries and stores each record id in the food log. */
    suspend fun wrote(context: Context, entries: List<CoreFood.Entry>) {
        val client = client(context) ?: return
        if (entries.isEmpty() || !writeEnabled(context) || !granted(context).containsAll(WRITE)) return
        runCatching {
            val ids = client.insertRecords(entries.map { record(it) }).recordIdsList
            entries.zip(ids).forEach { (entry, id) -> CoreFood.setHealthId(entry.id, id) }
        }
    }

    suspend fun removed(context: Context, entries: List<CoreFood.Entry>) {
        val client = client(context) ?: return
        val ids = entries.mapNotNull { it.healthId }
        if (ids.isEmpty() || !granted(context).containsAll(WRITE)) return
        runCatching { client.deleteRecords(NutritionRecord::class, recordIdsList = ids, clientRecordIdsList = emptyList()) }
    }

    suspend fun replaced(context: Context, old: CoreFood.Entry, new: CoreFood.Entry) {
        removed(context, listOf(old))
        wrote(context, listOf(new.copy(healthId = null)))
    }

    /** Other apps' nutrition for the last 30 days as daily totals per app, into the shared core. */
    suspend fun importDays(context: Context) {
        val client = client(context) ?: return
        if (!SwiftCore.available || !granted(context).containsAll(READ)) return
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val from = today.minusDays(WINDOW_DAYS - 1)
        val filter = TimeRangeFilter.between(from.atStartOfDay(zone).toInstant(), today.plusDays(1).atStartOfDay(zone).toInstant())
        data class Sum(var kcal: Double = 0.0, var protein: Double = 0.0, var carbs: Double = 0.0, var fat: Double = 0.0)
        val sums = HashMap<Pair<String, String>, Sum>()
        val own = context.packageName
        var token: String? = null
        val ok = runCatching {
            do {
                val page = client.readRecords(ReadRecordsRequest(NutritionRecord::class, filter, pageToken = token))
                for (r in page.records) {
                    val app = r.metadata.dataOrigin.packageName
                    if (app == own) continue
                    val day = r.startTime.atZone(r.startZoneOffset ?: ZoneOffset.UTC).withZoneSameInstant(zone).toLocalDate().toString()
                    val sum = sums.getOrPut(day to app) { Sum() }
                    sum.kcal += r.energy?.inKilocalories ?: 0.0
                    sum.protein += r.protein?.inGrams ?: 0.0
                    sum.carbs += r.totalCarbohydrate?.inGrams ?: 0.0
                    sum.fat += r.totalFat?.inGrams ?: 0.0
                }
                token = page.pageToken
            } while (!token.isNullOrEmpty())
        }.isSuccess
        // A failed read is not an empty one: only a complete read may replace the stored window.
        if (!ok) return
        val rows = JSONArray()
        sums.forEach { (key, sum) ->
            rows.put(JSONObject().put("day", key.first).put("source", key.second).put("calories", sum.kcal)
                .put("protein", sum.protein).put("carbs", sum.carbs).put("fat", sum.fat))
        }
        val preferred = com.noop.ui.NoopPrefs.of(context).getString(PREF_PREFERRED_SOURCE, "") ?: ""
        SwiftCore.call("food.importHealth", JSONObject().put("rows", rows).put("preferred", preferred)
            .put("from", from.toString()).put("to", today.toString()).toString())
    }
}
