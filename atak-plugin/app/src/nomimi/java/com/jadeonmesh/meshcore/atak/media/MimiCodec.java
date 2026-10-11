package com.jadeonmesh.meshcore.atak.media;

import java.io.File;

/** Build without ONNX Runtime (-PwithMimi=false): Mimi is unavailable. */
public final class MimiCodec {

    public interface Progress {
        void onProgress(double fraction);
    }

    public MimiCodec(File dir) {
    }

    public boolean isReady() {
        return false;
    }

    public static boolean runtimeAvailable() {
        return false;
    }

    public boolean isDownloading() {
        return false;
    }

    public static int downloadMb() {
        return 223;
    }

    public void cancelDownload() {
    }

    public String download(Progress p) {
        return "This build has no ONNX Runtime";
    }

    public void delete() {
    }

    public byte[] encode(float[] audio24k) throws Exception {
        throw new IllegalStateException("Mimi unavailable in this build");
    }

    public float[] decode(byte[] packed) throws Exception {
        throw new IllegalStateException("Mimi unavailable in this build");
    }

    public void closeIfIdle() {
    }

    public void close() {
    }
}
