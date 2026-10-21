package com.meshcore.meshcore_open

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val usbFunctions by lazy { MeshcoreUsbFunctions(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbFunctions.configureFlutterEngine(flutterEngine)
        TakBridgeHub.attach(flutterEngine)
        AeicHdChannel.attach(applicationContext, flutterEngine)
        AppUpdateChannel.attach(this, flutterEngine)
        SpeechChannel.attach(this, flutterEngine)
        PcmStreamChannel.attach(this, flutterEngine)
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
    }

    override fun onDestroy() {
        TakBridgeHub.detach()
        usbFunctions.dispose()
        super.onDestroy()
    }
}
