package com.meshcore.meshcore_open

import android.content.Context
import android.graphics.Bitmap
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * Video messages (lib/vox/video_source.dart): reads a picked clip as small
 * RGB888 frames at a fixed rate and its sound as 48 kHz mono PCM16, each
 * into a file in the cache, for the AV1 encoder in Dart (video_codec.dart).
 *
 * "meshcore_open/vox_video" "extract" {path, maxSide, fps, maxSeconds} ->
 * {frames, width, height, fps, count, durationMs, sound?, samples}
 */
object VoxVideoChannel {
    private const val SOUND_RATE = 48000
    private val main = Handler(Looper.getMainLooper())

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "meshcore_open/vox_video")
            .setMethodCallHandler { call, result ->
                if (call.method != "extract") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("extract", "no path", null)
                    return@setMethodCallHandler
                }
                val maxSide = call.argument<Int>("maxSide") ?: 256
                val fps = call.argument<Int>("fps") ?: 12
                val maxSeconds = call.argument<Int>("maxSeconds") ?: 15
                Thread {
                    try {
                        val out = extract(app, path, maxSide, fps, maxSeconds)
                        main.post { result.success(out) }
                    } catch (e: Throwable) {
                        main.post { result.error("extract", e.message ?: e.toString(), null) }
                    }
                }.start()
            }
    }

    private fun even(v: Double) = max(2, (v / 2).roundToInt() * 2)

    private fun extract(
        context: Context,
        path: String,
        maxSide: Int,
        fps: Int,
        maxSeconds: Int,
    ): Map<String, Any?> {
        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(path)
            val durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            if (durationMs <= 0) throw IllegalArgumentException("not a video")
            val clipMs = min(durationMs, maxSeconds * 1000L)
            val count = max(1, (clipMs * fps / 1000).toInt())

            // The frames come out upright (the retriever applies the
            // rotation), so the first one gives the shape.
            val first = mmr.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: throw IllegalArgumentException("no picture in this video")
            val aspect = first.width.toDouble() / first.height
            first.recycle()
            val w: Int
            val h: Int
            if (aspect >= 1) {
                w = even(maxSide.toDouble()); h = even(maxSide / aspect)
            } else {
                w = even(maxSide * aspect); h = even(maxSide.toDouble())
            }

            val framesFile = File(context.cacheDir, "vox_video_frames.rgb")
            BufferedOutputStream(FileOutputStream(framesFile), 1 shl 16).use { out ->
                val writer = FrameWriter(w, h, out)
                val sourceFrames = if (Build.VERSION.SDK_INT >= 28) {
                    mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
                        ?.toIntOrNull() ?: 0
                } else 0
                if (Build.VERSION.SDK_INT >= 28 && sourceFrames > 0) {
                    byIndex(mmr, writer, count, fps, sourceFrames, durationMs)
                } else {
                    byTime(mmr, writer, count, fps, w, h)
                }
            }

            val sound = try {
                sound(context, path, clipMs)
            } catch (_: Throwable) {
                null
            }
            return mapOf(
                "frames" to framesFile.absolutePath,
                "width" to w,
                "height" to h,
                "fps" to fps,
                "count" to count,
                "durationMs" to clipMs.toInt(),
                "sound" to sound?.first,
                "samples" to (sound?.second ?: 0),
            )
        } finally {
            mmr.release()
        }
    }

    /** Scales each frame to w x h and writes it as RGB888. */
    private class FrameWriter(val w: Int, val h: Int, val out: BufferedOutputStream) {
        private val px = IntArray(w * h)
        private val rgb = ByteArray(w * h * 3)
        var last: ByteArray? = null

        fun write(bmp: Bitmap?) {
            if (bmp == null) {
                out.write(last ?: ByteArray(w * h * 3))
                return
            }
            val scaled = if (bmp.width == w && bmp.height == h) bmp
            else Bitmap.createScaledBitmap(bmp, w, h, true)
            scaled.getPixels(px, 0, w, 0, 0, w, h)
            for (i in px.indices) {
                val c = px[i]
                rgb[i * 3] = (c shr 16).toByte()
                rgb[i * 3 + 1] = (c shr 8).toByte()
                rgb[i * 3 + 2] = c.toByte()
            }
            if (scaled !== bmp) scaled.recycle()
            out.write(rgb)
            last = rgb.copyOf()
        }
    }

    /**
     * Android 9+: decodes the source frames in order, a few at a time,
     * keeping the ones nearest each output time. One pass through the clip
     * instead of a seek per frame.
     */
    @androidx.annotation.RequiresApi(28)
    private fun byIndex(
        mmr: MediaMetadataRetriever,
        writer: FrameWriter,
        count: Int,
        fps: Int,
        sourceFrames: Int,
        durationMs: Long,
    ) {
        val perMs = sourceFrames.toDouble() / durationMs
        val wanted = IntArray(count) { i ->
            min(sourceFrames - 1, (i * 1000.0 / fps * perMs).roundToInt())
        }
        val params = MediaMetadataRetriever.BitmapParams().apply {
            preferredConfig = Bitmap.Config.RGB_565
        }
        val chunk = 6
        var next = 0 // next output frame
        var at = 0 // next source frame to decode
        val last = wanted[count - 1]
        while (next < count && at <= last) {
            // Skip ahead to the next wanted frame's chunk.
            if (wanted[next] >= at + chunk) at = wanted[next]
            val n = min(chunk, sourceFrames - at)
            val got = try {
                mmr.getFramesAtIndex(at, n, params)
            } catch (_: Throwable) {
                emptyList()
            }
            for (k in got.indices) {
                val idx = at + k
                while (next < count && wanted[next] == idx) {
                    writer.write(got[k])
                    next++
                }
            }
            got.forEach { it.recycle() }
            if (got.isEmpty()) {
                // Couldn't decode this stretch: repeat the last frame for it.
                while (next < count && wanted[next] < at + n) {
                    writer.write(null)
                    next++
                }
            }
            at += n
        }
        while (next < count) {
            writer.write(null)
            next++
        }
    }

    /** Older Android: a frame per output time. */
    private fun byTime(
        mmr: MediaMetadataRetriever,
        writer: FrameWriter,
        count: Int,
        fps: Int,
        w: Int,
        h: Int,
    ) {
        for (i in 0 until count) {
            val us = (i * 1_000_000.0 / fps).roundToLong()
            val bmp = if (Build.VERSION.SDK_INT >= 27) {
                mmr.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST, w, h)
            } else {
                mmr.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST)
            }
            writer.write(bmp)
            bmp?.recycle()
        }
    }

    /** The first [clipMs] of the sound, 48 kHz mono PCM16 LE in a file. */
    private fun sound(context: Context, path: String, clipMs: Long): Pair<String, Int>? {
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ex.setDataSource(path)
            var track = -1
            for (t in 0 until ex.trackCount) {
                val mime = ex.getTrackFormat(t).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    track = t
                    break
                }
            }
            if (track < 0) return null
            ex.selectTrack(track)
            val format = ex.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var floatPcm = false
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            var mono = FloatArray(1 shl 16)
            var have = 0
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            val limitUs = clipMs * 1000
            fun wantSamples() = (clipMs * rate / 1000).toInt()
            while (!outputDone) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
                        val size = ex.readSampleData(buf, 0)
                        if (size < 0 || ex.sampleTime > limitUs) {
                            codec.queueInputBuffer(
                                inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    floatPcm = Build.VERSION.SDK_INT >= 24 &&
                        f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (outIdx >= 0) {
                    val buf: ByteBuffer = codec.getOutputBuffer(outIdx)!!
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val order = buf.order(ByteOrder.nativeOrder())
                    val frames = if (floatPcm) info.size / 4 / channels else info.size / 2 / channels
                    if (have + frames > mono.size) {
                        mono = mono.copyOf(max(mono.size * 2, have + frames))
                    }
                    if (floatPcm) {
                        val fb = order.asFloatBuffer()
                        for (i in 0 until frames) {
                            var s = 0f
                            for (c in 0 until channels) s += fb.get(i * channels + c)
                            mono[have + i] = s / channels
                        }
                    } else {
                        val sb = order.asShortBuffer()
                        for (i in 0 until frames) {
                            var s = 0f
                            for (c in 0 until channels) s += sb.get(i * channels + c) / 32768f
                            mono[have + i] = s / channels
                        }
                    }
                    have += frames
                    codec.releaseOutputBuffer(outIdx, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0 ||
                        have >= wantSamples()
                    ) {
                        outputDone = true
                    }
                }
            }
            have = min(have, wantSamples())
            if (have <= 0 || rate <= 0) return null

            // Linear resample to 48 kHz (the Dart side low-passes it again).
            val n = (have.toLong() * SOUND_RATE / rate).toInt()
            val out = ByteBuffer.allocate(n * 2).order(ByteOrder.LITTLE_ENDIAN)
            val step = rate.toDouble() / SOUND_RATE
            for (i in 0 until n) {
                val x = i * step
                val j = x.toInt()
                val f = (x - j).toFloat()
                val a = mono[min(j, have - 1)]
                val b = mono[min(j + 1, have - 1)]
                val v = (a + (b - a) * f).coerceIn(-1f, 1f)
                out.putShort((v * 32767).roundToInt().toShort())
            }
            val file = File(context.cacheDir, "vox_video_sound.pcm")
            file.writeBytes(out.array())
            return Pair(file.absolutePath, n)
        } finally {
            try {
                codec?.stop()
            } catch (_: Throwable) {
            }
            codec?.release()
            ex.release()
        }
    }
}
