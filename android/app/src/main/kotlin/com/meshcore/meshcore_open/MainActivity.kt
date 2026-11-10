package com.meshcore.meshcore_open

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import androidx.activity.enableEdgeToEdge
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (a ComponentActivity) so enableEdgeToEdge() works:
// Android 15+ enforces edge-to-edge for apps targeting SDK 35, and the app
// already draws behind the system bars and handles insets in Flutter.
class MainActivity : FlutterFragmentActivity() {
    private val usbFunctions by lazy { MeshcoreUsbFunctions(this) }
    private var scrollCapture: FlutterScrollCapture? = null

    // Settings > Keep screen on (lib/services/screen_awake_service.dart).
    // The flag only holds while this window is showing.
    private var keepScreenOn = false

    private fun applyKeepScreenOn() {
        if (keepScreenOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbFunctions.configureFlutterEngine(flutterEngine)
        TakBridgeHub.attach(flutterEngine)
        AeicHdChannel.attach(applicationContext, flutterEngine)
        AppUpdateChannel.attach(this, flutterEngine)
        SpeechChannel.attach(this, flutterEngine)
        PcmStreamChannel.attach(this, flutterEngine)
        OrientationChannel.attach(this, flutterEngine)
        // ESP32 Wi-Fi updates: open the system Wi-Fi settings to join the
        // device's access point (esp32_wifi_ota_screen.dart).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.meshcore.meshcore_open/settings"
        ).setMethodCallHandler { call, result ->
            if (call.method == "openWifiSettings") {
                startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "meshcore_open/screen_awake"
        ).setMethodCallHandler { call, result ->
            if (call.method == "set") {
                keepScreenOn = call.arguments as? Boolean ?: false
                runOnUiThread { applyKeepScreenOn() }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            scrollCapture?.detach()
            scrollCapture = FlutterScrollCapture(
                this,
                flutterEngine.dartExecutor.binaryMessenger,
            ).also { it.attach(findViewById<View>(android.R.id.content)) }
        }
    }

    override fun onResume() {
        super.onResume()
        applyKeepScreenOn()
    }

    override fun onDestroy() {
        TakBridgeHub.detach()
        scrollCapture?.detach()
        scrollCapture = null
        usbFunctions.dispose()
        super.onDestroy()
    }
}
