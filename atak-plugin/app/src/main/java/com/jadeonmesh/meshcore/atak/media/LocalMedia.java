package com.jadeonmesh.meshcore.atak.media;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import android.content.Context;
import android.os.Handler;
import android.os.HandlerThread;

import com.jadeonmesh.meshcore.atak.core.Bytes;
import com.jadeonmesh.meshcore.atak.core.Companion;
import com.jadeonmesh.meshcore.atak.core.TeamWire;
import com.jadeonmesh.meshcore.atak.core.VoiceWire;
import com.jadeonmesh.meshcore.atak.engine.LogBuffer;
import com.jadeonmesh.meshcore.atak.engine.Settings;
import com.jadeonmesh.meshcore.atak.radio.DirectRadio;

/**
 * Direct mode: VE3/VM1/VI1 clips handled in the plugin, a Java port of the
 * fetch/serve logic in lib/vox/voice_service.dart so the plugin and the app
 * can fetch each other's clips.
 *
 * Audio and photos are never pushed unasked. The sender announces a clip
 * with an envelope; a listener pulls the packets: by raw data along a known
 * direct route, by a flooded VR3 DM that makes both radios learn a route,
 * or by a request flooded on the channel the clip was posted in.
 */
public final class LocalMedia implements MediaBackend {

    private static final int MAX_ATTEMPTS = 8;
    private static final int MAX_STALLS = 3;
    public static final int MAX_CLIP_SECONDS = 20;

    private enum Method {
        DIRECT, DM_REQUEST, CHANNEL
    }

    private static final class Incoming {
        VoiceWire.Envelope env;
        String senderHex; // prefix, 8 or 12 hex chars, may be null
        int channel = -1;
        final TreeMap<Integer, byte[]> packets = new TreeMap<>();
        Status status = Status.IDLE;
        String message;
        int attempts, stalls, directFailures;
        boolean sentDmRequest;
        Method lastMethod;
        int expectedLast = -1;
        int packetsAtLastAttempt;
        Runnable watchdog;

        boolean complete() {
            return packets.size() >= env.totalPackets;
        }

        List<Integer> missing() {
            List<Integer> m = new ArrayList<>();
            for (int i = 0; i < env.totalPackets; i++)
                if (!packets.containsKey(i))
                    m.add(i);
            return m;
        }

        byte[] joined() {
            int n = 0;
            for (byte[] b : packets.values())
                n += b.length;
            byte[] out = new byte[n];
            int o = 0;
            for (byte[] b : packets.values()) {
                System.arraycopy(b, 0, out, o, b.length);
                o += b.length;
            }
            return out;
        }
    }

    private final DirectRadio radio;
    private final LogBuffer log;
    private final Settings settings;
    private final File clipDir;
    private final MimiCodec mimi;
    private final HandlerThread thread = new HandlerThread("MeshTakMedia");
    private Handler h;
    private final ExecutorService codecs = Executors.newSingleThreadExecutor();
    private final SecureRandom rng = new SecureRandom();
    private volatile Listener listener;

    private final Map<String, byte[]> bits = Collections
            .synchronizedMap(new HashMap<String, byte[]>());
    private final Map<String, VoiceWire.Mode> modes = Collections
            .synchronizedMap(new HashMap<String, VoiceWire.Mode>());
    private final Set<String> own = Collections
            .synchronizedSet(new HashSet<String>());
    private final Map<String, Incoming> incoming = new HashMap<>();
    private final Map<String, Map<Integer, byte[]>> orphans = new LinkedHashMap<>();
    private final Map<String, Long> lastChannelPacket = new HashMap<>();
    private final Map<String, Long> recentServes = new HashMap<>();
    private final Map<String, Integer> serveGen = new HashMap<>();
    private final ArrayList<Runnable> serveQueue = new ArrayList<>();
    private boolean serving;

    public LocalMedia(Context ctx, DirectRadio radio, LogBuffer log,
            Settings settings) {
        this.radio = radio;
        this.log = log;
        this.settings = settings;
        File base = new File(ctx.getFilesDir(), "meshcore_tak");
        this.clipDir = new File(base, "clips");
        clipDir.mkdirs();
        this.mimi = new MimiCodec(new File(base, "mimi"));
    }

    public MimiCodec mimi() {
        return mimi;
    }

    @Override
    public void setListener(Listener l) {
        listener = l;
    }

    @Override
    public void start() {
        thread.start();
        h = new Handler(thread.getLooper());
        NativeCodecs.load();
        h.postDelayed(this::idle, 60_000);
    }

    private void idle() {
        mimi.closeIfIdle();
        h.postDelayed(this::idle, 60_000);
    }

    @Override
    public void stop() {
        if (h != null)
            h.post(() -> {
                for (Incoming c : incoming.values())
                    if (c.watchdog != null)
                        h.removeCallbacks(c.watchdog);
                thread.quitSafely();
            });
        codecs.shutdown();
        mimi.close();
    }

    private void event(String sid, String s) {
        log.add("Voice " + (sid == null || sid.isEmpty() ? "" : sid + " ") + s);
    }

    // -------------------------------------------------------------- codecs

    @Override
    public boolean canSendVoice() {
        return NativeCodecs.load() || mimi.isReady();
    }

    @Override
    public boolean canSendImages() {
        return NativeCodecs.hasAv1();
    }

    @Override
    public boolean canPlay(VoiceWire.Mode mode) {
        if (mode.isImage())
            return NativeCodecs.hasAv1();
        if (mode.isMimi())
            return mimi.isReady();
        return NativeCodecs.load();
    }

    private static final class Clip {
        VoiceWire.Mode mode;
        byte[] bits;
        int extra;
    }

    private Clip encodeVoice(short[] pcm48k) throws Exception {
        int max = MAX_CLIP_SECONDS * AudioIO.RATE;
        short[] in = pcm48k.length > max ? java.util.Arrays.copyOf(pcm48k, max)
                : pcm48k;
        Clip c = new Clip();
        c.extra = Math.max(1, (int) Math.ceil(in.length / (double) AudioIO.RATE));
        if (settings.preferMimi() && mimi.isReady()) {
            c.mode = VoiceWire.Mode.MIMI;
            c.bits = mimi.encode(AudioIO.decimate(in, 2));
        } else {
            if (!NativeCodecs.load())
                throw new IllegalStateException("Codec2 unavailable: "
                        + NativeCodecs.error());
            c.mode = VoiceWire.DEFAULT_CODEC2;
            c.bits = NativeCodecs.c2Encode(c.mode.codec2Id,
                    AudioIO.toPcm16(AudioIO.decimate(in, 6)));
        }
        if (c.bits == null || c.bits.length == 0)
            throw new IllegalStateException("Recording is empty");
        return c;
    }

    private Clip encodePhoto(byte[] image, int detail) {
        ImageCodec.Encoded e = ImageCodec.encodeImage(image, detail);
        Clip c = new Clip();
        c.mode = VoiceWire.Mode.AV1_IMAGE;
        c.bits = e.payload;
        c.extra = e.aspectCode;
        return c;
    }

    private VoiceWire.Envelope register(Clip c) {
        String sid = VoiceWire.newSessionId();
        int packets = VoiceWire.packetize(sid, c.bits, c.mode).size();
        if (packets == 0)
            throw new IllegalStateException("Empty clip");
        remember(sid, c.mode, c.bits, true);
        return new VoiceWire.Envelope(sid, c.mode, packets, c.extra);
    }

    private void remember(String sid, VoiceWire.Mode mode, byte[] b,
            boolean mine) {
        bits.put(sid, b);
        modes.put(sid, mode);
        if (mine)
            own.add(sid);
        try (FileOutputStream o = new FileOutputStream(new File(clipDir, sid))) {
            o.write(mode.wireId);
            o.write(mine ? 1 : 0);
            o.write(b);
        } catch (Exception ignored) {
        }
        trimStore();
    }

    private boolean loadFromStore(String sid) {
        if (bits.containsKey(sid))
            return true;
        File f = new File(clipDir, sid);
        if (!VoiceWire.isSessionId(sid) || !f.exists())
            return false;
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] all = new byte[(int) f.length()];
            int off = 0;
            while (off < all.length) {
                int n = in.read(all, off, all.length - off);
                if (n < 0)
                    break;
                off += n;
            }
            VoiceWire.Mode m = VoiceWire.Mode.fromWireId(all[0] & 0xFF);
            if (m == null)
                return false;
            modes.put(sid, m);
            if (all[1] == 1)
                own.add(sid);
            bits.put(sid, java.util.Arrays.copyOfRange(all, 2, all.length));
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private void trimStore() {
        File[] fs = clipDir.listFiles();
        if (fs == null || fs.length <= 200)
            return;
        java.util.Arrays.sort(fs, (a, b) -> Long.compare(a.lastModified(),
                b.lastModified()));
        for (int i = 0; i < fs.length - 200; i++)
            fs[i].delete();
    }

    // ------------------------------------------------------------ sending

    private void announce(VoiceWire.Envelope env, Target t, SendDone done) {
        Companion.Contact c = t.isChannel() ? null : contactByKeyHex(Bytes.hex(t.contactKey));
        com.jadeonmesh.meshcore.atak.radio.MeshRadio.Done sent = (ok, msg) -> {
            if (done != null)
                done.done(ok ? env : null, msg);
        };
        if (t.isChannel()) {
            event(env.sessionId, "announced " + env.totalPackets + "-packet "
                    + env.mode.label + " on channel " + t.channel);
            radio.sendChannelText(t.channel, env.encode(), sent);
        } else {
            event(env.sessionId, "sent " + env.mode.label + " to "
                    + (c == null ? "contact" : c.name));
            radio.sendDirectText(t.contactKey, env.encode(), sent);
        }
    }

    @Override
    public void sendVoice(short[] pcm48k, Target t, SendDone done) {
        codecs.execute(() -> {
            try {
                VoiceWire.Envelope env = register(encodeVoice(pcm48k));
                announce(env, t, done);
            } catch (Exception e) {
                done.done(null, e.getMessage());
            }
        });
    }

    @Override
    public void sendImage(byte[] image, Target t, int detail, SendDone done) {
        codecs.execute(() -> {
            try {
                VoiceWire.Envelope env = register(encodePhoto(image, detail));
                announce(env, t, done);
            } catch (Exception e) {
                done.done(null, e.getMessage());
            }
        });
    }

    @Override
    public void registerImage(byte[] image, int detail, AttachDone done) {
        codecs.execute(() -> {
            try {
                VoiceWire.Envelope env = register(encodePhoto(image, detail));
                event(env.sessionId, "registered photo attachment ("
                        + env.totalPackets + " packets)");
                done.done(new TeamWire.Attachment(env.mode.wireId, env.sessionId,
                        env.totalPackets, env.durationSeconds), null);
            } catch (Exception e) {
                done.done(null, e.getMessage());
            }
        });
    }

    @Override
    public void registerVoice(short[] pcm48k, AttachDone done) {
        codecs.execute(() -> {
            try {
                VoiceWire.Envelope env = register(encodeVoice(pcm48k));
                done.done(new TeamWire.Attachment(env.mode.wireId, env.sessionId,
                        env.totalPackets, env.durationSeconds), null);
            } catch (Exception e) {
                done.done(null, e.getMessage());
            }
        });
    }

    // ------------------------------------------------------------ decoding

    @Override
    public void audio(VoiceWire.Envelope env, AudioDone done) {
        codecs.execute(() -> {
            if (!loadFromStore(env.sessionId)) {
                done.done(null, 0, "Not downloaded yet");
                return;
            }
            byte[] b = bits.get(env.sessionId);
            VoiceWire.Mode m = modes.get(env.sessionId);
            try {
                if (m.isMimi()) {
                    if (!mimi.isReady()) {
                        done.done(null, 0, "Download the Mimi voice model to play this clip");
                        return;
                    }
                    done.done(AudioIO.toPcm16(mimi.decode(b)),
                            VoiceWire.MIMI_SAMPLE_RATE, null);
                } else if (m.isCodec2()) {
                    if (!NativeCodecs.load()) {
                        done.done(null, 0, "Codec2 unavailable");
                        return;
                    }
                    done.done(NativeCodecs.c2Decode(m.codec2Id, b),
                            VoiceWire.CODEC2_SAMPLE_RATE, null);
                } else {
                    done.done(null, 0, "Not audio");
                }
            } catch (Exception e) {
                done.done(null, 0, "Decode failed: " + e.getMessage());
            }
        });
    }

    @Override
    public void image(VoiceWire.Envelope env, ImageDone done) {
        codecs.execute(() -> {
            if (!loadFromStore(env.sessionId)) {
                done.done(null, "Not downloaded yet");
                return;
            }
            byte[] jpeg = ImageCodec.payloadToJpeg(bits.get(env.sessionId));
            done.done(jpeg, jpeg == null ? "This plugin build can't decode AV1 photos" : null);
        });
    }

    // ------------------------------------------------------------ fetching

    @Override
    public Status status(String sid) {
        if (bits.containsKey(sid) || new File(clipDir, sid).exists())
            return Status.COMPLETE;
        synchronized (incoming) {
            Incoming c = incoming.get(sid);
            return c == null ? Status.IDLE : c.status;
        }
    }

    @Override
    public void onEnvelope(VoiceWire.Envelope env, String senderKeyHex,
            int channel) {
        h.post(() -> warmUp(env, senderKeyHex, channel));
    }

    /** Registers a clip so packets heard for it are kept. True if complete. */
    private boolean warmUp(VoiceWire.Envelope env, String sender, int channel) {
        String sid = env.sessionId;
        if (loadFromStore(sid)) {
            notify(sid, Status.COMPLETE, env.totalPackets, env.totalPackets, null);
            return true;
        }
        Incoming c;
        synchronized (incoming) {
            c = incoming.get(sid);
            if (c == null) {
                c = new Incoming();
                c.env = env;
                incoming.put(sid, c);
            }
        }
        if (sender != null)
            c.senderHex = sender;
        if (channel >= 0)
            c.channel = channel;
        Map<Integer, byte[]> o = orphans.remove(sid);
        if (o != null)
            for (Map.Entry<Integer, byte[]> e : o.entrySet())
                accept(c, e.getKey(), e.getValue(), false);
        return c.complete();
    }

    @Override
    public void fetch(VoiceWire.Envelope env, String senderKeyHex, int channel) {
        h.post(() -> {
            if (warmUp(env, senderKeyHex, channel))
                return;
            Incoming c = incoming.get(env.sessionId);
            if (c.status == Status.REQUESTING || c.status == Status.RECEIVING)
                return;
            c.attempts = 0;
            c.stalls = 0;
            c.directFailures = 0;
            c.sentDmRequest = false;
            attempt(c);
        });
    }

    private Method choose(Incoming c) {
        Companion.Contact s = sender(c);
        byte[] route = s == null ? null : s.directRoute();
        boolean canChannel = c.channel >= 0 && radio.supportsChannelData();
        if (s != null) {
            if (route != null && c.directFailures == 0)
                return Method.DIRECT;
            if (!c.sentDmRequest)
                return Method.DM_REQUEST;
            if (route != null && c.directFailures < 3)
                return Method.DIRECT;
        }
        if (canChannel)
            return Method.CHANNEL;
        if (s != null && route != null)
            return Method.DIRECT;
        if (s != null)
            return Method.DM_REQUEST;
        return null;
    }

    private void attempt(Incoming c) {
        Companion.SelfInfo self = radio.self();
        String sid = c.env.sessionId;
        if (self == null || !radio.isConnected()) {
            fail(c, "Not connected to a radio");
            return;
        }
        Method m = choose(c);
        if (m == null) {
            fail(c, c.senderHex == null
                    ? "Sender unknown and the radio can't use channel data"
                    : "No route to the sender");
            return;
        }
        c.attempts++;
        c.lastMethod = m;
        c.packetsAtLastAttempt = c.packets.size();
        List<Integer> missing = c.missing();
        c.expectedLast = missing.isEmpty() ? c.env.totalPackets - 1
                : missing.get(missing.size() - 1);
        VoiceWire.FetchRequest req = new VoiceWire.FetchRequest(sid,
                VoiceWire.key6Hex(self.publicKey),
                c.packets.isEmpty() ? null : missing, true);
        c.status = Status.REQUESTING;
        Companion.Contact s = sender(c);
        c.message = m == Method.DIRECT ? "Requesting from " + s.name + "…"
                : m == Method.DM_REQUEST ? "Finding a route to " + s.name + "…"
                        : "Requesting on the channel…";
        notify(c);
        com.jadeonmesh.meshcore.atak.radio.MeshRadio.Done done = (ok, msg) -> h.post(() -> {
            if (ok) {
                arm(c);
                return;
            }
            event(sid, "attempt " + c.attempts + " send failed: " + msg);
            if (m != Method.CHANNEL)
                c.directFailures++;
            if (c.attempts < MAX_ATTEMPTS)
                attempt(c);
            else
                fail(c, "Could not send request: " + msg);
        });
        switch (m) {
            case DIRECT:
                event(sid, "attempt " + c.attempts + ": raw request to " + s.name);
                radio.sendRawData(s.directRoute(), req.encode(rng.nextInt(256)), done);
                break;
            case DM_REQUEST:
                c.sentDmRequest = true;
                event(sid, "attempt " + c.attempts + ": VR3 DM (flood) to " + s.name);
                // Flood even if a (possibly one-way) route exists, so the
                // sender's radio learns a route back.
                radio.resetPath(s.publicKey, (ok, msg) -> radio.sendDirectText(
                        s.publicKey, VoiceWire.TextRequest.encode(req), done));
                break;
            default:
                event(sid, "attempt " + c.attempts + ": request on channel "
                        + c.channel);
                radio.sendChannelData(c.channel, VoiceWire.CHANNEL_DATA_TYPE,
                        Collections.singletonList(req.encode(rng.nextInt(256))), 0, done);
        }
    }

    private int hops(Incoming c) {
        Companion.Contact s = sender(c);
        return Math.max(s == null ? 3 : s.pathLength, 0);
    }

    private long waitFor(Incoming c) {
        long hopsN = hops(c) + 1;
        long hopMs = packetAirMs() * 2 + 700;
        int trips = c.lastMethod == Method.DM_REQUEST ? 5
                : c.lastMethod == Method.CHANNEL ? 3 : 2;
        long wait = trips * hopsN * hopMs + 8000;
        return c.status == Status.RECEIVING
                ? packetGap(c.lastMethod == Method.CHANNEL, hops(c)) * 3 + wait
                : wait;
    }

    private void arm(Incoming c) {
        if (c.watchdog != null)
            h.removeCallbacks(c.watchdog);
        c.watchdog = () -> onWatchdog(c);
        h.postDelayed(c.watchdog, waitFor(c));
    }

    private void onWatchdog(Incoming c) {
        if (c.complete())
            return;
        boolean progressed = c.packets.size() > c.packetsAtLastAttempt;
        event(c.env.sessionId, "timeout after " + c.lastMethod + ": "
                + c.packets.size() + "/" + c.env.totalPackets);
        if (progressed) {
            c.stalls = 0;
        } else {
            c.stalls++;
            if (c.lastMethod != Method.CHANNEL)
                c.directFailures++;
        }
        if (c.stalls < MAX_STALLS && c.attempts < MAX_ATTEMPTS) {
            attempt(c);
            return;
        }
        fail(c, c.packets.isEmpty() ? "Unavailable right now. Tap to retry."
                : "Got " + c.packets.size() + "/" + c.env.totalPackets
                        + ". Tap to retry.");
    }

    private void fail(Incoming c, String why) {
        if (c.watchdog != null)
            h.removeCallbacks(c.watchdog);
        c.status = Status.UNAVAILABLE;
        c.message = why;
        notify(c);
    }

    private void notify(Incoming c) {
        notify(c.env.sessionId, c.status, c.packets.size(), c.env.totalPackets,
                c.message);
    }

    private void notify(String sid, Status s, int have, int total, String msg) {
        Listener l = listener;
        if (l != null)
            l.onClipChanged(sid, s, have, total, msg);
    }

    // ------------------------------------------------------------- inbound

    @Override
    public void onRawData(byte[] payload) {
        h.post(() -> onPayload(payload, -1));
    }

    @Override
    public void onChannelData(int channel, byte[] payload) {
        h.post(() -> onPayload(payload, channel));
    }

    private void onPayload(byte[] p, int channel) {
        if (p.length == 0)
            return;
        int magic = p[0] & 0xFF;
        if (magic == VoiceWire.PACKET_MAGIC || magic == VoiceWire.PACKET_SALTED_MAGIC) {
            VoiceWire.Packet pkt = VoiceWire.Packet.parse(p);
            if (pkt == null)
                return;
            if (channel >= 0)
                lastChannelPacket.put(pkt.sessionId, System.currentTimeMillis());
            onPacket(pkt);
        } else if (magic == VoiceWire.FETCH_MAGIC) {
            VoiceWire.FetchRequest req = VoiceWire.FetchRequest.parse(p);
            Companion.SelfInfo self = radio.self();
            if (req == null || (self != null
                    && req.requesterKey6.equals(VoiceWire.key6Hex(self.publicKey))))
                return;
            if (channel >= 0)
                onChannelRequest(req, channel);
            else
                queueServe(req, -1, false);
        }
    }

    @Override
    public boolean onDirectControlText(String senderPrefixHex, String text) {
        if (!VoiceWire.TextRequest.looksLikeRequest(text))
            return false;
        VoiceWire.FetchRequest req = VoiceWire.TextRequest.parse(text);
        if (req != null)
            h.post(() -> {
                event(req.sessionId, "VR3 DM request from " + req.requesterKey6);
                queueServe(req, -1, true);
            });
        return true;
    }

    private void onPacket(VoiceWire.Packet pkt) {
        String sid = pkt.sessionId;
        if (bits.containsKey(sid))
            return;
        Incoming c = incoming.get(sid);
        if (c == null) {
            Map<Integer, byte[]> o = orphans.get(sid);
            if (o == null) {
                o = new HashMap<>();
                orphans.put(sid, o);
            }
            o.put(pkt.index, pkt.codecData);
            if (orphans.size() > 32) {
                Iterator<String> it = orphans.keySet().iterator();
                it.next();
                it.remove();
            }
            return;
        }
        accept(c, pkt.index, pkt.codecData, true);
    }

    private void accept(Incoming c, int index, byte[] data, boolean notify) {
        if (c.complete() || index >= c.env.totalPackets)
            return;
        c.packets.put(index, data);
        String sid = c.env.sessionId;
        if (c.complete()) {
            if (c.watchdog != null)
                h.removeCallbacks(c.watchdog);
            c.status = Status.COMPLETE;
            remember(sid, c.env.mode, c.joined(), false);
            event(sid, "complete (" + c.env.totalPackets + " packets)");
        } else if (c.status == Status.REQUESTING || c.status == Status.RECEIVING) {
            c.status = Status.RECEIVING;
            c.message = null;
            if (index == c.expectedLast) {
                // The sender has finished: re-ask for the gaps right away.
                if (c.watchdog != null)
                    h.removeCallbacks(c.watchdog);
                c.watchdog = () -> onWatchdog(c);
                h.postDelayed(c.watchdog,
                        packetGap(c.lastMethod == Method.CHANNEL, hops(c)) + 1500);
            } else {
                arm(c);
            }
        }
        if (notify)
            notify(c);
    }

    // ------------------------------------------------------------- serving

    private void onChannelRequest(VoiceWire.FetchRequest req, int channel) {
        if (!loadFromStore(req.sessionId))
            return;
        boolean mine = own.contains(req.sessionId);
        // The original sender answers at once; anyone else holding the clip
        // steps in only if nobody has started sending it a little later.
        long delay = mine ? 300 : 5000 + rng.nextInt(3000);
        long asked = System.currentTimeMillis();
        h.postDelayed(() -> {
            Long heard = lastChannelPacket.get(req.sessionId);
            if (!mine && heard != null && heard > asked)
                return;
            queueServe(req, channel, false);
        }, delay);
    }

    private void queueServe(VoiceWire.FetchRequest req, int viaChannel,
            boolean waitForRoute) {
        String key = req.sessionId + "/"
                + (viaChannel < 0 ? req.requesterKey6 : "ch" + viaChannel);
        String sig = key + "|" + (req.missing == null ? "all" : req.missing.toString());
        long now = System.currentTimeMillis();
        Long last = recentServes.get(sig);
        if (last != null && now - last < 6000)
            return;
        recentServes.put(sig, now);
        for (Iterator<Map.Entry<String, Long>> it = recentServes.entrySet()
                .iterator(); it.hasNext();)
            if (now - it.next().getValue() > 600_000)
                it.remove();
        Integer g = serveGen.get(key);
        int gen = (g == null ? 0 : g) + 1;
        serveGen.put(key, gen);
        serveQueue.add(() -> serve(req, viaChannel, waitForRoute, key, gen));
        pumpServes();
    }

    private void pumpServes() {
        if (serving || serveQueue.isEmpty())
            return;
        serving = true;
        serveQueue.remove(0).run();
    }

    private void serveDone() {
        serving = false;
        pumpServes();
    }

    private void serve(VoiceWire.FetchRequest req, int viaChannel,
            boolean waitForRoute, String key, int gen) {
        Integer cur = serveGen.get(key);
        if (cur == null || cur != gen || !loadFromStore(req.sessionId)) {
            serveDone();
            return;
        }
        byte[] b = bits.get(req.sessionId);
        VoiceWire.Mode mode = modes.get(req.sessionId);
        Set<Integer> wanted = req.missing == null ? null : new HashSet<>(req.missing);
        List<VoiceWire.Packet> packets = new ArrayList<>();
        for (VoiceWire.Packet p : VoiceWire.packetize(req.sessionId, b, mode))
            if (wanted == null || wanted.contains(p.index))
                packets.add(p);
        if (packets.isEmpty()) {
            serveDone();
            return;
        }
        if (viaChannel >= 0) {
            event(req.sessionId, "serving " + packets.size() + " packets on channel "
                    + viaChannel);
            List<byte[]> blobs = new ArrayList<>();
            for (VoiceWire.Packet p : packets)
                blobs.add(p.encode(req.saltOk ? rng.nextInt(256) : -1));
            radio.sendChannelData(viaChannel, VoiceWire.CHANNEL_DATA_TYPE, blobs,
                    packetGap(true, 0), (ok, msg) -> h.post(() -> {
                        lastChannelPacket.put(req.sessionId,
                                System.currentTimeMillis());
                        serveDone();
                    }));
            return;
        }
        long deadline = System.currentTimeMillis() + (waitForRoute ? 25_000 : 3_000);
        waitForRoute(req, deadline, route -> {
            if (route == null) {
                event(req.sessionId, "cannot answer " + req.requesterKey6
                        + ": no direct route back");
                serveDone();
                return;
            }
            long gap = packetGap(false, route.length);
            event(req.sessionId, "serving " + packets.size() + " packets to "
                    + req.requesterKey6);
            sendDirect(req, packets, 0, route, gap, key, gen);
        });
    }

    private interface RouteCb {
        void got(byte[] route);
    }

    private void waitForRoute(VoiceWire.FetchRequest req, long deadline,
            RouteCb cb) {
        Companion.Contact c = contactByKeyHex(req.requesterKey6);
        byte[] route = c == null ? null : c.directRoute();
        if (route != null || System.currentTimeMillis() > deadline) {
            cb.got(route);
            return;
        }
        if (c == null)
            radio.refreshContacts();
        h.postDelayed(() -> waitForRoute(req, deadline, cb), 1000);
    }

    private void sendDirect(VoiceWire.FetchRequest req,
            List<VoiceWire.Packet> packets, int i, byte[] route, long gap,
            String key, int gen) {
        Integer cur = serveGen.get(key);
        if (i >= packets.size() || !radio.isConnected() || cur == null
                || cur != gen) {
            if (i >= packets.size())
                event(req.sessionId, "served all " + packets.size() + " packets");
            serveDone();
            return;
        }
        boolean fits = 2 + route.length + packets.get(i).encode(-1).length + 1
                <= Companion.MAX_FRAME;
        byte[] payload = packets.get(i).encode(req.saltOk && fits
                ? rng.nextInt(256) : -1);
        radio.sendRawData(route, payload, (ok, msg) -> h.post(() -> {
            if (!ok) {
                event(req.sessionId, "serve stopped at packet " + i + ": " + msg);
                serveDone();
                return;
            }
            h.postDelayed(() -> sendDirect(req, packets, i + 1, route, gap, key,
                    gen), gap);
        }));
    }

    // ------------------------------------------------------------- helpers

    private Companion.Contact sender(Incoming c) {
        return c.senderHex == null ? null : contactByKeyHex(c.senderHex);
    }

    private Companion.Contact contactByKeyHex(String prefix) {
        if (prefix == null)
            return null;
        String p = prefix.toLowerCase(java.util.Locale.US);
        for (Companion.Contact c : radio.contacts())
            if (c.keyHex().startsWith(p))
                return c;
        return null;
    }

    private long packetAirMs() {
        Companion.SelfInfo s = radio.self();
        if (s == null || s.sf <= 0 || s.bwHz <= 0)
            return 1200;
        return VoiceWire.airtimeMs(1, VoiceWire.MAX_CODEC_BYTES_PER_PACKET, s.sf,
                s.bwHz / 1000.0, s.cr > 0 ? s.cr : 5, 0);
    }

    /** Pause between packets so we never talk over our own relays. */
    private long packetGap(boolean flood, int hops) {
        long air = packetAirMs();
        if (flood)
            return Math.max(800, air * 4 + 150);
        if (hops <= 0)
            return Math.max(400, air * 2 + 150);
        double relay = air * 1.15;
        int hh = Math.min(hops, 2);
        return Math.round(air + hh * 2.5 * relay + 400);
    }
}
