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
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;

/**
 * MeshCore companion radio over BLE: the Nordic UART service. Each
 * notification on TX is one frame; each write to RX is one frame.
 *
 * Android's Bluetooth stack takes one operation at a time and reports each
 * result later, and on some phones a result never comes. So the link goes
 * strictly step by step (connect, discover, packet size, notifications), each
 * step has a time limit, and writes are acknowledged one at a time. Phones,
 * Samsung ones especially, often fail a first connection with status 133, so
 * connecting waits a moment and is tried up to three times. The packet-size
 * request may go unanswered (some tablets stall there): the link carries on
 * at the default size. When the radio asks for pairing, the link waits for
 * Android's PIN prompt instead of giving up. These are lessons the Colorado
 * Mesh TAK bridge (github.com/Colorado-Mesh/meshcore-tak-bridge) documented
 * from testing on devices; this is an independent implementation.
 *
 * The plugin runs inside ATAK's process, so it uses ATAK's Bluetooth
 * permissions (ATAK 5.8 targets SDK 35 and holds BLUETOOTH_SCAN,
 * BLUETOOTH_CONNECT and location). A transport is used once; reconnecting
 * makes a new one.
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

    private static final long SETTLE_MS = 600;
    private static final long CONNECT_MS = 12_000;
    private static final int CONNECT_TRIES = 3;
    private static final long RETRY_PAUSE_MS = 1_500;
    private static final long DISCOVER_MS = 15_000;
    private static final long MTU_MS = 4_000;
    private static final long SUBSCRIBE_MS = 10_000;
    private static final long PAIRING_MS = 60_000;
    private static final long WRITE_MS = 5_000;
    private static final int WANTED_MTU = 512;

    private enum Step {
        IDLE, CONNECTING, DISCOVERING, SIZING, SUBSCRIBING, PAIRING, READY, CLOSED
    }

    private final Context context;
    private final String address;
    private final String label;
    private final HandlerThread thread = new HandlerThread("MeshCoreBle");
    private final Handler h;

    // Everything below is touched only on [h]'s thread.
    private Listener listener;
    private Step step = Step.IDLE;
    private BluetoothGatt gatt;
    private BluetoothDevice device;
    private BluetoothGattCharacteristic rx, tx;
    private final ArrayDeque<byte[]> writes = new ArrayDeque<>();
    private boolean writing;
    private int attempts;
    private Runnable stepLimit, writeLimit;
    private boolean receiverRegistered;
    private boolean closedByUser;

    public BleTransport(Context context, String address, String label) {
        this.context = context;
        this.address = address;
        this.label = label;
        thread.start();
        h = new Handler(thread.getLooper());
    }

    @Override
    public String describe() {
        return "Bluetooth " + (label == null || label.isEmpty() ? address : label);
    }

    @Override
    public void open(Listener l) {
        h.post(() -> {
            listener = l;
            if (step != Step.IDLE)
                return;
            BluetoothManager bm = (BluetoothManager) context
                    .getSystemService(Context.BLUETOOTH_SERVICE);
            BluetoothAdapter ad = bm == null ? null : bm.getAdapter();
            if (ad == null || !ad.isEnabled()) {
                shutdown("Bluetooth is off");
                return;
            }
            try {
                device = ad.getRemoteDevice(address);
            } catch (IllegalArgumentException e) {
                shutdown("Bad Bluetooth address " + address);
                return;
            }
            step = Step.CONNECTING;
            registerBondReceiver();
            // A scan that stopped a moment ago can make the first try fail.
            h.postDelayed(this::attempt, SETTLE_MS);
        });
    }

    // --------------------------------------------------------------- steps

    private void attempt() {
        if (step != Step.CONNECTING)
            return;
        attempts++;
        limit(CONNECT_MS, () -> connectFailed("no answer within "
                + CONNECT_MS / 1000 + " s"));
        try {
            if (Build.VERSION.SDK_INT >= 26)
                gatt = device.connectGatt(context, false, cb,
                        BluetoothDevice.TRANSPORT_LE,
                        BluetoothDevice.PHY_LE_1M_MASK, h);
            else if (Build.VERSION.SDK_INT >= 23)
                gatt = device.connectGatt(context, false, cb,
                        BluetoothDevice.TRANSPORT_LE);
            else
                gatt = device.connectGatt(context, false, cb);
        } catch (SecurityException e) {
            shutdown(PERMISSION_HINT);
            return;
        }
        if (gatt == null)
            shutdown("Android refused to open a Bluetooth connection");
    }

    /** A try failed before the link came up: drop it and try again. */
    private void connectFailed(String why) {
        clearLimit();
        closeGatt();
        if (attempts < CONNECT_TRIES) {
            h.postDelayed(this::attempt, RETRY_PAUSE_MS);
            return;
        }
        String advice = why.startsWith("status 133:")
                ? ". If it persists, remove the radio from Android's"
                        + " paired devices, then pair it again"
                : "";
        shutdown("Could not connect after " + attempts + " tries (" + why + ")"
                + advice);
    }

    private void discover(BluetoothGatt g) {
        if (step != Step.DISCOVERING || g != gatt)
            return;
        try {
            if (Build.VERSION.SDK_INT >= 21)
                g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH);
            if (!g.discoverServices())
                shutdown("Android wouldn't look up the radio's services");
        } catch (SecurityException e) {
            shutdown(PERMISSION_HINT);
        }
    }

    private void onServices(BluetoothGatt g, int status) {
        if (step != Step.DISCOVERING || g != gatt)
            return;
        BluetoothGattService s = g.getService(SERVICE);
        rx = s == null ? null : s.getCharacteristic(RX);
        tx = s == null ? null : s.getCharacteristic(TX);
        if (status != BluetoothGatt.GATT_SUCCESS || rx == null || tx == null) {
            shutdown("Not a MeshCore companion radio (no UART service, status "
                    + status + ")");
            return;
        }
        step = Step.SIZING;
        // The answer may never come; carry on at the default size then.
        limit(MTU_MS, this::subscribe);
        boolean asked;
        try {
            asked = Build.VERSION.SDK_INT >= 21 && g.requestMtu(WANTED_MTU);
        } catch (SecurityException e) {
            shutdown(PERMISSION_HINT);
            return;
        }
        if (!asked)
            subscribe();
    }

    /** Turns on notifications. Reached after sizing and again after pairing. */
    private void subscribe() {
        BluetoothGatt g = gatt;
        if (g == null || tx == null || step == Step.CLOSED
                || step == Step.READY)
            return;
        step = Step.SUBSCRIBING;
        limit(SUBSCRIBE_MS, () -> {
            // Android can start pairing part-way through this write, silently.
            if (bondState() == BluetoothDevice.BOND_BONDING)
                awaitPairing();
            else
                shutdown("The radio didn't confirm notifications in time");
        });
        try {
            BluetoothGattDescriptor d = tx.getDescriptor(CCCD);
            if (!g.setCharacteristicNotification(tx, true)) {
                shutdown("Android refused to turn on radio notifications");
                return;
            }
            if (d == null) {
                ready();
                return;
            }
            byte[] on = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE;
            boolean ok;
            if (Build.VERSION.SDK_INT >= 33) {
                ok = g.writeDescriptor(d, on) == BluetoothGatt.GATT_SUCCESS;
            } else {
                d.setValue(on);
                ok = g.writeDescriptor(d);
            }
            if (!ok)
                shutdown("Android refused to turn on radio notifications");
        } catch (SecurityException e) {
            shutdown(PERMISSION_HINT);
        }
    }

    private void onSubscribed(int status) {
        if (step != Step.SUBSCRIBING)
            return;
        if (status == BluetoothGatt.GATT_SUCCESS) {
            ready();
        } else if (status == 5 || status == 8 || status == 15 || status == 137) {
            // Authentication / encryption needed: the radio wants a PIN.
            awaitPairing();
        } else {
            shutdown("Could not turn on radio notifications ("
                    + describeStatus(status) + ")");
        }
    }

    private void ready() {
        clearLimit();
        step = Step.READY;
        if (listener != null)
            listener.onTransportUp();
        pump();
    }

    // ------------------------------------------------------------ pairing

    private int bondState() {
        try {
            return device == null ? BluetoothDevice.BOND_NONE : device.getBondState();
        } catch (SecurityException e) {
            return BluetoothDevice.BOND_NONE;
        }
    }

    private void awaitPairing() {
        if (step == Step.PAIRING)
            return;
        step = Step.PAIRING;
        limit(PAIRING_MS, () -> shutdown(
                "Pairing wasn't completed: enter the radio's PIN when Android asks"));
        int state = bondState();
        if (state == BluetoothDevice.BOND_BONDED) {
            h.postDelayed(() -> {
                if (step == Step.PAIRING)
                    subscribe();
            }, SETTLE_MS);
        } else if (state == BluetoothDevice.BOND_NONE) {
            try {
                if (!device.createBond())
                    shutdown("Android wouldn't start pairing");
            } catch (SecurityException e) {
                shutdown(PERMISSION_HINT);
            }
        }
    }

    private final BroadcastReceiver bondReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent i) {
            BluetoothDevice d = i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
            if (d == null || !address.equalsIgnoreCase(d.getAddress()))
                return;
            int state = i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1);
            int prev = i.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1);
            // Delivered on [h] (see registerBondReceiver).
            if (step != Step.PAIRING)
                return;
            if (state == BluetoothDevice.BOND_BONDED) {
                h.postDelayed(() -> {
                    if (step == Step.PAIRING)
                        subscribe();
                }, SETTLE_MS);
            } else if (state == BluetoothDevice.BOND_NONE
                    && prev == BluetoothDevice.BOND_BONDING) {
                shutdown("Pairing was cancelled or the PIN was wrong");
            }
        }
    };

    private void registerBondReceiver() {
        IntentFilter f = new IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
        try {
            if (Build.VERSION.SDK_INT >= 33)
                context.registerReceiver(bondReceiver, f, null, h,
                        Context.RECEIVER_NOT_EXPORTED);
            else
                context.registerReceiver(bondReceiver, f, null, h);
            receiverRegistered = true;
        } catch (RuntimeException e) {
            // Without it, pairing still works; the link just can't follow it.
            receiverRegistered = false;
        }
    }

    // -------------------------------------------------------------- GATT

    private final BluetoothGattCallback cb = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status,
                int newState) {
            h.post(() -> onConnection(g, status, newState));
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            h.post(() -> onServices(g, status));
        }

        @Override
        public void onMtuChanged(BluetoothGatt g, int mtu, int status) {
            h.post(() -> {
                if (step == Step.SIZING && g == gatt)
                    subscribe();
            });
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g,
                BluetoothGattDescriptor d, int status) {
            h.post(() -> {
                if (g == gatt)
                    onSubscribed(status);
            });
        }

        // Android 13+ hands the bytes to the three-argument callback; older
        // versions only call this one. Each frame is delivered exactly once.
        @Override
        public void onCharacteristicChanged(BluetoothGatt g,
                BluetoothGattCharacteristic c) {
            if (Build.VERSION.SDK_INT >= 33)
                return;
            byte[] v = c.getValue();
            frame(c, v == null ? null : v.clone());
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g,
                BluetoothGattCharacteristic c, byte[] value) {
            frame(c, value == null ? null : value.clone());
        }

        private void frame(BluetoothGattCharacteristic c, byte[] v) {
            if (!TX.equals(c.getUuid()) || v == null || v.length == 0)
                return;
            h.post(() -> {
                if (step == Step.READY && listener != null)
                    listener.onFrame(v);
            });
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g,
                BluetoothGattCharacteristic c, int status) {
            h.post(() -> {
                if (g != gatt)
                    return;
                if (writeLimit != null)
                    h.removeCallbacks(writeLimit);
                writeLimit = null;
                writing = false;
                pump();
            });
        }
    };

    private void onConnection(BluetoothGatt g, int status, int newState) {
        // A callback from a try already given up on is ignored.
        if (step == Step.CLOSED || g != gatt)
            return;
        boolean connected = newState == BluetoothProfile.STATE_CONNECTED
                && status == BluetoothGatt.GATT_SUCCESS;
        if (step == Step.CONNECTING) {
            if (!connected) {
                connectFailed(describeStatus(status));
                return;
            }
            step = Step.DISCOVERING;
            limit(DISCOVER_MS, () -> shutdown("The radio didn't list its services in time"));
            // A short pause lets the link settle; some phones fail discovery without it.
            h.postDelayed(() -> discover(g), SETTLE_MS);
            return;
        }
        if (!connected)
            shutdown("Bluetooth link lost (" + describeStatus(status) + ")");
    }

    // ------------------------------------------------------------- writes

    @Override
    public void send(byte[] frame) {
        h.post(() -> {
            if (step == Step.CLOSED)
                return;
            writes.add(frame);
            pump();
        });
    }

    /** One acknowledged write at a time, each with a time limit. */
    private void pump() {
        if (writing || step != Step.READY || gatt == null || rx == null
                || writes.isEmpty())
            return;
        byte[] f = writes.poll();
        int type = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT;
        boolean ok;
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                ok = gatt.writeCharacteristic(rx, f, type) == BluetoothGatt.GATT_SUCCESS;
            } else {
                rx.setWriteType(type);
                rx.setValue(f);
                ok = gatt.writeCharacteristic(rx);
            }
        } catch (SecurityException e) {
            shutdown(PERMISSION_HINT);
            return;
        }
        if (!ok) {
            // The stack is busy for a moment; try again shortly.
            writes.addFirst(f);
            h.postDelayed(this::pump, 50);
            return;
        }
        writing = true;
        writeLimit = () -> shutdown("The radio stopped confirming what we send it");
        h.postDelayed(writeLimit, WRITE_MS);
    }

    // ---------------------------------------------------------- shutdown

    private void limit(long ms, Runnable onTimeout) {
        clearLimit();
        stepLimit = onTimeout;
        h.postDelayed(stepLimit, ms);
    }

    private void clearLimit() {
        if (stepLimit != null)
            h.removeCallbacks(stepLimit);
        stepLimit = null;
    }

    private void closeGatt() {
        BluetoothGatt g = gatt;
        gatt = null;
        if (g != null) {
            try {
                g.disconnect();
                g.close();
            } catch (RuntimeException ignored) {
            }
        }
    }

    private void shutdown(String reason) {
        if (step == Step.CLOSED)
            return;
        step = Step.CLOSED;
        h.removeCallbacksAndMessages(null);
        stepLimit = writeLimit = null;
        writes.clear();
        writing = false;
        if (receiverRegistered) {
            try {
                context.unregisterReceiver(bondReceiver);
            } catch (RuntimeException ignored) {
            }
            receiverRegistered = false;
        }
        closeGatt();
        Listener l = listener;
        if (!closedByUser && l != null)
            l.onTransportDown(reason);
        thread.quitSafely();
    }

    @Override
    public void close() {
        h.post(() -> {
            closedByUser = true;
            shutdown("Disconnected");
        });
    }

    static String describeStatus(int status) {
        switch (status) {
            case 0:
                return "status 0";
            case 5:
                return "status 5: the radio wants an authenticated link";
            case 8:
                return "status 8: link timed out; is the radio in range and powered?";
            case 15:
                return "status 15: the radio wants an encrypted link";
            case 19:
                return "status 19: the radio hung up";
            case 22:
                return "status 22: Android dropped the link";
            case 133:
                return "status 133: Android's catch-all Bluetooth failure";
            default:
                return "status " + status;
        }
    }
}
