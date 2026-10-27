package com.noop.ui.forge

import com.noop.core.CoreTrainingLibrary
import java.text.Normalizer
import java.util.Locale

/** Presentation-only text and facet filtering over the core's reviewed library metadata. */
internal data class ExerciseLibraryFilters(val query: String = "", val region: String? = null,
                                          val muscle: String? = null, val equipment: String? = null,
                                          val mode: String? = null, val favoritesOnly: Boolean = false) {
    fun apply(rows: List<CoreTrainingLibrary.Row>, favorites: Set<String>,
              muscles: Map<String, String>, equipmentNames: Map<String, String>): List<CoreTrainingLibrary.Row> {
        val needle = searchable(query.trim())
        return rows.filter { e ->
            (region == null || region == e.region) &&
                (muscle == null || muscle in e.matchingMuscles) &&
                (equipment == null || equipment in e.equipment) &&
                (mode == null || mode == e.mode) && (!favoritesOnly || e.id in favorites) &&
                (needle.isEmpty() || (listOf(e.title) + e.aliases + e.matchingMuscles + e.equipment +
                    e.matchingMuscles.mapNotNull(muscles::get) + e.equipment.mapNotNull(equipmentNames::get))
                    .any { searchable(it).contains(needle) })
        }
    }
    companion object {
        private fun searchable(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFD)
            .replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT)
    }
}
