package com.meshcore.meshcore_open

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Push-to-talk audio (lib/vox/walkie_audio.dart): 8 kHz mono PCM16 streamed to
 * an AudioTrack as it arrives, so a talk plays without gaps between packets.
 * "open" {sampleRate} -> true once playing; "write" {pcm: bytes} queues audio;
 * "close" {drain} lets queued audio finish (drain) or stops at once. Other audio
 * is ducked while a talk plays.
 */
object PcmStreamChannel {
    private const val CHANNEL = "meshcore_open/pcm_stream"
    private val writer = Executors.newSingleThreadExecutor()
    private var track: AudioTrack? = null
    private var rate = 8000
    private var written = 0L
    private var focus: AudioFocusRequest? = null

    private val attrs: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val r = call.argument<Int>("sampleRate") ?: 8000
                    result.success(open(app, r))
                }
                "write" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    val t = track
                    if (pcm == null || t == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    // AudioTrack.write blocks while its buffer is full: off the
                    // platform thread, in order.
                    writer.execute {
                        try {
                            if (track === t) {
                                t.write(pcm, 0, pcm.size)
                                written += pcm.size / 2
                            }
                        } catch (_: Exception) {
                        }
                    }
                    result.success(null)
                }
                "close" -> {
                    val drain = call.argument<Boolean>("drain") ?: true
                    close(app, drain)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun open(app: Context, sampleRate: Int): Boolean {
        if (track != null && rate == sampleRate) return true
        stopNow(app)
        rate = sampleRate
        return try {
            val min = AudioTrack.getMinBufferSize(
                sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
            // About two seconds: a whole packet fits while the last one plays.
            val size = maxOf(min, sampleRate * 2 * 2)
            val t = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build())
                .setBufferSizeInBytes(size)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            t.play()
            track = t
            written = 0
            duck(app)
            true
        } catch (_: Exception) {
            track = null
            false
        }
    }

    private fun close(app: Context, drain: Boolean) {
        val t = track ?: return
        if (!drain) {
            stopNow(app)
            return
        }
        track = null
        writer.execute {
            try {
                // Wait for the queued audio to play out, then release.
                val total = written
                var waited = 0
                while (waited < 25000) {
                    val head = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                    if (head >= total) break
                    Thread.sleep(50)
                    waited += 50
                }
                t.stop()
            } catch (_: Exception) {
            }
            t.release()
            release(app)
        }
    }

    private fun stopNow(app: Context) {
        val t = track ?: return
        track = null
        try {
            t.pause()
            t.flush()
            t.stop()
        } catch (_: Exception) {
        }
        t.release()
        release(app)
    }

    private fun duck(app: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val am = app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(attrs)
            .build()
        focus = req
        am.requestAudioFocus(req)
    }

    private fun release(app: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val req = focus ?: return
        focus = null
        (app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.abandonAudioFocusRequest(req)
    }
}
