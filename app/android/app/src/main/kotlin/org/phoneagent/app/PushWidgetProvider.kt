package org.phoneagent.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import android.widget.Toast
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt
import org.json.JSONObject


class PushWidgetProvider : AppWidgetProvider() {
    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"


        private const val TAG = "PhoneAgentWidget"
        private const val SNAP_PREFS = "widget_snapshot_prefs"
        private const val SNAP_KEY_JSON = "snapshot_json"
        private const val SNAP_KEY_AT = "snapshot_at_epoch"


        private const val KEY_REMAIN = "flutter.latest_push_remain_pct"
        private const val KEY_ELAPSED = "flutter.latest_push_elapsed_min"
        private const val KEY_REFRESH = "flutter.latest_push_refresh_h"
        private const val KEY_FETCH_AT = "flutter.latest_push_fetch_at_epoch"
        private const val KEY_REFRESH_AT = "flutter.latest_push_refresh_at_epoch"
        private const val KEY_RESET_CREDITS_KNOWN = "flutter.codex_reset_credits_known"
        private const val KEY_RESET_CREDITS_AVAILABLE = "flutter.codex_reset_credits_available"
        private const val KEY_RESET_CREDIT_EARLIEST_EXPIRY =
            "flutter.codex_reset_credit_earliest_expiry"


        private const val KEY_TITLE = "flutter.latest_push_title"
        private const val KEY_BODY = "flutter.latest_push_body"
        private const val KEY_LEVEL = "flutter.latest_push_level"
        private const val KEY_TS_EPOCH = "flutter.latest_push_ts_epoch"
        private const val KEY_AGENT_ID = "flutter.latest_push_agent_id"


        private const val KEY_MUTE_GLOBAL = "flutter.mute_global_enabled"


        private const val KEY_PAI_RUNNING = "flutter.widget_pai_running"
        private const val KEY_PAI_DONE = "flutter.widget_pai_pending_review"
        private const val KEY_PAI_FAILED = "flutter.widget_pai_failed"


        private const val KEY_ALERT_LEVEL = "flutter.widget_machine_alert_level"
        private const val KEY_ALERT_TEXT = "flutter.widget_machine_alert_text"
        private const val KEY_ALERTS_TOTAL = "flutter.widget_machine_alerts_total"


        private const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"


        private val WIDGET_SUMMARY_URL = BuildConfig.WIDGET_SUMMARY_URL


        private val PAI_ACK_URL = BuildConfig.PAI_ACK_URL


        private const val KEY_LISTEN_TOKEN = "flutter.widget_listen_token"


        private const val KEY_FETCH_STATE = "flutter.widget_fetch_state"
        private const val STATE_OK = "ok"
        private const val STATE_UNPAIRED = "unpaired"
        private const val STATE_UNREACHABLE = "unreachable"
        private const val STATE_HTTP_ERROR_PREFIX = "http_"


        const val ACTION_REFRESH = "org.phoneagent.app.REFRESH_WIDGET"
        private const val ACTION_OPEN = "org.phoneagent.app.OPEN_FROM_WIDGET"
        private const val ACTION_TOGGLE_MUTE = "org.phoneagent.app.WIDGET_TOGGLE_MUTE"
        private const val ACTION_QUICK_SEND = "org.phoneagent.app.WIDGET_QUICK_SEND"


        private const val ACTION_TEST_PUSH = "org.phoneagent.app.TEST_PUSH"

        private const val ACTION_CLEAR_DONE = "org.phoneagent.app.WIDGET_CLEAR_DONE"


        private const val KEY_LAST_RENDERED_DONE = "last_rendered_pai_done"


        private val ALERT_LINE_IDS = intArrayOf(R.id.widget_machine_alert)

        private fun readDouble(all: Map<String, *>, key: String, default: Double): Double = try {
            when (val raw = all[key]) {
                is String -> if (raw.startsWith(DOUBLE_PREFIX)) raw.substring(DOUBLE_PREFIX.length).toDouble() else default
                is Long -> java.lang.Double.longBitsToDouble(raw)
                is Double -> raw
                else -> default
            }
        } catch (_: Exception) { default }

        private fun earliestResetCreditExpiry(quota: JSONObject?): Long {
            val expiries = quota?.optJSONArray("reset_credit_expiries") ?: return 0L
            var earliest = Long.MAX_VALUE
            for (i in 0 until expiries.length()) {
                val expiry = expiries.optLong(i, 0L)
                if (expiry > 0L && expiry < earliest) earliest = expiry
            }
            return if (earliest == Long.MAX_VALUE) 0L else earliest
        }

        private fun readEpoch(all: Map<String, *>, key: String): Long = try {
            when (val raw = all[key]) {
                is Long -> raw
                is Int -> raw.toLong()
                is String -> raw.toLongOrNull() ?: 0L
                else -> 0L
            }
        } catch (_: Exception) { 0L }

        private fun readString(all: Map<String, *>, key: String): String = try {
            when (val raw = all[key]) {
                is String -> raw
                else -> ""
            }
        } catch (_: Exception) { "" }

        private fun readBool(all: Map<String, *>, key: String, default: Boolean): Boolean = try {
            when (val raw = all[key]) {
                is Boolean -> raw
                else -> default
            }
        } catch (_: Exception) { default }

        private fun readInt(all: Map<String, *>, key: String, default: Int): Int = try {
            when (val raw = all[key]) {
                is Int -> raw
                is Long -> raw.toInt()
                else -> default
            }
        } catch (_: Exception) { default }


        private fun saveSnapshot(context: Context, rawJson: String) {
            context.getSharedPreferences(SNAP_PREFS, Context.MODE_PRIVATE).edit()
                .putString(SNAP_KEY_JSON, rawJson)
                .putLong(SNAP_KEY_AT, System.currentTimeMillis() / 1000L)
                .commit()
        }


        private fun loadSnapshot(context: Context): Pair<JSONObject, Long>? {
            val p = context.getSharedPreferences(SNAP_PREFS, Context.MODE_PRIVATE)
            val raw = p.getString(SNAP_KEY_JSON, null) ?: return null
            val at = p.getLong(SNAP_KEY_AT, 0L)
            return try {
                Pair(JSONObject(raw), at)
            } catch (_: Exception) {


                null
            }
        }

        private fun fetchLatest(context: Context) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val token = prefs.getString(KEY_LISTEN_TOKEN, null)
            if (token.isNullOrEmpty()) {


                prefs.edit().putString(KEY_FETCH_STATE, STATE_UNPAIRED).commit()
                return
            }
            var conn: HttpURLConnection? = null
            try {
                val (responseCode, rawBody) = WidgetIngress.summary(prefs)
                if (responseCode != 200) {
                    prefs.edit().putString(KEY_FETCH_STATE, "$STATE_HTTP_ERROR_PREFIX$responseCode").commit()
                    return
                }
                val root = JSONObject(rawBody)


                val machine = root.optJSONObject("machine")
                if (!root.has("grok_bot_quota") ||
                    (machine != null && !machine.has("openrouter_balance"))) {
                    try {
                        val secondary = WidgetIngress.walletSummary(prefs)?.let(::JSONObject)
                        if (machine != null && !machine.has("openrouter_balance")) {
                            secondary?.optJSONObject("machine")
                                ?.optJSONObject("openrouter_balance")?.let { wallet ->
                                    machine.put("openrouter_balance", wallet)
                                }
                        }
                        if (!root.has("grok_bot_quota")) {
                            secondary?.optJSONObject("grok_bot_quota")?.let { bot ->
                                root.put("grok_bot_quota", bot)
                                Log.i(TAG, "botSource=shared-readonly primary-schema=old")
                            }
                        }
                    } catch (_: Exception) {                          }
                }

                saveSnapshot(context, root.toString())
                val editor = prefs.edit()

                val quota = root.optJSONObject("quota")
                if (quota != null) {
                    val remain = quota.optDouble("remain_pct", -1.0)
                    val elapsed = quota.optDouble("elapsed_min", 0.0)
                    val refresh = quota.optDouble("refresh_h", -1.0)
                    val fetchAt = quota.optLong("fetch_at_epoch", 0L)
                    val refreshAt = quota.optLong("refresh_at_epoch", 0L)
                    val resetKnown = quota.optBoolean("reset_credits_known", false)
                    val resetAvailable = quota.optInt("reset_credits_available", -1)
                    val earliestExpiry = earliestResetCreditExpiry(quota)
                    editor.putLong(KEY_REMAIN, java.lang.Double.doubleToRawLongBits(remain))
                    editor.putLong(KEY_ELAPSED, java.lang.Double.doubleToRawLongBits(elapsed))
                    editor.putLong(KEY_REFRESH, java.lang.Double.doubleToRawLongBits(refresh))
                    editor.putLong(KEY_FETCH_AT, fetchAt)
                    editor.putLong(KEY_REFRESH_AT, refreshAt)
                    editor.putBoolean(
                        KEY_RESET_CREDITS_KNOWN,
                        resetKnown && resetAvailable >= 0,
                    )
                    editor.putInt(
                        KEY_RESET_CREDITS_AVAILABLE,
                        if (resetKnown && resetAvailable >= 0) resetAvailable else -1,
                    )
                    editor.putLong(
                        KEY_RESET_CREDIT_EARLIEST_EXPIRY,
                        if (resetKnown && resetAvailable > 0) earliestExpiry else 0L,
                    )
                } else {
                    editor.putLong(KEY_REMAIN, java.lang.Double.doubleToRawLongBits(-1.0))
                    editor.putBoolean(KEY_RESET_CREDITS_KNOWN, false)
                    editor.putInt(KEY_RESET_CREDITS_AVAILABLE, -1)
                    editor.putLong(KEY_RESET_CREDIT_EARLIEST_EXPIRY, 0L)


                    editor.putLong(KEY_FETCH_AT, 0L)
                }

                val latest = root.optJSONObject("latest")
                if (latest != null) {
                    editor.putString(KEY_TITLE, latest.optString("title", ""))
                    editor.putString(KEY_BODY, latest.optString("body", ""))
                    editor.putString(KEY_LEVEL, latest.optString("level", "info"))
                    editor.putLong(KEY_TS_EPOCH, latest.optLong("ts_epoch", 0L))
                    editor.putString(KEY_AGENT_ID, root.optString("role", root.optString("agent_id", "")))
                } else {
                    editor.putString(KEY_TITLE, "")
                }


                root.optJSONObject("pai")?.let { pai ->
                    editor.putInt(KEY_PAI_RUNNING, pai.optInt("running", 0))
                    editor.putInt(KEY_PAI_DONE, pai.optInt("pending_review", 0))
                    editor.putInt(KEY_PAI_FAILED, pai.optInt("failed", 0))
                }
                root.optJSONObject("machine")?.let { machine ->


                    val alert = machine.optJSONObject("alert")
                    editor.putString(KEY_ALERT_LEVEL, alert?.optString("level", "") ?: "")
                    editor.putString(KEY_ALERT_TEXT, alert?.optString("text", "") ?: "")
                    editor.putInt(KEY_ALERTS_TOTAL, machine.optInt("alerts_total", 0))
                }

                editor.putString(KEY_FETCH_STATE, STATE_OK)
                editor.commit()
            } catch (e: Exception) {

                prefs.edit().putString(KEY_FETCH_STATE, STATE_UNREACHABLE).commit()
            } finally {
                conn?.disconnect()
            }
        }

        private fun levelDrawable(level: String): Int = when (level) {
            "ok" -> R.drawable.widget_circle_green
            "warn" -> R.drawable.widget_circle_orange
            "err" -> R.drawable.widget_circle_red
            else -> R.drawable.widget_circle_blue
        }

        private fun relativeTime(epochSeconds: Long): String {
            if (epochSeconds <= 0L) return "--"
            val now = System.currentTimeMillis() / 1000L
            val deltaSec = max(0L, now - epochSeconds)
            return when {
                deltaSec < 60 -> "刚刚"
                deltaSec < 3600 -> "${deltaSec / 60}分钟前"
                deltaSec < 86400 -> "${deltaSec / 3600}小时前"
                else -> "${deltaSec / 86400}天前"
            }
        }

        private fun openPendingIntent(context: Context, agentId: String): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                action = ACTION_OPEN
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                if (agentId.isNotEmpty()) putExtra("open_agent_id", agentId)
            }

            return PendingIntent.getActivity(
                context, agentId.hashCode(), intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }


        private fun openTabPendingIntent(context: Context, tab: String): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                action = ACTION_OPEN
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("open_tab", tab)
            }
            return PendingIntent.getActivity(
                context, tab.hashCode() xor 0x7A16,
                intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }


        private data class AckResult(val ok: Boolean, val acked: Int, val retried: Int, val skipped: Int)


        private fun postAck(context: Context, queryString: String): AckResult {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val token = prefs.getString(KEY_LISTEN_TOKEN, null)
            if (token.isNullOrEmpty()) return AckResult(false, 0, 0, 0)
            var conn: HttpURLConnection? = null
            return try {
                conn = WidgetIngress.openUrl("${WidgetIngress.ack(prefs)}?$queryString")
                conn.instanceFollowRedirects = false
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.requestMethod = "GET"
                conn.setRequestProperty("Authorization", "Bearer $token")
                val code = conn.responseCode
                val ok = code in 200..299
                var acked = 0
                var retried = 0
                var skipped = 0
                if (ok) {
                    try {
                        val body = conn.inputStream.bufferedReader().use { it.readText() }
                        val j = JSONObject(body)
                        acked = j.optInt("acked", 0)
                        retried = j.optInt("retried", 0)
                        skipped = j.optJSONArray("retry_skipped")?.length() ?: 0
                    } catch (e: Exception) {
                        Log.w(TAG, "postAck 响应体解析失败(不影响 ok 判定,只是拿不到 acked/retried 明细): ${e.message}")
                    }
                }
                Log.i(TAG, "postAck query=$queryString responseCode=$code acked=$acked retried=$retried skipped=$skipped")
                AckResult(ok, acked, retried, skipped)
            } catch (e: Exception) {
                Log.w(TAG, "postAck failed: ${e.message}")
                AckResult(false, 0, 0, 0)
            } finally {
                conn?.disconnect()
            }
        }

        private fun broadcastPendingIntent(context: Context, action: String, requestCode: Int): PendingIntent {
            val intent = Intent(context, PushWidgetProvider::class.java).apply { this.action = action }
            return PendingIntent.getBroadcast(
                context, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        @Suppress("unused")
        private fun quickSendPendingIntent(context: Context, agentId: String, agentName: String): PendingIntent {
            val intent = Intent(context, QuickSendActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                putExtra("agent_id", agentId)
                putExtra("agent_name", agentName)
            }
            return PendingIntent.getActivity(
                context, agentId.hashCode() xor 0x51E2D,
                intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        fun updateAllWidgets(context: Context) {
            val all = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).all
            val agentId = readString(all, KEY_AGENT_ID)
            val fetchState = readString(all, KEY_FETCH_STATE)


            val snap = loadSnapshot(context)
            val offline = fetchState != STATE_OK && snap != null
            val snapJson = snap?.first
            val snapAt = snap?.second ?: 0L


            val staleFlag = (snapJson?.optBoolean("stale", false) ?: false) || offline
            val rolesAgeSec = snapJson?.optLong("roles_age_sec", -1L) ?: -1L

            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, PushWidgetProvider::class.java))


            Log.i(
                TAG,
                "render widgets=${ids.size} fetchState=\"$fetchState\" hasSnapshot=${snapJson != null} " +
                    "offline=$offline stale=$staleFlag snapshotAge=${if (snapAt > 0) relativeTime(snapAt) else "n/a"} " +
                    "rolesAgeSec=$rolesAgeSec"
            )


            val quotaObj = snapJson?.optJSONObject("quota")

            val machineObj = snapJson?.optJSONObject("machine")
            val machineStale = (machineObj?.optBoolean("stale", false) ?: false) || offline
            val machineSuffix = if (machineStale) "·旧" else ""
            val alertsArr = machineObj?.optJSONArray("alerts")
            val alertTexts = mutableListOf<String>()


            val alertLevels = mutableListOf<String>()


            val alertHeals = mutableListOf<String>()
            var worstLevel = ""
            if (alertsArr != null) {
                for (i in 0 until minOf(alertsArr.length(), ALERT_LINE_IDS.size)) {
                    val a = alertsArr.optJSONObject(i) ?: continue
                    val t = a.optString("text", "")
                    if (t.isEmpty()) continue
                    alertTexts.add(t)
                    val lv = a.optString("level", "")
                    alertLevels.add(lv)
                    alertHeals.add(a.optString("heal", "none"))
                    if (worstLevel.isEmpty()) worstLevel = lv
                }
            } else {
                val legacyText = readString(all, KEY_ALERT_TEXT)
                if (legacyText.isNotEmpty()) {
                    alertTexts.add(legacyText)
                    worstLevel = readString(all, KEY_ALERT_LEVEL)
                    alertLevels.add(worstLevel)
                    alertHeals.add("none")
                }
            }
            val alertsTotal = machineObj?.optInt("alerts_total", 0) ?: readInt(all, KEY_ALERTS_TOTAL, 0)


            val internalTotal = machineObj?.optInt("internal_total", 0) ?: 0


            val idleAlertText = "无待办"


            val grokObj = snapJson?.optJSONObject("grok_quota")
            val wallet = snapJson?.optJSONObject("machine")?.optJSONObject("openrouter_balance")
            val walletExpiry = wallet?.optLong("expires_at_epoch", 0L) ?: 0L
            val walletUsable = wallet != null && wallet.optString("provider") == "openrouter" &&
                wallet.optString("currency") == "USD" &&
                !wallet.optBoolean("stale", true) && !offline &&
                walletExpiry > System.currentTimeMillis() / 1000L
            val walletText = WidgetWalletBalance.text(
                wallet?.optDouble("balance_usd", Double.NaN) ?: Double.NaN, walletUsable,
            )
            Log.i(TAG, "walletBalance text=\"$walletText\" usable=$walletUsable")
            val nowSecForGrok = System.currentTimeMillis() / 1000L
            val grokBotObj = snapJson?.optJSONObject("grok_bot_quota")
            fun poolText(value: JSONObject?, provider: String): String = WidgetGrokQuota.text(
                provider = value?.optString("provider"), expectedProvider = provider,
                remaining = value?.optDouble("remain_pct", Double.NaN) ?: Double.NaN,
                sampledAt = value?.optLong("fetch_at_epoch", 0L) ?: 0L,
                resetsAt = value?.optLong("refresh_at_epoch", 0L) ?: 0L,
                stale = value?.optBoolean("stale", true) ?: true,
                offline = offline, now = nowSecForGrok,
            )
            val grokCurrentText = poolText(grokObj, "grok")
            val grokBotText = poolText(grokBotObj, "grokbot")


            Log.i(TAG, "grokPools build=\"$grokCurrentText\" bot=\"$grokBotText\" " +
                "botAvailable=${grokBotObj?.opt("has_available_usage")}")


            Log.i(TAG, "state alerts=${alertTexts.size} alertsTotal=$alertsTotal " +
                "internalTotal=$internalTotal layout=4x1")


            Log.i(TAG, "alertline=\"" + (
                if (alertTexts.isEmpty()) idleAlertText + machineSuffix
                else alertTexts.joinToString(" | ")
            ) + "\"")


            try { WidgetRefreshTicker.start(context.applicationContext) } catch (_: Exception) {}

            for (id in ids) {
                val views = RemoteViews(context.packageName, R.layout.widget_push)
                views.setTextViewText(R.id.widget_wallet_balance, walletText)
                views.setOnClickPendingIntent(
                    R.id.widget_wallet_balance,
                    broadcastPendingIntent(context, ACTION_REFRESH, 17),
                )


                views.setOnClickPendingIntent(R.id.widget_root, openPendingIntent(context, ""))


                views.setOnClickPendingIntent(R.id.widget_row_alert, openPendingIntent(context, ""))


                views.setOnClickPendingIntent(
                    R.id.widget_claude_container,
                    broadcastPendingIntent(context, ACTION_REFRESH, 11),
                )


                views.setOnClickPendingIntent(R.id.widget_quota_container, broadcastPendingIntent(context, ACTION_REFRESH, 9))
                val now = System.currentTimeMillis() / 1000L
                val remainPct = readDouble(all, KEY_REMAIN, -1.0)
                val storedRefresh = readDouble(all, KEY_REFRESH, -1.0)
                val snapshotRefreshAt = quotaObj?.optLong("refresh_at_epoch", 0L) ?: 0L
                val refreshAt = if (snapshotRefreshAt > 0L) {
                    snapshotRefreshAt
                } else {
                    readEpoch(all, KEY_REFRESH_AT)
                }
                val refreshH = if (refreshAt > 0L) {
                    max(0.0, ceil((refreshAt - now) / 3600.0))
                } else {
                    storedRefresh
                }
                val resetCreditsKnown = quotaObj?.optBoolean("reset_credits_known", false)
                    ?: readBool(all, KEY_RESET_CREDITS_KNOWN, false)
                val resetCreditsAvailable = quotaObj?.optInt("reset_credits_available", -1)
                    ?.takeIf { it >= 0 }
                    ?: readInt(all, KEY_RESET_CREDITS_AVAILABLE, -1)
                val snapshotExpiry = earliestResetCreditExpiry(quotaObj)
                val earliestExpiry = if (snapshotExpiry > 0L) {
                    snapshotExpiry
                } else {
                    readEpoch(all, KEY_RESET_CREDIT_EARLIEST_EXPIRY)
                }
                val cardExpiryText = when {
                    !resetCreditsKnown || resetCreditsAvailable < 0 -> "--"
                    resetCreditsAvailable == 0 -> "无"
                    earliestExpiry > 0L ->
                        "${max(0.0, ceil((earliestExpiry - now) / 86400.0)).toInt()}d"
                    else -> "--"
                }
                if (remainPct >= 0) {
                    views.setTextViewText(R.id.widget_metric_current, "${remainPct.roundToInt()}%")
                } else {
                    views.setTextViewText(R.id.widget_metric_current, "--")
                }
                if (refreshH >= 0.0) {
                    views.setTextViewText(R.id.widget_metric_refresh, "${refreshH.toInt()}h")
                } else {
                    views.setTextViewText(R.id.widget_metric_refresh, "--")
                }
                views.setTextViewText(R.id.widget_metric_card_expiry, cardExpiryText)
                Log.i(
                    TAG,
                    "widget[$id] quota current=$remainPct refreshH=$refreshH " +
                        "cardExpiry=$cardExpiryText fixedRects=true compact=true",
                )


                val badge: String? = when {
                    offline -> "离线 · ${relativeTime(snapAt)}"
                    staleFlag && rolesAgeSec >= 0 -> "过期 · ${relativeTime(now - rolesAgeSec)}"
                    staleFlag -> "过期 · ${relativeTime(snapAt)}"
                    else -> null
                }
                if (badge != null) {
                    views.setTextViewText(R.id.widget_status_badge, badge)
                    views.setViewVisibility(R.id.widget_status_badge, android.view.View.VISIBLE)
                    Log.i(TAG, "widget[$id] badge=\"$badge\"")
                } else {
                    views.setViewVisibility(R.id.widget_status_badge, android.view.View.GONE)
                }


                for ((idx, lineId) in ALERT_LINE_IDS.withIndex()) {
                    if (alertTexts.isEmpty()) {

                        if (idx == 0) {
                            views.setViewVisibility(lineId, View.VISIBLE)


                            views.setTextViewText(lineId, "$idleAlertText$machineSuffix")
                            views.setTextColor(lineId, 0xFF9E9E9E.toInt())
                        } else {
                            views.setViewVisibility(lineId, View.GONE)
                        }
                        continue
                    }
                    if (idx >= alertTexts.size) {
                        views.setViewVisibility(lineId, View.GONE)
                        continue
                    }
                    val isLast = idx == alertTexts.size - 1
                    val overflow = if (isLast && alertsTotal > alertTexts.size) {
                        " +${alertsTotal - alertTexts.size}"
                    } else ""
                    val suffix = if (isLast) "$overflow$machineSuffix" else ""


                    val defaultPrefix = if (idx == 0) "⚠ " else "· "


                    val lv = alertLevels.getOrNull(idx) ?: worstLevel
                    val defaultColor = if (lv == "err") 0xFFF44336.toInt() else 0xFFFF9800.toInt()


                    val heal = alertHeals.getOrNull(idx) ?: "none"
                    val (prefix, color) = when (heal) {
                        "healing" -> "🔧 " to 0xFF9E9E9E.toInt()
                        "failed" -> "⚠ " to 0xFFF44336.toInt()
                        else -> defaultPrefix to defaultColor
                    }
                    views.setViewVisibility(lineId, View.VISIBLE)
                    views.setTextViewText(lineId, "$prefix${alertTexts[idx]}$suffix")


                    Log.i(TAG, "alert line$idx VISIBLE text=\"$prefix${alertTexts[idx]}$suffix\" level=${alertLevels.getOrNull(idx)} heal=$heal")
                    views.setTextColor(lineId, color)
                }


                views.setTextViewText(R.id.widget_claude_current, grokCurrentText)
                views.setTextViewText(R.id.widget_claude_refresh, grokBotText)


                var title = readString(all, KEY_TITLE)
                var body = readString(all, KEY_BODY)
                var level = readString(all, KEY_LEVEL).ifEmpty { "info" }
                var tsEpoch = readEpoch(all, KEY_TS_EPOCH)


                if (title.isEmpty()) {
                    snapJson?.optJSONObject("latest")?.let { l ->
                        title = l.optString("title", "")
                        body = l.optString("body", "")
                        level = l.optString("level", "info").ifEmpty { "info" }
                        tsEpoch = l.optLong("ts_epoch", 0L)
                    }
                }
                val statusMessage: String? = when {
                    fetchState == STATE_UNPAIRED -> "未配对 · 点此重试"
                    fetchState == STATE_UNREACHABLE -> "网络不可达 · 点此重试"
                    fetchState.startsWith(STATE_HTTP_ERROR_PREFIX) ->
                        "数据源${fetchState.removePrefix(STATE_HTTP_ERROR_PREFIX)} · 未授权"
                    else -> null
                }

                if (title.isNotEmpty()) {
                    views.setViewVisibility(R.id.widget_row_middle, android.view.View.VISIBLE)
                    views.setViewVisibility(R.id.widget_generic_container, android.view.View.VISIBLE)
                    views.setTextViewText(R.id.widget_generic_title, title)
                    views.setTextViewText(R.id.widget_generic_body, body)


                    views.setTextViewText(
                        R.id.widget_generic_time,
                        if (offline) "离线 · ${relativeTime(tsEpoch)}" else relativeTime(tsEpoch)
                    )

                    views.setImageViewResource(
                        R.id.widget_generic_dot,
                        if (staleFlag) R.drawable.widget_circle_gray else levelDrawable(level)
                    )


                    views.setOnClickPendingIntent(
                        R.id.widget_generic_container,
                        if (offline) broadcastPendingIntent(context, ACTION_REFRESH, 5)
                        else openPendingIntent(context, agentId)
                    )
                } else if (snapJson != null) {


                    views.setViewVisibility(R.id.widget_row_middle, View.GONE)
                } else if (statusMessage != null) {
                    views.setViewVisibility(R.id.widget_row_middle, android.view.View.VISIBLE)
                    views.setViewVisibility(R.id.widget_generic_container, android.view.View.VISIBLE)
                    views.setTextViewText(R.id.widget_generic_title, "widget 状态")
                    views.setTextViewText(R.id.widget_generic_body, statusMessage)
                    views.setTextViewText(R.id.widget_generic_time, "")
                    views.setImageViewResource(R.id.widget_generic_dot, R.drawable.widget_circle_red)


                    views.setOnClickPendingIntent(
                        R.id.widget_generic_container,
                        broadcastPendingIntent(context, ACTION_REFRESH, 4)
                    )
                } else {


                    views.setViewVisibility(R.id.widget_row_middle, android.view.View.VISIBLE)
                    views.setViewVisibility(R.id.widget_generic_container, android.view.View.VISIBLE)
                    views.setTextViewText(R.id.widget_generic_title, "正在加载")
                    views.setTextViewText(R.id.widget_generic_body, "还没拉到过数据 · 点此刷新")
                    views.setTextViewText(R.id.widget_generic_time, "")
                    views.setImageViewResource(R.id.widget_generic_dot, R.drawable.widget_circle_gray)
                    views.setOnClickPendingIntent(
                        R.id.widget_generic_container,
                        broadcastPendingIntent(context, ACTION_REFRESH, 7)
                    )
                }


                mgr.updateAppWidget(id, views)
            }
        }
    }


    private fun ensureAliveOpportunistically(ctx: Context) {
        BootReceiver.reviveWithFallback(ctx.applicationContext, "widget")
    }


    private fun showRefreshing(ctx: Context) {
        try {
            val mgr = AppWidgetManager.getInstance(ctx)
            val ids = mgr.getAppWidgetIds(ComponentName(ctx, PushWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val v = RemoteViews(ctx.packageName, R.layout.widget_push)
            v.setTextViewText(R.id.widget_status_badge, "刷新中…")
            v.setViewVisibility(R.id.widget_status_badge, View.VISIBLE)
            for (id in ids) mgr.partiallyUpdateAppWidget(id, v)
            Log.i(TAG, "showRefreshing applied to ${ids.size} widget(s)")
        } catch (e: Exception) {

            Log.w(TAG, "showRefreshing failed: ${e.message}")
        }
    }

    private fun refreshAsync(ctx: Context) {
        showRefreshing(ctx)
        val pending = goAsync()
        Thread {
            try {
                ensureAliveOpportunistically(ctx)
                try { fetchLatest(ctx.applicationContext) } catch (_: Exception) {}
                updateAllWidgets(ctx.applicationContext)
            } finally {
                pending.finish()
            }
        }.start()
    }


    private fun clearDoneAsync(context: Context) {
        val pending = goAsync()
        Thread {
            try {
                val result = postAck(context.applicationContext, "all_done=1")
                Log.i(TAG, "clearDone ack ok=${result.ok} acked=${result.acked} " +
                        "retried=${result.retried} skipped=${result.skipped}")
                try { fetchLatest(context.applicationContext) } catch (_: Exception) {}
                updateAllWidgets(context.applicationContext)
                val msg = if (result.ok) {
                    buildString {
                        append("已归档${result.acked} · 已重派${result.retried}")
                        if (result.skipped > 0) append(" · 跳过${result.skipped}")
                    }
                } else {
                    "重派失败 · 网络不通或未配对"
                }
                Handler(Looper.getMainLooper()).post {
                    Toast.makeText(context.applicationContext, msg, Toast.LENGTH_LONG).show()
                }
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun toggleMute(context: Context) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val current = prefs.getBoolean(KEY_MUTE_GLOBAL, false)
        prefs.edit().putBoolean(KEY_MUTE_GLOBAL, !current).commit()
        updateAllWidgets(context.applicationContext)
    }

    private fun handleTestPush(context: Context, intent: Intent) {
        val editor = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
        val kind = intent.getStringExtra("kind") ?: "generic"
        editor.putString(KEY_AGENT_ID, intent.getStringExtra("agent_id") ?: "")
        if (kind == "quota") {
            val remain = intent.getDoubleExtra("remain_pct", -1.0)
            val elapsed = intent.getDoubleExtra("elapsed_min", 0.0)
            val refresh = intent.getDoubleExtra("refresh_h", -1.0)
            editor.putLong(KEY_REMAIN, java.lang.Double.doubleToRawLongBits(remain))
            editor.putLong(KEY_ELAPSED, java.lang.Double.doubleToRawLongBits(elapsed))
            editor.putLong(KEY_REFRESH, java.lang.Double.doubleToRawLongBits(refresh))


            val fetchAgeMin = intent.getDoubleExtra("fetch_age_min", 0.0)
            editor.putLong(KEY_FETCH_AT, System.currentTimeMillis() / 1000L - (fetchAgeMin * 60).toLong())
            editor.putLong(KEY_REFRESH_AT, System.currentTimeMillis() / 1000L + 3600L)
        } else {
            editor.putString(KEY_TITLE, intent.getStringExtra("title") ?: "")
            editor.putString(KEY_BODY, intent.getStringExtra("body") ?: "")
            editor.putString(KEY_LEVEL, intent.getStringExtra("level") ?: "info")
            val tsEpoch = intent.getLongExtra("ts_epoch", System.currentTimeMillis() / 1000L)
            editor.putLong(KEY_TS_EPOCH, tsEpoch)
        }
        if (kind == "pai_machine") {


            editor.putInt(KEY_PAI_RUNNING, intent.getIntExtra("pai_running", 0))
            editor.putInt(KEY_PAI_DONE, intent.getIntExtra("pai_pending_review", 0))
            editor.putInt(KEY_PAI_FAILED, intent.getIntExtra("pai_failed", 0))
            editor.putString(KEY_ALERT_LEVEL, intent.getStringExtra("alert_level") ?: "")
            editor.putString(KEY_ALERT_TEXT, intent.getStringExtra("alert_text") ?: "")
            editor.putInt(KEY_ALERTS_TOTAL, intent.getIntExtra("alerts_total", 0))
        }
        if (kind == "snapshot_json") {


            val b64 = intent.getStringExtra("raw_json_b64")
            val raw = if (b64 != null) {
                String(android.util.Base64.decode(b64, android.util.Base64.DEFAULT), Charsets.UTF_8)
            } else {
                "{}"
            }
            saveSnapshot(context, raw)
        }
        editor.commit()
        updateAllWidgets(context.applicationContext)
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_REFRESH -> refreshAsync(context)
            ACTION_TOGGLE_MUTE -> toggleMute(context)
            ACTION_CLEAR_DONE -> clearDoneAsync(context)


            ACTION_TEST_PUSH -> if (BuildConfig.DEBUG) handleTestPush(context, intent)
            else -> super.onReceive(context, intent)
        }
    }

    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) = refreshAsync(ctx)

    override fun onEnabled(ctx: Context) = updateAllWidgets(ctx)


    override fun onAppWidgetOptionsChanged(
        ctx: Context,
        mgr: AppWidgetManager,
        id: Int,
        newOptions: android.os.Bundle
    ) {
        super.onAppWidgetOptionsChanged(ctx, mgr, id, newOptions)
        updateAllWidgets(ctx.applicationContext)
    }
}
