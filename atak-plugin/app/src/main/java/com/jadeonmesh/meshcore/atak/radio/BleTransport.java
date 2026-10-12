package com.jadeonmesh.meshcore.atak.radio;

import java.util.ArrayDeque;
import java.util.UUID;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

/**
 * MeshCore companion radio over BLE: the Nordic UART service. Each
 * notification on TX is one frame; each write to RX is one frame.
 *
 * The plugin runs inside ATAK's process, so it uses ATAK's Bluetooth
 * permissions (ATAK 5.8 targets SDK 35 and holds BLUETOOTH_SCAN,
 * BLUETOOTH_CONNECT and location, which is what scanning and connecting
 * need).
 */
@SuppressLint("MissingPermission")
public final class BleTransport implements FrameTransport {

    public static final UUID SERVICE = UUID
            .fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
    public static final UUID RX = UUID
            .fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e");
    public static final UUID TX = UUID
            .fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e");
    /** Shown when Android refuses ATAK the Bluetooth runtime permission. */
    static final String PERMISSION_HINT = "ATAK isn't allowed to use Bluetooth:"
            + " Android Settings > Apps > ATAK > Permissions > Nearby devices";

    static final UUID CCCD = UUID
            .fromString("00002902-0000-1000-8000-00805f9b34fb");

    private final Context context;
    private final String address;
    private final String label;
    private final Handler main = new Handler(Looper.getMainLooper());

    private Listener listener;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic rx;
    private final ArrayDeque<byte[]> writes = new ArrayDeque<>();
    private boolean writing;
    private int writeSeq;
    private boolean up;
    private boolean closed;

    public BleTransport(Context context, String address, String label) {
        this.context = context;
        this.address = address;
        this.label = label;
    }

    @Override
    public String describe() {
        return "Bluetooth " + (label == null || label.isEmpty() ? address : label);
    }

    @Override
    public void open(Listener l) {
        this.listener = l;
        main.post(this::connect);
    }

    private void connect() {
        BluetoothManager bm = (BluetoothManager) context
                .getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter ad = bm == null ? null : bm.getAdapter();
        if (ad == null || !ad.isEnabled()) {
            down("Bluetooth is off");
            return;
        }
        BluetoothDevice dev;
        try {
            dev = ad.getRemoteDevice(address);
        } catch (IllegalArgumentException e) {
            down("Bad Bluetooth address " + address);
            return;
        }
        try {
            if (Build.VERSION.SDK_INT >= 23)
                gatt = dev.connectGatt(context, false, cb,
                        BluetoothDevice.TRANSPORT_LE);
            else
                gatt = dev.connectGatt(context, false, cb);
        } catch (SecurityException e) {
            down(PERMISSION_HINT);
            return;
        }
        if (gatt == null)
            down("Could not start a Bluetooth connection");
    }

    private final BluetoothGattCallback cb = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status,
                int newState) {
            if (newState == BluetoothProfile.STATE_CONNECTED
                    && status == BluetoothGatt.GATT_SUCCESS) {
                if (Build.VERSION.SDK_INT >= 21) {
                    g.requestConnectionPriority(
                            BluetoothGatt.CONNECTION_PRIORITY_HIGH);
                    if (!g.requestMtu(185))
                        g.discoverServices();
                } else {
                    g.discoverServices();
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                down(status == BluetoothGatt.GATT_SUCCESS ? "Disconnected"
                        : "Bluetooth link lost (status " + status + ")");
            }
        }

        @Override
        public void onMtuChanged(BluetoothGatt g, int mtu, int status) {
            g.discoverServices();
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            BluetoothGattService s = g.getService(SERVICE);
            if (s == null) {
                down("Not a MeshCore companion radio (no UART service)");
                return;
            }
            rx = s.getCharacteristic(RX);
            BluetoothGattCharacteristic tx = s.getCharacteristic(TX);
            if (rx == null || tx == null) {
                down("MeshCore UART characteristics missing");
                return;
            }
            boolean noResp = (rx.getProperties()
                    & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0;
            rx.setWriteType(noResp
                    ? BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    : BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            g.setCharacteristicNotification(tx, true);
            BluetoothGattDescriptor d = tx.getDescriptor(CCCD);
            if (d == null) {
                ready();
                return;
            }
            d.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
            if (!g.writeDescriptor(d))
                down("Could not enable radio notifications");
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g,
                BluetoothGattDescriptor d, int status) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                // Insufficient authentication: the bond prompt is showing.
                down("Pairing needed: accept the PIN prompt, then reconnect"
                        + " (status " + status + ")");
                return;
            }
            ready();
        }

        // Android 13+ hands the bytes to the three-argument callback; older
        // versions only call this one. Each frame is delivered exactly once.
        @Override
        public void onCharacteristicChanged(BluetoothGatt g,
                BluetoothGattCharacteristic c) {
            if (Build.VERSION.SDK_INT >= 33)
                return;
            frame(c, c.getValue());
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g,
                BluetoothGattCharacteristic c, byte[] value) {
            frame(c, value);
        }

        private void frame(BluetoothGattCharacteristic c, byte[] v) {
            if (TX.equals(c.getUuid()) && v != null && v.length > 0
                    && listener != null)
                listener.onFrame(v.clone());
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g,
                BluetoothGattCharacteristic c, int status) {
            main.post(() -> {
                writing = false;
                pump();
            });
        }
    };

    private void ready() {
        main.post(() -> {
            if (up || closed)
                return;
            up = true;
            if (listener != null)
                listener.onTransportUp();
            pump();
        });
    }

    @Override
    public void send(byte[] frame) {
        main.post(() -> {
            writes.add(frame);
            pump();
        });
    }

    private void pump() {
        if (writing || !up || gatt == null || rx == null || writes.isEmpty())
            return;
        byte[] f = writes.poll();
        rx.setValue(f);
        writing = gatt.writeCharacteristic(rx);
        if (!writing) {
            // The stack is busy; try again shortly.
            writes.addFirst(f);
            main.postDelayed(this::pump, 30);
        } else {
            // Some stacks never call back for no-response writes.
            final int seq = ++writeSeq;
            main.postDelayed(() -> {
                if (writing && writeSeq == seq) {
                    writing = false;
                    pump();
                }
            }, 400);
        }
    }

    private void down(String why) {
        main.post(() -> {
            boolean wasClosed = closed;
            cleanup();
            if (!wasClosed && listener != null)
                listener.onTransportDown(why);
        });
    }

    private void cleanup() {
        up = false;
        writing = false;
        writes.clear();
        if (gatt != null) {
            try {
                gatt.disconnect();
                gatt.close();
            } catch (Exception ignored) {
            }
            gatt = null;
        }
    }

    @Override
    public void close() {
        main.post(() -> {
            closed = true;
            cleanup();
        });
    }
}
