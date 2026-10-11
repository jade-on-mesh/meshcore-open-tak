package com.jadeonmesh.meshcore.atak.tak;

import java.io.File;

import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.preference.PreferenceManager;
import android.widget.Toast;

import com.atakmap.android.cot.CotMapComponent;
import com.atakmap.android.ipc.AtakBroadcast;
import com.atakmap.android.maps.MapView;
import com.atakmap.android.maps.Marker;
import com.atakmap.comms.CommsMapComponent;
import com.atakmap.coremap.cot.event.CotEvent;
import com.atakmap.coremap.filesystem.FileSystemUtils;
import com.atakmap.coremap.log.Log;
import com.atakmap.coremap.maps.coords.GeoPoint;

import com.jadeonmesh.meshcore.atak.core.XNode;
import com.jadeonmesh.meshcore.atak.engine.MeshTakEngine;
import com.jadeonmesh.meshcore.atak.engine.TakSink;

/**
 * ATAK side of the plugin. Like the Meshtastic plugin, outgoing CoT is
 * intercepted with a PreSendProcessor and handed to the engine; mesh traffic
 * comes back in through ATAK's internal CoT dispatcher.
 */
public final class AtakBridge implements TakSink,
        CommsMapComponent.PreSendProcessor {

    private static final String TAG = "MeshCoreTAK";

    public interface ChangeListener {
        void onEngineChanged();
    }

    private final MapView mapView;
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile MeshTakEngine engine;
    private volatile ChangeListener changeListener;
    private volatile boolean disposed;
    private boolean changePosted;

    public AtakBridge(MapView mapView) {
        this.mapView = mapView;
    }

    public void attach(MeshTakEngine engine) {
        this.engine = engine;
        // There is no unregister in 4.6; dispose() makes this a no-op.
        CommsMapComponent.getInstance().registerPreSendProcessor(this);
    }

    public void setChangeListener(ChangeListener l) {
        changeListener = l;
    }

    public void dispose() {
        disposed = true;
        engine = null;
    }

    // ------------------------------------------------------- ATAK -> mesh

    @Override
    public void processCotEvent(CotEvent event, String[] toUIDs) {
        MeshTakEngine e = engine;
        if (disposed || e == null || event == null || !event.isValid())
            return;
        try {
            e.onAtakSend(event.toString(), toUIDs);
        } catch (RuntimeException ex) {
            Log.e(TAG, "pre-send failed", ex);
        }
    }

    // ------------------------------------------------------- mesh -> ATAK

    @Override
    public void dispatch(XNode event) {
        if (disposed)
            return;
        String xml = event.toXml();
        CotEvent ev = CotEvent.parse(xml);
        if (ev == null || !ev.isValid()) {
            Log.w(TAG, "not dispatching invalid CoT: " + xml);
            return;
        }
        try {
            CotMapComponent.getInternalDispatcher().dispatch(ev);
        } catch (RuntimeException ex) {
            Log.e(TAG, "dispatch failed", ex);
        }
    }

    @Override
    public void toast(String message) {
        if (message == null || disposed)
            return;
        main.post(() -> Toast.makeText(mapView.getContext(), message,
                Toast.LENGTH_LONG).show());
    }

    @Override
    public String selfUid() {
        return MapView.getDeviceUid();
    }

    @Override
    public SelfFix selfFix() {
        Marker self = mapView.getSelfMarker();
        if (self == null)
            return null;
        GeoPoint p = self.getPoint();
        if (p == null || !p.isValid() || (p.getLatitude() == 0 && p.getLongitude() == 0))
            return null;
        SelfFix f = new SelfFix();
        f.lat = p.getLatitude();
        f.lon = p.getLongitude();
        double alt = p.getAltitude();
        if (!Double.isNaN(alt))
            f.hae = alt;
        double ce = p.getCE();
        if (!Double.isNaN(ce) && ce < 9_999_999)
            f.ce = ce;
        double speed = self.getTrackSpeed(), heading = self.getTrackHeading();
        if (!Double.isNaN(speed) && !Double.isNaN(heading) && speed >= 0) {
            f.speedMps = speed;
            f.courseDeg = heading;
        }
        f.callsign = mapView.getDeviceCallsign();
        SharedPreferences prefs = PreferenceManager
                .getDefaultSharedPreferences(mapView.getContext());
        f.team = prefs.getString("locationTeam", "Cyan");
        f.role = prefs.getString("atakRoleType", "Team Member");
        try {
            Integer b = CotMapComponent.getInstance().getBatteryPercent();
            if (b != null)
                f.battery = b;
        } catch (RuntimeException ignored) {
        }
        f.timeMs = System.currentTimeMillis();
        return f;
    }

    @Override
    public File attachmentsDir(String uid) {
        return FileSystemUtils.getItem("attachments" + File.separator + uid);
    }

    @Override
    public File mediaDir() {
        return FileSystemUtils.getItem("tools" + File.separator + "meshcore");
    }

    @Override
    public void importFile(File f) {
        Intent i = new Intent(
                "com.atakmap.android.importfiles.USER_HANDLE_IMPORT_FILE_ACTION");
        i.putExtra("filepath", f.getAbsolutePath());
        i.putExtra("importInPlace", false);
        i.putExtra("promptOnMultipleMatch", true);
        i.putExtra("zoomToFile", false);
        AtakBroadcast.getInstance().sendBroadcast(i);
    }

    @Override
    public void onEngineChanged() {
        // Coalesce bursts (a burst of mesh traffic) into one UI refresh.
        synchronized (this) {
            if (changePosted)
                return;
            changePosted = true;
        }
        main.postDelayed(() -> {
            synchronized (AtakBridge.this) {
                changePosted = false;
            }
            ChangeListener l = changeListener;
            if (l != null && !disposed)
                l.onEngineChanged();
        }, 250);
    }
}
