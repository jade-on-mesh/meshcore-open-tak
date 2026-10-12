package com.jadeonmesh.meshcore.atak.media;

import java.io.ByteArrayOutputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import android.os.Bundle;

import com.jadeonmesh.meshcore.atak.core.TeamWire;
import com.jadeonmesh.meshcore.atak.core.VoiceWire;
import com.jadeonmesh.meshcore.atak.engine.LogBuffer;
import com.jadeonmesh.meshcore.atak.radio.AppRadio;
import com.jadeonmesh.meshcore.atak.radio.BridgeProtocol;

/**
 * App mode: the MeshCore Open TAK app encodes, announces, serves and fetches
 * clips with its own codecs (Mimi, Codec2, AV1); the plugin only moves PCM
 * and JPEG across the bridge.
 */
public final class AppMedia implements MediaBackend, AppRadio.MediaSink {

    private final AppRadio app;
    private final LogBuffer log;
    private volatile Listener listener;
    private final AtomicInteger xfers = new AtomicInteger(1);
    private final Map<String, Status> states = new ConcurrentHashMap<>();
    private final Map<Integer, SendDone> sends = new ConcurrentHashMap<>();
    private final Map<Integer, AttachDone> attaches = new ConcurrentHashMap<>();
    private final Map<Integer, Object> gets = new ConcurrentHashMap<>();
    private final Map<Integer, ByteArrayOutputStream> incoming = new HashMap<>();

    public AppMedia(AppRadio app, LogBuffer log) {
        this.app = app;
        this.log = log;
    }

    @Override
    public void setListener(Listener l) {
        listener = l;
    }

    @Override
    public void start() {
        app.setMediaSink(this);
    }

    @Override
    public void stop() {
        app.setMediaSink(null);
    }

    @Override
    public boolean canSendVoice() {
        return app.codecCodec2() || app.codecMimi();
    }

    @Override
    public boolean canSendImages() {
        return app.codecAv1();
    }

    @Override
    public boolean canPlay(VoiceWire.Mode mode) {
        if (mode.isImage())
            return app.codecAv1();
        if (mode.isMimi())
            return app.codecMimi();
        return app.codecCodec2();
    }

    // ------------------------------------------------------------- upload

    private int upload(byte[] data, String kind) {
        int xfer = xfers.getAndIncrement();
        int chunks = Math.max(1, (data.length + BridgeProtocol.CHUNK - 1)
                / BridgeProtocol.CHUNK);
        for (int i = 0; i < chunks; i++) {
            int off = i * BridgeProtocol.CHUNK;
            int len = Math.min(BridgeProtocol.CHUNK, data.length - off);
            byte[] part = new byte[Math.max(0, len)];
            if (len > 0)
                System.arraycopy(data, off, part, 0, len);
            Bundle b = new Bundle();
            b.putInt(BridgeProtocol.K_XFER, xfer);
            b.putInt(BridgeProtocol.K_INDEX, i);
            b.putBoolean(BridgeProtocol.K_LAST, i == chunks - 1);
            b.putByteArray(BridgeProtocol.K_BYTES, part);
            b.putString(BridgeProtocol.K_KIND, kind);
            if (!app.send(BridgeProtocol.MEDIA_CHUNK_IN, b))
                return -1;
        }
        return xfer;
    }

    static byte[] pcmBytes(short[] pcm) {
        byte[] out = new byte[pcm.length * 2];
        for (int i = 0; i < pcm.length; i++) {
            out[i * 2] = (byte) pcm[i];
            out[i * 2 + 1] = (byte) (pcm[i] >> 8);
        }
        return out;
    }

    static short[] pcmShorts(byte[] b) {
        short[] out = new short[b.length / 2];
        for (int i = 0; i < out.length; i++)
            out[i] = (short) ((b[i * 2] & 0xFF) | (b[i * 2 + 1] << 8));
        return out;
    }

    private void putTarget(Bundle b, Target t) {
        if (t.isChannel())
            b.putInt(BridgeProtocol.K_CHANNEL, t.channel);
        else
            b.putByteArray(BridgeProtocol.K_KEY, t.contactKey);
    }

    private void send(int what, int xfer, String kind, Target t, int detail,
            SendDone sendDone, AttachDone attachDone) {
        if (xfer < 0) {
            if (sendDone != null)
                sendDone.done(null, "MeshCore Open TAK not connected");
            if (attachDone != null)
                attachDone.done(null, "MeshCore Open TAK not connected");
            return;
        }
        Bundle b = new Bundle();
        b.putInt(BridgeProtocol.K_XFER, xfer);
        b.putString(BridgeProtocol.K_KIND, kind);
        b.putInt(BridgeProtocol.K_DETAIL_LEVEL, detail);
        if (t != null)
            putTarget(b, t);
        final int id = app.nextId();
        b.putInt(BridgeProtocol.K_ID, id);
        if (sendDone != null)
            sends.put(id, sendDone);
        if (attachDone != null)
            attaches.put(id, attachDone);
        app.request(what, b, (ok, msg) -> {
            if (ok)
                return; // MEDIA_REGISTERED carries the result
            SendDone s = sends.remove(id);
            AttachDone a = attaches.remove(id);
            if (s != null)
                s.done(null, msg);
            if (a != null)
                a.done(null, msg);
        });
    }

    @Override
    public void sendVoice(short[] pcm48k, Target t, SendDone done) {
        send(BridgeProtocol.MEDIA_SEND, upload(pcmBytes(pcm48k), "pcm16"),
                "pcm16", t, 0, done, null);
    }

    @Override
    public void sendImage(byte[] image, Target t, int detail, SendDone done) {
        send(BridgeProtocol.MEDIA_SEND, upload(image, "jpeg"), "jpeg", t, detail,
                done, null);
    }

    @Override
    public void registerImage(byte[] image, int detail, AttachDone done) {
        send(BridgeProtocol.MEDIA_REGISTER, upload(image, "jpeg"), "jpeg", null,
                detail, null, done);
    }

    @Override
    public void registerVoice(short[] pcm48k, AttachDone done) {
        send(BridgeProtocol.MEDIA_REGISTER, upload(pcmBytes(pcm48k), "pcm16"),
                "pcm16", null, 0, null, done);
    }

    // ------------------------------------------------------------ fetching

    @Override
    public void onEnvelope(VoiceWire.Envelope env, String senderKeyHex,
            int channel) {
        if (!states.containsKey(env.sessionId))
            states.put(env.sessionId, Status.IDLE);
    }

    @Override
    public void fetch(VoiceWire.Envelope env, String senderKeyHex, int channel) {
        Bundle b = new Bundle();
        b.putString(BridgeProtocol.K_ENVELOPE, env.encode());
        if (senderKeyHex != null)
            b.putString(BridgeProtocol.K_SENDER, senderKeyHex);
        b.putInt(BridgeProtocol.K_CHANNEL, channel);
        if (!app.send(BridgeProtocol.MEDIA_FETCH, b)) {
            Listener l = listener;
            if (l != null)
                l.onClipChanged(env.sessionId, Status.UNAVAILABLE, 0,
                        env.totalPackets, "MeshCore Open TAK not connected");
        }
    }

    @Override
    public Status status(String sid) {
        Status s = states.get(sid);
        return s == null ? Status.IDLE : s;
    }

    @Override
    public void audio(VoiceWire.Envelope env, AudioDone done) {
        get(env, "pcm16", done);
    }

    @Override
    public void image(VoiceWire.Envelope env, ImageDone done) {
        get(env, "jpeg", done);
    }

    private void get(VoiceWire.Envelope env, String kind, Object done) {
        int xfer = xfers.getAndIncrement();
        gets.put(xfer, done);
        Bundle b = new Bundle();
        b.putInt(BridgeProtocol.K_XFER, xfer);
        b.putString(BridgeProtocol.K_ENVELOPE, env.encode());
        b.putString(BridgeProtocol.K_KIND, kind);
        if (!app.send(BridgeProtocol.MEDIA_GET, b)) {
            gets.remove(xfer);
            finishGet(done, null, 0, "MeshCore Open TAK not connected");
        }
    }

    private static void finishGet(Object done, byte[] data, int rate,
            String msg) {
        if (done instanceof AudioDone)
            ((AudioDone) done).done(data == null ? null : pcmShorts(data), rate,
                    msg);
        else if (done instanceof ImageDone)
            ((ImageDone) done).done(data, msg);
    }

    @Override
    public void onMediaMessage(int what, Bundle b) {
        switch (what) {
            case BridgeProtocol.MEDIA_STATE: {
                String sid = b.getString(BridgeProtocol.K_SID, "");
                Status s;
                try {
                    s = Status.valueOf(b.getString(BridgeProtocol.K_STATUS,
                            "IDLE"));
                } catch (IllegalArgumentException e) {
                    s = Status.IDLE;
                }
                states.put(sid, s);
                Listener l = listener;
                if (l != null)
                    l.onClipChanged(sid, s, b.getInt(BridgeProtocol.K_HAVE),
                            b.getInt(BridgeProtocol.K_TOTAL),
                            b.getString(BridgeProtocol.K_MESSAGE));
                break;
            }
            case BridgeProtocol.MEDIA_CHUNK_OUT: {
                int xfer = b.getInt(BridgeProtocol.K_XFER);
                byte[] part = b.getByteArray(BridgeProtocol.K_BYTES);
                ByteArrayOutputStream acc;
                synchronized (incoming) {
                    acc = incoming.get(xfer);
                    if (acc == null) {
                        acc = new ByteArrayOutputStream();
                        incoming.put(xfer, acc);
                    }
                }
                if (part != null)
                    acc.write(part, 0, part.length);
                if (b.getBoolean(BridgeProtocol.K_LAST)) {
                    synchronized (incoming) {
                        incoming.remove(xfer);
                    }
                    Object done = gets.remove(xfer);
                    boolean ok = b.getBoolean(BridgeProtocol.K_OK, true);
                    finishGet(done, ok ? acc.toByteArray() : null,
                            b.getInt(BridgeProtocol.K_RATE, 8000),
                            b.getString(BridgeProtocol.K_MESSAGE));
                }
                break;
            }
            case BridgeProtocol.MEDIA_REGISTERED: {
                int id = b.getInt(BridgeProtocol.K_ID);
                VoiceWire.Envelope env = VoiceWire.Envelope
                        .parse(b.getString(BridgeProtocol.K_ENVELOPE, ""));
                SendDone s = sends.remove(id);
                AttachDone a = attaches.remove(id);
                if (env != null)
                    states.put(env.sessionId, Status.COMPLETE);
                if (s != null)
                    s.done(env, env == null ? "Bad envelope from the app" : null);
                if (a != null) {
                    if (env == null)
                        a.done(null, "Bad envelope from the app");
                    else
                        a.done(new TeamWire.Attachment(env.mode.wireId,
                                env.sessionId, env.totalPackets,
                                env.durationSeconds), null);
                }
                if (env != null)
                    log.add("App registered " + env.mode.label + " clip "
                            + env.sessionId);
                break;
            }
            default:
                break;
        }
    }

    @Override
    public void onRawData(byte[] payload) {
    }

    @Override
    public void onChannelData(int channel, byte[] payload) {
    }

    @Override
    public boolean onDirectControlText(String senderPrefixHex, String text) {
        // The app answers VR3 requests itself and doesn't forward them.
        return VoiceWire.TextRequest.looksLikeRequest(text);
    }
}
