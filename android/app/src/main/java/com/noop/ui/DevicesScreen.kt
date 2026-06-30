package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.RemoveCircleOutline
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.SourceCoordinator
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import kotlinx.coroutines.launch

// MARK: - Devices
//
// Pair and manage the bands NOOP reads from. WHOOP-FIRST: the WHOOP is the primary, fully-supported
// device; generic heart-rate straps (Polar / Wahoo / Coospo / Garmin HRM …) are an early, in-development
// addition. The screen is a thin UI over [com.noop.data.DeviceRegistry] (the Phase 1A/1B data layer):
// every mutation goes through an [AppViewModel] registry op, and the [SourceCoordinator] (wired in
// NoopApplication) reacts to the active-device change — so this view never touches the BLE client or the
// WHOOP path directly. Faithful Kotlin twin of Strand/Screens/DevicesView.swift.
//
// The registry's reads are one-shot suspend (not a Flow), so the screen keeps the list in a remembered
// state and reloads it after every mutation via [reload].

@Composable
fun DevicesScreen(
    viewModel: AppViewModel,
    /** Routes to the non-destructive file-import lane (Data Sources). The Oura adopt wizard's "Keep the
     *  Oura app instead (import a file)" link and every honest Oura failure offer this. Defaults to a no-op
     *  so existing call sites keep compiling; AppRoot wires it to navigate to Data Sources. */
    onUseFileImport: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val live by viewModel.live.collectAsStateWithLifecycle()

    // The current device list, reloaded after each registry op. Null while the first read is in flight.
    var devices by remember { mutableStateOf<List<PairedDeviceRow>?>(null) }
    fun reload() {
        scope.launch { devices = viewModel.pairedDevices() }
    }
    LaunchedEffect(Unit) { devices = viewModel.pairedDevices() }

    // Sheets / dialogs (mirror the Swift @State targets).
    var showAddWizard by remember { mutableStateOf(false) }
    var switchTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var renameTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var removeTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var deleteDataTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    // After removing the ACTIVE device with other devices still paired, prompt to pick a new active one.
    var pickNewActive by remember { mutableStateOf(false) }

    val all = devices.orEmpty()
    val activeDevices = all.filter { it.status != DeviceStatus.archived.name }
    val removedDevices = all.filter { it.status == DeviceStatus.archived.name }
    val currentActiveName =
        all.firstOrNull { it.status == DeviceStatus.active.name }?.let { displayName(it) }
            ?: "Your current strap"

    // PERF (#707): lazy scaffold — each device card is virtualized via `items(...)` (each was a direct
    // child of the eager `spacedBy(20.dp)` column, so the LazyColumn's matching spacing is identical) and
    // the static button/footer are single items. Only on-screen cards compose + are accessibility-walked.
    // Conditional rows use `if (cond) { item/items }` so a hidden section adds no row.
    LazyScreenScaffold(
        title = "Devices",
        subtitle = "Pair and manage the bands NOOP reads from.",
    ) {
        if (devices == null) {
            // The registry resolves a beat after launch. Show a calm pending note in that brief window.
            item {
            DataPendingNote(
                title = "Getting your devices ready",
                body = "NOOP is opening your on-device data. Your paired bands will appear here in a moment.",
            )
            }
            return@LazyScreenScaffold
        }

        items(activeDevices) { device ->
            DeviceCard(
                device = device,
                isActive = device.status == DeviceStatus.active.name,
                isLiveConnected = device.status == DeviceStatus.active.name && live.connected,
                // The live battery belongs to whichever device is ACTIVE + connected (WHOOP, a generic
                // strap, or an FTMS machine all funnel into live.batteryPct). null otherwise.
                liveBatteryPct = if (device.status == DeviceStatus.active.name && live.connected)
                    live.batteryPct?.let { Math.round(it).toInt() } else null,
                // Firmware version from the connect handshake — only for the active, connected device.
                liveFirmware = if (device.status == DeviceStatus.active.name && live.connected)
                    live.strapFirmware else null,
                onMakeActive = { switchTarget = device },
                onRename = { renameTarget = device },
                onRemove = { removeTarget = device },
            )
        }

        // Prominent "+ Add a device" button.
        item { AddDeviceButton(onClick = { showAddWizard = true }) }

        if (removedDevices.isNotEmpty()) {
            item { Overline("Removed", modifier = Modifier.padding(top = 4.dp)) }
            items(removedDevices) { device ->
                DeviceCard(
                    device = device,
                    isActive = false,
                    isLiveConnected = false,
                    dimmed = true,
                    onMakeActive = { switchTarget = device },
                    onRename = { renameTarget = device },
                    onRemove = null,
                    onReAdd = { switchTarget = device },
                    onDeleteData = { deleteDataTarget = device },
                )
            }
        }

        item { WhoopFirstFooter() }
    }

    // --- Add a device (guided, branching wizard: WHOOP family · HR strap · coming-soon rows) ---
    if (showAddWizard) {
        AddDeviceWizard(
            viewModel = viewModel,
            onClose = { showAddWizard = false; reload() },
            // The Oura gate's file-import links close the wizard and route to Data Sources, so the
            // non-destructive lane is always one tap away (it is never the only door).
            onUseFileImport = { showAddWizard = false; reload(); onUseFileImport() },
        )
    }

    // --- Switch confirm ---
    switchTarget?.let { device ->
        ConfirmDialog(
            title = "Make this your active strap?",
            message = "Make ${displayName(device)} your active strap? From now on it provides your live data. " +
                "$currentActiveName's history stays exactly as it is — only new days come from ${displayName(device)}.",
            confirmLabel = "Make active",
            onConfirm = {
                scope.launch { viewModel.setActiveDevice(device.id); reload() }
                switchTarget = null
            },
            onDismiss = { switchTarget = null },
        )
    }

    // --- Rename ---
    renameTarget?.let { device ->
        RenameDialog(
            device = device,
            onSave = { name ->
                scope.launch { viewModel.renamePairedDevice(device.id, name); reload() }
                renameTarget = null
            },
            onDismiss = { renameTarget = null },
        )
    }

    // --- Remove confirm ---
    removeTarget?.let { device ->
        ConfirmDialog(
            title = "Remove this device?",
            message = "Remove ${displayName(device)}? NOOP will stop connecting to it. Its recorded data is " +
                "kept and you can re-add it any time.",
            confirmLabel = "Remove",
            destructive = true,
            onConfirm = {
                val wasActive = device.status == DeviceStatus.active.name
                scope.launch {
                    viewModel.archivePairedDevice(device.id)
                    devices = viewModel.pairedDevices()
                    // If the removed device was active and other paired devices remain, prompt to pick a
                    // new active one (the registry's reload demotes the active row to paired).
                    if (wasActive && devices.orEmpty().any { it.status != DeviceStatus.archived.name }) {
                        pickNewActive = true
                    }
                }
                removeTarget = null
            },
            onDismiss = { removeTarget = null },
        )
    }

    // --- Second, strongly-worded delete-data confirm (from the Removed card's secondary control) ---
    deleteDataTarget?.let { device ->
        ConfirmDialog(
            title = "Delete all of this device's data?",
            message = "This permanently deletes all data recorded from ${displayName(device)}. This can't be undone.",
            confirmLabel = "Delete data",
            destructive = true,
            onConfirm = {
                scope.launch { viewModel.deletePairedDeviceData(device.id); reload() }
                deleteDataTarget = null
            },
            onDismiss = { deleteDataTarget = null },
        )
    }

    // --- After removing the active device, offer to pick a new active one (if any remain) ---
    if (pickNewActive) {
        PickActiveDialog(
            devices = activeDevices,
            onPick = { device ->
                scope.launch { viewModel.setActiveDevice(device.id); reload() }
                pickNewActive = false
            },
            onLeaveNone = { pickNewActive = false },
        )
    }
}

// MARK: - Device card

/** One paired device as a [NoopCard]: name, brand·model, a capabilities line, a state pill, last-seen,
 *  and a per-device actions menu. The active device is tinted with the accent (WHOOP blue) and carries
 *  an "Active" pill. */
@Composable
private fun DeviceCard(
    device: PairedDeviceRow,
    isActive: Boolean,
    isLiveConnected: Boolean,
    dimmed: Boolean = false,
    /** The active+connected device's live battery percent (0–100) — surfaced the same way for WHOOP, a
     *  generic strap, or an FTMS machine. null when not active/connected or no battery was reported. */
    liveBatteryPct: Int? = null,
    /** The active+connected device's firmware version (from the connect handshake). null when not
     *  active/connected or the strap hasn't reported it (e.g. a non-WHOOP strap). */
    liveFirmware: String? = null,
    onMakeActive: () -> Unit,
    onRename: () -> Unit,
    onRemove: (() -> Unit)?,
    onReAdd: (() -> Unit)? = null,
    onDeleteData: (() -> Unit)? = null,
) {
    val profile = deviceProfile(device)
    NoopCard(
        modifier = Modifier.alpha(if (dimmed) 0.6f else 1f),
        padding = 18.dp,
        tint = if (isActive) Palette.accent else null,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    imageVector = deviceIcon(device),
                    contentDescription = null,
                    tint = if (isActive) Palette.accent else Palette.textSecondary,
                    modifier = Modifier.size(28.dp),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Text(displayName(device), style = NoopType.headline, color = Palette.textPrimary)
                    Text(profile.displayModel, style = NoopType.subhead, color = Palette.textSecondary)
                }
                // Locally-adopted Oura is Beta: a non-dot Beta chip sits beside the usual state pill.
                if (device.sourceKind == SourceKind.oura.name) {
                    StatePill("Beta", tone = StrandTone.Warning, showsDot = false)
                    Spacer(Modifier.width(6.dp))
                }
                StatePill(device, isActive, isLiveConnected)
            }

            // Honest local-takeover state row for an adopted Oura ring that is paired but not the
            // active+connected source right now. States the single-owner reality plainly (if the ring was
            // reset again or re-claimed in the Oura app, NOOP no longer owns it) without faking a live
            // reading. Suppressed for the active+connected ring and for removed rings. Mirrors the macOS
            // ouraLocalStateNote.
            if (device.sourceKind == SourceKind.oura.name && !isLiveConnected &&
                device.status == DeviceStatus.paired.name
            ) {
                OuraLocalStateNote()
            }

            // What this device CAPTURES — honest, per-model (not the generic stored set, which would
            // mislabel e.g. a "Blood oxygen" chip when no SpO₂ % ever comes off the strap).
            CapabilityInfoRow(Icons.Filled.FavoriteBorder, profile.captures)
            // What NOOP USES it for — the scores / screens this device drives.
            CapabilityInfoRow(Icons.Filled.Bolt, profile.powers)
            // Honest footnote: the "*" estimates + the SpO₂/steps caveats.
            if (profile.footnote.isNotEmpty()) {
                Text(profile.footnote, style = NoopType.footnote, color = Palette.textTertiary)
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    lastSeenLine(device, isLiveConnected) +
                        (liveBatteryPct?.let { " · Battery $it%" } ?: "") +
                        (liveFirmware?.let { " · FW $it" } ?: ""),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier.weight(1f),
                )
                DeviceActionsMenu(
                    device = device,
                    isActive = isActive,
                    onMakeActive = onMakeActive,
                    onRename = onRename,
                    onRemove = onRemove,
                    onReAdd = onReAdd,
                    onDeleteData = onDeleteData,
                )
            }
        }
    }
}

@Composable
private fun StatePill(device: PairedDeviceRow, isActive: Boolean, isLiveConnected: Boolean) {
    when {
        device.status == DeviceStatus.archived.name ->
            StatePill("Removed", tone = StrandTone.Neutral, showsDot = false)
        isActive ->
            StatePill(
                if (isLiveConnected) "Active · Live" else "Active",
                tone = StrandTone.Positive,
                pulsing = isLiveConnected,
            )
        else -> StatePill("Paired", tone = StrandTone.Neutral)
    }
}

@Composable
private fun DeviceActionsMenu(
    device: PairedDeviceRow,
    isActive: Boolean,
    onMakeActive: () -> Unit,
    onRename: () -> Unit,
    onRemove: (() -> Unit)?,
    onReAdd: (() -> Unit)?,
    onDeleteData: (() -> Unit)?,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(
            onClick = { open = true },
            modifier = Modifier
                .size(32.dp)
                .semantics { contentDescription = "Device actions for ${displayName(device)}" },
        ) {
            Icon(Icons.Filled.MoreVert, contentDescription = null, tint = Palette.textSecondary, modifier = Modifier.size(20.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (device.status == DeviceStatus.archived.name) {
                if (onReAdd != null) {
                    MenuItem("Make active", Icons.Filled.Bolt) { open = false; onReAdd() }
                }
                MenuItem("Rename", Icons.Filled.Edit) { open = false; onRename() }
                if (onDeleteData != null) {
                    HorizontalDivider(color = Palette.hairline)
                    MenuItem("Delete this device's data…", Icons.Filled.Delete, destructive = true) {
                        open = false; onDeleteData()
                    }
                }
            } else {
                if (!isActive) {
                    MenuItem("Make active", Icons.Filled.Bolt) { open = false; onMakeActive() }
                }
                MenuItem("Rename", Icons.Filled.Edit) { open = false; onRename() }
                if (onRemove != null) {
                    HorizontalDivider(color = Palette.hairline)
                    MenuItem("Remove", Icons.Filled.RemoveCircleOutline, destructive = true) {
                        open = false; onRemove()
                    }
                }
            }
        }
    }
}

@Composable
private fun MenuItem(
    label: String,
    icon: ImageVector,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val color = if (destructive) Palette.statusCritical else Palette.textPrimary
    DropdownMenuItem(
        text = { Text(label, style = NoopType.body, color = color) },
        leadingIcon = { Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp)) },
        onClick = onClick,
    )
}

@Composable
private fun AddDeviceButton(onClick: () -> Unit) {
    // Routed through the unified NoopButton (Design Reset) so the add affordance is the crisp
    // filled-accent-blue / white-label primary the iOS DevicesView uses (`NoopButton(... kind: .primary,
    // fullWidth: true)`) — no hand-rolled gold-text fill, no glow.
    NoopButton(
        text = "Add a device",
        leadingIcon = Icons.Filled.Add,
        kind = NoopButtonKind.Primary,
        fullWidth = true,
        modifier = Modifier
            .padding(top = 4.dp)
            .semantics { contentDescription = "Add a device" },
        onClick = onClick,
    )
}

@Composable
private fun WhoopFirstFooter() {
    Row(
        modifier = Modifier.padding(top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Filled.FavoriteBorder,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            "WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps are an early, " +
                "in-development addition — they stream live heart rate and HRV, but not WHOOP's deeper " +
                "sleep and recovery data.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

// MARK: - Shared dialogs

@Composable
private fun ConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    cancelLabel: String = "Cancel",
    destructive: Boolean = false,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(title, style = NoopType.title2, color = Palette.textPrimary) },
        text = { Text(message, style = NoopType.subhead, color = Palette.textSecondary) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(
                    confirmLabel,
                    style = NoopType.body,
                    color = if (destructive) Palette.statusCritical else Palette.accent,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(cancelLabel, style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun RenameDialog(
    device: PairedDeviceRow,
    onSave: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var draft by remember { mutableStateOf(device.nickname ?: displayName(device)) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text("Rename device", style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "Give ${device.brand} ${device.model} a name you'll recognise.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = true,
                    placeholder = { Text("Name", style = NoopType.body, color = Palette.textTertiary) },
                    colors = devicesFieldColors(),
                    modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Device name" },
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(draft) }) {
                Text("Save", style = NoopType.body, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun PickActiveDialog(
    devices: List<PairedDeviceRow>,
    onPick: (PairedDeviceRow) -> Unit,
    onLeaveNone: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onLeaveNone,
        containerColor = Palette.surfaceOverlay,
        title = { Text("Pick a new active strap", style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "You removed your active strap. Choose which paired band provides your live data, or " +
                        "leave none active and pair one later.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Spacer(Modifier.height(4.dp))
                devices.forEach { device ->
                    Text(
                        displayName(device),
                        style = NoopType.body,
                        color = Palette.accent,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { onPick(device) }
                            .padding(vertical = 10.dp),
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onLeaveNone) {
                Text("Leave none active", style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

// MARK: - Signal indicator
//
// A four-bar signal indicator derived from RSSI. RSSI is negative dBm: closer to 0 is stronger. Buckets
// are coarse on purpose — a precise dBm readout would be noise to the user. Mirrors the Swift SignalBars.

@Composable
internal fun SignalBars(rssi: Int) {
    val level = SignalBars.level(rssi)
    Row(
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.height(18.dp),
    ) {
        for (i in 0 until 4) {
            Box(
                modifier = Modifier
                    .width(3.dp)
                    .height((6 + i * 3).dp)
                    .clip(RoundedCornerShape(1.dp))
                    .background(if (i < level) Palette.accent else Palette.hairlineStrong),
            )
        }
    }
}

internal object SignalBars {
    /** RSSI (negative dBm) → 0..4 signal level, coarse buckets. Matches the Swift SignalBars.level. */
    fun level(rssi: Int): Int = when {
        rssi >= -55 -> 4
        rssi >= -67 -> 3
        rssi >= -80 -> 2
        rssi >= -90 -> 1
        else -> 0
    }
}

// MARK: - Field colours

@Composable
private fun devicesFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)

// MARK: - Presentation helpers (mirror the Swift PairedDevice computed props)

/**
 * Collapsed display name (mirrors Swift `PairedDevice.displayName`): the nickname if present, else the
 * model if it already contains the brand (so the seeded WHOOP/WHOOP reads "WHOOP", not "WHOOP WHOOP"),
 * else "brand model".
 */
internal fun displayName(device: PairedDeviceRow): String {
    device.nickname?.takeIf { it.isNotBlank() }?.let { return it }
    return if (device.model.contains(device.brand, ignoreCase = true)) device.model
    else "${device.brand} ${device.model}"
}

/** SF-Symbol-equivalent icon: WHOOP keeps the band glyph; an FTMS machine reads as gym equipment;
 *  generic straps read as a heart-rate strap. */
private fun deviceIcon(device: PairedDeviceRow): ImageVector = when {
    device.sourceKind == SourceKind.ftms.name -> Icons.AutoMirrored.Filled.DirectionsRun
    device.sourceKind == SourceKind.huami.name -> Icons.Filled.GraphicEq
    device.sourceKind == SourceKind.oura.name -> Icons.Filled.Circle
    SourceCoordinator.isWhoop(device) -> Icons.Filled.Watch
    else -> Icons.Filled.FavoriteBorder
}

/**
 * Honest, per-model capability + function summary for a device card — mirrors the Swift
 * `DeviceCapabilityProfile`. Derived from brand/model, NOT the generic stored capability set (which
 * would render an identical line for a 4.0 and a 5/MG and mislabel "Blood oxygen" when no SpO₂ % ever
 * comes off any WHOOP strap — raw red/IR only; a real % is import-only). "*" in a label = an on-device
 * estimate, not a raw sensor. Source-verified against the decode + scoring paths (capability audit).
 */
private data class DeviceCapabilityProfile(
    val displayModel: String,  // clean card subtitle (replaces the redundant "WHOOP · WHOOP")
    val captures: String,      // "·"-joined honest capture labels for THIS model
    val powers: String,        // the NOOP scores / screens this device drives
    val footnote: String,      // one short honest caveat line ("*" estimates + the SpO₂/steps notes)
)

private fun deviceProfile(device: PairedDeviceRow): DeviceCapabilityProfile {
    // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
    // live-workout path. Effort-scored only when the machine actually reports heart rate.
    if (device.sourceKind == SourceKind.ftms.name) {
        return DeviceCapabilityProfile(
            displayModel = "Gym equipment (FTMS)",
            captures = "Speed · Cadence · Power · Distance · Energy · Heart rate (if the machine sends it)",
            powers = "Records a live machine workout — Effort-scored from HR when the machine reports it",
            footnote = "Live machine data over Bluetooth FTMS. No sleep, recovery, skin temp or SpO₂. " +
                "Effort needs the machine's heart rate; without it the session logs the machine metrics only.",
        )
    }
    // EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band): best-effort live HR only, honest about it.
    if (device.sourceKind == SourceKind.huami.name) {
        return DeviceCapabilityProfile(
            displayModel = "${device.brand} (experimental)",
            captures = "Heart rate (live, best-effort)",
            powers = "Powers the live console + Effort — no Charge, Rest or Sleep",
            footnote = "Experimental: live heart rate where the band exposes it. Some bands need a pairing " +
                "we can't do yet — NOOP will say so honestly and never show a made-up number. No sleep, " +
                "recovery, skin temp, SpO₂ or steps.",
        )
    }
    // EXPERIMENTAL locally-adopted Oura ring (gen 3/4/5). The gen is carried on `model` ("Oura Ring
    // 3/4/5") and recovered with OuraRingGen.from(model). NOOP reads the ring's OWN raw signals + open
    // HRV/sleep-phase tags and computes its own Charge/Effort/Rest; it NEVER reads Oura's encrypted
    // Readiness/Sleep scores, and claims NO absolute SpO₂ %. Estimates carry "*"; a signal it can't read
    // stays "-". Per-gen copy + the canonical Beta caveat (spec
    // docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md s3/s4). Mirrors the macOS Oura branch.
    if (device.sourceKind == SourceKind.oura.name) {
        val gen = com.noop.oura.OuraRingGen.from(device.model)
        // gen3/4 are verified-shape; gen5 ("newer") carries the least-proven caveat.
        val newer = gen == com.noop.oura.OuraRingGen.GEN5
        val captures = if (newer)
            "Heart rate* · HRV* · Sleep* · Resting HR* · Skin temp* · Battery*"
        else
            "Heart rate · HRV* · Sleep · Resting HR · Skin temp* · Battery"
        val powers = if (newer)
            "Powers Effort now; Charge and Rest once enough nights and decode are confirmed"
        else
            "Powers Charge, Effort, Rest and Sleep"
        return DeviceCapabilityProfile(
            displayModel = "${gen.displayName} (Beta)",
            captures = captures,
            powers = powers,
            footnote = "Beta. * is an on-device estimate. Skin temp is a trend versus your own baseline, " +
                "and HRV needs you to be still. No Oura Readiness or SpO₂ " +
                "percentage comes off the ring (import an Oura file for those).",
        )
    }
    // Generic heart-rate strap: live HR + R-R only; drives the live console + Effort, nothing nightly.
    if (!SourceCoordinator.isWhoop(device)) {
        return DeviceCapabilityProfile(
            displayModel = "Heart-rate strap",
            captures = "Heart rate · HRV (live)* · Strain",
            powers = "Powers the live console + Effort — no Charge, Rest or Sleep",
            footnote = "Live HR + R-R only · no sleep, recovery, skin temp, SpO₂, steps or battery " +
                "(those are WHOOP-only).",
        )
    }
    val whoopPowers = "Powers Charge, Effort, Rest, Sleep + Health Monitor"
    val model = device.model.lowercase()
    // WHOOP 5.0 / MG — adds a (raw) step count the 4.0 can't read over BLE.
    if (model.contains("5") || model.contains("mg")) {
        return DeviceCapabilityProfile(
            displayModel = "WHOOP 5.0 / MG",
            captures = "Heart rate · HRV · Skin temp* · Resp rate* · Steps* · Sleep · Strain · Battery",
            powers = whoopPowers,
            footnote = "* on-device estimate — skin temp is a nightly ±°C deviation, steps are a raw " +
                "motion count (#78). No SpO₂ % off the strap; import a WHOOP CSV for a real %.",
        )
    }
    // WHOOP 4.0 — NOOP's primary band; no steps over BLE.
    if (model.contains("4")) {
        return DeviceCapabilityProfile(
            displayModel = "WHOOP 4.0",
            captures = "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery",
            powers = whoopPowers,
            footnote = "* on-device estimate — skin temp is a nightly ±°C deviation (firmware-dependent); " +
                "no steps over BLE on a 4.0. No SpO₂ % off the strap; import a WHOOP CSV for a real %.",
        )
    }
    // Legacy / unknown WHOOP (the seeded device, model just "WHOOP") — show only the common-to-all set.
    return DeviceCapabilityProfile(
        displayModel = "WHOOP",
        captures = "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery",
        powers = whoopPowers,
        footnote = "Exact model unknown — shows what every WHOOP can do. * on-device estimate · " +
            "no SpO₂ % off the strap (import a WHOOP CSV for that).",
    )
}

/** One icon-prefixed info row (captures / powers) for a device card, matching the caption style. */
@Composable
private fun CapabilityInfoRow(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(14.dp))
        Text(text, style = NoopType.caption, color = Palette.textSecondary)
    }
}

/**
 * Honest paired-but-not-connected note for a locally-adopted Oura ring (Beta). Amber heads-up, no
 * fabricated reading: re-states the single-owner reality so the user understands why a re-reset or an Oura
 * re-claim would break NOOP's ownership. Mirrors the macOS DeviceCard.ouraLocalStateNote (no em-dashes).
 */
@Composable
private fun OuraLocalStateNote() {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Info, contentDescription = null, tint = Palette.statusWarning, modifier = Modifier.size(14.dp))
        Text(
            "Paired locally. NOOP owns this ring while it holds the key. If you reset it again or set it " +
                "up in the Oura app, NOOP no longer owns it and you would re-add it to take it over.",
            style = NoopType.caption,
            color = Palette.statusWarning,
        )
    }
}

private fun lastSeenLine(device: PairedDeviceRow, isLiveConnected: Boolean): String = when {
    device.status == DeviceStatus.archived.name -> "Removed · data kept"
    isLiveConnected -> "Connected now"
    else -> "Last seen ${relativeAgo(device.lastSeenAt)}"
}

/** Best-effort brand from the advertised name. Falls back to a neutral label. Mirrors Swift brandGuess. */
internal fun brandGuess(name: String): String {
    val lower = name.lowercase()
    return when {
        lower.contains("polar") -> "Polar"
        lower.contains("wahoo") || lower.contains("tickr") -> "Wahoo"
        lower.contains("coospo") -> "Coospo"
        lower.contains("garmin") || lower.contains("hrm") -> "Garmin"
        lower.contains("scosche") || lower.contains("rhythm") -> "Scosche"
        lower.contains("magene") -> "Magene"
        lower.contains("amazfit") || lower.contains("helio") || lower.contains("zepp") -> "Amazfit"
        else -> "Heart-rate strap"
    }
}
