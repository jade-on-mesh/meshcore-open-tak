package com.jadeonmesh.meshcore.atak.plugin;

import android.content.Context;
import android.content.Intent;

import com.atakmap.android.dropdown.DropDownMapComponent;
import com.atakmap.android.ipc.AtakBroadcast.DocumentedIntentFilter;
import com.atakmap.android.maps.MapView;

import com.jadeonmesh.meshcore.atak.R;
import com.jadeonmesh.meshcore.atak.engine.MeshTakEngine;
import com.jadeonmesh.meshcore.atak.engine.Settings;
import com.jadeonmesh.meshcore.atak.radio.MeshRadio;
import com.jadeonmesh.meshcore.atak.tak.AtakBridge;
import com.jadeonmesh.meshcore.atak.ui.MeshDropDown;
import com.jadeonmesh.meshcore.atak.ui.StatusWidget;

/** Wires the plugin together when ATAK loads it. */
public final class MeshTakMapComponent extends DropDownMapComponent {

    private AtakBridge bridge;
    private MeshTakEngine engine;
    private StatusWidget widget;
    private MeshDropDown pane;

    @Override
    public void onCreate(Context pluginContext, Intent intent, MapView view) {
        pluginContext.setTheme(R.style.ATAKPluginTheme);
        super.onCreate(pluginContext, intent, view);
        Context atak = view.getContext();

        bridge = new AtakBridge(view);
        engine = new MeshTakEngine(atak, new Settings(atak), bridge);
        bridge.attach(engine);

        widget = new StatusWidget(view, pluginContext);
        pane = new MeshDropDown(view, engine);
        DocumentedIntentFilter f = new DocumentedIntentFilter();
        f.addAction(MeshDropDown.SHOW, "Show the MeshCore pane");
        registerDropDownReceiver(pane, f);

        bridge.setChangeListener(() -> {
            widget.setColor(colorFor(engine));
            if (pane.isShowing())
                pane.refresh();
        });
        engine.start();
    }

    static int colorFor(MeshTakEngine e) {
        MeshRadio r = e.radio();
        if (e.problem() == null)
            return StatusWidget.GREEN;
        if (r == null)
            return StatusWidget.GREY;
        return r.state() == MeshRadio.State.ERROR ? StatusWidget.RED
                : StatusWidget.AMBER;
    }

    @Override
    protected void onDestroyImpl(Context context, MapView view) {
        if (engine != null)
            engine.stop();
        if (bridge != null)
            bridge.dispose();
        if (widget != null)
            widget.dispose();
        super.onDestroyImpl(context, view);
    }
}
