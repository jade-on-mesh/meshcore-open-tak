package com.jadeonmesh.meshcore.atak.radio;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Message;
import android.os.Messenger;
import android.os.RemoteException;

import com.jadeonmesh.meshcore.atak.core.Bytes;
import com.jadeonmesh.meshcore.atak.core.Companion;

/**
 * Reaches the radio through the MeshCore Open TAK app's bridge service, the
 * way the Meshtastic plugin binds to the Meshtastic app. The app keeps its
 * BLE/USB connection and its own team, voice and photo handling; the plugin
 * sends and receives through it.
 */
public final class AppRadio implements MeshRadio {

    /** Media traffic is handed to the media layer. */
    public interface MediaSink {
        void onMediaMessage(int what, Bundle data);
    }

    private final Context context;
    private final String appPackage;
    private final HandlerThread thread = new HandlerThread("MeshTakApp");
    private Handler h;
    private Messenger service;
    private Messenger inbox;
    private volatile Listener listener;
    private volatile MediaSink mediaSink;
    private boolean bound;
    private boolean stopped;

    private volatile State state = State.OFF;
    private volatile String detail = "";
    private volatile Companion.SelfInfo self;
    private volatile List<Companion.Channel> channels = Collections.emptyList();
    private volatile List<Companion.Contact> contacts = Collections.emptyList();
    private volatile boolean channelDataOk;
    private volatile int teamChannel = -1;
    private volatile boolean appOwnsTeam = true;
    private volatile boolean codecMimi, codecAv1, codecCodec2;

    private final AtomicInteger ids = new AtomicInteger(1);
    private final Map<Integer, Done> pending = new ConcurrentHashMap<>();

    public AppRadio(Context context, String appPackage) {
        this.context = context;
        this.appPackage = appPackage == null || appPackage.isEmpty()
                ? BridgeProtocol.DEFAULT_PACKAGE
                : appPackage;
    }

    /** True if the app with the bridge service is installed. */
    public static boolean isAppInstalled(Context ctx, String pkg) {
        Intent i = new Intent(BridgeProtocol.ACTION).setPackage(
                pkg == null || pkg.isEmpty() ? BridgeProtocol.DEFAULT_PACKAGE : pkg);
        try {
            return !ctx.getPackageManager()
                    .queryIntentServices(i, PackageManager.MATCH_ALL).isEmpty();
        } catch (RuntimeException e) {
            return false;
        }
    }

    public void setMediaSink(MediaSink s) {
        this.mediaSink = s;
    }

    public boolean codecMimi() {
        return codecMimi;
    }

    public boolean codecAv1() {
        return codecAv1;
    }

    public boolean codecCodec2() {
        return codecCodec2;
    }

    @Override
    public String name() {
        return "MeshCore Open TAK app";
    }

    @Override
    public void setListener(Listener l) {
        this.listener = l;
    }

    @Override
    public void start() {
        thread.start();
        h = new Handler(thread.getLooper(), this::onMessage);
        inbox = new Messenger(h);
        bind();
    }

    private void bind() {
        if (stopped)
            return;
        setState(State.CONNECTING, "Binding to MeshCore Open TAK");
        Intent i = new Intent(BridgeProtocol.ACTION).setPackage(appPackage);
        try {
            bound = context.bindService(i, conn, Context.BIND_AUTO_CREATE);
        } catch (SecurityException e) {
            bound = false;
        }
        if (!bound) {
            setState(State.ERROR, "MeshCore Open TAK app not installed or bridge disabled");
            h.postDelayed(this::bind, 15_000);
        }
    }

    private final ServiceConnection conn = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            service = new Messenger(binder);
            Bundle b = new Bundle();
            b.putInt(BridgeProtocol.K_VERSION, BridgeProtocol.VERSION);
            send(BridgeProtocol.HELLO, b);
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            service = null;
            failPending("App bridge disconnected");
            setState(State.CONNECTING, "Waiting for MeshCore Open TAK");
        }

        @Override
        public void onBindingDied(ComponentName name) {
            service = null;
            try {
                context.unbindService(this);
            } catch (Exception ignored) {
            }
            bound = false;
            failPending("App bridge died");
            setState(State.ERROR, "MeshCore Open TAK stopped");
            if (h != null)
                h.postDelayed(AppRadio.this::bind, 5_000);
        }
    };

    @Override
    public void stop() {
        stopped = true;
        send(BridgeProtocol.BYE, new Bundle());
        if (bound) {
            try {
                context.unbindService(conn);
            } catch (Exception ignored) {
            }
            bound = false;
        }
        failPending("Stopped");
        setState(State.OFF, "");
        thread.quitSafely();
    }

    /** Sends a bridge message; false if the app isn't connected. */
    public boolean send(int what, Bundle data) {
        Messenger s = service;
        if (s == null)
            return false;
        Message m = Message.obtain(null, what);
        m.setData(data);
        m.replyTo = inbox;
        try {
            s.send(m);
            return true;
        } catch (RemoteException e) {
            return false;
        }
    }

    /** A fresh request id, for callers that must register before sending. */
    public int nextId() {
        return ids.getAndIncrement();
    }

    /** Sends with a result id; [done] gets the app's RESULT. */
    public void request(int what, Bundle data, Done done) {
        int id = data.containsKey(BridgeProtocol.K_ID)
                ? data.getInt(BridgeProtocol.K_ID)
                : ids.getAndIncrement();
        data.putInt(BridgeProtocol.K_ID, id);
        if (done != null)
            pending.put(id, done);
        if (!send(what, data)) {
            pending.remove(id);
            if (done != null)
                done.done(false, "MeshCore Open TAK not connected");
            return;
        }
        if (done != null && h != null)
            h.postDelayed(() -> {
                Done d = pending.remove(id);
                if (d != null)
                    d.done(false, "App did not answer");
            }, 60_000);
    }

    private void failPending(String why) {
        for (Integer id : new ArrayList<>(pending.keySet())) {
            Done d = pending.remove(id);
            if (d != null)
                d.done(false, why);
        }
    }

    private void setState(State s, String d) {
        state = s;
        detail = d == null ? "" : d;
        Listener l = listener;
        if (l != null)
            l.onStateChanged(s, detail);
    }

    // ----------------------------------------------------------- inbound

    private boolean onMessage(Message m) {
        Bundle b = m.getData();
        Listener l = listener;
        switch (m.what) {
            case BridgeProtocol.STATE:
                readState(b);
                return true;
            case BridgeProtocol.RESULT: {
                Done d = pending.remove(b.getInt(BridgeProtocol.K_ID));
                if (d != null)
                    d.done(b.getBoolean(BridgeProtocol.K_OK),
                            b.getString(BridgeProtocol.K_MESSAGE));
                return true;
            }
            case BridgeProtocol.CHANNEL_DATA:
                if (l != null)
                    l.onChannelData(b.getInt(BridgeProtocol.K_CHANNEL),
                            b.getInt(BridgeProtocol.K_TYPE),
                            b.getByteArray(BridgeProtocol.K_PAYLOAD),
                            b.getInt(BridgeProtocol.K_HOPS, -1));
                return true;
            case BridgeProtocol.CHANNEL_TEXT:
                if (l != null)
                    l.onChannelText(b.getInt(BridgeProtocol.K_CHANNEL),
                            b.getString(BridgeProtocol.K_SENDER, ""),
                            b.getString(BridgeProtocol.K_TEXT, ""),
                            b.getLong(BridgeProtocol.K_TS),
                            b.getInt(BridgeProtocol.K_HOPS, -1));
                return true;
            case BridgeProtocol.DIRECT_TEXT:
                if (l != null)
                    l.onDirectText(b.getString(BridgeProtocol.K_SENDER, ""),
                            b.getString(BridgeProtocol.K_TEXT, ""),
                            b.getLong(BridgeProtocol.K_TS));
                return true;
            case BridgeProtocol.TEAM_PAYLOAD:
                if (l != null)
                    l.onTeamPayload(b.getByteArray(BridgeProtocol.K_PAYLOAD),
                            b.getBoolean(BridgeProtocol.K_OWN));
                return true;
            case BridgeProtocol.MEDIA_STATE:
            case BridgeProtocol.MEDIA_CHUNK_OUT:
            case BridgeProtocol.MEDIA_REGISTERED: {
                if (m.what == BridgeProtocol.MEDIA_REGISTERED) {
                    Done d = pending.remove(b.getInt(BridgeProtocol.K_ID));
                    if (d != null)
                        d.done(true, null);
                }
                MediaSink s = mediaSink;
                if (s != null)
                    s.onMediaMessage(m.what, b);
                return true;
            }
            default:
                return false;
        }
    }

    private void readState(Bundle b) {
        boolean connected = b.getBoolean(BridgeProtocol.K_CONNECTED);
        byte[] key = b.getByteArray(BridgeProtocol.K_SELF_KEY);
        if (key != null && key.length == Companion.PUB_KEY_SIZE) {
            Companion.SelfInfo s = new Companion.SelfInfo();
            s.publicKey = key;
            s.name = b.getString(BridgeProtocol.K_SELF_NAME, "");
            s.sf = b.getInt(BridgeProtocol.K_SF);
            s.bwHz = b.getLong(BridgeProtocol.K_BW);
            s.cr = b.getInt(BridgeProtocol.K_CR);
            self = s;
        } else {
            self = null;
        }
        channelDataOk = b.getBoolean(BridgeProtocol.K_CHANNEL_DATA_OK);
        teamChannel = b.getInt(BridgeProtocol.K_TEAM_CHANNEL, -1);
        appOwnsTeam = b.getBoolean(BridgeProtocol.K_APP_OWNS_TEAM, true);
        codecMimi = b.getBoolean(BridgeProtocol.K_CODEC_MIMI);
        codecAv1 = b.getBoolean(BridgeProtocol.K_CODEC_AV1);
        codecCodec2 = b.getBoolean(BridgeProtocol.K_CODEC_CODEC2);

        int[] idx = b.getIntArray(BridgeProtocol.K_CH_INDEX);
        String[] names = b.getStringArray(BridgeProtocol.K_CH_NAME);
        boolean[] priv = b.getBooleanArray(BridgeProtocol.K_CH_PRIVATE);
        List<Companion.Channel> chs = new ArrayList<>();
        if (idx != null && names != null && priv != null) {
            for (int i = 0; i < idx.length && i < names.length; i++) {
                Companion.Channel c = new Companion.Channel();
                c.index = idx[i];
                c.name = names[i];
                // Only privacy matters to the plugin; fake a non-public PSK.
                c.psk = priv[i] ? new byte[16] : Bytes.unhex(Companion.PUBLIC_CHANNEL_PSK);
                if (priv[i])
                    c.psk[0] = 1;
                chs.add(c);
            }
        }
        channels = chs;

        byte[] keys = b.getByteArray(BridgeProtocol.K_CONTACT_KEYS);
        String[] cn = b.getStringArray(BridgeProtocol.K_CONTACT_NAMES);
        int[] cp = b.getIntArray(BridgeProtocol.K_CONTACT_PATH);
        int[] ct = b.getIntArray(BridgeProtocol.K_CONTACT_TYPE);
        int[] clat = b.getIntArray(BridgeProtocol.K_CONTACT_LAT);
        int[] clon = b.getIntArray(BridgeProtocol.K_CONTACT_LON);
        long[] cadv = b.getLongArray(BridgeProtocol.K_CONTACT_ADVERT);
        List<Companion.Contact> cs = new ArrayList<>();
        if (keys != null && cn != null) {
            int n = Math.min(keys.length / 32, cn.length);
            for (int i = 0; i < n; i++) {
                Companion.Contact c = new Companion.Contact();
                c.publicKey = java.util.Arrays.copyOfRange(keys, i * 32, i * 32 + 32);
                c.name = cn[i];
                c.pathLength = cp != null && i < cp.length ? cp[i] : -1;
                c.type = ct != null && i < ct.length ? ct[i] : Companion.ADV_CHAT;
                // Older app builds don't send these; nodes then stay off the map.
                if (clat != null && clon != null && i < clat.length && i < clon.length
                        && (clat[i] != 0 || clon[i] != 0)) {
                    c.lat = clat[i] / 1e6;
                    c.lon = clon[i] / 1e6;
                }
                if (cadv != null && i < cadv.length)
                    c.lastAdvert = cadv[i];
                cs.add(c);
            }
        }
        contacts = cs;

        if (connected && self != null)
            setState(State.CONNECTED, self.name);
        else
            setState(State.CONNECTING, b.getString(BridgeProtocol.K_DETAIL,
                    "App is not connected to a radio"));
        Listener l = listener;
        if (l != null)
            l.onRadioInfoChanged();
    }

    // ---------------------------------------------------------- MeshRadio

    @Override
    public State state() {
        return state;
    }

    @Override
    public String stateDetail() {
        return detail;
    }

    @Override
    public boolean isConnected() {
        return state == State.CONNECTED;
    }

    @Override
    public Companion.SelfInfo self() {
        return self;
    }

    @Override
    public List<Companion.Channel> channels() {
        return channels;
    }

    @Override
    public List<Companion.Contact> contacts() {
        return contacts;
    }

    @Override
    public boolean supportsChannelData() {
        return channelDataOk;
    }

    @Override
    public int teamChannel() {
        return teamChannel;
    }

    @Override
    public boolean appOwnsTeam() {
        return appOwnsTeam;
    }

    @Override
    public void sendChannelData(int channel, int dataType, List<byte[]> blobs,
            long gapMs, Done done) {
        Bundle b = new Bundle();
        b.putInt(BridgeProtocol.K_CHANNEL, channel);
        b.putInt(BridgeProtocol.K_TYPE, dataType);
        b.putByteArray(BridgeProtocol.K_BLOBS, BridgeProtocol.packBlobs(blobs));
        b.putLong(BridgeProtocol.K_GAP, gapMs);
        request(BridgeProtocol.SEND_CHANNEL_DATA, b, done);
    }

    @Override
    public void sendChannelText(int channel, String text, Done done) {
        Bundle b = new Bundle();
        b.putInt(BridgeProtocol.K_CHANNEL, channel);
        b.putString(BridgeProtocol.K_TEXT, text);
        request(BridgeProtocol.SEND_CHANNEL_TEXT, b, done);
    }

    @Override
    public void sendDirectText(byte[] pubKey, String text, Done done) {
        Bundle b = new Bundle();
        b.putByteArray(BridgeProtocol.K_KEY, pubKey);
        b.putString(BridgeProtocol.K_TEXT, text);
        request(BridgeProtocol.SEND_DIRECT_TEXT, b, done);
    }

    @Override
    public void sendRawData(byte[] path, byte[] payload, Done done) {
        if (done != null)
            done.done(false, "Raw data goes through the app's own voice service");
    }

    @Override
    public void resetPath(byte[] pubKey, Done done) {
        if (done != null)
            done.done(true, null);
    }

    @Override
    public void sendTeam(List<byte[]> blobs, long gapMs, Done done) {
        Bundle b = new Bundle();
        b.putByteArray(BridgeProtocol.K_BLOBS, BridgeProtocol.packBlobs(blobs));
        b.putLong(BridgeProtocol.K_GAP, gapMs);
        request(BridgeProtocol.SEND_TEAM, b, done);
    }

    @Override
    public void publishSelf(byte[] positionPayload) {
        Bundle b = new Bundle();
        b.putByteArray(BridgeProtocol.K_PAYLOAD, positionPayload);
        send(BridgeProtocol.PUBLISH_SELF, b);
    }

    @Override
    public void refreshContacts() {
        send(BridgeProtocol.REFRESH_CONTACTS, new Bundle());
    }
}
