package com.jadeonmesh.meshcore.atak.plugin;

import android.content.Context;

import com.atak.plugins.impl.AbstractPlugin;
import com.atak.plugins.impl.PluginContextProvider;

import gov.tak.api.plugin.IServiceController;

/**
 * Entry point named in assets/plugin.xml (ATAK 5.x {@code IPlugin}). Wraps
 * the toolbar tool and the map component, as the SDK's PluginTemplateLegacy
 * does.
 */
public final class MeshTakLifecycle extends AbstractPlugin {
    public MeshTakLifecycle(IServiceController serviceController) {
        super(serviceController, new MeshTakTool(pluginContext(serviceController)),
                new MeshTakMapComponent());
        PluginNativeLoader.init(pluginContext(serviceController));
    }

    private static Context pluginContext(IServiceController sc) {
        return sc.getService(PluginContextProvider.class).getPluginContext();
    }
}
