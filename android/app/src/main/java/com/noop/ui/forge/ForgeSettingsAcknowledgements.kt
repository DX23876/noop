package com.noop.ui.forge

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreAcknowledgements
import com.noop.core.CoreExerciseProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Settings › About › Acknowledgements (iOS `AcknowledgementsView`): third-party content under its own licence, the
 * bundled licence texts, the exercise provider's credit and the people whose work the fork adopted. The list comes
 * from the shared core (`CoreAcknowledgements`), so the two platforms credit the same people; only the intro lines
 * and headings are this screen's strings.
 */
@Composable
internal fun AcknowledgementsPage(onBack: () -> Unit) {
    val context = LocalContext.current
    var credits by remember { mutableStateOf<CoreAcknowledgements.Credits?>(null) }
    var failed by remember { mutableStateOf(false) }
    var provider by remember { mutableStateOf<CoreExerciseProvider.Defaults?>(null) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            credits = CoreAcknowledgements.credits()
            provider = CoreExerciseProvider.defaults()
        }
        failed = credits == null
    }
    // The licence text that is open, by its resource name.
    var licence by rememberSaveable { mutableStateOf<String?>(null) }
    BackHandler(enabled = licence != null) { licence = null }
    val shown = credits?.licenses?.firstOrNull { it.resource == licence }
    if (shown != null) {
        LicenceTextPage(shown, onBack = { licence = null })
        return
    }
    val colors = Forge.colors
    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_provider_acknowledgements), onBack)
        Text(stringResource(R.string.fsp6_ack_intro), style = Forge.type.subhead, color = colors.textSecondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        val c = credits
        if (c == null) {
            if (failed) Text(stringResource(R.string.fsp6_ack_unavailable), style = Forge.type.subhead, color = colors.textSecondary)
            return@SettingsColumn
        }
        SettingsCard(title = null, blurb = null) {
            c.content.forEachIndexed { i, item ->
                if (i > 0) RowDivider()
                CreditEntry(item.title, item.detail, item.link, ::open)
            }
            provider?.let { source ->
                RowDivider()
                CreditEntry(source.attribution, stringResource(R.string.forge_provider_acknowledgements_detail),
                            source.documentation, ::open)
            }
            c.licenses.forEach { item ->
                RowDivider()
                CreditEntry(item.title, item.detail, item.link, ::open)
                TextButton(onClick = { licence = item.resource }) {
                    Text(item.fileLabel, style = Forge.type.caption, color = colors.accent)
                }
            }
            RowDivider()
            CreditEntry(c.media.title, c.media.detail, c.media.link, ::open)
        }
        // The people the fork took work from (ATTRIBUTION.md), as the fork's credit rule asks.
        SettingsCard(title = stringResource(R.string.fsp6_ack_adopted_header), blurb = null) {
            Text(stringResource(R.string.fsp6_ack_adopted_intro), style = Forge.type.subhead, color = colors.textSecondary)
            c.contributors.forEach { person ->
                RowDivider()
                CreditEntry(person.handle, person.work, null, ::open)
            }
            TextButton(onClick = { open(c.attributionUrl) }) {
                Text(c.attributionUrl, style = Forge.type.caption, color = colors.accent)
            }
        }
    }
}

/** One credit: a title over what it is used for and, when there is one, its link. */
@Composable
private fun CreditEntry(title: String, detail: String, link: String?, open: (String) -> Unit) {
    val colors = Forge.colors
    Column(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space1), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
        Text(detail, style = Forge.type.caption, color = colors.textSecondary)
        if (link != null) {
            Text(link, style = Forge.type.caption, color = colors.accent,
                 modifier = Modifier.clickable(role = Role.Button) { open(link) })
        }
    }
}

/** One bundled licence text, shown verbatim from the assets (`<resource>.txt`). */
@Composable
private fun LicenceTextPage(item: CoreAcknowledgements.License, onBack: () -> Unit) {
    val context = LocalContext.current
    val missing = stringResource(R.string.fsp6_ack_licence_missing)
    val text by remember(item.resource) {
        mutableStateOf(runCatching {
            context.assets.open(item.resource + ".txt").bufferedReader().use { it.readText() }
        }.getOrDefault(missing))
    }
    SettingsColumn {
        PageTitle(item.title, onBack)
        SelectionContainer {
            Text(text, style = Forge.type.footnote.copy(fontFamily = FontFamily.Monospace), color = Forge.colors.text)
        }
    }
}
