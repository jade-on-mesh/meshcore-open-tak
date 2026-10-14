package com.meshcore.meshcore_open

import android.app.ActivityManager
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MeshCore Open TAK: tells lib/vox/aeic_hd_service.dart where Android
 * installed the AEIC HD codec program (jniLibs/libaeic_codec_exec.so, see
 * tool/build_aeic_hd_android.sh) and how much memory the phone has.
 */
object AeicHdChannel {
    private const val CHANNEL = "meshcore_open_tak/aeic_hd"

    fun attach(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "nativeLibraryDir" -> result.success(context.applicationInfo.nativeLibraryDir)
                "memory" -> {
                    val info = ActivityManager.MemoryInfo()
                    (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(info)
                    result.success(mapOf("total" to info.totalMem, "available" to info.availMem))
                }
                else -> result.notImplemented()
            }
        }
    }
}
