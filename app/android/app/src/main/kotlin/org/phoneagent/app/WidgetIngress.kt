package org.phoneagent.app

import android.content.SharedPreferences
import java.net.HttpURLConnection
import java.net.URL
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URI


object WidgetIngress {
    const val SUMMARY_KEY = "flutter.widget_summary_url"
    const val ACK_KEY = "flutter.widget_ack_url"
    const val WALLET_TOKEN_KEY = "flutter.widget_wallet_token"
    private const val RETRY_PUBLIC_KEY = "flutter.widget_retry_public_after"
    private const val COOLDOWN_MS = 15 * 60 * 1000L
    private fun publicUrl(path: String): String? =
        BuildConfig.PA_PUBLIC_ORIGIN.takeIf { it.isNotEmpty() }?.let { "$it/agents/agent_a$path" }
    private fun backupUrl(path: String): String? =
        BuildConfig.PA_BACKUP_ORIGIN.takeIf { it.isNotEmpty() }?.let { "$it/agents/agent_a$path" }

    fun openUrl(value: String): HttpURLConnection = URL(value).openConnection() as HttpURLConnection

    fun trusted(value: String?, path: String, legacy: String): Boolean =
        value == legacy || (value != null && (value == publicUrl(path) || value == backupUrl(path)))

    fun summary(
        prefs: SharedPreferences,
        now: () -> Long = System::currentTimeMillis,
        open: (String) -> HttpURLConnection = ::openUrl
    ): Pair<Int, String> {
        val token = prefs.getString("flutter.widget_listen_token", "") ?: ""
        val mirror = prefs.getString(SUMMARY_KEY, null)
        val retryAt = prefs.getLong(RETRY_PUBLIC_KEY, 0L)
        val public = publicUrl("/widget_summary")
        val first = if (public != null && retryAt > 0L && now() >= retryAt) public
            else if (trusted(mirror, "/widget_summary", BuildConfig.WIDGET_SUMMARY_URL)) mirror!!
            else publicUrl("/widget_summary") ?: BuildConfig.WIDGET_SUMMARY_URL
        val backup = backupUrl("/widget_summary")
        val candidates = (listOf(first) +
            (if (first == public) listOfNotNull(backup) else emptyList()) +
            listOf(BuildConfig.WIDGET_SUMMARY_URL)).distinct()
        var last: Exception? = null
        for ((index, url) in candidates.withIndex()) {
            var conn: HttpURLConnection? = null
            try {
                conn = open(url)
                conn.instanceFollowRedirects = false
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.setRequestProperty("Authorization", "Bearer $token")
                val code = conn.responseCode
                if (code in 502..504 && index + 1 < candidates.size) {
                    prefs.edit().putLong(RETRY_PUBLIC_KEY, now() + COOLDOWN_MS).commit()
                    continue
                }

                val body = if (code == 200) conn.inputStream.bufferedReader().use { it.readText() } else ""
                if (code == 200) {
                    prefs.edit().putString(SUMMARY_KEY, url)
                        .putString(ACK_KEY, when (url) {
                            BuildConfig.WIDGET_SUMMARY_URL -> BuildConfig.PAI_ACK_URL
                            backup -> backupUrl("/pai/ack")
                            else -> publicUrl("/pai/ack")
                        })
                        .putLong(RETRY_PUBLIC_KEY, if (url == public) 0L else prefs.getLong(RETRY_PUBLIC_KEY, 0L))
                        .commit()
                }
                return code to body
            } catch (e: Exception) {
                last = e
                if (url == public) {
                    prefs.edit().putLong(RETRY_PUBLIC_KEY, now() + COOLDOWN_MS).commit()
                }
                if (index + 1 == candidates.size) throw e
            } finally { conn?.disconnect() }
        }
        throw last ?: IllegalStateException("no trusted widget route")
    }

    fun ack(prefs: SharedPreferences): String {
        val mirror = prefs.getString(ACK_KEY, null)
        return if (trusted(mirror, "/pai/ack", BuildConfig.PAI_ACK_URL)) mirror!! else BuildConfig.PAI_ACK_URL
    }


    fun walletSummary(
        prefs: SharedPreferences,
        open: (String) -> HttpURLConnection = ::openUrl
    ): String? {
        if (BuildConfig.PA_PUBLIC_ORIGIN.isEmpty()) return null
        val token = prefs.getString(WALLET_TOKEN_KEY, "") ?: ""
        if (token.isEmpty()) return null
        val candidates = listOf(BuildConfig.PA_PUBLIC_ORIGIN, BuildConfig.PA_BACKUP_ORIGIN)
            .filter { it.isNotEmpty() }.distinct()
            .map { "$it/agents/agent_a/widget_summary" }
        for ((index, url) in candidates.withIndex()) {
            var conn: HttpURLConnection? = null
            try {
                conn = open(url)
                conn.instanceFollowRedirects = false
                conn.connectTimeout = 4000
                conn.readTimeout = 4000
                conn.setRequestProperty("Authorization", "Bearer $token")
                val code = conn.responseCode
                if (code in 502..504 && index + 1 < candidates.size) continue
                if (code != 200) return null


                return conn.inputStream.bufferedReader().use { reader ->
                    val buffer = CharArray(4096)
                    val body = StringBuilder()
                    while (true) {
                        val count = reader.read(buffer)
                        if (count < 0) break
                        if (body.length + count > 65536) return null
                        body.append(buffer, 0, count)
                    }
                    body.toString()
                }
            } catch (_: Exception) {
                if (index + 1 == candidates.size) return null
            } finally { conn?.disconnect() }
        }
        return null
    }
}
