package com.jadeonmesh.meshcore.atak.plugin;

import java.io.File;

import android.content.Context;

/**
 * Loads the plugin's native libraries from its own APK (from the ATAK plugin
 * template: the class loader that loads this class is what makes System.load
 * work for a plugin, so it must live in the plugin).
 */
public final class PluginNativeLoader {
    private PluginNativeLoader() {
    }

    private static String ndl;

    public static synchronized void init(Context context) {
        if (ndl == null) {
            try {
                ndl = context.getPackageManager().getApplicationInfo(
                        context.getPackageName(), 0).nativeLibraryDir;
            } catch (Exception e) {
                throw new IllegalArgumentException(
                        "native library loading will fail: no nativeLibraryDir");
            }
        }
    }

    /** Loads lib[name].so by absolute path (per the ATAK security guidance). */
    public static void loadLibrary(String name) {
        if (ndl == null)
            throw new IllegalArgumentException("NativeLoader not initialized");
        String lib = ndl + File.separator + System.mapLibraryName(name);
        if (!new File(lib).exists())
            throw new UnsatisfiedLinkError(lib + " is not in the plugin");
        System.load(lib);
    }
}
