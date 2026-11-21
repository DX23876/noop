package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), owner 2026-11-21: kept meals, the day's, week's and month's food note, where a day stands against
 * the goal, badges and the reminders' content, all from the shared core (`CoreFoodNotes.swift` over `FoodQuality`,
 * `FoodGoalState`, `FoodBadges`, `FoodNotice`). This only turns the JSON into Kotlin values; the iPhone reads the
 * same resolvers, so both show the same note for the same log. Blocking; call off the main thread.
 */
object CoreFoodNotes {
    data class MealItem(val foodId: String?, val name: String, val grams: Double, val per100g: Map<String, Double>) {
        val kcal get() = (per100g["energy_kcal"] ?: 0.0) * grams / 100.0
        val proteinG get() = (per100g["protein_g"] ?: 0.0) * grams / 100.0
    }
    data class Meal(val id: String, val name: String, val items: List<MealItem>, val kcal: Double, val motif: String?,
                    val createdAt: Int) {
        val foods get() = items.joinToString(", ") { it.name.substringBefore(", ") }
    }
    data class Part(val component: String, val points: Double, val amountPerDay: Double)
    data class Note(val day: String, val span: Int, val score: Double, val parts: List<Part>, val loggedDays: Int,
                    val placedShare: Double, val processedShare: Double?, val provisional: Boolean) {
        val uncertain get() = placedShare < 0.70
    }
    data class Goal(val energy: String, val ratio: Double, val proteinMet: Boolean?, val carbsWithinCap: Boolean?)
    data class Earned(val key: String, val day: String)
    data class Quality(val day: Note?, val nothing: Boolean, val missingLogged: Double?, val missingNeeded: Double?,
                       val week: Note?, val month: Note?, val trend: List<Note>, val goal: Goal?,
                       val earned: List<Earned>, val streak: Int)
    data class Recap(val kind: String, val score: Double?, val previous: Double?, val strongest: String?, val weakest: String?,
                     val goal: String?)
    data class Gap(val proteinG: Double?, val vegetablePortions: Double?)

    /** Every badge in the collection's order, the same keys as iOS (`FoodText.allBadges`). */
    val allBadges = listOf("firstFullWeek", "days30", "days100", "goodWeek", "goodMonth") +
        listOf("vegetables", "fruit", "wholeGrains", "sugaryDrinks", "nutsLegumes", "redMeat", "fishOmega3", "polyFats",
               "sodium", "alcohol").map { "habit.$it" }

    private fun call(op: String, args: JSONObject = JSONObject()): JSONObject? {
        if (!SwiftCore.available) return null
        val text = SwiftCore.call(op, args.toString()) ?: return null
        if (text == "null") return null
        return runCatching { JSONObject(text) }.getOrNull()?.takeIf { !it.has("error") }
    }

    private fun numbers(json: JSONObject?): Map<String, Double> {
        if (json == null) return emptyMap()
        return json.keys().asSequence().associateWith { json.optDouble(it) }.filterValues { !it.isNaN() }
    }
    private fun JSONObject.number(key: String): Double? = if (isNull(key) || !has(key)) null else optDouble(key).takeIf { !it.isNaN() }
    private fun JSONObject.text(key: String): String? = if (isNull(key) || !has(key)) null else optString(key).ifEmpty { null }
    private fun JSONObject.flag(key: String): Boolean? = if (isNull(key) || !has(key)) null else optBoolean(key)

    private fun meal(json: JSONObject): Meal {
        val items = json.optJSONArray("items") ?: JSONArray()
        return Meal(json.optString("id"), json.optString("name"), (0 until items.length()).mapNotNull { i ->
            items.optJSONObject(i)?.let { MealItem(it.text("foodId"), it.optString("name"), it.optDouble("grams"), numbers(it.optJSONObject("per100g"))) }
        }, json.optDouble("kcal"), json.text("motif"), json.optInt("createdAt"))
    }

    private fun note(json: JSONObject?): Note? {
        if (json == null) return null
        val parts = json.optJSONArray("parts") ?: JSONArray()
        return Note(json.optString("day"), json.optInt("span"), json.optDouble("score"), (0 until parts.length()).mapNotNull { i ->
            parts.optJSONObject(i)?.let { Part(it.optString("component"), it.optDouble("points"), it.optDouble("amountPerDay")) }
        }, json.optInt("loggedDays"), json.optDouble("placedShare", 1.0), json.number("processedShare"), json.optBoolean("provisional"))
    }

    fun meals(): List<Meal> {
        val array = call("food.meals")?.optJSONArray("meals") ?: return emptyList()
        return (0 until array.length()).mapNotNull { array.optJSONObject(it)?.let(::meal) }
    }

    /** Keeps a meal from logged entries, from the cart, or (with [id]) the builder's items. */
    fun saveFromEntries(name: String, entryIds: List<String>): Meal? =
        call("food.saveMeal", JSONObject().put("name", name).put("entryIds", JSONArray(entryIds)))?.let(::meal)

    fun saveFromCart(name: String, lines: List<CoreFood.CartLine>): Meal? =
        call("food.saveMeal", JSONObject().put("name", name).put("cart", JSONArray(lines.map {
            JSONObject().put("item", it.item.json).put("grams", it.grams)
        })))?.let(::meal)

    fun saveItems(id: String?, name: String, items: List<MealItem>, createdAt: Int?): Meal? {
        val args = JSONObject().put("name", name).put("items", JSONArray(items.map { item ->
            JSONObject().put("foodId", item.foodId ?: JSONObject.NULL).put("name", item.name).put("grams", item.grams)
                .put("per100g", JSONObject(item.per100g))
        }))
        id?.let { args.put("id", it) }; createdAt?.let { args.put("createdAt", it) }
        return call("food.saveMeal", args)?.let(::meal)
    }

    fun delete(id: String) { call("food.deleteMeal", JSONObject().put("id", id)) }

    /** Logs a kept meal at [atEpoch]; the entries come back for Health Connect. */
    fun log(id: String, atEpoch: Long): List<CoreFood.Entry> {
        val json = call("food.logMeal", JSONObject().put("id", id).put("at", atEpoch)) ?: return emptyList()
        return CoreFood.entriesOf(json)
    }

    private fun profileArgs(today: String, sex: String, age: Int, weightKg: Double?, heightCm: Double?, dietForm: String?,
                            goalKcal: Double?, proteinG: Double?): JSONObject {
        val args = JSONObject().put("today", today).put("sex", sex).put("age", age)
        weightKg?.let { args.put("weightKg", it) }; heightCm?.let { args.put("heightCm", it) }
        dietForm?.let { args.put("dietForm", it) }; goalKcal?.let { args.put("goalKcal", it) }; proteinG?.let { args.put("proteinG", it) }
        return args
    }

    fun quality(day: String, today: String, sex: String, age: Int, weightKg: Double?, heightCm: Double?, dietForm: String?,
                goalKcal: Double?, proteinG: Double?): Quality? {
        val json = call("food.quality", profileArgs(today, sex, age, weightKg, heightCm, dietForm, goalKcal, proteinG).put("day", day))
            ?: return null
        val trend = json.optJSONArray("trend") ?: JSONArray()
        val earned = json.optJSONArray("earned") ?: JSONArray()
        return Quality(note(json.optJSONObject("day")), json.optBoolean("nothing"), json.number("missingLogged"),
            json.number("missingNeeded"), note(json.optJSONObject("week")), note(json.optJSONObject("month")),
            (0 until trend.length()).mapNotNull { note(trend.optJSONObject(it)) },
            json.optJSONObject("goal")?.let { Goal(it.optString("energy"), it.optDouble("ratio"), it.flag("proteinMet"), it.flag("carbsWithinCap")) },
            (0 until earned.length()).mapNotNull { i -> earned.optJSONObject(i)?.let { Earned(it.optString("key"), it.optString("day")) } },
            json.optInt("streak"))
    }

    fun recap(today: String, sex: String, age: Int, weightKg: Double?, heightCm: Double?, dietForm: String?,
              goalKcal: Double?, proteinG: Double?): Recap? {
        val json = call("food.recap", profileArgs(today, sex, age, weightKg, heightCm, dietForm, goalKcal, proteinG)) ?: return null
        return Recap(json.optString("kind"), json.number("score"), json.number("previous"), json.text("strongest"),
                     json.text("weakest"), json.text("goal"))
    }

    fun evening(today: String, proteinG: Double?): Gap? {
        val args = JSONObject().put("today", today); proteinG?.let { args.put("proteinG", it) }
        val json = call("food.evening", args) ?: return null
        val gap = Gap(json.number("proteinG"), json.number("vegetablePortions"))
        return if (gap.proteinG == null && gap.vegetablePortions == null) null else gap
    }

    /** When the reminders go, in minutes of the day: (morning, evening). */
    fun reminderTimes(wakeMinutes: Int, sleepNeedMinutes: Int): Pair<Int, Int> {
        val json = call("food.reminderTimes", JSONObject().put("wakeMinutes", wakeMinutes).put("sleepNeedMinutes", sleepNeedMinutes))
        return (json?.optInt("morning", 7 * 60 + 30) ?: (7 * 60 + 30)) to (json?.optInt("evening", 20 * 60) ?: (20 * 60))
    }

    /** The meal a time of day usually is (`FoodLog.MealKind.around`). */
    fun mealAround(epoch: Long): String = call("food.mealAround", JSONObject().put("at", epoch))?.optString("kind") ?: "snack"

    /** The still life of each food (`FoodGroupMotif`), keyed by food id; foods without one are left out. */
    fun motifs(items: List<CoreFood.Item>): Map<String, String> {
        if (items.isEmpty()) return emptyMap()
        val json = call("food.motifs", JSONObject().put("items", JSONArray(items.map {
            JSONObject().put("id", it.id).put("group", it.json.optString("group").ifEmpty { JSONObject.NULL })
        }))) ?: return emptyMap()
        return json.keys().asSequence().associateWith { json.optString(it) }
    }

    /** The day's energy with the cart when, while losing weight, it takes the day more than 20 % over the goal. */
    fun overWarning(dayKcal: Double, adding: Double, goalKcal: Double, losing: Boolean): Double? =
        call("food.overWarning", JSONObject().put("dayKcal", dayKcal).put("adding", adding).put("goalKcal", goalKcal)
            .put("losing", losing))?.number("kcal")
}
