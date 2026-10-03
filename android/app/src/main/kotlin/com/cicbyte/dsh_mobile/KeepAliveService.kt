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
 * 无独立逻辑：不持有连接，纯粹把进程抬到前台优先级。
 * START_STICKY：被系统回收后自动拉起（连接由 mux 持续重连自愈）。
 */
class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        return START_STICKY
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
        val pi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or flagImmutable()
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CH_KEEP)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        val notif = builder
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("DSH 已连接")
            .setContentText("后台保持实时连接（消息/交互照常到达）")
            .setOngoing(true)
            .setContentIntent(pi)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID_KEEP, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID_KEEP, notif)
        }
    }

    companion object {
        const val CH_KEEP = "dsh_keepalive"
        const val CH_EVENT = "dsh_events"
        const val ID_KEEP = 1
        const val ID_EVENT = 2

        fun flagImmutable(): Int {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        }
    }
}

/**
 * 事件通知：后台收到的提问/授权/回答完成等，走高优先级通道点开直达 App。
 * 前台时 Dart 侧不会调用（UI 内已呈现，免重复打扰）。
 */
object DshNotifier {
    fun notifyEvent(ctx: Context, title: String, text: String) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(KeepAliveService.CH_EVENT, "会话与交互提醒", NotificationManager.IMPORTANCE_HIGH)
            )
        }
        val pi = PendingIntent.getActivity(
            ctx, 0,
            Intent(ctx, MainActivity::class.java),
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
        nm.notify(KeepAliveService.ID_EVENT, notif)
    }
}
