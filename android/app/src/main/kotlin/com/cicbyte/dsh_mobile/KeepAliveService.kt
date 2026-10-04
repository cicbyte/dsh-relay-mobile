package com.cicbyte.dsh_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 后台保活前台服务：挂一条低优先级常驻通知，Android 不冻结本进程——
 * 切后台后 Flutter 主 isolate 的 relay WebSocket / mux 流照常运行，
 * 交互卡（提问/授权）与会话更新实时到达，由 Dart 侧经 notifyEvent 弹系统通知。
 *
 * 常驻通知本身即「运行中进度卡」：agent 运行时 Dart 调 keepAliveUpdate 把
 * 标题/任务名写进来，配 setUsesChronometer 系统秒表实时走字（灵动岛式观感，
 * 所有 ROM 通用）；HyperOS 上若装了焦点通知组件则按 miui.focus.param 增强。
 *
 * START_STICKY：被系统回收后自动拉起（连接由 mux 持续重连自愈）。
 */
class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        running = true
        goForeground()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun goForeground() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CH_KEEP, "后台连接保持", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "连接期间常驻，保证切后台仍实时收消息/交互"
                    setShowBadge(false)
                }
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                ID_KEEP, buildKeep(this, "DSH 已连接", "后台保持实时连接（消息/交互照常到达）", null, 0L),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(ID_KEEP, buildKeep(this, "DSH 已连接", "后台保持实时连接（消息/交互照常到达）", null, 0L))
        }
    }

    companion object {
        const val CH_KEEP = "dsh_keepalive"
        const val CH_EVENT = "dsh_events"
        const val ID_KEEP = 1
        const val ID_EVENT = 2

        /** 服务是否在跑（Dart 只在跑的时候更新进度，避免通知脱离 FGS 单独出现） */
        @Volatile var running: Boolean = false

        fun flagImmutable(): Int {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        }

        /** 构建常驻通知：running 时标题=深度求索中…，系统秒表从 startMs 走字 */
        fun buildKeep(
            ctx: Context,
            title: String,
            text: String,
            sessionId: String?,
            chronometerStartMs: Long,
        ): Notification {
            val tap = Intent(ctx, MainActivity::class.java)
            if (!sessionId.isNullOrEmpty()) tap.putExtra("dsh.sessionId", sessionId)
            val pi = PendingIntent.getActivity(
                ctx, 0, tap,
                PendingIntent.FLAG_UPDATE_CURRENT or flagImmutable()
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(ctx, CH_KEEP)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(ctx).setPriority(Notification.PRIORITY_LOW)
            }
            builder
                .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(pi)
                .setOnlyAlertOnce(true)
            if (chronometerStartMs > 0L) {
                // 系统秒表实时走字，无需 Dart 反复更新
                builder.setUsesChronometer(true).setWhen(chronometerStartMs)
            }
            // 小米焦点通知/超级岛增强（miui.focus.param）：未获平台准入时被系统
            // 忽略（普通通知照常），不产生副作用；未来若有权限则自动上岛。
            try {
                val focus = org.json.JSONObject()
                    .put("type", "text")
                    .put("title", title)
                    .put("content", text)
                builder.extras.putString("miui.focus.param", focus.toString())
            } catch (_: Exception) {
            }
            return builder.build()
        }

        /** 更新常驻通知内容（服务在跑才生效）；切后台运行中/回前台复位都走这里 */
        fun update(ctx: Context, title: String, text: String, sessionId: String?, chronometerStartMs: Long) {
            if (!running) return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(ID_KEEP, buildKeep(ctx, title, text, sessionId, chronometerStartMs))
        }
    }
}

/**
 * 事件通知：后台收到的提问/授权/回答完成等，走高优先级通道点开直达 App。
 * 携 sessionId 时点开直达对应会话页（MainActivity onNewIntent → Dart）。
 * 前台时 Dart 侧不会调用（UI 内已呈现，免重复打扰）。
 */
object DshNotifier {
    fun notifyEvent(ctx: Context, title: String, text: String, sessionId: String? = null) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(KeepAliveService.CH_EVENT, "会话与交互提醒", NotificationManager.IMPORTANCE_HIGH)
            )
        }
        val tap = Intent(ctx, MainActivity::class.java)
        if (!sessionId.isNullOrEmpty()) tap.putExtra("dsh.sessionId", sessionId)
        val pi = PendingIntent.getActivity(
            ctx, sessionId?.hashCode() ?: 0, tap,
            PendingIntent.FLAG_UPDATE_CURRENT or KeepAliveService.flagImmutable()
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(ctx, KeepAliveService.CH_EVENT)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(ctx).setPriority(Notification.PRIORITY_HIGH)
        }
        val notif = builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        nm.notify((sessionId ?: "event").hashCode(), notif)
    }
}
