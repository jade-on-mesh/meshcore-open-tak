package com.jadeonmesh.meshcore.atak.radio;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

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

/** Finds MeshCore companion radios by their Nordic UART service UUID. */
@SuppressLint("MissingPermission")
public final class BleScanner {

    public interface Callback {
        /** Called as radios are found and once more when the scan ends. */
        void onResults(List<String[]> addressAndName, boolean finished,
                String error);
    }

    private final Context ctx;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, String> found = new LinkedHashMap<>();
    private BluetoothLeScanner scanner;
    private ScanCallback cb;

    public BleScanner(Context ctx) {
        this.ctx = ctx;
    }

    public void scan(long ms, Callback out) {
        stop();
        found.clear();
        BluetoothManager bm = (BluetoothManager) ctx
                .getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter ad = bm == null ? null : bm.getAdapter();
        if (ad == null || !ad.isEnabled()) {
            out.onResults(Collections.<String[]> emptyList(), true,
                    "Turn Bluetooth on");
            return;
        }
        // Bonded radios first: they show even when not advertising.
        for (BluetoothDevice d : ad.getBondedDevices())
            if (d.getType() != BluetoothDevice.DEVICE_TYPE_CLASSIC)
                found.put(d.getAddress(), (d.getName() == null ? "" : d.getName())
                        + " (paired)");
        scanner = ad.getBluetoothLeScanner();
        if (scanner == null) {
            out.onResults(list(), true, "Bluetooth LE unavailable");
            return;
        }
        cb = new ScanCallback() {
            @Override
            public void onScanResult(int type, ScanResult r) {
                BluetoothDevice d = r.getDevice();
                String name = r.getScanRecord() != null
                        && r.getScanRecord().getDeviceName() != null
                                ? r.getScanRecord().getDeviceName()
                                : d.getName();
                found.put(d.getAddress(), (name == null ? "MeshCore" : name)
                        + "  " + r.getRssi() + " dBm");
                out.onResults(list(), false, null);
            }

            @Override
            public void onScanFailed(int errorCode) {
                out.onResults(list(), true, "Scan failed (" + errorCode
                        + "): check ATAK's location permission");
            }
        };
        List<ScanFilter> filters = new ArrayList<>();
        filters.add(new ScanFilter.Builder()
                .setServiceUuid(new ParcelUuid(BleTransport.SERVICE)).build());
        try {
            scanner.startScan(filters, new ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), cb);
        } catch (SecurityException e) {
            out.onResults(list(), true, BleTransport.PERMISSION_HINT);
            return;
        }
        out.onResults(list(), false, null);
        main.postDelayed(() -> {
            stop();
            out.onResults(list(), true, null);
        }, ms);
    }

    private List<String[]> list() {
        List<String[]> l = new ArrayList<>();
        for (Map.Entry<String, String> e : found.entrySet())
            l.add(new String[] { e.getKey(), e.getValue() });
        return l;
    }

    public void stop() {
        if (scanner != null && cb != null) {
            try {
                scanner.stopScan(cb);
            } catch (RuntimeException ignored) {
            }
        }
        cb = null;
    }
}
