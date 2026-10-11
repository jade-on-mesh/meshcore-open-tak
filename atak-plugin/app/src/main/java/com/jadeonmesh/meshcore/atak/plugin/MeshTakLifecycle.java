package com.jadeonmesh.meshcore.atak.plugin;

import android.content.Context;

import com.atak.plugins.impl.AbstractPluginLifecycle;

/** Entry point named in assets/plugin.xml. */
public final class MeshTakLifecycle extends AbstractPluginLifecycle {
    public MeshTakLifecycle(Context ctx) {
        super(ctx, new MeshTakMapComponent());
        PluginNativeLoader.init(ctx);
    }
}
