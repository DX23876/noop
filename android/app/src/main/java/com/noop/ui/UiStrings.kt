package com.noop.ui

import androidx.annotation.StringRes
import com.noop.NoopApplication

/**
 * Resource lookup for presentation code that is not itself composable.
 *
 * Most call sites can use Compose's `stringResource`; several NOOP screens deliberately keep pure
 * formatting helpers and data-driven catalogs outside composition. Resolving through the process's
 * Application resources keeps those helpers locale-aware without threading an Activity through the
 * model or storing translated text as an identity/database key.
 */
internal fun uiString(@StringRes id: Int, vararg formatArgs: Any): String =
    NoopApplication.localizedString(id, *formatArgs)
