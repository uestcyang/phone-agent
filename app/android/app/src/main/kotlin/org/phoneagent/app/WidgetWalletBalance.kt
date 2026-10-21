package org.phoneagent.app

import java.util.Locale


object WidgetWalletBalance {
    fun text(amount: Double, usable: Boolean): String {
        if (!usable || !amount.isFinite() || amount < 0) return "--"
        val exact = String.format(Locale.US, "%.2f", amount)
        if (exact.length <= 6) return exact
        val divisor = if (amount >= 1_000_000) 1_000_000.0 else 1_000.0
        val suffix = if (amount >= 1_000_000) "m" else "k"
        val compact = String.format(Locale.US, "%.1f%s", amount / divisor, suffix)
        return if (compact.length <= 6) compact else "--"
    }
}
