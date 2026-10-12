package com.jadeonmesh.meshcore.atak.plugin;

import android.content.Context;

import com.atak.plugins.impl.AbstractPluginTool;
import gov.tak.api.util.Disposable;

import com.jadeonmesh.meshcore.atak.R;
import com.jadeonmesh.meshcore.atak.ui.MeshDropDown;

/** Toolbar / overflow-menu entry that opens the MeshCore pane. */
public final class MeshTakTool extends AbstractPluginTool implements Disposable {
    public MeshTakTool(Context context) {
        super(context, context.getString(R.string.app_name),
                context.getString(R.string.app_name),
                context.getResources().getDrawable(R.drawable.ic_launcher),
                MeshDropDown.SHOW);
    }

    @Override
    public void dispose() {
    }
}
