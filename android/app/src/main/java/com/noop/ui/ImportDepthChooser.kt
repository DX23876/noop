package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ingest.ImportDepth
import com.noop.ui.forge.Forge

/**
 * How far back the next import reads, chosen where the import is started.
 *
 * Fork (DX23876), 2026-11-22. Shown in both import flows rather than buried in settings: the choice is
 * made at the moment somebody decides to import, and it is the same decision in both places, so it is
 * one composable reading and writing one preference.
 *
 * It is remembered, because the periodic auto-sync has no screen to ask from and must use the same answer
 * as the manual one — otherwise a wearer who picked a month would still have a decade read behind his
 * back every twelve hours.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ImportDepthChooser(modifier: Modifier = Modifier, enabled: Boolean = true) {
    val context = LocalContext.current
    val colors = Forge.colors
    var depth by remember { mutableStateOf(ImportDepth.ofMonths(NoopPrefs.importMonths(context))) }
    val steps = ImportDepth.entries

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(uiString(R.string.import_depth_label), style = Forge.type.subhead, color = colors.textSecondary)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            steps.forEachIndexed { i, step ->
                SegmentedButton(
                    selected = step == depth,
                    enabled = enabled,
                    onClick = {
                        depth = step
                        NoopPrefs.setImportMonths(context, step.months)
                    },
                    shape = SegmentedButtonDefaults.itemShape(i, steps.size),
                    colors = SegmentedButtonDefaults.colors(
                        activeContainerColor = colors.accent.copy(alpha = 0.18f),
                        activeContentColor = colors.text,
                        inactiveContentColor = colors.textSecondary,
                    ),
                    icon = {},
                ) { Text(uiString(importDepthLabel(step)), style = Forge.type.subhead) }
            }
        }
    }
}

/** The label of one step. Separate so a test can assert every step has one. */
internal fun importDepthLabel(depth: ImportDepth): Int = when (depth) {
    ImportDepth.ONE_MONTH -> R.string.import_depth_one_month
    ImportDepth.ONE_YEAR -> R.string.import_depth_one_year
    ImportDepth.THREE_YEARS -> R.string.import_depth_three_years
    ImportDepth.TEN_YEARS -> R.string.import_depth_ten_years
}
