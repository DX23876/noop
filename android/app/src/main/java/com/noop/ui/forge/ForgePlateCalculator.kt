package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreTraining
import com.noop.ui.NoopPrefs
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitSystem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.text.NumberFormat
import java.util.UUID

/**
 * Fork (DX23876), Android parity: the plate calculator of the iOS strength session (`TrainingPlateCalculatorView`).
 * The loading comes from the shared core (`PlateCalculator`); bar, plates and equipment profiles are kept per weight
 * unit under the iOS keys, so a pound gym keeps its own setup.
 */
private object PlatePrefs {
    private const val POUNDS_PER_KG = 2.20462262185
    fun keys(pounds: Boolean) = if (pounds)
        Keys("training.plateCalculator.barLbKg", "training.plateCalculator.availableLbKg",
             "training.plateCalculator.profilesLb", "training.plateCalculator.selectedProfileLb")
    else Keys("training.plateCalculator.barKg", "training.plateCalculator.available",
              "training.plateCalculator.profiles", "training.plateCalculator.selectedProfile")
    data class Keys(val bar: String, val available: String, val profiles: String, val selected: String)

    fun standard(pounds: Boolean): List<Double> =
        if (pounds) listOf(55.0, 45.0, 35.0, 25.0, 10.0, 5.0, 2.5).map { it / POUNDS_PER_KG }
        else listOf(25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25, 1.0, 0.5)
    fun defaultBar(pounds: Boolean) = if (pounds) 45 / POUNDS_PER_KG else 20.0
    fun defaultAvailable(pounds: Boolean): List<Double> =
        if (pounds) standard(true) else listOf(25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25)
}

private data class EquipmentProfile(val id: String, val name: String, val barKg: Double, val platesKg: List<Double>)

@Composable
internal fun ForgePlateCalculator(targetKg: Double, onClose: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { NoopPrefs.of(context) }
    val units = strengthUnits()
    val pounds = units == UnitSystem.IMPERIAL
    val keys = PlatePrefs.keys(pounds)
    var target by remember { mutableStateOf(targetKg.coerceAtLeast(0.0)) }
    var bar by remember(pounds) { mutableStateOf(prefs.getString(keys.bar, null)?.toDoubleOrNull() ?: PlatePrefs.defaultBar(pounds)) }
    var available by remember(pounds) {
        mutableStateOf(prefs.getString(keys.available, null)?.split(',')?.mapNotNull { it.toDoubleOrNull() }?.filter { it > 0 }
                           ?: PlatePrefs.defaultAvailable(pounds))
    }
    var profiles by remember(pounds) { mutableStateOf(readProfiles(prefs.getString(keys.profiles, null))) }
    var selected by remember(pounds) { mutableStateOf(prefs.getString(keys.selected, "") ?: "") }
    var profileName by remember { mutableStateOf("") }
    fun saveBar(kg: Double) { bar = kg; prefs.edit().putString(keys.bar, kg.toString()).apply() }
    fun saveAvailable(list: List<Double>) {
        available = list.sortedDescending(); prefs.edit().putString(keys.available, available.joinToString(",")).apply()
    }
    fun saveProfiles(list: List<EquipmentProfile>, selectedId: String) {
        profiles = list; selected = selectedId
        prefs.edit().putString(keys.profiles, writeProfiles(list)).putString(keys.selected, selectedId).apply()
    }
    val loading by produceState<CoreTraining.PlateLoading?>(null, target, bar, available) {
        value = withContext(Dispatchers.IO) { CoreTraining.plates(target, bar, available) }
    }
    fun weight(kg: Double) = "${number(TrainingSetInput.massForInput(kg, units))} ${UnitFormatter.massUnit(units)}"
    BackHandler { onClose() }

    SettingsColumn {
        PageTitle(stringResource(R.string.forge_pl_title), onClose)
        SettingsCard(stringResource(R.string.forge_pl_profiles), null) {
            profiles.sortedBy { it.name.lowercase() }.forEach { profile ->
                Row(Modifier.fillMaxWidth().clickable {
                        saveBar(profile.barKg); saveAvailable(profile.platesKg)
                        saveProfiles(profiles, profile.id); profileName = profile.name
                    }.padding(vertical = ForgeMetrics.space1), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(profile.name, style = Forge.type.body, color = Forge.colors.text)
                        Text(stringResource(R.string.forge_pl_profile_line, profile.platesKg.size, weight(profile.barKg)),
                             style = Forge.type.caption, color = Forge.colors.textTertiary)
                    }
                    if (selected == profile.id) Icon(Icons.Rounded.Check, contentDescription = null, tint = Forge.colors.accent)
                    IconButton(onClick = { saveProfiles(profiles - profile, if (selected == profile.id) "" else selected) }) {
                        Icon(Icons.Rounded.Delete, stringResource(R.string.forge_training_remove_exercise), tint = Forge.colors.textTertiary)
                    }
                }
                RowDivider()
            }
            OutlinedTextField(profileName, { profileName = it }, Modifier.fillMaxWidth(), singleLine = true,
                              placeholder = { Text(stringResource(R.string.forge_pl_profile_name)) })
            TextButton(enabled = profileName.isNotBlank(), onClick = {
                val name = profileName.trim()
                val existing = profiles.firstOrNull { it.name.equals(name, ignoreCase = true) }
                val profile = EquipmentProfile(existing?.id ?: UUID.randomUUID().toString().uppercase(), name, bar, available)
                saveProfiles(profiles.filterNot { it.id == profile.id } + profile, profile.id)
            }) { Text(stringResource(R.string.forge_pl_save), color = Forge.colors.accent) }
        }
        SettingsCard(stringResource(R.string.forge_pl_target), null) {
            WeightField(stringResource(R.string.forge_pl_total), target, units) { target = it }
            RowDivider()
            WeightField(stringResource(R.string.forge_pl_bar), bar, units) { saveBar(it) }
        }
        SettingsCard(stringResource(R.string.forge_pl_available), null) {
            PlatePrefs.standard(pounds).forEachIndexed { i, plate ->
                if (i > 0) RowDivider()
                val on = available.any { kotlin.math.abs(it - plate) < 1e-6 }
                ToggleRow(weight(plate), null, on) { enable ->
                    saveAvailable(if (enable) available + plate else available.filterNot { kotlin.math.abs(it - plate) < 1e-6 })
                }
            }
        }
        SettingsCard(stringResource(R.string.forge_pl_each_side), null) {
            val l = loading
            if (l == null) {
                Text(stringResource(R.string.forge_pl_min_bar), style = Forge.type.body, color = Forge.colors.textSecondary)
            } else {
                if (l.platesPerSideKg.isEmpty()) {
                    Text(stringResource(R.string.forge_pl_bar_only), style = Forge.type.body, color = Forge.colors.textSecondary)
                } else {
                    Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = ForgeMetrics.space1),
                        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        l.platesPerSideKg.forEach { plate ->
                            val (w, h) = when { plate >= 20 -> 58 to 72; plate >= 10 -> 50 to 62; else -> 42 to 52 }
                            Box(Modifier.size(w.dp, h.dp).background(Forge.colors.accent, RoundedCornerShape(8.dp)),
                                contentAlignment = Alignment.Center) {
                                Text(number(TrainingSetInput.massForInput(plate, units)),
                                     style = Forge.type.subhead.copy(fontWeight = FontWeight.Bold), color = Color.White)
                            }
                        }
                    }
                }
                Row {
                    Text(stringResource(R.string.forge_pl_achievable), style = Forge.type.body, color = Forge.colors.text,
                         modifier = Modifier.weight(1f))
                    Text(weight(l.achievableTotalKg), style = Forge.type.body, color = Forge.colors.textSecondary)
                }
                if (l.remainderKg > 0.001) Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Info, contentDescription = null, tint = Forge.colors.textSecondary, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.forge_pl_cannot, weight(l.remainderKg)), style = Forge.type.caption,
                         color = Forge.colors.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun WeightField(label: String, kg: Double, units: UnitSystem, onChange: (Double) -> Unit) {
    var text by remember(units) { mutableStateOf(number(TrainingSetInput.massForInput(kg, units))) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
        OutlinedTextField(text, { input ->
            text = input.filter { it.isDigit() || it == '.' || it == ',' }
            text.replace(',', '.').toDoubleOrNull()?.let { onChange(TrainingSetInput.massForStore(it, units)) }
        }, Modifier.width(110.dp), singleLine = true,
            textStyle = Forge.type.body.copy(textAlign = TextAlign.End, color = Forge.colors.text),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
        Spacer(Modifier.width(ForgeMetrics.space2))
        Text(UnitFormatter.massUnit(units), style = Forge.type.body, color = Forge.colors.textSecondary)
    }
}

private fun number(value: Double): String =
    NumberFormat.getNumberInstance().apply { minimumFractionDigits = 0; maximumFractionDigits = 2 }.format(value)

/** iOS's `[TrainingEquipmentProfile]` JSON (id, name, barKg, platesKg). */
private fun readProfiles(json: String?): List<EquipmentProfile> = runCatching {
    val a = JSONArray(json ?: "[]")
    (0 until a.length()).map { i ->
        val o = a.getJSONObject(i); val p = o.getJSONArray("platesKg")
        EquipmentProfile(o.getString("id"), o.getString("name"), o.getDouble("barKg"), (0 until p.length()).map(p::getDouble))
    }
}.getOrDefault(emptyList())

private fun writeProfiles(list: List<EquipmentProfile>): String = JSONArray(list.map { p ->
    JSONObject().put("id", p.id).put("name", p.name).put("barKg", p.barKg).put("platesKg", JSONArray(p.platesKg))
}).toString()

