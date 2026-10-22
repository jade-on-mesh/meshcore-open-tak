package com.meshcore.meshcore_open

import android.content.Context
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The AR view's sensors (lib/team/ar_view.dart): gravity and the magnetic
 * field in device axes (x right, y up, z out of the screen), and the magnetic
 * declination where the phone is, about 20 times a second, as
 * [gx, gy, gz, mx, my, mz, declinationDeg]. The heading maths is in Dart, the
 * same for iOS (AppDelegate.swift, MeshOrientation).
 * "meshcore_open/orientation_ctl" "setLocation" {lat, lon} sets where the
 * declination is worked out.
 */
object OrientationChannel : SensorEventListener {
    private var sensors: SensorManager? = null
    private var sink: EventChannel.EventSink? = null
    private val gravity = FloatArray(3)
    private val magnetic = FloatArray(3)
    private var haveGravity = false
    private var haveMagnetic = false
    private var declination = 0.0
    private var lastEmit = 0L

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        sensors = app.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        EventChannel(engine.dartExecutor.binaryMessenger, "meshcore_open/orientation")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    start()
                }

                override fun onCancel(arguments: Any?) {
                    stop()
                    sink = null
                }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "meshcore_open/orientation_ctl")
            .setMethodCallHandler { call, result ->
                if (call.method == "setLocation") {
                    val lat = call.argument<Double>("lat") ?: 0.0
                    val lon = call.argument<Double>("lon") ?: 0.0
                    declination = GeomagneticField(
                        lat.toFloat(), lon.toFloat(), 0f, System.currentTimeMillis()
                    ).declination.toDouble()
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun start() {
        val sm = sensors ?: return
        haveGravity = false
        haveMagnetic = false
        val g = sm.getDefaultSensor(Sensor.TYPE_GRAVITY) ?: sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        val m = sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)
        if (g == null || m == null) {
            sink?.error("no_sensors", "This phone has no compass", null)
            return
        }
        sm.registerListener(this, g, SensorManager.SENSOR_DELAY_GAME)
        sm.registerListener(this, m, SensorManager.SENSOR_DELAY_GAME)
    }

    private fun stop() {
        sensors?.unregisterListener(this)
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_GRAVITY, Sensor.TYPE_ACCELEROMETER -> {
                System.arraycopy(event.values, 0, gravity, 0, 3)
                haveGravity = true
            }
            Sensor.TYPE_MAGNETIC_FIELD -> {
                System.arraycopy(event.values, 0, magnetic, 0, 3)
                haveMagnetic = true
            }
        }
        val now = System.currentTimeMillis()
        if (!haveGravity || !haveMagnetic || now - lastEmit < 50) return
        lastEmit = now
        sink?.success(
            listOf(
                gravity[0].toDouble(), gravity[1].toDouble(), gravity[2].toDouble(),
                magnetic[0].toDouble(), magnetic[1].toDouble(), magnetic[2].toDouble(),
                declination,
            )
        )
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
