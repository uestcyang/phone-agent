package org.phoneagent.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat


object PushNotifications {
    private const val TAG = "PhoneAgentPush"


    const val CHANNEL_ID = "phone_agent_push_alert"


    private val LEGACY_CHANNEL_IDS = listOf("phone_agent_push", "phone_agent_push_v2")


    const val SILENT_CHANNEL_ID = "phone_agent_push_silent"
    const val KEY_REPLY_TEXT = "key_reply_text"
    const val EXTRA_AGENT_ID = "agent_id"
    const val EXTRA_AGENT_NAME = "agent_name"
    const val ACTION_REPLY = "org.phoneagent.app.NOTIF_REPLY"


    private const val WEARABLE_SUMMARY_MAX = 40


    private val VIBRATION_PATTERN = longArrayOf(0, 250, 150, 250)


    private val BOILERPLATE_PREFIXES = listOf(
        "手机 Agent 在线", "手机Agent 在线", "手机Agent 运行中", "手机 Agent 运行中",
        "正在连接", "正在恢复连接", "已连接",
    )


    private const val MAX_HISTORY = 30
    private val history = mutableMapOf<String, MutableList<NotificationCompat.MessagingStyle.Message>>()

    fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(CHANNEL_ID, "手机 Agent 完工/消息", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "角色完工或有新消息时提醒（响铃 + 双短震，由系统通知设置控制）"
                enableVibration(true)


                vibrationPattern = VIBRATION_PATTERN
                setShowBadge(true)
            }
            nm.createNotificationChannel(channel)
        }
        if (nm.getNotificationChannel(SILENT_CHANNEL_ID) == null) {
            val silent = NotificationChannel(SILENT_CHANNEL_ID, "手机 Agent 完工/消息(免打扰)", NotificationManager.IMPORTANCE_LOW).apply {
                description = "免打扰期间的完工/消息——仍然进通知栏，只是不响不震不弹横幅"
                enableVibration(false)
                setSound(null, null)
                setShowBadge(true)
            }
            nm.createNotificationChannel(silent)
        }
        deleteLegacyChannels(nm)
    }


    private fun deleteLegacyChannels(nm: NotificationManager) {
        val busy = try {
            nm.activeNotifications.mapNotNull { it.notification?.channelId }.toSet()
        } catch (e: Exception) {


            Log.w(TAG, "activeNotifications unavailable, keep legacy channels", e)
            return
        }
        for (id in LEGACY_CHANNEL_IDS) {
            if (nm.getNotificationChannel(id) == null) continue
            if (busy.contains(id)) {
                Log.i(TAG, "legacy channel $id still has active notifications, defer delete")
                continue
            }
            nm.deleteNotificationChannel(id)
            Log.i(TAG, "deleted legacy channel $id")
        }
    }


    fun wearableSummary(raw: String, fallback: String): String {
        val lines = raw.split('\n')
        var picked: String? = null
        for (line in lines) {
            val t = line.trim()
            if (t.isEmpty()) continue
            if (BOILERPLATE_PREFIXES.any { t.startsWith(it) }) continue
            picked = t
            break
        }
        if (picked == null) picked = lines.firstOrNull { it.isNotBlank() }?.trim()
        val collapsed = (picked ?: "").replace(Regex("\\s+"), " ").trim()
        val body = if (collapsed.isEmpty()) fallback else collapsed


        val codePointCount = body.codePointCount(0, body.length)
        return if (codePointCount <= WEARABLE_SUMMARY_MAX) body
        else {
            val cutEnd = body.offsetByCodePoints(0, WEARABLE_SUMMARY_MAX - 1)
            body.substring(0, cutEnd).trimEnd() + "…"
        }
    }

    private fun notifIdFor(agentId: String) = agentId.hashCode() and 0x7fffffff

    private fun appIcon(context: Context) = IconCompat.createWithResource(context, context.applicationInfo.icon)

    private fun agentPerson(context: Context, agentId: String, displayName: String): Person =
        Person.Builder()
            .setName(displayName)
            .setKey(agentId)
            .setIcon(appIcon(context))
            .setImportant(true)
            .build()

    private fun openIntent(context: Context, agentId: String): Intent =
        (context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent(context, MainActivity::class.java)).apply {
            action = Intent.ACTION_VIEW
            putExtra("open_agent_id", agentId)
        }

    private fun contentIntent(context: Context, notifId: Int, agentId: String): PendingIntent {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, notifId, openIntent(context, agentId), flags)
    }


    private fun ensureShortcut(context: Context, agentId: String, displayName: String, person: Person) {
        val shortcut = ShortcutInfoCompat.Builder(context, agentId)
            .setLongLived(true)
            .setShortLabel(displayName)
            .setIcon(appIcon(context))
            .setPerson(person)
            .setCategories(setOf("org.phoneagent.app.category.CHAT"))
            .setIntent(openIntent(context, agentId))
            .build()
        try {
            ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
        } catch (_: Exception) {

        }
    }


    fun publishShareTargets(context: Context, agents: List<Map<String, String>>) {
        val limit = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context)
        val shortcuts = agents.distinctBy { it["id"] }.take(limit).mapIndexedNotNull { rank, agent ->
            val id = agent["id"]?.takeIf { it.isNotBlank() } ?: return@mapIndexedNotNull null
            val name = agent["name"]?.takeIf { it.isNotBlank() } ?: id
            ShortcutInfoCompat.Builder(context, id)
                .setLongLived(true).setShortLabel(name).setRank(rank)
                .setIcon(appIcon(context)).setPerson(agentPerson(context, id, name))
                .setCategories(setOf("org.phoneagent.app.category.CHAT"))
                .setIntent(openIntent(context, id)).build()
        }

        check(ShortcutManagerCompat.setDynamicShortcuts(context, shortcuts)) {
            "Shortcut publication was throttled"
        }
    }

    private fun replyAction(context: Context, notifId: Int, agentId: String, displayName: String): NotificationCompat.Action {
        val remoteInput = RemoteInput.Builder(KEY_REPLY_TEXT).setLabel("回复").build()
        val replyIntent = Intent(context, ReplyReceiver::class.java).apply {
            action = ACTION_REPLY
            putExtra(EXTRA_AGENT_ID, agentId)
            putExtra(EXTRA_AGENT_NAME, displayName)
        }


        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        flags = flags or PendingIntent.FLAG_MUTABLE
        val replyPendingIntent = PendingIntent.getBroadcast(context, notifId, replyIntent, flags)
        return NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send, "回复", replyPendingIntent
        )
            .addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(false)
            .setShowsUserInterface(false)
            .build()
    }

    private fun bubbleMetadata(context: Context, notifId: Int, agentId: String): NotificationCompat.BubbleMetadata? {


        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val bubbleIntent = PendingIntent.getActivity(
            context, notifId, openIntent(context, agentId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )
        return NotificationCompat.BubbleMetadata.Builder(bubbleIntent, appIcon(context))
            .setDesiredHeight(600)
            .setAutoExpandBubble(false)
            .setSuppressNotification(false)
            .build()
    }


    fun post(
        context: Context,
        agentId: String,
        displayName: String,
        body: String,
        fromUser: Boolean = false,
        silent: Boolean = false,
    ) {
        createChannel(context)
        val notifId = notifIdFor(agentId)
        val person = agentPerson(context, agentId, displayName)
        ensureShortcut(context, agentId, displayName, person)

        val list = history.getOrPut(agentId) { mutableListOf() }
        val message = if (fromUser) {
            NotificationCompat.MessagingStyle.Message(body, System.currentTimeMillis(), null as Person?)
        } else {
            NotificationCompat.MessagingStyle.Message(body, System.currentTimeMillis(), person)
        }
        list.add(message)
        while (list.size > MAX_HISTORY) list.removeAt(0)


        val style = NotificationCompat.MessagingStyle(Person.Builder().setName("我").build())
            .setGroupConversation(false)
        for (m in list) style.addMessage(m)

        val builder = NotificationCompat.Builder(context, if (silent) SILENT_CHANNEL_ID else CHANNEL_ID)
            .setContentTitle(displayName)
            .setContentText(body)
            .setStyle(style)
            .setSmallIcon(context.applicationInfo.icon)


            .setPriority(if (silent) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setOnlyAlertOnce(fromUser)
            .setContentIntent(contentIntent(context, notifId, agentId))
            .setShortcutId(agentId)


            .setLocalOnly(false)
            .addAction(replyAction(context, notifId, agentId, displayName))
        bubbleMetadata(context, notifId, agentId)?.let { builder.setBubbleMetadata(it) }

        val notification = builder.build()


        val summary = wearableSummary(body, displayName)
        notification.extras.putCharSequence(Notification.EXTRA_TITLE, displayName)
        notification.extras.putCharSequence(Notification.EXTRA_TEXT, summary)

        val nm = context.getSystemService(NotificationManager::class.java)
        nm.notify(notifId, notification)


        Log.i(
            TAG,
            "posted id=$notifId agent=$agentId channel=${if (silent) SILENT_CHANNEL_ID else CHANNEL_ID} " +
                "silent=$silent localOnly=false title=\"$displayName\" summary=\"$summary\""
        )
    }
}
