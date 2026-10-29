package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Watch
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.ble.WhoopBleClient
import com.noop.ble.WhoopModel
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import com.noop.data.WhoopLiveCapabilities
import com.noop.ui.AppViewModel
import com.noop.ui.rememberRequestScan
import kotlinx.coroutines.launch

/**
 * The registry row a picked WHOOP becomes, field for field what the classic Add-a-device wizard writes: id
 * namespaced by address, model "4.0" or "5.0 MG", the honest live capability set for that model.
 */
fun forgeWhoopRow(strap: WhoopBleClient.DiscoveredWhoop, model: WhoopModel, nowSeconds: Long): PairedDeviceRow {
    val label = if (model == WhoopModel.WHOOP4) "4.0" else "5.0 MG"
    return PairedDeviceRow(
        id = "whoop-${strap.address}",
        brand = "WHOOP",
        model = label,
        nickname = strap.name?.takeIf { it.isNotBlank() },
        peripheralId = strap.address,
        sourceKind = SourceKind.liveBLE.name,
        capabilities = WhoopLiveCapabilities.encoded(label),
        status = DeviceStatus.paired.name,
        addedAt = nowSeconds,
        lastSeenAt = nowSeconds,
    )
}

/**
 * Fork (DX23876), Android plan E-3f: pairing a WHOOP in the Forge design. Pick the family, get the strap ready,
 * pick it from the live scan; it is registered and made active the way the classic wizard does it, and the app's
 * source coordinator connects. Every other kind of device opens the classic wizard through [onOtherDevice].
 */
@Composable
fun ForgePairing(viewModel: AppViewModel, onClose: () -> Unit, onOtherDevice: () -> Unit) {
    val colors = Forge.colors
    val scope = rememberCoroutineScope()
    val live by viewModel.live.collectAsStateWithLifecycle()
    var model by remember { mutableStateOf<WhoopModel?>(null) }
    val startScan = rememberRequestScan { model?.let { viewModel.presentWhoopScan(it) } }
    DisposableEffect(Unit) { onDispose { viewModel.stopWhoopScan() } }

    ForgeSceneBackdrop(ForgeBackdrop.Sky) {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())
                .padding(horizontal = ForgeMetrics.screenPadding).widthIn(max = ForgeMetrics.maxContentWidth),
            verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap),
        ) {
            Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_pair_title), style = Forge.type.title1, color = Forge.sceneInk.text,
                     modifier = Modifier.weight(1f))
                IconButton(onClick = onClose) {
                    Icon(Icons.Rounded.Close, stringResource(R.string.forge_cancel), tint = Forge.sceneInk.text)
                }
            }
            val chosen = model
            if (chosen == null) {
                ChoiceCard(Icons.Rounded.Watch, colors.charge, stringResource(R.string.forge_pair_whoop5)) {
                    model = WhoopModel.WHOOP5_MG; startScan()
                }
                ChoiceCard(Icons.Rounded.Watch, colors.effort, stringResource(R.string.forge_pair_whoop4)) {
                    model = WhoopModel.WHOOP4; startScan()
                }
                ChoiceCard(Icons.Rounded.Devices, colors.textSecondary, stringResource(R.string.forge_pair_other),
                           stringResource(R.string.forge_pair_other_detail)) {
                    viewModel.stopWhoopScan(); onOtherDevice()
                }
            } else {
                ForgeCard(Modifier.fillMaxWidth()) {
                    Text(stringResource(if (chosen == WhoopModel.WHOOP4) R.string.forge_pair_prep4 else R.string.forge_pair_prep5),
                         style = Forge.type.body, color = colors.textSecondary)
                }
                val found by viewModel.discoveredWhoops.collectAsStateWithLifecycle()
                ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
                    Row(Modifier.fillMaxWidth().padding(ForgeMetrics.cardPadding), verticalAlignment = Alignment.CenterVertically) {
                        if (live.scanning) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = colors.accent)
                            Spacer(Modifier.width(ForgeMetrics.space2 + ForgeMetrics.space1))
                        }
                        Text(stringResource(if (live.scanning) R.string.forge_pair_searching else R.string.onboarding_state_ready_scan), style = Forge.type.subhead,
                             color = colors.textSecondary)
                    }
                    found.sortedByDescending { it.rssi }.forEach { strap ->
                        StrapRow(strap) {
                            viewModel.stopWhoopScan()
                            val row = forgeWhoopRow(strap, chosen, System.currentTimeMillis() / 1000)
                            scope.launch { viewModel.registerDevice(row, makeActive = true) }
                            onClose()
                        }
                    }
                }
                OutlinedButton(onClick = startScan, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.forge_pair_rescan))
                }
            }
            Spacer(Modifier.height(ForgeMetrics.space4))
        }
    }
}

@Composable
private fun ChoiceCard(icon: ImageVector, tint: Color, title: String, detail: String? = null, onClick: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).background(tint.copy(alpha = 0.16f), RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, tint = tint)
            }
            Spacer(Modifier.width(ForgeMetrics.space4))
            Column(Modifier.weight(1f)) {
                Text(title, style = Forge.type.headline, color = colors.text)
                if (detail != null) Text(detail, style = Forge.type.subhead, color = colors.textSecondary)
            }
            Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary)
        }
    }
}

/** A strap from the live scan: its name and how strong its signal is, as four bars. */
@Composable
private fun StrapRow(strap: WhoopBleClient.DiscoveredWhoop, onClick: () -> Unit) {
    val colors = Forge.colors
    val bars = signalBars(strap.rssi)
    Row(
        Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = ForgeMetrics.cardPadding, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(strap.name?.takeIf { it.isNotBlank() } ?: WHOOP_NAME, style = Forge.type.headline, color = colors.text,
             modifier = Modifier.weight(1f))
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            for (i in 1..4) {
                Box(Modifier.width(4.dp).height((4 + i * 4).dp)
                    .background(if (i <= bars) colors.charge else colors.divider.copy(alpha = 0.4f), RoundedCornerShape(1.dp)))
            }
        }
        Spacer(Modifier.width(ForgeMetrics.space2))
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary)
    }
}

/** Signal strength as 1 to 4 bars: -55 dBm or better is full, -85 or worse one bar. */
fun signalBars(rssi: Int): Int = when {
    rssi >= -55 -> 4
    rssi >= -65 -> 3
    rssi >= -75 -> 2
    else -> 1
}

/** The name a strap shows when it advertises none; the brand, not translated. */
private const val WHOOP_NAME = "WHOOP"
