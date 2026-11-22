package com.noop.ingest

/**
 * How far back an import reads, as a wearer chooses it.
 *
 * Fork (DX23876), 2026-11-22. The window was a constant of ten years, taken on every run including the
 * automatic one every few hours. A tester's phone read 2 269 462 records in a pass that way; nobody had
 * asked him whether he wanted a decade. Reading a month at a time ([ImportBlocks]) bounds what that costs
 * at once, and this bounds what it costs at all.
 *
 * Four steps rather than a number field: the choice is "how much of my history", and a wearer who wants
 * a decade and a wearer who wants last month are the two real cases with two steps in between. The
 * default is a year — enough for every trend the app draws, and a tenth of the records.
 *
 * The longest step is named for what it actually is. Ten years is the furthest this importer has ever
 * read and is not the same as "everything Health Connect holds", which nothing here can promise.
 */
enum class ImportDepth(val months: Long) {
    ONE_MONTH(1),
    ONE_YEAR(12),
    THREE_YEARS(36),
    TEN_YEARS(120),
    ;

    companion object {
        /** What an import uses when the wearer has not chosen. */
        val DEFAULT: ImportDepth = ONE_YEAR

        /**
         * The step a stored month count belongs to, [DEFAULT] for anything else. A stored value that no
         * step matches is a value from a build that offered different steps, and falling back is how the
         * chooser stays readable across such a change — never an exception on a settings read.
         */
        fun ofMonths(months: Long): ImportDepth = entries.firstOrNull { it.months == months } ?: DEFAULT
    }
}
