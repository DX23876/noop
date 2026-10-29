package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material.icons.rounded.RemoveCircle
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.noop.R

/**
 * Fork (DX23876), Android parity: the editor pages' frame after the Apple customization sheets. A title bar with
 * Cancel (the first page) or Back (a nested page) and Save, over one scrolling column on the sky.
 */
@Composable
internal fun ForgeEditorPage(
    title: String,
    onCancel: (() -> Unit)?,
    onBack: (() -> Unit)?,
    onSave: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val ink = Forge.sceneInk
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = ForgeMetrics.space2),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                when {
                    onBack != null -> IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.forge_lay_back), tint = ink.text)
                    }
                    onCancel != null -> TextButton(onClick = onCancel) {
                        Text(stringResource(R.string.forge_lay_cancel), style = Forge.type.body, color = Forge.colors.accent)
                    }
                }
            }
            Text(title, style = Forge.type.headline, color = ink.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                 textAlign = TextAlign.Center, modifier = Modifier.weight(2f))
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                TextButton(onClick = onSave) {
                    Text(stringResource(R.string.forge_lay_save), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold),
                         color = Forge.colors.accent)
                }
            }
        }
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(horizontal = ForgeMetrics.screenPadding).widthIn(max = ForgeMetrics.maxContentWidth)
                .navigationBarsPadding().padding(top = ForgeMetrics.space2, bottom = ForgeMetrics.space6),
            verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap),
            content = content,
        )
    }
}

/** One row's look in the Shown / Hidden lists. */
internal class LayoutRowStyle<T>(
    val title: @Composable (T) -> String,
    val subtitle: @Composable (T) -> String? = { null },
    val icon: (T) -> ImageVector,
    val tint: @Composable (T) -> Color,
    val configurationLabel: @Composable (T) -> String? = { null },
    val onConfigure: (T) -> Unit = {},
)

/**
 * The shared Shown / Hidden list after the Apple `EditableLayoutList`: [options] on top, the shown items to drag
 * into order (or move up and down with a screen reader) and hide, the hidden ones to show again, then Reset.
 * The last shown item cannot be hidden unless [allowEmpty].
 */
@Composable
internal fun <T> ForgeEditableLayoutList(
    draft: EditableLayoutDraft<T>,
    onChange: (EditableLayoutDraft<T>) -> Unit,
    shownTitle: String,
    hiddenTitle: String,
    style: LayoutRowStyle<T>,
    onReset: () -> Unit,
    allowEmpty: Boolean = false,
    options: @Composable () -> Unit = {},
) {
    val current by rememberUpdatedState(draft)
    val change by rememberUpdatedState(onChange)
    options()
    EditorGroup(shownTitle, stringResource(R.string.forge_lay_drag_hint)) {
        ReorderableRows(draft.visible, onMove = { from, to -> change(current.moveVisible(from, to)) }) { item, index, handle ->
            EditorRow(item, style, visible = true, canHide = draft.visible.size > (if (allowEmpty) 0 else 1),
                      handle = handle, index = index, count = draft.visible.size,
                      onMove = { to -> change(current.moveVisible(index, to)) },
                      onToggle = { change(current.hide(item, allowEmpty)) })
        }
    }
    EditorGroup(hiddenTitle, stringResource(R.string.forge_lay_hidden_hint)) {
        if (draft.hidden.isEmpty()) {
            Text(stringResource(R.string.forge_lay_nothing_hidden), style = Forge.type.body, color = Forge.colors.textTertiary,
                 modifier = Modifier.padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space3))
        } else {
            draft.hidden.forEachIndexed { i, item ->
                if (i > 0) RowRule()
                EditorRow(item, style, visible = false, canHide = true, handle = null, index = i, count = draft.hidden.size,
                          onMove = {}, onToggle = { change(current.show(item)) })
            }
        }
    }
    ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onReset), radius = ForgeMetrics.groupedRadius,
              contentPadding = ForgeMetrics.space4) {
        Text(stringResource(R.string.forge_lay_reset), style = Forge.type.body, color = ForgeTokens.Color.systemRed.resolve())
    }
}

/** A titled group card with its footnote underneath, as an inset grouped list section. */
@Composable
internal fun EditorGroup(title: String?, footer: String?, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        // On the sky, so in the scene's ink; the card below carries the page's own colours.
        if (title != null) {
            Text(title.uppercase(), style = Forge.type.overline, color = Forge.sceneInk.secondary,
                 modifier = Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space1))
        }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp, content = content)
        if (footer != null) {
            Text(footer, style = Forge.type.footnote, color = Forge.sceneInk.tertiary,
                 modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        }
    }
}

@Composable
private fun RowRule() {
    HorizontalDivider(color = Forge.colors.divider.copy(alpha = 0.5f), modifier = Modifier.padding(start = 60.dp))
}

/**
 * Rows the user drags into order by their handle. The lifted row follows the finger and swaps with a neighbour
 * once it has crossed that neighbour's middle; the order is applied through [onMove] as it changes.
 */
@Composable
private fun <T> ReorderableRows(
    items: List<T>,
    onMove: (from: Int, to: Int) -> Unit,
    row: @Composable (item: T, index: Int, handle: Modifier) -> Unit,
) {
    val heights = remember { mutableStateMapOf<Int, Int>() }
    var dragged by remember { mutableStateOf<T?>(null) }
    var offset by remember { mutableFloatStateOf(0f) }
    val latest by rememberUpdatedState(items)
    val move by rememberUpdatedState(onMove)
    val haptics = LocalHapticFeedback.current
    items.forEachIndexed { index, item -> key(item) {
        if (index > 0) RowRule()
        val lifted = item == dragged
        val handle = Modifier.pointerInput(item) {
            detectDragGestures(
                onDragStart = { dragged = item; offset = 0f; haptics.performHapticFeedback(HapticFeedbackType.LongPress) },
                onDragEnd = { dragged = null; offset = 0f },
                onDragCancel = { dragged = null; offset = 0f },
                onDrag = { change, amount ->
                    change.consume()
                    offset += amount.y
                    val at = latest.indexOf(item)
                    val below = heights[at + 1]
                    val above = heights[at - 1]
                    if (below != null && offset > below / 2f) {
                        move(at, at + 1); offset -= below
                    } else if (above != null && offset < -above / 2f) {
                        move(at, at - 1); offset += above
                    }
                },
            )
        }
        Box(Modifier.onSizeChanged { heights[index] = it.height }
                .zIndex(if (lifted) 1f else 0f)
                .graphicsLayer { if (lifted) { translationY = offset; shadowElevation = 8f } }
                .background(if (lifted) Forge.colors.surfaceTop else Color.Transparent)) {
            row(item, index, handle)
        }
    } }
}

@Composable
private fun <T> EditorRow(
    item: T, style: LayoutRowStyle<T>, visible: Boolean, canHide: Boolean, handle: Modifier?,
    index: Int, count: Int, onMove: (Int) -> Unit, onToggle: () -> Unit,
) {
    val colors = Forge.colors
    val title = style.title(item)
    val tint = style.tint(item)
    val moveUp = stringResource(R.string.forge_lay_move_up)
    val moveDown = stringResource(R.string.forge_lay_move_down)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp)
            .padding(start = ForgeMetrics.space4, end = ForgeMetrics.space2, top = ForgeMetrics.space2, bottom = ForgeMetrics.space2)
            .semantics {
                if (handle != null) customActions = buildList {
                    if (index > 0) add(CustomAccessibilityAction(moveUp) { onMove(index - 1); true })
                    if (index < count - 1) add(CustomAccessibilityAction(moveDown) { onMove(index + 1); true })
                }
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(32.dp).background(colors.inset, RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
            Icon(style.icon(item), contentDescription = null, tint = if (visible) tint else colors.textTertiary,
                 modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
            Text(title, style = Forge.type.body, color = if (visible) colors.text else colors.textTertiary)
            style.subtitle(item)?.let {
                Text(it, style = Forge.type.caption, color = colors.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        style.configurationLabel(item)?.let { label ->
            val spoken = stringResource(R.string.forge_lay_edit_item, title)
            TextButton(onClick = { style.onConfigure(item) },
                       modifier = Modifier.semantics { contentDescription = spoken }) {
                Text(label, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
            }
        }
        val toggleLabel = stringResource(if (visible) R.string.forge_lay_hide_item else R.string.forge_lay_show_item, title)
        IconButton(onClick = onToggle, enabled = !visible || canHide) {
            Icon(if (visible) Icons.Rounded.RemoveCircle else Icons.Rounded.AddCircle, toggleLabel,
                 tint = when {
                     !visible -> colors.accent
                     canHide -> colors.textSecondary
                     else -> colors.textTertiary.copy(alpha = 0.4f)
                 })
        }
        if (handle != null) {
            Box(handle.size(40.dp), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.DragHandle, contentDescription = null, tint = colors.textTertiary)
            }
        }
    }
}
