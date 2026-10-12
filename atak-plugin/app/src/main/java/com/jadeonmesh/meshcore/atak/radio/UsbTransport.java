package com.jadeonmesh.meshcore.atak.radio;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.os.Build;

import com.jadeonmesh.meshcore.atak.core.Companion;

/**
 * MeshCore companion radio over USB serial, 115200 8N1, framed as
 * [marker][len u16 LE][payload] ('&lt;' to the radio, '&gt;' from it).
 *
 * Drivers: CDC-ACM (nRF52 and ESP32-S3 native USB, CH9102), Silicon Labs
 * CP210x (Heltec V3 and most ESP32 dev boards) and WCH CH340/CH341.
 * On ESP32 boards with auto-reset wiring DTR and RTS are kept equal so the
 * chip is never held in reset.
 */
public final class UsbTransport implements FrameTransport {

    public static final String ACTION_PERMISSION = "com.jadeonmesh.meshcore.atak.USB_PERMISSION";
    static final int BAUD = 115200;
    static final int VID_SILABS = 0x10C4, VID_WCH = 0x1A86;

    private final Context context;
    private final String deviceName;
    private final ExecutorService io = Executors.newSingleThreadExecutor();

    private Listener listener;
    private UsbDeviceConnection conn;
    private UsbInterface dataIf, ctrlIf;
    private UsbEndpoint in, out;
    private volatile boolean reading;
    private Thread reader;
    private BroadcastReceiver permReceiver;

    public UsbTransport(Context context, String deviceName) {
        this.context = context;
        this.deviceName = deviceName;
    }

    /** "name - product - VID:PID" for each attached USB device. */
    public static List<String[]> listDevices(Context ctx) {
        UsbManager um = (UsbManager) ctx.getSystemService(Context.USB_SERVICE);
        List<String[]> out = new ArrayList<>();
        if (um == null)
            return out;
        for (UsbDevice d : um.getDeviceList().values()) {
            String product = Build.VERSION.SDK_INT >= 21 && d.getProductName() != null
                    ? d.getProductName()
                    : "USB serial";
            out.add(new String[] { d.getDeviceName(),
                    String.format(Locale.US, "%s (%04X:%04X)", product,
                            d.getVendorId(), d.getProductId()) });
        }
        return out;
    }

    @Override
    public String describe() {
        return "USB " + deviceName;
    }

    @Override
    public void open(Listener l) {
        this.listener = l;
        UsbManager um = (UsbManager) context.getSystemService(Context.USB_SERVICE);
        UsbDevice dev = find(um);
        if (dev == null) {
            l.onTransportDown("USB device not attached");
            return;
        }
        if (um.hasPermission(dev)) {
            io.execute(() -> openDevice(um, dev));
            return;
        }
        permReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent i) {
                if (!ACTION_PERMISSION.equals(i.getAction()))
                    return;
                try {
                    context.unregisterReceiver(this);
                } catch (Exception ignored) {
                }
                permReceiver = null;
                if (i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
                    io.execute(() -> openDevice(um, dev));
                else
                    listener.onTransportDown("USB permission denied");
            }
        };
        IntentFilter f = new IntentFilter(ACTION_PERMISSION);
        if (Build.VERSION.SDK_INT >= 33)
            context.registerReceiver(permReceiver, f, 4 /* RECEIVER_NOT_EXPORTED */);
        else
            context.registerReceiver(permReceiver, f);
        int flags = Build.VERSION.SDK_INT >= 31 ? 0x02000000 /* FLAG_MUTABLE */ : 0;
        PendingIntent pi = PendingIntent.getBroadcast(context, 0,
                new Intent(ACTION_PERMISSION).setPackage(context.getPackageName()),
                flags);
        um.requestPermission(dev, pi);
    }

    private UsbDevice find(UsbManager um) {
        if (um == null)
            return null;
        for (UsbDevice d : um.getDeviceList().values())
            if (d.getDeviceName().equals(deviceName))
                return d;
        return null;
    }

    private void openDevice(UsbManager um, UsbDevice dev) {
        try {
            // Pick the bulk IN/OUT pair, preferring the CDC data interface.
            UsbInterface fallback = null, cdcData = null, comm = null;
            for (int i = 0; i < dev.getInterfaceCount(); i++) {
                UsbInterface it = dev.getInterface(i);
                boolean pair = bulk(it, UsbConstants.USB_DIR_IN) != null
                        && bulk(it, UsbConstants.USB_DIR_OUT) != null;
                if (it.getInterfaceClass() == UsbConstants.USB_CLASS_COMM
                        && comm == null)
                    comm = it;
                else if (pair && it.getInterfaceClass() == UsbConstants.USB_CLASS_CDC_DATA)
                    cdcData = it;
                else if (pair && fallback == null)
                    fallback = it;
            }
            dataIf = cdcData != null ? cdcData : fallback;
            if (dataIf == null) {
                listener.onTransportDown("No serial interface on this USB device");
                return;
            }
            ctrlIf = cdcData != null ? comm : null;
            in = bulk(dataIf, UsbConstants.USB_DIR_IN);
            out = bulk(dataIf, UsbConstants.USB_DIR_OUT);
            conn = um.openDevice(dev);
            if (conn == null || !conn.claimInterface(dataIf, true)) {
                listener.onTransportDown("Could not open the USB device");
                closeConn();
                return;
            }
            if (ctrlIf != null && ctrlIf.getId() != dataIf.getId())
                conn.claimInterface(ctrlIf, true);
            configure(dev);
            reading = true;
            reader = new Thread(this::readLoop, "MeshTakUsbRead");
            reader.setDaemon(true);
            reader.start();
            listener.onTransportUp();
        } catch (Exception e) {
            closeConn();
            listener.onTransportDown("USB error: " + e.getMessage());
        }
    }

    private static UsbEndpoint bulk(UsbInterface it, int dir) {
        for (int e = 0; e < it.getEndpointCount(); e++) {
            UsbEndpoint ep = it.getEndpoint(e);
            if (ep.getType() == UsbConstants.USB_ENDPOINT_XFER_BULK
                    && ep.getDirection() == dir)
                return ep;
        }
        return null;
    }

    private void configure(UsbDevice dev) {
        int vid = dev.getVendorId();
        if (ctrlIf != null) {
            configureCdc();
        } else if (vid == VID_SILABS) {
            configureCp210x();
        } else if (vid == VID_WCH) {
            configureCh34x();
        }
        // Anything else: a bulk pair with no known setup, used as is.
    }

    private void configureCdc() {
        byte[] coding = { (byte) BAUD, (byte) (BAUD >> 8), (byte) (BAUD >> 16),
                (byte) (BAUD >> 24), 0, 0, 8 };
        int type = UsbConstants.USB_DIR_OUT | UsbConstants.USB_TYPE_CLASS | 0x01;
        conn.controlTransfer(type, 0x20, 0, ctrlIf.getId(), coding,
                coding.length, 1000);
        // DTR on, RTS off: what the MeshCore app does on native-USB boards.
        conn.controlTransfer(type, 0x22, 0x0001, ctrlIf.getId(), null, 0, 1000);
    }

    private void configureCp210x() {
        int t = 0x41; // host to device, vendor, interface
        int idx = dataIf.getId();
        conn.controlTransfer(t, 0x00, 0x0001, idx, null, 0, 1000); // UART enable
        byte[] baud = { (byte) BAUD, (byte) (BAUD >> 8), (byte) (BAUD >> 16),
                (byte) (BAUD >> 24) };
        conn.controlTransfer(t, 0x1E, 0, idx, baud, 4, 1000);
        conn.controlTransfer(t, 0x03, 0x0800, idx, null, 0, 1000); // 8N1
        // Write both DTR and RTS low together: ESP32 runs, not reset/boot.
        conn.controlTransfer(t, 0x07, 0x0300, idx, null, 0, 1000);
    }

    private void configureCh34x() {
        int t = 0x40; // host to device, vendor, device
        conn.controlTransfer(t, 0xA1, 0, 0, null, 0, 1000);
        ch34xBaud(t);
        conn.controlTransfer(t, 0x9A, 0x2518, 0xC3, null, 0, 1000); // LCR 8N1, rx+tx
        conn.controlTransfer(t, 0xA1, 0x501F, 0xD90A, null, 0, 1000);
        ch34xBaud(t);
        // Modem control: neither DTR nor RTS asserted (bits are active low).
        conn.controlTransfer(t, 0xA4, ~0 & 0xFFFF, 0, null, 0, 1000);
    }

    private void ch34xBaud(int t) {
        long factor = 1532620800L / BAUD;
        long divisor = 3;
        while (factor > 0xFFF0 && divisor > 0) {
            factor >>= 3;
            divisor--;
        }
        factor = 0x10000 - factor;
        divisor |= 0x0080;
        conn.controlTransfer(t, 0x9A, 0x1312, (int) ((factor & 0xFF00) | divisor),
                null, 0, 1000);
        conn.controlTransfer(t, 0x9A, 0x0F2C, (int) (factor & 0xFF), null, 0,
                1000);
    }

    private void readLoop() {
        Decoder dec = new Decoder();
        byte[] buf = new byte[Math.max(64, in.getMaxPacketSize()) * 4];
        try {
            while (reading) {
                int n = conn.bulkTransfer(in, buf, buf.length, 250);
                if (!reading)
                    break;
                if (n <= 0)
                    continue;
                for (byte[] f : dec.ingest(buf, n))
                    listener.onFrame(f);
            }
        } catch (Exception e) {
            if (reading) {
                reading = false;
                listener.onTransportDown("USB read failed: " + e.getMessage());
            }
        }
    }

    @Override
    public void send(byte[] frame) {
        final byte[] wire = Companion.serialFrame(frame);
        io.execute(() -> {
            UsbDeviceConnection c = conn;
            if (c == null)
                return;
            int max = Math.max(64, out.getMaxPacketSize());
            for (int off = 0; off < wire.length; off += max) {
                int len = Math.min(max, wire.length - off);
                byte[] chunk = Arrays.copyOfRange(wire, off, off + len);
                if (c.bulkTransfer(out, chunk, len, 1000) != len) {
                    reading = false;
                    listener.onTransportDown("USB write failed");
                    closeConn();
                    return;
                }
            }
        });
    }

    @Override
    public void close() {
        reading = false;
        if (permReceiver != null) {
            try {
                context.unregisterReceiver(permReceiver);
            } catch (Exception ignored) {
            }
            permReceiver = null;
        }
        io.execute(this::closeConn);
        io.shutdown();
    }

    private void closeConn() {
        reading = false;
        if (reader != null && reader != Thread.currentThread()) {
            try {
                reader.join(400);
            } catch (InterruptedException ignored) {
            }
        }
        reader = null;
        if (conn != null) {
            try {
                if (dataIf != null)
                    conn.releaseInterface(dataIf);
                if (ctrlIf != null)
                    conn.releaseInterface(ctrlIf);
                conn.close();
            } catch (Exception ignored) {
            }
        }
        conn = null;
    }

    /** Splits the serial byte stream into frames from the radio. */
    public static final class Decoder {
        private final ByteArrayOutputStream buf = new ByteArrayOutputStream();

        public List<byte[]> ingest(byte[] data, int len) {
            buf.write(data, 0, len);
            byte[] b = buf.toByteArray();
            List<byte[]> frames = new ArrayList<>();
            int i = 0;
            while (true) {
                while (i < b.length && b[i] != Companion.SERIAL_FROM_RADIO)
                    i++; // resync on garbage (boot logs, noise)
                if (b.length - i < 3)
                    break;
                int n = (b[i + 1] & 0xFF) | ((b[i + 2] & 0xFF) << 8);
                if (n == 0 || n > Companion.MAX_FRAME) {
                    i++;
                    continue;
                }
                if (b.length - i - 3 < n)
                    break;
                frames.add(Arrays.copyOfRange(b, i + 3, i + 3 + n));
                i += 3 + n;
            }
            buf.reset();
            if (i < b.length)
                buf.write(b, i, b.length - i);
            return frames;
        }
    }
}
