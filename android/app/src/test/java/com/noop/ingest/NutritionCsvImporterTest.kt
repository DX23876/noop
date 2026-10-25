package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins NutritionCsvImporter.parse: nutrition CSV → long-format metricSeries rows under the
 * cross-platform contract shared with the Swift lane — source id "nutrition-csv" and keys
 * calories_in / protein_g / carbs_g / fat_g / weight (kg). Covers the three explicit header
 * shapes (NOOP native, MyFitnessPal per-meal, Cronometer daily summary), the tolerant
 * fallback (including lb→kg), and the skip rules.
 */
class NutritionCsvImporterTest {

    private val source = NutritionCsvImporter.SOURCE_ID

    private fun parse(csv: String) =
        NutritionCsvImporter.parse(CsvTable.fromData(csv.trimIndent().toByteArray()), source)

    private fun List<com.noop.data.MetricSeriesRow>.value(day: String, key: String): Double =
        first { it.day == day && it.key == key }.value

    @Test
    fun sourceIdMatchesTheCrossPlatformContract() {
        assertEquals("nutrition-csv", NutritionCsvImporter.SOURCE_ID)
    }

    // MARK: Shape 1 — NOOP native

    @Test
    fun nativeHeaderShapeMapsAllFiveKeys() {
        val rows = parse(
            """
            date,calories_in,protein_g,carbs_g,fat_g,weight
            2026-06-01,2150,160,220,70,81.4
            """
        )
        assertEquals(5, rows.size)
        assertTrue(rows.all { it.deviceId == source && it.day == "2026-06-01" })
        assertEquals(2150.0, rows.value("2026-06-01", "calories_in"), 1e-9)
        assertEquals(160.0, rows.value("2026-06-01", "protein_g"), 1e-9)
        assertEquals(220.0, rows.value("2026-06-01", "carbs_g"), 1e-9)
        assertEquals(70.0, rows.value("2026-06-01", "fat_g"), 1e-9)
        assertEquals(81.4, rows.value("2026-06-01", "weight"), 1e-9)
    }

    // MARK: Shape 2 — MyFitnessPal (per-meal rows sum per day)

    @Test
    fun myFitnessPalMealRowsSumPerDay() {
        val rows = parse(
            """
            Date,Meal,Calories,Protein (g),Carbohydrates (g),Fat (g)
            2026-06-01,Breakfast,520,30,55,18
            2026-06-01,Lunch,700,45,80,22
            2026-06-02,Breakfast,480,28,50,16
            """
        )
        assertEquals(1220.0, rows.value("2026-06-01", "calories_in"), 1e-9)
        assertEquals(75.0, rows.value("2026-06-01", "protein_g"), 1e-9)
        assertEquals(135.0, rows.value("2026-06-01", "carbs_g"), 1e-9)
        assertEquals(40.0, rows.value("2026-06-01", "fat_g"), 1e-9)
        assertEquals(480.0, rows.value("2026-06-02", "calories_in"), 1e-9)
        // No weight column → no weight rows.
        assertTrue(rows.none { it.key == "weight" })
        assertEquals(8, rows.size)
    }

    // MARK: Shape 3 — Cronometer daily summary

    @Test
    fun cronometerDailySummaryShape() {
        val rows = parse(
            """
            Date,Completed,Energy (kcal),Protein (g),Carbs (g),Fat (g)
            2026-06-01,true,"2,154.5",161.2,230.8,71.9
            """
        )
        // "Energy (kcal)" → calories_in, including the quoted thousands separator.
        assertEquals(2154.5, rows.value("2026-06-01", "calories_in"), 1e-9)
        assertEquals(161.2, rows.value("2026-06-01", "protein_g"), 1e-9)
        assertEquals(230.8, rows.value("2026-06-01", "carbs_g"), 1e-9)
        assertEquals(71.9, rows.value("2026-06-01", "fat_g"), 1e-9)
        assertEquals(4, rows.size)
    }

    // MARK: Tolerant fallback

    @Test
    fun tolerantFallbackHeadersAndPoundsConvertToKg() {
        val rows = parse(
            """
            Log Date,Total Energy (kcal),Protein (grams),Net Carbs,Total Fat (g),Body Weight (lbs)
            2026-06-03,1990,150,180,60,180
            """
        )
        assertEquals(1990.0, rows.value("2026-06-03", "calories_in"), 1e-9)
        assertEquals(150.0, rows.value("2026-06-03", "protein_g"), 1e-9)
        assertEquals(180.0, rows.value("2026-06-03", "carbs_g"), 1e-9)
        assertEquals(60.0, rows.value("2026-06-03", "fat_g"), 1e-9)
        assertEquals(180 * NutritionCsvImporter.LB_TO_KG, rows.value("2026-06-03", "weight"), 1e-6)
    }

    @Test
    fun saturatedFatAndBurnedEnergyAreNotMistakenForIntake() {
        val cols = NutritionCsvImporter.resolveColumns(
            listOf("date", "saturated_fat_g", "energy_burned_cal", "calories", "body_fat_pct")
        )!!
        assertEquals("calories", cols.calories)
        assertNull(cols.fat) // saturated/body fat never binds the total-fat key
        val rows = parse(
            """
            Date,Saturated Fat (g),Calories
            2026-06-01,12,2000
            """
        )
        assertEquals(2000.0, rows.value("2026-06-01", "calories_in"), 1e-9)
        assertTrue(rows.none { it.key == "fat_g" })
    }

    // MARK: Skip rules

    @Test
    fun unparsableDatesAndBlankCellsAreSkipped() {
        val rows = parse(
            """
            date,calories_in,protein_g
            not-a-date,2000,150
            2026-06-04,,150
            """
        )
        assertEquals(1, rows.size)
        assertEquals("protein_g", rows.single().key)
        assertEquals("2026-06-04", rows.single().day)
        assertEquals(150.0, rows.single().value, 1e-9)
    }

    @Test
    fun unrecognisableHeadersYieldNoRows() {
        val rows = parse(
            """
            foo,bar
            1,2
            """
        )
        assertTrue(rows.isEmpty())
        assertNull(NutritionCsvImporter.resolveColumns(listOf("foo", "bar")))
    }

    // MARK: Date formats

    @Test
    fun slashedDatesDefaultToUsMonthFirstUnlessImpossible() {
        val rows = parse(
            """
            date,calories_in
            06/02/2026,1800
            13/02/2026,1900
            2026/06/05,2000
            """
        )
        assertEquals(1800.0, rows.value("2026-06-02", "calories_in"), 1e-9) // US month-first
        assertEquals(1900.0, rows.value("2026-02-13", "calories_in"), 1e-9) // 13 forces day-first
        assertEquals(2000.0, rows.value("2026-06-05", "calories_in"), 1e-9) // ISO with slashes
    }

    @Test
    fun isoDatetimeAndDateOnlyCellsResolveToTheirDay() {
        assertEquals("2026-06-01", NutritionCsvImporter.parseDay("2026-06-01 08:30"))
        assertEquals("2026-06-01", NutritionCsvImporter.parseDay("2026-06-01T08:30:00Z"))
        assertNull(NutritionCsvImporter.parseDay(""))
        assertNull(NutritionCsvImporter.parseDay("31/31/2026")) // not a real date either way
    }

    @Test
    fun lastWeightOfTheDayWinsAndNegativesAreIgnored() {
        val rows = parse(
            """
            date,weight,calories_in
            2026-06-01,82.0,-5
            2026-06-01,81.2,
            """
        )
        assertEquals(81.2, rows.value("2026-06-01", "weight"), 1e-9)
        assertTrue(rows.none { it.key == "calories_in" }) // negative intake skipped
    }
}
