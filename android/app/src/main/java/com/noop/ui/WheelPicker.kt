package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.abs

// MARK: - WheelPickerField — a tap-to-open number selector (replaces +/- stepper tap-spamming)
//
// A read-only value row that, when tapped, opens a snap-scrolling wheel dialog to pick from [options].
// Universal by design: the caller supplies the display strings + the current index, and maps the chosen
// index back to its own (unit-aware) value. Reused wherever a bounded numeric field would otherwise make
// the user tap − / + many times (onboarding age / weight / height; open to Settings later).
//
// Presentation only: no persistence here — [onSelected] hands the chosen index back to the caller, which
// owns the write. Design-system tokens only (Palette / NoopType).

@Composable
fun WheelPickerField(
    value: String,
    accessibility: String,
    options: List<String>,
    selectedIndex: Int,
    dialogTitle: String,
    onSelected: (Int) -> Unit,
    unit: String? = null,
) {
    var open by remember { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = options.isNotEmpty()) { open = true }
            .semantics { contentDescription = uiString(R.string.l10n_wheel_picker_accessibility_tap_to_choose_1314c4ed, accessibility) },
    ) {
        Text(value, style = NoopType.bodyNumber, color = Palette.textPrimary, modifier = Modifier.widthIn(min = 44.dp))
        if (unit != null) Text(unit, style = NoopType.caption, color = Palette.textTertiary)
        Icon(
            Icons.Filled.KeyboardArrowDown,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(18.dp),
        )
    }
    if (open && options.isNotEmpty()) {
        WheelPickerDialog(
            title = dialogTitle,
            options = options,
            initialIndex = selectedIndex.coerceIn(0, options.lastIndex),
            onConfirm = { onSelected(it); open = false },
            onDismiss = { open = false },
        )
    }
}

/** The pick popup: a snap wheel over [options] with Cancel / Done. Committing calls [onConfirm]. */
@Composable
private fun WheelPickerDialog(
    title: String,
    options: List<String>,
    initialIndex: Int,
    onConfirm: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    var index by remember { mutableIntStateOf(initialIndex) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceBase,
        title = { Text(title, style = NoopType.headline, color = Palette.textPrimary) },
        text = {
            WheelPicker(
                options = options,
                selectedIndex = initialIndex,
                onSelectedIndexChange = { index = it },
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(index.coerceIn(0, options.lastIndex)) }) {
                Text(uiString(R.string.l10n_wheel_picker_done_e9b450d1), style = NoopType.headline, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_wheel_picker_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/**
 * A vertical snap wheel: [visibleCount] rows tall (odd), the centred row is the selection. Starts centred
 * on [selectedIndex] and reports the settled centre via [onSelectedIndexChange]. A tinted band marks the
 * centre so the affordance reads without a value label. Pure presentation.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun WheelPicker(
    options: List<String>,
    selectedIndex: Int,
    onSelectedIndexChange: (Int) -> Unit,
    modifier: Modifier = Modifier,
    visibleCount: Int = 5,
    itemHeight: Dp = 40.dp,
) {
    if (options.isEmpty()) return
    val listState = rememberLazyListState()
    val fling = rememberSnapFlingBehavior(lazyListState = listState)
    // Centre the initial selection once (scrollToItem aligns the item to the content-area start, which the
    // vertical contentPadding pushes to the middle row). Guarded so a recomposition doesn't yank the wheel.
    LaunchedEffect(Unit) { listState.scrollToItem(selectedIndex.coerceIn(0, options.lastIndex)) }
    // The centred item = the visible item whose middle is nearest the viewport centre.
    val centre by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            val mid = (info.viewportStartOffset + info.viewportEndOffset) / 2f
            info.visibleItemsInfo.minByOrNull { abs((it.offset + it.size / 2f) - mid) }?.index ?: selectedIndex
        }
    }
    LaunchedEffect(centre) { onSelectedIndexChange(centre.coerceIn(0, options.lastIndex)) }

    Box(modifier = modifier.height(itemHeight * visibleCount), contentAlignment = Alignment.Center) {
        // Centre selection band.
        Box(
            Modifier
                .fillMaxWidth()
                .height(itemHeight)
                .clip(RoundedCornerShape(8.dp))
                .background(Palette.surfaceInset),
        )
        LazyColumn(
            state = listState,
            flingBehavior = fling,
            horizontalAlignment = Alignment.CenterHorizontally,
            contentPadding = PaddingValues(vertical = itemHeight * ((visibleCount - 1) / 2)),
            modifier = Modifier.fillMaxWidth(),
        ) {
            itemsIndexed(options) { i, label ->
                Box(Modifier.height(itemHeight).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Text(
                        label,
                        style = NoopType.bodyNumber,
                        color = if (i == centre) Palette.textPrimary else Palette.textTertiary,
                    )
                }
            }
        }
    }
}
