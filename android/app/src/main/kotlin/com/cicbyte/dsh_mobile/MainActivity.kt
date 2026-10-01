package com.cicbyte.dsh_mobile

import android.content.ContentValues
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
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                else -> result.notImplemented()
            }
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
