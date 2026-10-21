package org.phoneagent.app

import kotlin.math.roundToInt


object WidgetGrokQuota {
    fun text(
        provider: String?, expectedProvider: String, remaining: Double,
        sampledAt: Long, resetsAt: Long, stale: Boolean, offline: Boolean, now: Long,
    ): String {
        if (provider != expectedProvider || stale || offline ||
            !remaining.isFinite() || remaining !in 0.0..100.0 ||
            sampledAt <= 0L || now - sampledAt !in 0L..1800L || resetsAt <= now
        ) return "--"
        return "${remaining.roundToInt()}%"
    }
}
