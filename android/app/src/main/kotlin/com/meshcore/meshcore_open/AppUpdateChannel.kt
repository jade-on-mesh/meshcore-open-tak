package com.meshcore.meshcore_open

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * In-app updates: hands a downloaded APK to Android's package installer.
 * Android always shows its own confirmation screen; nothing installs silently.
 * The APK must sit under cacheDir/updates/ (see res/xml/app_update_paths.xml).
 *
 * An earlier build can't be installed over a newer one, so for "Install an
 * earlier version" the APK is copied to Downloads (it must outlive this app)
 * and this app asks Android to uninstall it; the person then opens the file.
 */
object AppUpdateChannel {
    private const val CHANNEL = "meshcore_open/app_update"

    fun attach(activity: Activity, flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Whether "Install unknown apps" is allowed for this app.
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            activity.packageManager.canRequestPackageInstalls()
                    )
                    "openInstallPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            activity.startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:" + activity.packageName)
                                )
                            )
                        }
                        result.success(null)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        val file = path?.let { File(it) }
                        val updates = File(activity.cacheDir, "updates").canonicalPath
                        if (file == null || !file.exists() ||
                            !file.canonicalPath.startsWith(updates + File.separator)
                        ) {
                            result.error("bad_path", "APK not found in the update folder", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = FileProvider.getUriForFile(
                                activity,
                                activity.packageName + ".appupdate",
                                file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            activity.startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                    // Copies an APK from the update folder to Downloads, under
                    // its own name. Android 10+ (MediaStore, no permission).
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path")
                        val file = path?.let { File(it) }
                        val updates = File(activity.cacheDir, "updates").canonicalPath
                        if (file == null || !file.exists() ||
                            !file.canonicalPath.startsWith(updates + File.separator)
                        ) {
                            result.error("bad_path", "APK not found in the update folder", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            result.error("too_old", "needs Android 10 or later", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val values = ContentValues().apply {
                                put(MediaStore.Downloads.DISPLAY_NAME, file.name)
                                put(
                                    MediaStore.Downloads.MIME_TYPE,
                                    "application/vnd.android.package-archive"
                                )
                                put(MediaStore.Downloads.IS_PENDING, 1)
                            }
                            val resolver = activity.contentResolver
                            val uri = resolver.insert(
                                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                                values
                            ) ?: throw IllegalStateException("Downloads refused the file")
                            resolver.openOutputStream(uri).use { out ->
                                file.inputStream().use { it.copyTo(out!!) }
                            }
                            values.clear()
                            values.put(MediaStore.Downloads.IS_PENDING, 0)
                            resolver.update(uri, values, null, null)
                            result.success(file.name)
                        } catch (e: Exception) {
                            result.error("save_failed", e.message, null)
                        }
                    }
                    // Android's own "Uninstall this app?" confirmation.
                    "uninstallSelf" -> {
                        try {
                            activity.startActivity(
                                Intent(
                                    Intent.ACTION_DELETE,
                                    Uri.parse("package:" + activity.packageName)
                                )
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("uninstall_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
