package com.noop.ui

import android.content.Context
import com.noop.core.SwiftCore
import org.json.JSONObject

/**
 * Demo builds only: writes the demo account's BODY into the profile prefs.
 *
 * The demo account has a history in the store and, until now, no body at all, so every screen that starts
 * from the person read empty while everything around it was full: the calorie goal (whose formula burn
 * needs a weight, a height, years and a cohort), the heart-rate zones, the body composition, AgeLess. The
 * Nutrition tile said "– left today" over seven logged days because of it, on both phones at once
 * (2026-11-19).
 *
 * The figures are not Kotlin's to choose: they come from the shared dataset through `demo.person`, the same
 * ones the iPhone writes, so there is one demo person and not two. The weight is that dataset's last
 * weigh-in, so the profile and the scale agree.
 *
 * It refuses on a profile anybody has filled in.
 */
object DemoPerson {

    /** True when it wrote, false when a profile was already there or the core could not answer. */
    fun seedIfUnset(context: Context): Boolean {
        val profile = ProfileStore.from(context)
        if (!profile.isUnset()) return false
        val answer = if (SwiftCore.available) SwiftCore.call("demo.person", "{}") else null
        val person = runCatching { JSONObject(answer ?: return false) }.getOrNull() ?: return false
        if (!person.has("weightKg") || !person.has("ageYears")) return false
        profile.applyBackup(
            mapOf(
                "profile.age" to person.getInt("ageYears"),
                "profile.sex" to person.getString("sex"),
                "profile.weightKg" to person.getDouble("weightKg"),
                "profile.heightCm" to person.getDouble("heightCm"),
                "profile.waistCm" to person.getDouble("waistCm"),
            ),
        )
        return true
    }
}
