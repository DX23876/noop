package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.core.CoreCoach

/** "How Coach works" (`CoachInfoView`): what runs here, what is sent, the provider, the model and the limits. */
@Composable
fun CoachInfoPage(vm: CoachViewModel) {
    val info by vm.info.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.loadInfo() }
    val i = info ?: return
    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        i.sections.forEach { (title, paras) ->
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                paras.forEach { Text(it, style = NoopType.subhead, color = Palette.textSecondary) }
            }
        }
    }
}

/**
 * The note shown once before the first conversation (`CoachFirstUseSheet`): four honest points, a way to the full
 * page, and "Got it". It cannot be dismissed any other way, as on iOS.
 */
@Composable
internal fun CoachFirstUseNote(info: CoreCoach.Info, onMore: () -> Unit, onGotIt: () -> Unit) {
    Dialog(onDismissRequest = {}, properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false,
                                                                usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Palette.surfaceBase).padding(20.dp)) {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp),
                   horizontalAlignment = Alignment.CenterHorizontally) {
                CoachAvatar(size = 72.dp)
                Text(info.firstTitle, style = NoopType.title2, color = Palette.textPrimary, textAlign = TextAlign.Center)
                Text(info.firstSubtitle, style = NoopType.subhead, color = Palette.textSecondary, textAlign = TextAlign.Center)
                info.points.forEach { (title, body) ->
                    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(title, style = NoopType.subhead, color = Palette.textPrimary)
                            Text(body, style = NoopType.footnote, color = Palette.textSecondary)
                        }
                    }
                }
                Text(info.more, style = NoopType.footnote, color = Palette.accent,
                     modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onMore).padding(8.dp))
                Text(info.gotIt, style = NoopType.headline, color = Palette.textPrimary, textAlign = TextAlign.Center,
                     modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(Palette.accent)
                         .clickable(onClick = onGotIt).padding(vertical = 14.dp))
            }
        }
    }
}
