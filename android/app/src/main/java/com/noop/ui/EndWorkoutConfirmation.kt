package com.noop.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import com.noop.R

/**
 * Shared destructive confirmation for compact manual-workout stop affordances (#517).
 *
 * Keeping the dialog in one place prevents the compact Live/Workouts cards from drifting back to
 * one-tap termination independently. The full-screen view owns the same copy in its richer layout.
 */
@Composable
internal fun EndWorkoutConfirmationDialog(
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = {
            Text(
                uiString(R.string.l10n_live_workout_screen_end_this_workout_4869c76a),
                style = NoopType.title2,
                color = Palette.textPrimary,
            )
        },
        text = {
            Text(
                uiString(R.string.l10n_live_workout_screen_this_stops_recording_and_saves_what_3e17a23e),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(
                    uiString(R.string.l10n_live_workout_screen_end_workout_3e8d6238),
                    style = NoopType.body,
                    color = Palette.statusCritical,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(
                    uiString(R.string.l10n_live_workout_screen_cancel_77dfd213),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            }
        },
    )
}
