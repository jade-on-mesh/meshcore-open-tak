package com.meshcore.meshcore_open

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * In-app updates: hands a downloaded APK to Android's package installer.
 * Android always shows its own confirmation screen; nothing installs silently.
 * The APK must sit under cacheDir/updates/ (see res/xml/app_update_paths.xml).
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
                    else -> result.notImplemented()
                }
            }
    }
}
