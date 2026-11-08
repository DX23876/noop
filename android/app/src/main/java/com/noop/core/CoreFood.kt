package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), decision 2026-11-08: the food log from the shared core (`CoreFood.swift`). Search, the day,
 * logging, recipes, packs and the label reader all run in Swift; this only turns the JSON into Kotlin values.
 * Blocking; call off the main thread. Health Connect writing is [com.noop.ingest.FoodHealthConnect]'s.
 */
object CoreFood {
    /** A food, nutrients per 100 g under the canonical names (`energy_kcal`, `protein_g`, ...). */
    data class Item(
        val json: JSONObject, val id: String, val source: String, val name: String, val brand: String?,
        val servingG: Double?, val servingLabel: String?, val per100g: Map<String, Double>, val barcode: String?,
        val estimatedFrom: String? = null, val estimatedCount: Int = 0,
    ) {
        fun scaled(grams: Double): Map<String, Double> = per100g.mapValues { it.value * grams / 100.0 }
    }

    data class Entry(
        val id: String, val loggedAt: Long, val day: String, val meal: String?, val foodId: String?, val name: String,
        val brand: String?, val grams: Double?, val portionLabel: String?, val totals: Map<String, Double>,
        val per100g: Map<String, Double>?, val origin: String, val healthId: String?,
    )

    /** [motif] names the still life the meal card shows (`FoodGroupMotif`), null without one. */
    data class Meal(val kind: String, val start: Long, val entries: List<Entry>, val totals: Map<String, Double>, val motif: String? = null)
    data class WeekDay(val day: String, val totals: Map<String, Double>) { val logged get() = totals.isNotEmpty() }
    data class ScorePart(val component: String, val points: Double, val amountPerDay: Double)
    data class Score(val score: Double, val parts: List<ScorePart>, val loggedDays: Int, val processedShare: Double?)
    data class Week(val days: List<WeekDay>, val loggedDays: Int, val score: Score?)
    data class Habit(val kind: String, val days: Int, val entries: List<Entry>, val motif: String?)
    data class SentencePoint(val nutrient: String, val plenty: Boolean, val watch: Boolean)
    data class Day(val day: String, val meals: List<Meal>, val totals: Map<String, Double>, val otherKcal: Double?, val otherSource: String?)
    data class Pack(val country: String, val iso: String, val rows: Int, val builtAt: String, val sha256: String)
    data class Label(val per100: Map<String, Double>, val servingAmount: Double?, val complete: Boolean)
    data class CartLine(val item: Item, val grams: Double, val portionLabel: String? = null)

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

    private fun JSONObject.text(key: String): String? = if (isNull(key) || !has(key)) null else optString(key).ifEmpty { null }
    private fun JSONObject.number(key: String): Double? = if (isNull(key) || !has(key)) null else optDouble(key).takeIf { !it.isNaN() }

    fun item(json: JSONObject) = Item(
        json, json.optString("id"), json.optString("source"), json.optString("name"), json.text("brand"),
        json.number("servingG"), json.text("servingLabel"), numbers(json.optJSONObject("per100g")), json.text("barcode"),
        json.text("estimatedFrom"), json.optJSONArray("estimatedKeys")?.length() ?: 0,
    )

    private fun entry(json: JSONObject) = Entry(
        json.optString("id"), json.optLong("loggedAt"), json.optString("day"), json.text("meal"), json.text("foodId"),
        json.optString("name"), json.text("brand"), json.number("grams"), json.text("portionLabel"),
        numbers(json.optJSONObject("totals")), json.optJSONObject("per100g")?.let(::numbers), json.optString("origin"),
        json.text("healthId"),
    )

    private fun items(json: JSONObject?, key: String = "items"): List<Item> {
        val array = json?.optJSONArray(key) ?: return emptyList()
        return (0 until array.length()).mapNotNull { array.optJSONObject(it)?.let(::item) }
    }

    private fun entries(json: JSONObject?, key: String = "entries"): List<Entry> {
        val array = json?.optJSONArray(key) ?: return emptyList()
        return (0 until array.length()).mapNotNull { array.optJSONObject(it)?.let(::entry) }
    }

    /** Builds the BLS search file on first use. */
    fun prepare(): Boolean = call("food.prepare")?.optBoolean("ok") == true

    fun search(query: String, limit: Int = 40): List<Item> = items(call("food.search", JSONObject().put("query", query).put("limit", limit)))

    fun recents(): List<Pair<Item, Double?>> {
        val array = call("food.recents")?.optJSONArray("items") ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            val row = array.optJSONObject(index) ?: return@mapNotNull null
            val item = row.optJSONObject("item")?.let(::item) ?: return@mapNotNull null
            item to row.number("lastGrams")
        }
    }

    fun favourites(): List<Item> = items(call("food.favourites"))
    fun own(): List<Item> = items(call("food.own")) + items(call("food.recipes"))

    fun setFavourite(item: Item, on: Boolean) {
        call("food.setFavourite", JSONObject().put("foodId", item.id).put("name", item.name).put("on", on))
    }

    fun barcode(code: String): Item? = call("food.barcode", JSONObject().put("code", code))?.let(::item)

    fun day(day: String): Day? {
        val json = call("food.day", JSONObject().put("day", day)) ?: return null
        val meals = json.optJSONArray("meals") ?: JSONArray()
        return Day(json.optString("day"), (0 until meals.length()).mapNotNull { index ->
            val meal = meals.optJSONObject(index) ?: return@mapNotNull null
            Meal(meal.optString("kind"), meal.optLong("start"), entries(meal), numbers(meal.optJSONObject("totals")), meal.text("motif"))
        }, numbers(json.optJSONObject("totals")), json.number("otherKcal"), json.text("otherSource"))
    }

    fun logCart(lines: List<CartLine>, atEpoch: Long, meal: String?, origin: String = "search"): List<Entry> {
        val array = JSONArray()
        lines.forEach { array.put(JSONObject().put("item", it.item.json).put("grams", it.grams).put("portionLabel", it.portionLabel)) }
        val args = JSONObject().put("items", array).put("at", atEpoch).put("origin", origin)
        if (meal != null) args.put("meal", meal)
        return entries(call("food.logCart", args))
    }

    fun quick(name: String, kcal: Double, protein: Double?, carbs: Double?, fat: Double?, atEpoch: Long, meal: String?): List<Entry> {
        val args = JSONObject().put("name", name).put("kcal", kcal).put("at", atEpoch)
        protein?.let { args.put("proteinG", it) }; carbs?.let { args.put("carbsG", it) }; fat?.let { args.put("fatG", it) }
        meal?.let { args.put("meal", it) }
        return entries(call("food.quick", args))
    }

    /** The edited entry and the one it replaced, so the Health Connect record can be swapped. */
    fun edit(id: String, grams: Double?, atEpoch: Long?, meal: String?, changeMeal: Boolean): Pair<Entry, Entry>? {
        val args = JSONObject().put("id", id)
        grams?.let { args.put("grams", it) }; atEpoch?.let { args.put("at", it) }
        if (changeMeal) args.put("meal", meal ?: JSONObject.NULL)
        val json = call("food.edit", args) ?: return null
        return entry(json.getJSONObject("entry")) to entry(json.getJSONObject("previous"))
    }

    fun delete(ids: List<String>): List<Entry> = entries(call("food.delete", JSONObject().put("ids", JSONArray(ids))), "removed")

    fun copy(ids: List<String>, days: List<String>): List<Entry> =
        entries(call("food.copy", JSONObject().put("ids", JSONArray(ids)).put("days", JSONArray(days))))

    fun setHealthId(id: String, healthId: String?) {
        call("food.setHealthId", JSONObject().put("id", id).put("healthId", healthId ?: JSONObject.NULL))
    }

    fun saveOwn(item: Item, origin: String): Item? =
        call("food.saveOwn", JSONObject().put("item", item.json).put("origin", origin))?.let(::item)

    fun makeRecipe(name: String, ids: List<String>, servings: Double): Item? =
        call("food.makeRecipe", JSONObject().put("name", name).put("ids", JSONArray(ids)).put("servings", servings))?.let(::item)

    fun parseLabel(lines: List<String>): Label? {
        val json = call("food.parseLabel", JSONObject().put("lines", JSONArray(lines))) ?: return null
        return Label(numbers(json.optJSONObject("per100")), json.number("servingAmount"), json.optBoolean("complete"))
    }

    fun packs(): List<Pack> {
        val array = call("food.packs")?.optJSONArray("packs") ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            val p = array.optJSONObject(index) ?: return@mapNotNull null
            Pack(p.optString("country"), p.optString("iso"), p.optInt("rows"), p.optString("builtAt"), p.optString("sha256"))
        }
    }

    /** Null on success, else the core's failure name (`checksumMismatch`, `notEnoughSpace`, ...). */
    fun installPack(path: String, sha256: String): String? {
        if (!SwiftCore.available) return "unavailable"
        val text = SwiftCore.call("food.installPack", JSONObject().put("path", path).put("sha256", sha256).toString()) ?: return "unavailable"
        return runCatching { JSONObject(text).optString("error").ifEmpty { null } }.getOrDefault("invalidArchive")
    }

    data class NutrientRow(val nutrient: String, val average: Double, val today: Double, val reference: Double?,
                           val atMost: Boolean, val source: String?, val coverage: Double, val estimatedShare: Double,
                           val modelShare: Double, val status: String,
                           val topFoods: List<Pair<String, Double>>)
    data class NutrientReport(val loggedDays: Int, val rows: List<NutrientRow>) {
        val fine get() = rows.count { it.status == "fine" }
        val judged get() = rows.count { it.status == "fine" || it.status == "attention" }
    }

    /** Seven days against the EFSA references for this person (`FoodNutrientReport` in the core). */
    data class Goals(val kcal: Double, val basis: String, val burnKcal: Double, val planDeltaKcal: Double,
                     val proteinG: Double?, val carbsG: Double?, val fatG: Double?)

    /** The calorie goal (the plan's or the wearer's fixed one) and its macro split (`FoodTargets` in the core). */
    fun goals(measured: Double?, allDays: Double?, formula: Double?, delta: Double?, fixedKcal: Double?,
              protein: Double?, carbs: Double?, fat: Double?): Goals? {
        val args = JSONObject()
        listOf("measuredMeanKcal" to measured, "allDaysMeanKcal" to allDays, "formulaTdeeKcal" to formula, "dailyDeltaKcal" to delta,
               "fixedKcal" to fixedKcal, "proteinPercent" to protein, "carbsPercent" to carbs, "fatPercent" to fat)
            .forEach { (k, v) -> v?.let { args.put(k, it) } }
        val json = call("food.goals", args) ?: return null
        val c = json.optJSONObject("calories") ?: return null
        val m = json.optJSONObject("macros")
        return Goals(c.optDouble("kcal"), c.optString("basis"), c.optDouble("burnKcal"), c.optDouble("planDeltaKcal"),
                     m?.optDouble("proteinG"), m?.optDouble("carbsG"), m?.optDouble("fatG"))
    }

    fun nutrients(day: String, sex: String, age: Int, weightKg: Double?, heightCm: Double?, energyKcal: Double?,
                  span: String = "week"): NutrientReport? {
        val args = JSONObject().put("day", day).put("sex", sex).put("age", age).put("span", span)
        weightKg?.let { args.put("weightKg", it) }; heightCm?.let { args.put("heightCm", it) }; energyKcal?.let { args.put("energyKcal", it) }
        val json = call("food.nutrients", args) ?: return null
        val rows = json.optJSONArray("rows") ?: return null
        return NutrientReport(json.optInt("loggedDays"), (0 until rows.length()).mapNotNull { i ->
            val r = rows.optJSONObject(i) ?: return@mapNotNull null
            val ref = r.optJSONObject("reference")
            val top = r.optJSONArray("topFoods") ?: JSONArray()
            NutrientRow(r.optString("nutrient"), r.optDouble("average"), r.optDouble("today"),
                ref?.optDouble("amount"), ref?.optString("kind") == "atMost", ref?.optString("source"),
                r.optDouble("coverage"), r.optDouble("estimatedShare", 0.0), r.optDouble("modelShare", 0.0), r.optString("status"),
                (0 until top.length()).mapNotNull { j -> top.optJSONObject(j)?.let { it.optString("name") to it.optDouble("amount") } })
        })
    }

    fun removePack(country: String) { call("food.removePack", JSONObject().put("country", country)) }

    /** Open Food Facts online (only in the online mode); null when the network failed. */
    fun onlineSearch(query: String, countries: List<String>, language: String): List<Item>? {
        val json = callRaw("food.onlineSearch", JSONObject().put("query", query).put("countries", JSONArray(countries)).put("language", language))
            ?: return null
        if (json.has("error")) return null
        return items(json)
    }

    fun onlineBarcode(code: String, language: String): Item? =
        call("food.onlineBarcode", JSONObject().put("code", code).put("language", language))?.let(::item)

    /** The cart's products with missing nutrients borrowed from the closest BLS food; unchanged ones as they were. */
    fun coachEnrich(items: List<Item>): List<Item>? {
        val array = JSONArray(); items.forEach { array.put(it.json) }
        val json = call("coach.foodEnrich", JSONObject().put("items", array)) ?: return null
        return items(json).takeIf { it.size == items.size }
    }

    fun coachReadsPhotos(): Boolean = call("coach.foodPhotos")?.optBoolean("reads") == true

    /** A described or photographed meal as cart lines and the foods the coach named but the phone did not find. */
    fun coachCart(description: String, imageBase64: String?): Pair<List<CartLine>, List<String>>? {
        val args = JSONObject().put("description", description)
        imageBase64?.let { args.put("image", it).put("mimeType", "image/jpeg") }
        val json = call("coach.foodCart", args) ?: return null
        val lines = json.optJSONArray("lines") ?: JSONArray()
        val unmatched = json.optJSONArray("unmatched") ?: JSONArray()
        return (0 until lines.length()).mapNotNull { index ->
            val line = lines.optJSONObject(index) ?: return@mapNotNull null
            CartLine(item(line.getJSONObject("item")), line.optDouble("grams"))
        } to (0 until unmatched.length()).mapNotNull { unmatched.optJSONObject(it)?.optString("name") }
    }

    private fun callRaw(op: String, args: JSONObject): JSONObject? {
        if (!SwiftCore.available) return null
        val text = SwiftCore.call(op, args.toString()) ?: return null
        return runCatching { JSONObject(text) }.getOrNull()
    }

    /** A food item from an online result (Open Food Facts JSON already converted by Kotlin into the shared shape). */
    fun itemJson(id: String, source: String, name: String, brand: String?, servingG: Double?, servingLabel: String?,
                 per100g: Map<String, Double>, barcode: String?): Item {
        val json = JSONObject().put("id", id).put("source", source).put("name", name).put("per100g", JSONObject(per100g))
        brand?.let { json.put("brand", it) }; servingG?.let { json.put("servingG", it) }
        servingLabel?.let { json.put("servingLabel", it) }; barcode?.let { json.put("barcode", it) }
        return item(json)
    }

    /** The week strip's seven days and, when [withScore], the week's nutrition score (null below five logged days). */
    fun week(day: String, today: String, withScore: Boolean, sex: String): Week? {
        val json = call("food.week", JSONObject().put("day", day).put("today", today).put("score", withScore).put("sex", sex)) ?: return null
        val days = json.optJSONArray("days") ?: JSONArray()
        val score = json.optJSONObject("score")?.let { s ->
            val parts = s.optJSONArray("parts") ?: JSONArray()
            Score(s.optDouble("score"), (0 until parts.length()).mapNotNull { i ->
                parts.optJSONObject(i)?.let { ScorePart(it.optString("component"), it.optDouble("points"), it.optDouble("amountPerDay")) }
            }, s.optInt("loggedDays"), s.number("processedShare"))
        }
        return Week((0 until days.length()).mapNotNull { i ->
            days.optJSONObject(i)?.let { WeekDay(it.optString("day"), numbers(it.optJSONObject("totals"))) }
        }, json.optInt("loggedDays"), score)
    }

    /** "As usual": a meal eaten on several of the last days, offered at its time of day; null without one. */
    fun habit(day: String, nowEpoch: Long): Habit? {
        val json = call("food.habit", JSONObject().put("day", day).put("now", nowEpoch)) ?: return null
        return Habit(json.optString("kind"), json.optInt("days"), entries(json), json.text("motif"))
    }

    /** The evening sentence's observations for [day], read against the same goals as the plate and the card. */
    fun sentence(day: String, proteinGoalG: Double?, sex: String, age: Int, weightKg: Double?, heightCm: Double?, energyKcal: Double?): List<SentencePoint> {
        val args = JSONObject().put("day", day).put("sex", sex).put("age", age)
        proteinGoalG?.let { args.put("proteinGoalG", it) }; weightKg?.let { args.put("weightKg", it) }
        heightCm?.let { args.put("heightCm", it) }; energyKcal?.let { args.put("energyKcal", it) }
        val array = call("food.sentence", args)?.optJSONArray("points") ?: return emptyList()
        return (0 until array.length()).mapNotNull { i ->
            array.optJSONObject(i)?.let { SentencePoint(it.optString("nutrient"), it.optBoolean("plenty"), it.optBoolean("watch")) }
        }
    }
}
