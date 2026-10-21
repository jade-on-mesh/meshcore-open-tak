package com.meshcore.meshcore_open

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Spoken turn prompts for Bloodhound directions, with Android's own
 * text-to-speech (no plugin). Other audio is ducked while a prompt plays.
 * "speak" {text, language} answers true once queued, false when there is no
 * speech engine or no voice for the language; "stop" cuts a prompt short.
 */
object SpeechChannel {
    private const val CHANNEL = "meshcore_open/speech"
    private var tts: TextToSpeech? = null
    private var ready = false
    private var pending: Pair<String, String?>? = null
    private var focus: AudioFocusRequest? = null

    private val attrs: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    val text = call.argument<String>("text") ?: ""
                    val lang = call.argument<String>("language")
                    if (text.isBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val engineNow = tts
                    if (engineNow == null || !ready) {
                        pending = text to lang
                        if (engineNow == null) start(app)
                        result.success(true)
                    } else {
                        result.success(say(app, text, lang))
                    }
                }
                "stop" -> {
                    tts?.stop()
                    release(app)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun start(app: Context) {
        tts = TextToSpeech(app) { status ->
            ready = status == TextToSpeech.SUCCESS
            val t = tts ?: return@TextToSpeech
            if (!ready) return@TextToSpeech
            t.setAudioAttributes(attrs)
            t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(id: String?) {}
                override fun onDone(id: String?) = release(app)
                @Deprecated("Deprecated in Java")
                override fun onError(id: String?) = release(app)
            })
            pending?.let { (text, lang) -> say(app, text, lang) }
            pending = null
        }
    }

    private fun say(app: Context, text: String, lang: String?): Boolean {
        val t = tts ?: return false
        if (!lang.isNullOrBlank()) {
            val r = t.setLanguage(Locale.forLanguageTag(lang))
            if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED) {
                t.setLanguage(Locale.getDefault())
            }
        }
        duck(app)
        return t.speak(text, TextToSpeech.QUEUE_FLUSH, null, "turn") == TextToSpeech.SUCCESS
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
