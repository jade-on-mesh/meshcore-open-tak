package com.meshcore.meshcore_open

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Bridge for the MeshCore ATAK plugin (atak-plugin/), the way the Meshtastic
 * ATAK plugin binds to the Meshtastic app. The plugin runs inside ATAK and
 * binds here with action [ACTION]; messages are relayed to Dart
 * (lib/team/tak/atak_plugin_bridge.dart) over the 'meshcore/tak_bridge'
 * method channel, so the plugin uses this app's radio connection, team
 * identity and voice/photo codecs.
 *
 * Only ATAK may bind: callers whose UID doesn't belong to an ATAK package
 * are ignored. Users can turn the bridge off in the app (TAK settings).
 *
 * Message codes and bundle keys mirror the plugin's BridgeProtocol.java.
 */
class TakBridgeService : Service() {

    private val handler = object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(msg: Message) {
            TakBridgeHub.fromPlugin(this@TakBridgeService, msg)
        }
    }
    private val messenger = Messenger(handler)

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onUnbind(intent: Intent?): Boolean {
        TakBridgeHub.clientsGone()
        return false
    }

    companion object {
        const val ACTION = "com.jadeonmesh.meshcore.TAK_BRIDGE"
    }
}

/** Ties the bound service to the Flutter engine's method channel. */
object TakBridgeHub {
    private const val TAG = "TakBridge"
    private const val CHANNEL = "meshcore/tak_bridge"
    private const val CHUNK = 64 * 1024

    // Plugin -> app
    private const val HELLO = 1
    private const val SEND_CHANNEL_DATA = 2
    private const val SEND_CHANNEL_TEXT = 3
    private const val SEND_DIRECT_TEXT = 4
    private const val SEND_TEAM = 5
    private const val PUBLISH_SELF = 6
    private const val REFRESH_CONTACTS = 7
    private const val BYE = 8
    private const val MEDIA_CHUNK_IN = 20
    private const val MEDIA_SEND = 21
    private const val MEDIA_FETCH = 22
    private const val MEDIA_GET = 23
    private const val MEDIA_REGISTER = 24

    // App -> plugin
    private const val STATE = 101
    private const val CHANNEL_TEXT = 103
    private const val DIRECT_TEXT = 104
    private const val TEAM_PAYLOAD = 105
    private const val RESULT = 106
    private const val MEDIA_STATE = 110
    private const val MEDIA_CHUNK_OUT = 111
    private const val MEDIA_REGISTERED = 112

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private val clients = LinkedHashSet<Messenger>()
    private val uploads = HashMap<Int, ByteArrayOutputStream>()

    fun attach(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::fromDart)
        }
        // A plugin may already be bound from before the app (re)started.
        if (clients.isNotEmpty()) invokeDart("hello", emptyMap(), null)
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        broadcast(STATE, Bundle().apply {
            putBoolean("connected", false)
            putString("detail", "Open MeshCore Open TAK")
        })
    }

    fun clientsGone() {
        clients.clear()
        uploads.clear()
        invokeDart("bye", emptyMap(), null)
    }

    // ------------------------------------------------------- from plugin

    private fun isAtak(ctx: Context, msg: Message): Boolean {
        val uid = if (Build.VERSION.SDK_INT >= 22) msg.sendingUid else -1
        if (uid < 0) return false
        if (uid == android.os.Process.myUid()) return true
        val pkgs = ctx.packageManager.getPackagesForUid(uid) ?: return false
        return pkgs.any { it.startsWith("com.atakmap.app") || it.startsWith("gov.tak.") }
    }

    private fun enabled(ctx: Context): Boolean =
        ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.atak_bridge_enabled", true)

    fun fromPlugin(ctx: Context, msg: Message) {
        if (!isAtak(ctx, msg)) {
            Log.w(TAG, "ignoring a bridge message from an app that isn't ATAK")
            return
        }
        if (!enabled(ctx)) {
            send(msg.replyTo, STATE, Bundle().apply {
                putBoolean("connected", false)
                putString("detail", "Turned off in MeshCore Open TAK (TAK interop)")
            })
            if (msg.what != HELLO && msg.what != BYE && msg.what != MEDIA_CHUNK_IN) {
                send(msg.replyTo, RESULT, result(msg.data?.getInt("id") ?: 0, false,
                    "The ATAK bridge is off in MeshCore Open TAK"))
            }
            return
        }
        val reply = msg.replyTo
        val b = msg.data ?: Bundle()
        if (reply != null) clients.add(reply)
        val id = b.getInt("id")
        when (msg.what) {
            HELLO -> {
                if (channel == null) {
                    send(reply, STATE, Bundle().apply {
                        putBoolean("connected", false)
                        putString("detail", "Open MeshCore Open TAK (it isn't running)")
                    })
                }
                invokeDart("hello", hashMapOf("v" to b.getInt("v")), null)
            }
            BYE -> {
                if (reply != null) clients.remove(reply)
                if (clients.isEmpty()) invokeDart("bye", emptyMap(), null)
            }
            SEND_CHANNEL_DATA -> invokeDart("sendChannelData", hashMapOf(
                "ch" to b.getInt("ch"), "type" to b.getInt("type"),
                "blobs" to b.getByteArray("blobs"), "gap" to b.getLong("gap").toInt(),
            ), reply, id)
            SEND_CHANNEL_TEXT -> invokeDart("sendChannelText", hashMapOf(
                "ch" to b.getInt("ch"), "text" to b.getString("text"),
            ), reply, id)
            SEND_DIRECT_TEXT -> invokeDart("sendDirectText", hashMapOf(
                "key" to b.getByteArray("key"), "text" to b.getString("text"),
            ), reply, id)
            SEND_TEAM -> invokeDart("sendTeam", hashMapOf(
                "blobs" to b.getByteArray("blobs"), "gap" to b.getLong("gap").toInt(),
            ), reply, id)
            PUBLISH_SELF -> invokeDart("publishSelf", hashMapOf(
                "payload" to b.getByteArray("payload"),
            ), null)
            REFRESH_CONTACTS -> invokeDart("refreshContacts", emptyMap(), null)
            MEDIA_CHUNK_IN -> {
                val xfer = b.getInt("xfer")
                val acc = uploads.getOrPut(xfer) { ByteArrayOutputStream() }
                b.getByteArray("bytes")?.let { acc.write(it) }
                if (acc.size() > 8 * 1024 * 1024) uploads.remove(xfer)
            }
            MEDIA_SEND, MEDIA_REGISTER -> {
                val bytes = uploads.remove(b.getInt("xfer"))?.toByteArray()
                if (bytes == null) {
                    send(reply, RESULT, result(id, false, "Upload incomplete"))
                    return
                }
                val args = hashMapOf<String, Any?>(
                    "id" to id, "bytes" to bytes, "kind" to b.getString("kind"),
                    "detailLevel" to b.getInt("detailLevel"),
                )
                if (b.containsKey("key")) args["key"] = b.getByteArray("key")
                if (b.containsKey("ch")) args["ch"] = b.getInt("ch")
                invokeDart(if (msg.what == MEDIA_SEND) "mediaSend" else "mediaRegister",
                    args, reply, id)
            }
            MEDIA_FETCH -> invokeDart("mediaFetch", hashMapOf(
                "env" to b.getString("env"), "sender" to b.getString("sender"),
                "ch" to b.getInt("ch", -1),
            ), null)
            MEDIA_GET -> invokeDart("mediaGet", hashMapOf(
                "xfer" to b.getInt("xfer"), "env" to b.getString("env"),
                "kind" to b.getString("kind"),
            ), null)
        }
    }

    private fun result(id: Int, ok: Boolean, message: String?) = Bundle().apply {
        putInt("id", id)
        putBoolean("ok", ok)
        putString("msg", message)
    }

    /** Calls Dart; with a reply target, its {ok, msg} answer goes back as RESULT. */
    private fun invokeDart(method: String, args: Map<String, Any?>, reply: Messenger?, id: Int = 0) {
        val ch = channel
        if (ch == null) {
            if (reply != null) send(reply, RESULT, result(id, false, "MeshCore Open TAK isn't running"))
            return
        }
        main.post {
            ch.invokeMethod(method, args, object : MethodChannel.Result {
                override fun success(r: Any?) {
                    if (reply == null) return
                    val m = r as? Map<*, *>
                    send(reply, RESULT, result(id, m?.get("ok") as? Boolean ?: true, m?.get("msg") as? String))
                }

                override fun error(code: String, message: String?, details: Any?) {
                    if (reply != null) send(reply, RESULT, result(id, false, message ?: code))
                }

                override fun notImplemented() {
                    if (reply != null) send(reply, RESULT, result(id, false, "Not supported by this app version"))
                }
            })
        }
    }

    // --------------------------------------------------------- from Dart

    private fun fromDart(call: MethodCall, result: MethodChannel.Result) {
        val a = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        when (call.method) {
            "state" -> broadcast(STATE, Bundle().apply {
                putBoolean("connected", a["connected"] as? Boolean ?: false)
                putString("detail", a["detail"] as? String)
                (a["selfKey"] as? ByteArray)?.let { putByteArray("selfKey", it) }
                putString("selfName", a["selfName"] as? String)
                putInt("sf", (a["sf"] as? Number)?.toInt() ?: 0)
                putLong("bw", (a["bw"] as? Number)?.toLong() ?: 0L)
                putInt("cr", (a["cr"] as? Number)?.toInt() ?: 0)
                putBoolean("channelData", a["channelData"] as? Boolean ?: false)
                putInt("teamChannel", (a["teamChannel"] as? Number)?.toInt() ?: -1)
                putBoolean("appOwnsTeam", a["appOwnsTeam"] as? Boolean ?: false)
                putIntArray("chIndex", ints(a["chIndex"]))
                putStringArray("chName", strings(a["chName"]))
                putBooleanArray("chPrivate", bools(a["chPrivate"]))
                putByteArray("cKeys", a["cKeys"] as? ByteArray ?: ByteArray(0))
                putStringArray("cNames", strings(a["cNames"]))
                putIntArray("cPath", ints(a["cPath"]))
                putIntArray("cType", ints(a["cType"]))
                putBoolean("mimi", a["mimi"] as? Boolean ?: false)
                putBoolean("av1", a["av1"] as? Boolean ?: false)
                putBoolean("codec2", a["codec2"] as? Boolean ?: false)
            })
            "channelText" -> broadcast(CHANNEL_TEXT, Bundle().apply {
                putInt("ch", (a["ch"] as? Number)?.toInt() ?: -1)
                putString("sender", a["sender"] as? String)
                putString("text", a["text"] as? String)
                putLong("ts", (a["ts"] as? Number)?.toLong() ?: 0L)
                putInt("hops", (a["hops"] as? Number)?.toInt() ?: -1)
            })
            "directText" -> broadcast(DIRECT_TEXT, Bundle().apply {
                putString("sender", a["sender"] as? String)
                putString("text", a["text"] as? String)
                putLong("ts", (a["ts"] as? Number)?.toLong() ?: 0L)
            })
            "teamPayload" -> broadcast(TEAM_PAYLOAD, Bundle().apply {
                putByteArray("payload", a["payload"] as? ByteArray)
                putBoolean("own", a["own"] as? Boolean ?: false)
            })
            "mediaState" -> broadcast(MEDIA_STATE, Bundle().apply {
                putString("sid", a["sid"] as? String)
                putString("status", a["status"] as? String)
                putInt("have", (a["have"] as? Number)?.toInt() ?: 0)
                putInt("total", (a["total"] as? Number)?.toInt() ?: 0)
                putString("msg", a["msg"] as? String)
            })
            "mediaRegistered" -> broadcast(MEDIA_REGISTERED, Bundle().apply {
                putInt("id", (a["id"] as? Number)?.toInt() ?: 0)
                putString("env", a["env"] as? String)
            })
            "mediaData" -> {
                val bytes = a["bytes"] as? ByteArray ?: ByteArray(0)
                val xfer = (a["xfer"] as? Number)?.toInt() ?: 0
                val n = maxOf(1, (bytes.size + CHUNK - 1) / CHUNK)
                for (i in 0 until n) {
                    val from = i * CHUNK
                    val to = minOf(bytes.size, from + CHUNK)
                    broadcast(MEDIA_CHUNK_OUT, Bundle().apply {
                        putInt("xfer", xfer)
                        putInt("index", i)
                        putBoolean("last", i == n - 1)
                        putByteArray("bytes", if (from < to) bytes.copyOfRange(from, to) else ByteArray(0))
                        putBoolean("ok", a["ok"] as? Boolean ?: false)
                        putInt("rate", (a["rate"] as? Number)?.toInt() ?: 0)
                        putString("msg", a["msg"] as? String)
                    })
                }
            }
            else -> {
                result.notImplemented()
                return
            }
        }
        result.success(null)
    }

    private fun ints(v: Any?): IntArray = when (v) {
        is IntArray -> v
        is List<*> -> v.map { (it as? Number)?.toInt() ?: 0 }.toIntArray()
        else -> IntArray(0)
    }

    private fun strings(v: Any?): Array<String> =
        (v as? List<*>)?.map { it?.toString() ?: "" }?.toTypedArray() ?: emptyArray()

    private fun bools(v: Any?): BooleanArray =
        (v as? List<*>)?.map { it as? Boolean ?: false }?.toBooleanArray() ?: BooleanArray(0)

    private fun broadcast(what: Int, data: Bundle) {
        for (c in clients.toList()) send(c, what, data)
    }

    private fun send(to: Messenger?, what: Int, data: Bundle) {
        if (to == null) return
        val m = Message.obtain(null, what)
        m.data = data
        try {
            to.send(m)
        } catch (e: RemoteException) {
            clients.remove(to)
        }
    }
}
