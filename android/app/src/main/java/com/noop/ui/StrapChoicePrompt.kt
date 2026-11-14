package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.material3.Text
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R

/**
 * More than one WHOOP answered a scan this install names no strap for, so nothing has connected yet
 * (`StrapClaim`). The wearer picks; the strongest signal is first, which is almost always the strap on
 * this wrist, and the card says nothing it cannot know. Putting it away leaves every strap alone rather
 * than falling back to the loudest, which is the behaviour the question exists to end.
 *
 * Draws nothing when there is nothing to ask, so a screen can host it unconditionally. It belongs on
 * every surface that offers to connect, not only on the device list: a tester spent an evening tapping a
 * Connect button that had already asked its question on a page he never opened.
 */
@Composable
fun StrapChoicePrompt(viewModel: AppViewModel, modifier: Modifier = Modifier) {
    val question by viewModel.strapChoice.collectAsStateWithLifecycle()
    val asked = question ?: return
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Palette.surfaceRaised, RoundedCornerShape(Metrics.cardRadius))
            .padding(Metrics.cardPadding),
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        Text(uiString(R.string.cx_strap_choice_title), style = NoopType.subhead, color = Palette.textPrimary)
        Text(uiString(R.string.cx_strap_choice_body), style = NoopType.footnote, color = Palette.textSecondary)
        asked.straps.forEach { strap ->
            NoopButton(
                text = strap.name ?: uiString(R.string.cx_strap_choice_unnamed),
                kind = NoopButtonKind.Secondary,
                onClick = { viewModel.pickStrap(asked.model, strap) },
            )
        }
        NoopButton(text = uiString(R.string.cx_strap_choice_later), kind = NoopButtonKind.Tertiary,
                   onClick = { viewModel.dismissStrapChoice() })
    }
}
