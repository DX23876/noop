package com.noop.ui.forge


import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import com.noop.R
import com.noop.core.CoreBody
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.util.Locale

/**
 * Fork (DX23876), Android parity plan 2.3: the Body screen after `BodyView`: weight and its weigh-ins, body fat with
 * the Navy tape estimate kept on its own line, and every circumference site with its change and how to measure it.
 * The shared core resolves the readings, comparisons and estimate.
 */
@Composable
internal fun ForgeBodyPage(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var body by remember { mutableStateOf<CoreBody.Snapshot?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    var measuring by remember { mutableStateOf(false) }
    var photos by remember { mutableStateOf(false) }
    androidx.activity.compose.BackHandler(enabled = photos) { photos = false }
    if (photos) {
        ForgeBodyPhotosPage(onBack = { photos = false })
        return
    }
    LaunchedEffect(revision) {
        body = withContext(Dispatchers.IO) { CoreRead.open(context); CoreBody.snapshot(context) }
        loaded = true
    }
    fun after(block: suspend () -> Boolean) { scope.launch { if (withContext(Dispatchers.IO) { block() }) revision++ } }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_body_title), onBack)
        val b = body
        if (b == null) {
            Text(stringResource(if (loaded) R.string.forge_body_nothing else R.string.forge_goals_loading),
                 style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        WeightCard(b, onLog = { kg -> after { CoreBody.logWeight(kg) } }, onDelete = { id -> after { CoreBody.deleteWeight(id) } })
        BodyFatCard(b)
        if (measuring) {
            MeasureCard(b, onCancel = { measuring = false }) { values ->
                after { CoreBody.record(context, values).also { if (it) measuring = false } }
            }
        } else {
            SitesCard(b, onMeasure = { measuring = true }, onDelete = { id -> after { CoreBody.deleteMeasurement(context, id) } })
        }
        SettingsCard(title = null, blurb = null) {
            LinkRow(stringResource(R.string.forge_bp_title), stringResource(R.string.forge_bp_then_now)) { photos = true }
        }
    }
}

@Composable
private fun WeightCard(b: CoreBody.Snapshot, onLog: (Double) -> Unit, onDelete: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    SettingsCard(title = stringResource(R.string.forge_body_weight), blurb = null) {
        b.weight.lastOrNull()?.let {
            Text(stringResource(R.string.forge_body_kg, one(it.value)), style = Forge.type.title2, color = Forge.colors.text)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(value = text, onValueChange = { v -> text = v.filter { it.isDigit() || it == '.' || it == ',' }.take(6) },
                              singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                              suffix = { Text("kg") }, modifier = Modifier.weight(1f), colors = forgeFieldColors())
            Spacer(Modifier.width(ForgeMetrics.space2))
            val kg = text.replace(',', '.').toDoubleOrNull()
            TextButton(enabled = kg != null && kg > 0, onClick = { kg?.let(onLog); text = "" }) {
                Text(stringResource(R.string.forge_body_log_weight))
            }
        }
        if (b.weighIns.isNotEmpty()) {
            Text(stringResource(R.string.forge_body_weigh_ins), style = Forge.type.overline, color = Forge.colors.textSecondary)
            b.weighIns.take(5).forEach { w ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(w.day, style = Forge.type.body, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f))
                    Text(stringResource(R.string.forge_body_kg, one(w.value)), style = Forge.type.body, color = Forge.colors.text)
                    w.id?.let { id -> TextButton(onClick = { onDelete(id) }) { Text(stringResource(R.string.forge_body_delete)) } }
                }
            }
        }
    }
}

@Composable
private fun BodyFatCard(b: CoreBody.Snapshot) {
    SettingsCard(title = stringResource(R.string.forge_body_fat), blurb = null) {
        b.bodyFat.lastOrNull()?.let {
            Text(stringResource(R.string.forge_body_pct, one(it.value)), style = Forge.type.title2, color = Forge.colors.text)
        }
        when {
            b.navyEstimate != null -> Row(verticalAlignment = Alignment.Bottom) {
                Text(one(b.navyEstimate), style = Forge.type.headline, color = Forge.colors.text)
                Spacer(Modifier.width(4.dp1))
                Text(stringResource(R.string.forge_body_pct_estimated), style = Forge.type.subhead, color = Forge.colors.textSecondary)
            }
            b.navyMissing.isNotEmpty() -> Text(stringResource(R.string.forge_join_space, stringResource(R.string.forge_body_navy_missing),
                                                              b.navyMissing.joinToString(", ")),
                                               style = Forge.type.footnote, color = Forge.colors.textSecondary)
        }
    }
}

@Composable
private fun SitesCard(b: CoreBody.Snapshot, onMeasure: () -> Unit, onDelete: (String) -> Unit) {
    SettingsCard(title = stringResource(R.string.forge_body_measurements), blurb = null) {
        if (b.measured.isEmpty()) {
            Text(stringResource(R.string.forge_body_no_tape), style = Forge.type.footnote, color = Forge.colors.textSecondary)
        }
        val changes = b.changes.associateBy { it.key }
        b.measured.forEachIndexed { i, site ->
            Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space1), verticalAlignment = Alignment.CenterVertically) {
                Text(site.label, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                site.current?.let { Text(stringResource(R.string.forge_body_cm, one(it)), style = Forge.type.body, color = Forge.colors.text) }
                changes[site.key]?.let {
                    Spacer(Modifier.width(ForgeMetrics.space2))
                    Text(signed(it.deltaCm), style = Forge.type.caption, color = Forge.colors.textSecondary)
                }
            }
            if (i < b.measured.lastIndex) RowDivider()
        }
        TextButton(onClick = onMeasure) { Text(stringResource(R.string.forge_body_measure)) }
    }
}

@Composable
private fun MeasureCard(b: CoreBody.Snapshot, onCancel: () -> Unit, onSave: (Map<String, Double>) -> Unit) {
    val values = remember { mutableStateMapOf<String, String>() }
    SettingsCard(title = stringResource(R.string.forge_body_circumferences), blurb = stringResource(R.string.forge_body_leave_empty)) {
        (b.measured + b.unmeasured).forEach { site ->
            Column(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space1), verticalArrangement = Arrangement.spacedBy(2.dp1)) {
                OutlinedTextField(value = values[site.key] ?: "", label = { Text(site.label) },
                                  onValueChange = { v -> values[site.key] = v.filter { it.isDigit() || it == '.' || it == ',' }.take(6) },
                                  singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                  suffix = { Text("cm") }, modifier = Modifier.fillMaxWidth(), colors = forgeFieldColors())
                site.guidance?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
            }
        }
        Row {
            TextButton(onClick = onCancel) { Text(stringResource(R.string.forge_body_cancel)) }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = {
                onSave(values.mapNotNull { (k, v) -> v.replace(',', '.').toDoubleOrNull()?.takeIf { it > 0 }?.let { k to it } }.toMap())
            }) { Text(stringResource(R.string.forge_energy_save)) }
        }
    }
}

private val Int.dp1 get() = androidx.compose.ui.unit.Dp(this.toFloat())

private fun one(v: Double): String =
    NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }.format(v)

private fun signed(v: Double): String = (if (v > 0) "+" else if (v < 0) "−" else "") + one(kotlin.math.abs(v))
