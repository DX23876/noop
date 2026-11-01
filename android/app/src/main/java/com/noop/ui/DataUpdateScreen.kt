package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import com.noop.R

/**
 * Fork (DX23876), Android without Room: shown once while the core adopts an earlier build's Room store
 * (`CoreRoomAdoption`); the app restarts when it is done.
 */
@Composable
fun DataUpdateScreen() {
    Column(
        modifier = Modifier.fillMaxSize().background(Palette.surfaceBase).padding(Metrics.screenPadding),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator(color = Palette.accent)
        Spacer(Modifier.height(Metrics.screenPadding))
        Text(stringResource(R.string.forge_data_update_title), style = NoopType.headline,
             color = Palette.textPrimary, textAlign = TextAlign.Center)
        Spacer(Modifier.height(Metrics.gap))
        Text(stringResource(R.string.forge_data_update_body), style = NoopType.subhead,
             color = Palette.textSecondary, textAlign = TextAlign.Center)
    }
}
