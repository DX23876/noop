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
    ) {
        fun scaled(grams: Double): Map<String, Double> = per100g.mapValues { it.value * grams / 100.0 }
    }

    data class Entry(
        val id: String, val loggedAt: Long, val day: String, val meal: String?, val foodId: String?, val name: String,
        val brand: String?, val grams: Double?, val portionLabel: String?, val totals: Map<String, Double>,
        val per100g: Map<String, Double>?, val origin: String, val healthId: String?,
    )

    data class Meal(val kind: String, val start: Long, val entries: List<Entry>, val totals: Map<String, Double>)
    data class Day(val day: String, val meals: List<Meal>, val totals: Map<String, Double>)
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
            Meal(meal.optString("kind"), meal.optLong("start"), entries(meal), numbers(meal.optJSONObject("totals")))
        }, numbers(json.optJSONObject("totals")))
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
}
