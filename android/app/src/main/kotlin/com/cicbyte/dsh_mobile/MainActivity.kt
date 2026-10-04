package com.cicbyte.dsh_mobile

import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.webkit.MimeTypeMap
import java.io.File
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    /** Dart↔原生事件通道（通知点开直达/深链会话页）；engine 未就绪时事件进缓冲 */
    companion object {
        var notifySink: MethodChannel? = null
        val pendingEvents: ArrayDeque<Pair<String, Map<String, Any?>>> = ArrayDeque()

        fun sendToDart(method: String, args: Map<String, Any?>) {
            val ch = notifySink
            if (ch != null) {
                ch.invokeMethod(method, args)
            } else {
                if (pendingEvents.size > 16) pendingEvents.removeFirst()
                pendingEvents.addLast(method to args)
            }
        }

        fun flushPendingEvents() {
            val ch = notifySink ?: return
            while (pendingEvents.isNotEmpty()) {
                val (m, a) = pendingEvents.removeFirst()
                ch.invokeMethod(m, a)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        notifySink = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/notify")
        // 冷启动带 dsh.sessionId（点通知杀进程后重开）：engine 就绪后转发
        val cold = intent?.getStringExtra("dsh.sessionId")
        if (!cold.isNullOrEmpty()) {
            sendToDart("openSession", mapOf("sessionId" to cold))
            intent?.removeExtra("dsh.sessionId")
        }
        flushPendingEvents()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/device").setMethodCallHandler { call, result ->
            when (call.method) {
                // IANA 时区 ID（如 Asia/Shanghai）；session/prompt 的 clientTimeZone 只收这个
                "timeZoneId" -> result.success(TimeZone.getDefault().id)
                // 把 app 私有目录里的已下载文件保存到系统「下载」；文件 IO 下线程执行，
                // result 回主线程（大文件拷贝不 ANR）
                "saveToDownloads" -> {
                    val src = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    if (src.isNullOrBlank() || name.isNullOrBlank()) {
                        result.error("bad-args", "缺少 path/name", null)
                    } else {
                        Thread { saveToDownloads(File(src), name, result) }.start()
                    }
                }
                // 后台保活：起/停前台服务（常驻低优先级通知，进程不被冻结）
                "keepAliveStart" -> {
                    requestNotificationPermissionIfNeeded()
                    try {
                        startForegroundService(Intent(this, KeepAliveService::class.java))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("fgs-failed", e.message ?: e.toString(), null)
                    }
                }
                "keepAliveStop" -> {
                    stopService(Intent(this, KeepAliveService::class.java))
                    result.success(true)
                }
                // 电池优化白名单（一次性系统弹窗；部分国产 ROM 另需手动允许自启动）
                "requestBatteryExemption" -> {
                    try {
                        startActivity(Intent(
                            android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            android.net.Uri.parse("package:$packageName")
                        ))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("no-exemption", e.message ?: e.toString(), null)
                    }
                }
                // 后台事件通知（回答完成/需要确认）：高优先级通道，点开直达会话页
                "notifyEvent" -> {
                    val title = call.argument<String>("title") ?: "DSH"
                    val text = call.argument<String>("text") ?: ""
                    val sessionId = call.argument<String>("sessionId")
                    try {
                        DshNotifier.notifyEvent(applicationContext, title, text, sessionId)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("notify-failed", e.message ?: e.toString(), null)
                    }
                }
                // 更新常驻通知为运行中进度（系统秒表走字）；服务没跑时静默忽略
                "keepAliveUpdate" -> {
                    val title = call.argument<String>("title") ?: "DSH 已连接"
                    val text = call.argument<String>("text") ?: ""
                    val sessionId = call.argument<String>("sessionId")
                    val startMs = call.argument<Number>("chronometerStartMs")?.toLong() ?: 0L
                    try {
                        KeepAliveService.update(applicationContext, title, text, sessionId, startMs)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("notify-failed", e.message ?: e.toString(), null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 通知点开（热启动）：转发 dsh.sessionId 到 Dart 打开对应会话页 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val sid = intent.getStringExtra("dsh.sessionId")
        if (!sid.isNullOrEmpty()) {
            sendToDart("openSession", mapOf("sessionId" to sid))
            intent.removeExtra("dsh.sessionId")
        }
    }

    /** Android 13+ 通知运行时权限（前台服务与事件通知可见性；拒绝也能跑，只是看不到） */
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 4701)
        }
    }

    /** 保存到系统下载：29+ 走 MediaStore（免权限，IS_PENDING 防半成品可见）；
     *  更早回退公共 Downloads 目录直接拷贝（无权限时抛错，由 Dart 侧提示）。 */
    private fun saveToDownloads(src: File, displayName: String, result: MethodChannel.Result) {
        try {
            if (!src.exists() || !src.isFile) {
                runOnUiThread { result.error("no-file", "源文件不存在", null) }
                return
            }
            val where: String
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                    put(MediaStore.Downloads.MIME_TYPE, guessMime(displayName))
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("MediaStore insert 失败")
                contentResolver.openOutputStream(uri).use { out ->
                    if (out == null) throw IllegalStateException("打开输出流失败")
                    src.inputStream().use { input -> input.copyTo(out, 64 * 1024) }
                }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                where = "Download/$displayName"
            } else {
                val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                dir.mkdirs()
                // 同名冲突自动 (1)/(2) 后缀，与桥端下载池命名规则一致
                val dot = displayName.lastIndexOf('.')
                val base = if (dot > 0) displayName.substring(0, dot) else displayName
                val ext = if (dot > 0) displayName.substring(dot) else ""
                var dest = File(dir, displayName)
                var n = 0
                while (dest.exists()) {
                    n++
                    dest = File(dir, "$base ($n)$ext")
                }
                src.copyTo(dest, overwrite = false)
                where = dest.absolutePath
            }
            runOnUiThread { result.success(where) }
        } catch (e: Exception) {
            runOnUiThread { result.error("save-failed", e.message ?: e.toString(), null) }
        }
    }

    /** 按扩展名粗判 MIME（MediaStore 元数据用；未知回退 octet-stream）。 */
    private fun guessMime(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        val mime = if (ext.isNotEmpty()) MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) else null
        return mime ?: "application/octet-stream"
    }
}
