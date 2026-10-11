package com.jadeonmesh.meshcore.atak.media;

import com.jadeonmesh.meshcore.atak.plugin.PluginNativeLoader;

/** JNI bindings for libmtak_codecs.so (Codec2 and AV1 stills). */
public final class NativeCodecs {
    private NativeCodecs() {
    }

    private static Boolean loaded;
    private static String loadError;

    /** Loads the library once; false (with {@link #error()}) if it can't. */
    public static synchronized boolean load() {
        if (loaded != null)
            return loaded;
        try {
            PluginNativeLoader.loadLibrary("mtak_codecs");
            av1Available(); // links?
            loaded = true;
        } catch (Throwable t) {
            loadError = t.toString();
            loaded = false;
        }
        return loaded;
    }

    public static String error() {
        return loadError;
    }

    public static boolean hasAv1() {
        return load() && av1Available();
    }

    static native boolean av1Available();

    /** 8 kHz PCM to Codec2 bits for CODEC2_MODE_* [mode]. */
    static native byte[] c2Encode(int mode, short[] pcm8k);

    static native short[] c2Decode(int mode, byte[] bits);

    static native byte[] av1Encode(byte[] rgb, int w, int h, int q, int speed,
            int threads);

    /** [w u16][h u16][rgb...] or null. */
    static native byte[] av1Decode(byte[] obus);
}
