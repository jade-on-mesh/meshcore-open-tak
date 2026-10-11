package com.jadeonmesh.meshcore.atak.ui;

import android.content.Context;
import android.content.Intent;
import android.view.MotionEvent;

import com.atakmap.android.ipc.AtakBroadcast;
import com.atakmap.android.maps.MapView;
import com.atakmap.android.widgets.LinearLayoutWidget;
import com.atakmap.android.widgets.MapWidget;
import com.atakmap.android.widgets.MarkerIconWidget;
import com.atakmap.android.widgets.RootLayoutWidget;
import com.atakmap.coremap.maps.assets.Icon;

import com.jadeonmesh.meshcore.atak.R;

/**
 * The mesh icon in the bottom-right corner, like the Meshtastic plugin's:
 * green when team traffic can flow, amber while connecting or misconfigured,
 * red on error, grey when off. Tapping it opens the MeshCore pane.
 */
public final class StatusWidget implements MapWidget.OnClickListener {

    public static final int GREY = 0xFF9E9E9E, GREEN = 0xFF4CAF50,
            AMBER = 0xFFFFB300, RED = 0xFFF44336;

    private final Context pluginContext;
    private final MarkerIconWidget widget = new MarkerIconWidget();
    private final LinearLayoutWidget layout;
    private int color = -1;

    public StatusWidget(MapView mapView, Context pluginContext) {
        this.pluginContext = pluginContext;
        RootLayoutWidget root = (RootLayoutWidget) mapView
                .getComponentExtra("rootLayoutWidget");
        layout = root.getLayout(RootLayoutWidget.BOTTOM_RIGHT);
        widget.setName("MeshCore");
        widget.addOnClickListener(this);
        setColor(GREY);
        layout.addWidget(widget);
    }

    public void setColor(int argb) {
        if (argb == color)
            return;
        color = argb;
        String uri = "android.resource://" + pluginContext.getPackageName() + "/"
                + R.drawable.ic_mesh_status;
        Icon.Builder b = new Icon.Builder();
        b.setAnchor(0, 0);
        b.setColor(Icon.STATE_DEFAULT, argb);
        b.setSize(48, 48);
        b.setImageUri(Icon.STATE_DEFAULT, uri);
        widget.setIcon(b.build());
    }

    @Override
    public void onMapWidgetClick(MapWidget w, MotionEvent e) {
        AtakBroadcast.getInstance().sendBroadcast(
                new Intent(MeshDropDown.SHOW));
    }

    public void dispose() {
        layout.removeWidget(widget);
    }
}
