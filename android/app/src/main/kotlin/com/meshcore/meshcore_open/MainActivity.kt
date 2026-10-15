package com.meshcore.meshcore_open

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val usbFunctions by lazy { MeshcoreUsbFunctions(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbFunctions.configureFlutterEngine(flutterEngine)
        TakBridgeHub.attach(flutterEngine)
        AeicHdChannel.attach(applicationContext, flutterEngine)
        AppUpdateChannel.attach(this, flutterEngine)
    }

    override fun onDestroy() {
        TakBridgeHub.detach()
        usbFunctions.dispose()
        super.onDestroy()
    }
}
