package com.jadeonmesh.meshcore.atak.media;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.FloatBuffer;
import java.nio.LongBuffer;
import java.security.MessageDigest;
import java.util.Collections;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OnnxValue;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

import com.jadeonmesh.meshcore.atak.core.Bytes;
import com.jadeonmesh.meshcore.atak.core.VoiceWire;

/**
 * Kyutai's Mimi neural codec (CC-BY 4.0), ~1.1 kb/s, the same ONNX export
 * and release files the MeshCore Open TAK app uses, so clips are
 * interchangeable. The model (~223 MB) is downloaded on request.
 */
public final class MimiCodec {

    static final String BASE = "https://github.com/jade-on-mesh/meshcore-open-tak/releases/download/mimi-onnx-v1/";
    static final String[][] FILES = {
            { "mimi_encoder_fp16.onnx",
                    "d36a126fdcf47dd9e2bae2730d9dbd5a68c77f9be1dc1298ff9a4750af5241ae",
                    "124824482" },
            { "mimi_decoder_fp16.onnx",
                    "dd4b185fb4103261313157c31b5e65e5715605a3604f9bfb085c1d807d2b5ba6",
                    "97817328" } };

    public interface Progress {
        void onProgress(double fraction);
    }

    private final File dir;
    private OrtEnvironment env;
    private OrtSession encoder, decoder;
    private volatile boolean downloading;
    private volatile boolean cancel;
    private long lastUse;

    public MimiCodec(File dir) {
        this.dir = dir;
        dir.mkdirs();
    }

    /** ONNX Runtime is bundled and the model files are present. */
    public boolean isReady() {
        if (!runtimeAvailable())
            return false;
        for (String[] f : FILES) {
            File file = new File(dir, f[0]);
            if (!file.exists() || file.length() != Long.parseLong(f[2]))
                return false;
        }
        return true;
    }

    public static boolean runtimeAvailable() {
        try {
            Class.forName("ai.onnxruntime.OrtEnvironment");
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    public boolean isDownloading() {
        return downloading;
    }

    public static int downloadMb() {
        long t = 0;
        for (String[] f : FILES)
            t += Long.parseLong(f[2]);
        return (int) (t / 1_000_000);
    }

    public void cancelDownload() {
        cancel = true;
    }

    /** Blocking; run off the UI thread. Returns an error or null. */
    public String download(Progress p) {
        if (downloading)
            return "Already downloading";
        downloading = true;
        cancel = false;
        try {
            long total = 0, done = 0;
            for (String[] f : FILES)
                total += Long.parseLong(f[2]);
            for (String[] f : FILES) {
                File dest = new File(dir, f[0]);
                if (dest.exists() && dest.length() == Long.parseLong(f[2])
                        && f[1].equals(sha256(dest))) {
                    done += dest.length();
                    continue;
                }
                File part = new File(dir, f[0] + ".part");
                HttpURLConnection c = (HttpURLConnection) new URL(BASE + f[0])
                        .openConnection();
                c.setInstanceFollowRedirects(true);
                c.setConnectTimeout(20_000);
                c.setReadTimeout(60_000);
                if (c.getResponseCode() != 200)
                    return "HTTP " + c.getResponseCode() + " for " + f[0];
                MessageDigest md = MessageDigest.getInstance("SHA-256");
                try (InputStream in = c.getInputStream();
                        FileOutputStream out = new FileOutputStream(part)) {
                    byte[] buf = new byte[64 * 1024];
                    int n;
                    while ((n = in.read(buf)) > 0) {
                        if (cancel)
                            return "Cancelled";
                        out.write(buf, 0, n);
                        md.update(buf, 0, n);
                        done += n;
                        if (p != null)
                            p.onProgress(done / (double) total);
                    }
                } finally {
                    c.disconnect();
                }
                if (!f[1].equals(Bytes.hex(md.digest()))) {
                    part.delete();
                    return f[0] + " failed its checksum";
                }
                if (!part.renameTo(dest))
                    return "Could not save " + f[0];
            }
            return null;
        } catch (Exception e) {
            return e.getMessage();
        } finally {
            downloading = false;
        }
    }

    public void delete() {
        close();
        for (String[] f : FILES)
            new File(dir, f[0]).delete();
    }

    private static String sha256(File f) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0)
                md.update(buf, 0, n);
        }
        return Bytes.hex(md.digest());
    }

    private static boolean ortPreloaded;

    /**
     * ONNX Runtime loads its JNI library with System.loadLibrary, and that
     * library needs libonnxruntime.so. Inside ATAK the plugin's library
     * folder may not be on the linker's search path, so load both by
     * absolute path first (as the plugin does for its own codecs).
     */
    private static synchronized void preloadOrt() {
        if (ortPreloaded)
            return;
        ortPreloaded = true;
        for (String lib : new String[] { "onnxruntime", "onnxruntime4j_jni" }) {
            try {
                com.jadeonmesh.meshcore.atak.plugin.PluginNativeLoader.loadLibrary(lib);
            } catch (Throwable ignored) {
                // ORT's own loadLibrary below reports the real problem.
            }
        }
    }

    private OrtSession session(int which) throws Exception {
        if (env == null) {
            preloadOrt();
            env = OrtEnvironment.getEnvironment();
        }
        lastUse = System.currentTimeMillis();
        if (which == 0) {
            if (encoder == null)
                encoder = env.createSession(new File(dir, FILES[0][0]).getPath(),
                        new OrtSession.SessionOptions());
            return encoder;
        }
        if (decoder == null)
            decoder = env.createSession(new File(dir, FILES[1][0]).getPath(),
                    new OrtSession.SessionOptions());
        return decoder;
    }

    /** 24 kHz float audio (up to 20 s) to packed codes, 11 bytes per 80 ms. */
    public synchronized byte[] encode(float[] audio24k) throws Exception {
        OrtSession s = session(0);
        int frames = Math.min(VoiceWire.MIMI_MAX_FRAMES,
                (audio24k.length + VoiceWire.MIMI_FRAME_SAMPLES - 1)
                        / VoiceWire.MIMI_FRAME_SAMPLES);
        float[] padded = new float[VoiceWire.MIMI_MAX_SAMPLES];
        System.arraycopy(audio24k, 0, padded, 0,
                Math.min(audio24k.length, padded.length));
        try (OnnxTensor in = OnnxTensor.createTensor(env, FloatBuffer.wrap(padded),
                new long[] { 1, 1, VoiceWire.MIMI_MAX_SAMPLES });
                OrtSession.Result r = s.run(Collections.singletonMap("audio", in))) {
            OnnxValue v = r.get(0);
            long[] codes = flatten(v.getValue());
            return VoiceWire.packMimi(codes, frames, VoiceWire.MIMI_MAX_FRAMES);
        }
    }

    /** Packed codes to 24 kHz float audio, trimmed to the clip. */
    public synchronized float[] decode(byte[] packed) throws Exception {
        OrtSession s = session(1);
        int frames = Math.min(VoiceWire.MIMI_MAX_FRAMES,
                packed.length / VoiceWire.MIMI_BYTES_PER_FRAME);
        long[] codes = VoiceWire.unpackMimi(packed, VoiceWire.MIMI_MAX_FRAMES);
        try (OnnxTensor in = OnnxTensor.createTensor(env, LongBuffer.wrap(codes),
                new long[] { 1, VoiceWire.MIMI_CODEBOOKS, VoiceWire.MIMI_MAX_FRAMES });
                OrtSession.Result r = s.run(Collections.singletonMap("codes", in))) {
            FloatBuffer fb = ((OnnxTensor) r.get(0)).getFloatBuffer();
            int n = Math.min(frames * VoiceWire.MIMI_FRAME_SAMPLES, fb.remaining());
            float[] out = new float[n];
            fb.get(out, 0, n);
            return out;
        }
    }

    /** Flattens a nested long[][][] or int[][][] tensor value. */
    static long[] flatten(Object v) {
        java.util.ArrayList<Long> acc = new java.util.ArrayList<>();
        flattenInto(v, acc);
        long[] out = new long[acc.size()];
        for (int i = 0; i < out.length; i++)
            out[i] = acc.get(i);
        return out;
    }

    private static void flattenInto(Object v, java.util.List<Long> acc) {
        if (v instanceof long[]) {
            for (long x : (long[]) v)
                acc.add(x);
        } else if (v instanceof int[]) {
            for (int x : (int[]) v)
                acc.add((long) x);
        } else if (v instanceof Object[]) {
            for (Object o : (Object[]) v)
                flattenInto(o, acc);
        }
    }

    /** Frees the sessions (several hundred MB) after a minute idle. */
    public synchronized void closeIfIdle() {
        if (System.currentTimeMillis() - lastUse > 60_000)
            close();
    }

    public synchronized void close() {
        try {
            if (encoder != null)
                encoder.close();
            if (decoder != null)
                decoder.close();
        } catch (Exception ignored) {
        }
        encoder = null;
        decoder = null;
    }
}
