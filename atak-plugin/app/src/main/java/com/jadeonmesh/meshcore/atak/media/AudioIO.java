package com.jadeonmesh.meshcore.atak.media;

import java.util.Arrays;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;

/**
 * Microphone (48 kHz mono 16-bit, what the app records too, so both encode
 * identically) and speaker (any rate). Recording uses ATAK's RECORD_AUDIO
 * permission.
 */
public final class AudioIO {
    private AudioIO() {
    }

    public static final int RATE = 48000;

    private static AudioTrack track;

    /** Push-to-talk recorder. */
    public static final class Recorder {
        private AudioRecord rec;
        private Thread thread;
        private volatile boolean running;
        private short[] buf = new short[RATE * 4];
        private int len;
        private final int maxSamples;

        public Recorder(int maxSeconds) {
            this.maxSamples = maxSeconds * RATE;
        }

        /** Returns an error message, or null when recording started. */
        public String start() {
            int min = AudioRecord.getMinBufferSize(RATE,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            if (min <= 0)
                return "Microphone unavailable";
            try {
                rec = new AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                        RATE, AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT, Math.max(min, RATE));
            } catch (RuntimeException e) {
                return "Microphone unavailable: " + e.getMessage();
            }
            if (rec.getState() != AudioRecord.STATE_INITIALIZED) {
                rec.release();
                rec = null;
                return "Give ATAK microphone permission (Android settings > Apps > ATAK)";
            }
            len = 0;
            running = true;
            rec.startRecording();
            thread = new Thread(this::loop, "MeshTakRecord");
            thread.start();
            return null;
        }

        private void loop() {
            short[] chunk = new short[RATE / 10];
            while (running) {
                int n = rec.read(chunk, 0, chunk.length);
                if (n <= 0)
                    continue;
                synchronized (this) {
                    if (len + n > buf.length)
                        buf = Arrays.copyOf(buf, Math.max(buf.length * 2, len + n));
                    System.arraycopy(chunk, 0, buf, len, n);
                    len += n;
                    if (len >= maxSamples)
                        running = false;
                }
            }
        }

        public boolean isRunning() {
            return running;
        }

        public synchronized float seconds() {
            return len / (float) RATE;
        }

        /** Stops and returns the recording. */
        public short[] stop() {
            running = false;
            if (thread != null) {
                try {
                    thread.join(500);
                } catch (InterruptedException ignored) {
                }
            }
            if (rec != null) {
                try {
                    rec.stop();
                } catch (RuntimeException ignored) {
                }
                rec.release();
                rec = null;
            }
            synchronized (this) {
                return Arrays.copyOf(buf, Math.min(len, maxSamples));
            }
        }
    }

    /** Plays mono PCM at [rate], replacing whatever is playing. */
    public static synchronized void play(short[] pcm, int rate) {
        stopPlayback();
        if (pcm == null || pcm.length == 0)
            return;
        AudioTrack t = new AudioTrack(AudioManager.STREAM_MUSIC, rate,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
                pcm.length * 2, AudioTrack.MODE_STATIC);
        t.write(pcm, 0, pcm.length);
        t.play();
        track = t;
    }

    public static synchronized void stopPlayback() {
        if (track != null) {
            try {
                track.stop();
            } catch (IllegalStateException ignored) {
            }
            track.release();
            track = null;
        }
    }

    /**
     * Windowed-sinc decimation by an integer factor to float -1..1 (port of
     * the app's voxDecimate, so plugin and app feed codecs the same audio).
     */
    public static float[] decimate(short[] in, int factor) {
        int taps = 63;
        if (factor <= 1) {
            float[] out = new float[in.length];
            for (int i = 0; i < in.length; i++)
                out[i] = in[i] / 32768f;
            return out;
        }
        double cutoff = 0.45 / factor;
        double[] h = new double[taps];
        double mid = (taps - 1) / 2.0, sum = 0;
        for (int i = 0; i < taps; i++) {
            double n = i - mid;
            double sinc = n == 0 ? 2 * cutoff
                    : Math.sin(2 * Math.PI * cutoff * n) / (Math.PI * n);
            double w = 0.42 - 0.5 * Math.cos(2 * Math.PI * i / (taps - 1))
                    + 0.08 * Math.cos(4 * Math.PI * i / (taps - 1));
            h[i] = sinc * w;
            sum += h[i];
        }
        for (int i = 0; i < taps; i++)
            h[i] /= sum;
        int outLen = in.length / factor, half = taps / 2;
        float[] out = new float[outLen];
        for (int o = 0; o < outLen; o++) {
            int c = o * factor;
            double acc = 0;
            for (int k = 0; k < taps; k++) {
                int idx = c + k - half;
                if (idx >= 0 && idx < in.length)
                    acc += h[k] * in[idx];
            }
            out[o] = (float) Math.max(-1, Math.min(1, acc / 32768.0));
        }
        return out;
    }

    public static short[] toPcm16(float[] x) {
        short[] out = new short[x.length];
        for (int i = 0; i < x.length; i++)
            out[i] = (short) Math.round(Math.max(-1, Math.min(1, x[i])) * 32767);
        return out;
    }
}
