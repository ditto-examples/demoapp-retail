package live.ditto.zava.ui

import java.text.NumberFormat
import java.util.Locale

/// 1:1 with the Swift reference's Formatters.
object Formatters {
    private val currency = NumberFormat.getCurrencyInstance(Locale.US)

    fun usd(value: Double): String =
        runCatching { currency.format(value) }.getOrElse { "$%.2f".format(Locale.US, value) }

    /// "2025-06-27T18:20:00Z" → "2025-06-27 18:20" — string surgery only
    /// (ISO strings sort lexicographically; no date math needed).
    fun dateTime(iso: String): String =
        if (iso.length >= 16) iso.take(10) + " " + iso.drop(11).take(5) else iso
}

/** Thousands-grouped integer, like Swift's `Int.formatted()`. */
fun Int.formatted(): String = NumberFormat.getIntegerInstance(Locale.US).format(this)

fun Long.formatted(): String = NumberFormat.getIntegerInstance(Locale.US).format(this)
