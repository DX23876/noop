package com.noop.widget

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF

/**
 * The small charts the fitness and day widgets draw (the iPhone's `WidgetLineChart`, `WidgetBarChart`,
 * `WidgetHeatGrid`, `WidgetStageBar` and ring gauges), as bitmaps: Glance compiles to RemoteViews, which cannot
 * draw. Kept as plain drawing over values handed in; every decision about what to draw is the widget's. Bitmaps
 * are transparent, sized in pixels by the caller and kept small, because a widget's bitmaps share one payload.
 */
internal object WidgetCharts {
    private fun bitmap(w: Int, h: Int): Bitmap? =
        if (w < 2 || h < 2 || w.toLong() * h > 1_500_000) null
        else runCatching { Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888) }.getOrNull()

    private fun withAlpha(color: Int, alpha: Float): Int =
        (color and 0x00FFFFFF) or ((alpha.coerceIn(0f, 1f) * 255).toInt() shl 24)

    /** A line over [values] (gaps where null), the usual band behind it, the last point marked. */
    fun line(values: List<Double?>, usualLow: Double?, usualHigh: Double?, color: Int, w: Int, h: Int, density: Float): Bitmap? {
        val present = values.filterNotNull()
        if (present.isEmpty()) return null
        val bmp = bitmap(w, h) ?: return null
        val c = Canvas(bmp)
        var lo = present.min(); var hi = present.max()
        if (usualLow != null && usualHigh != null) { lo = minOf(lo, usualLow); hi = maxOf(hi, usualHigh) }
        val span = (hi - lo).takeIf { it > 0 } ?: 1.0
        val pad = 4 * density
        fun x(i: Int) = if (values.size <= 1) w / 2f else pad + (w - 2 * pad) * i / (values.size - 1).toFloat()
        fun y(v: Double) = (h - pad - (h - 2 * pad) * ((v - lo) / span)).toFloat()
        if (usualLow != null && usualHigh != null) {
            c.drawRect(RectF(0f, y(usualHigh), w.toFloat(), y(usualLow)),
                       Paint().apply { this.color = withAlpha(color, 0.14f) })
        }
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color; style = Paint.Style.STROKE; strokeWidth = 2.2f * density
            strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
        }
        val path = Path(); var open = false
        values.forEachIndexed { i, v ->
            if (v == null) { open = false; return@forEachIndexed }
            if (open) path.lineTo(x(i), y(v)) else { path.moveTo(x(i), y(v)); open = true }
        }
        c.drawPath(path, stroke)
        values.indexOfLast { it != null }.takeIf { it >= 0 }?.let { i ->
            c.drawCircle(x(i), y(values[i]!!), 3.2f * density, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color })
        }
        return bmp
    }

    /** Bars for [values] from zero to [maximum] (the largest value when null), each in [colorOf]'s colour, with an
     *  optional dashed [goal] line; a missing day is a short muted stub. */
    fun bars(values: List<Double?>, maximum: Double?, goal: Double?, muted: Int, colorOf: (Double) -> Int,
             w: Int, h: Int, density: Float): Bitmap? {
        if (values.isEmpty()) return null
        val bmp = bitmap(w, h) ?: return null
        val c = Canvas(bmp)
        val top = maxOf(maximum ?: 0.0, values.filterNotNull().maxOrNull() ?: 0.0, goal ?: 0.0).takeIf { it > 0 } ?: 1.0
        val gap = 4 * density
        val bw = (w - gap * (values.size - 1)) / values.size.toFloat()
        val radius = minOf(bw / 2, 4 * density)
        values.forEachIndexed { i, v ->
            val left = i * (bw + gap)
            val height = if (v == null || v <= 0) 3 * density else maxOf(3 * density, (h * (v / top)).toFloat())
            c.drawRoundRect(RectF(left, h - height, left + bw, h.toFloat()), radius, radius,
                            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = if (v == null || v <= 0) muted else colorOf(v) })
        }
        if (goal != null && goal > 0) {
            val y = (h - h * (goal / top)).toFloat().coerceIn(1f, h - 1f)
            val dash = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = muted; strokeWidth = 1.2f * density; style = Paint.Style.STROKE
                pathEffect = android.graphics.DashPathEffect(floatArrayOf(4 * density, 3 * density), 0f) }
            c.drawLine(0f, y, w.toFloat(), y, dash)
        }
        return bmp
    }

    /** A week-by-week grid of days (columns are weeks, oldest left): trained in [color], rest days muted, days before
     *  any record left empty. [days] runs oldest first and its length is a multiple of seven. */
    fun heatGrid(days: List<Boolean?>, color: Int, muted: Int, w: Int, h: Int, density: Float): Bitmap? {
        if (days.isEmpty()) return null
        val bmp = bitmap(w, h) ?: return null
        val c = Canvas(bmp)
        val weeks = (days.size + 6) / 7
        val gap = 3 * density
        val cell = minOf((w - gap * (weeks - 1)) / weeks.toFloat(), (h - gap * 6) / 7f)
        days.forEachIndexed { i, d ->
            if (d == null) return@forEachIndexed
            val col = i / 7; val row = i % 7
            val left = col * (cell + gap); val topY = row * (cell + gap)
            c.drawRoundRect(RectF(left, topY, left + cell, topY + cell), cell * 0.25f, cell * 0.25f,
                            Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = if (d) color else muted })
        }
        return bmp
    }

    /** One ring: a muted track and [fraction] of it in [color] from the top, clockwise. */
    fun ring(fraction: Double?, color: Int, track: Int, sizePx: Int, density: Float, stroke: Float = 5f): Bitmap? {
        val bmp = bitmap(sizePx, sizePx) ?: return null
        val c = Canvas(bmp)
        val sw = stroke * density
        val r = RectF(sw / 2, sw / 2, sizePx - sw / 2, sizePx - sw / 2)
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = sw; strokeCap = Paint.Cap.ROUND }
        c.drawArc(r, 0f, 360f, false, p.apply { this.color = track })
        val f = (fraction ?: 0.0).coerceIn(0.0, 1.0)
        if (f > 0) c.drawArc(r, -90f, (360 * f).toFloat(), false, p.apply { this.color = color })
        return bmp
    }

    /** A horizontal bar split into parts in proportion, each in its colour (sleep stages, macros). */
    fun stack(parts: List<Pair<Double, Int>>, track: Int, w: Int, h: Int, density: Float): Bitmap? {
        val bmp = bitmap(w, h) ?: return null
        val c = Canvas(bmp)
        val radius = h / 2f
        val clip = Path().apply { addRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), radius, radius, Path.Direction.CW) }
        c.clipPath(clip)
        c.drawColor(track)
        val total = parts.sumOf { it.first }.takeIf { it > 0 } ?: return bmp
        var x = 0f
        parts.forEach { (value, color) ->
            val width = (w * (value / total)).toFloat()
            c.drawRect(RectF(x, 0f, x + width, h.toFloat()), Paint().apply { this.color = color })
            x += width
        }
        return bmp
    }
}
