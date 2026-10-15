package com.jadeonmesh.meshcore.atak.radio;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelUuid;
import android.os.SystemClock;

/**
 * Finds MeshCore companion radios by their Nordic UART service UUID. Paired
 * MeshCore radios are listed first: a radio that is asleep or connected
 * elsewhere may not be advertising.
 *
 * Android silently ignores an app's sixth scan start within 30 seconds (the
 * scan just never reports anything), so starts are counted here and the user
 * is told how long to wait instead.
 */
@SuppressLint("MissingPermission")
public final class BleScanner {

    public interface Callback {
        /** A radio, possibly again with a new signal level. Main thread. */
        void onRadio(String address, String name, int rssi, boolean paired);

        /** The scan ended; [error] is null when it simply ran its time. */
        void onDone(String error);
    }

    private static final long THROTTLE_WINDOW_MS = 30_000;
    /** Android blocks the sixth start in 30 s; stay one under. */
    private static final int MAX_STARTS = 4;
    /** Shared: Android's limit is per app (here, per ATAK). Main thread. */
    private static final ArrayDeque<Long> starts = new ArrayDeque<>();

    private final Context ctx;
    private final Handler main = new Handler(Looper.getMainLooper());
    private BluetoothLeScanner scanner;
    private ScanCallback cb;
    private Runnable timer;

    public BleScanner(Context ctx) {
        this.ctx = ctx;
    }

    public boolean scanning() {
        return cb != null;
    }

    /** Null when a scan can start now, else why not. Main thread. */
    public String blocker() {
        BluetoothAdapter ad = adapter();
        if (ad == null)
            return "This phone has no Bluetooth";
        if (!ad.isEnabled())
            return "Turn Bluetooth on";
        long now = SystemClock.elapsedRealtime();
        while (!starts.isEmpty() && now - starts.peekFirst() >= THROTTLE_WINDOW_MS)
            starts.pollFirst();
        if (starts.size() < MAX_STARTS)
            return null;
        long s = Math.max(1, (starts.peekFirst() + THROTTLE_WINDOW_MS - now) / 1000 + 1);
        return "Android limits how often apps can scan; wait "
                + s + " s and try again";
    }

    private BluetoothAdapter adapter() {
        BluetoothManager bm = (BluetoothManager) ctx
                .getSystemService(Context.BLUETOOTH_SERVICE);
        return bm == null ? null : bm.getAdapter();
    }

    /** Main thread. */
    public void scan(long ms, Callback out) {
        stop();
        String why = blocker();
        if (why != null) {
            out.onDone(why);
            return;
        }
        BluetoothAdapter ad = adapter();
        try {
            for (BluetoothDevice d : ad.getBondedDevices()) {
                String n = d.getName();
                if (d.getType() != BluetoothDevice.DEVICE_TYPE_CLASSIC
                        && looksLikeMeshCore(n))
                    out.onRadio(d.getAddress(), n, 0, true);
            }
        } catch (SecurityException e) {
            out.onDone(BleTransport.PERMISSION_HINT);
            return;
        }
        scanner = ad.getBluetoothLeScanner();
        if (scanner == null) {
            out.onDone("Bluetooth LE scanning is unavailable");
            return;
        }
        final ScanCallback mine = new ScanCallback() {
            @Override
            public void onScanResult(int type, ScanResult r) {
                BluetoothDevice d = r.getDevice();
                String name = r.getScanRecord() != null
                        && r.getScanRecord().getDeviceName() != null
                                ? r.getScanRecord().getDeviceName()
                                : d.getName();
                String addr = d.getAddress();
                int rssi = r.getRssi();
                main.post(() -> {
                    if (cb == this)
                        out.onRadio(addr, name == null || name.isEmpty()
                                ? "MeshCore radio" : name, rssi, false);
                });
            }

            @Override
            public void onScanFailed(int errorCode) {
                main.post(() -> {
                    if (cb != this)
                        return;
                    stop();
                    out.onDone("Scan failed (error " + errorCode
                            + "): check ATAK's Nearby devices permission");
                });
            }
        };
        List<ScanFilter> filters = new ArrayList<>();
        filters.add(new ScanFilter.Builder()
                .setServiceUuid(new ParcelUuid(BleTransport.SERVICE)).build());
        try {
            starts.addLast(SystemClock.elapsedRealtime());
            scanner.startScan(filters, new ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), mine);
        } catch (SecurityException e) {
            out.onDone(BleTransport.PERMISSION_HINT);
            return;
        }
        cb = mine;
        timer = () -> {
            if (cb == mine) {
                stop();
                out.onDone(null);
            }
        };
        main.postDelayed(timer, ms);
    }

    public void stop() {
        if (timer != null)
            main.removeCallbacks(timer);
        timer = null;
        ScanCallback c = cb;
        cb = null;
        if (scanner != null && c != null) {
            try {
                scanner.stopScan(c);
            } catch (RuntimeException ignored) {
            }
        }
    }

    static boolean looksLikeMeshCore(String name) {
        return name != null && name.toLowerCase(Locale.US).startsWith("meshcore");
    }
}
