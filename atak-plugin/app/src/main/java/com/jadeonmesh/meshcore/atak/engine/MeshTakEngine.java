package com.jadeonmesh.meshcore.atak.engine;

import java.io.File;
import java.io.FileOutputStream;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import android.content.Context;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;

import com.jadeonmesh.meshcore.atak.core.Blob;
import com.jadeonmesh.meshcore.atak.core.Bytes;
import com.jadeonmesh.meshcore.atak.core.Companion;
import com.jadeonmesh.meshcore.atak.core.CotConvert;
import com.jadeonmesh.meshcore.atak.core.TeamWire;
import com.jadeonmesh.meshcore.atak.core.VoiceWire;
import com.jadeonmesh.meshcore.atak.core.XNode;
import com.jadeonmesh.meshcore.atak.media.AppMedia;
import com.jadeonmesh.meshcore.atak.media.LocalMedia;
import com.jadeonmesh.meshcore.atak.media.MediaBackend;
import com.jadeonmesh.meshcore.atak.radio.AppRadio;
import com.jadeonmesh.meshcore.atak.radio.BleTransport;
import com.jadeonmesh.meshcore.atak.radio.DirectRadio;
import com.jadeonmesh.meshcore.atak.radio.MeshRadio;
import com.jadeonmesh.meshcore.atak.radio.UsbTransport;

/**
 * The plugin's core: moves team traffic between the MeshCore radio and ATAK.
 * All state lives on one worker thread; public methods post to it.
 */
public final class MeshTakEngine implements MeshRadio.Listener,
        MediaBackend.Listener {

    /** A teammate heard on the mesh. */
    public static final class Member {
        public TeamWire.Position position;
        public long heardMs;

        public String callsign() {
            return position.callsign.isEmpty()
                    ? position.senderKey4.toUpperCase(Locale.US)
                    : position.callsign;
        }
    }

    /** A voice clip or photo seen on the mesh. */
    public static final class MediaItem {
        public VoiceWire.Envelope env;
        public String fromCallsign = "";
        public String fromKeyHex; // 6- or 4-byte prefix, may be null
        public int channel = -1;
        public long timeMs;
        /** Map item the clip is attached to, or null. */
        public String itemUid;
        public boolean outgoing;
        public MediaBackend.Status status = MediaBackend.Status.IDLE;
        public int have, total;
        public String message;
        public File savedFile;
        boolean autoPlay;
    }

    private static final long BEACON_TICK_MS = 5_000;
    private static final long DEDUP_MS = 30_000;
    private static final long TEAM_GAP_MS = 2_500;

    private final Context ctx;
    private final Settings settings;
    private final TakSink sink;
    public final LogBuffer log = new LogBuffer();
    private final HandlerThread thread = new HandlerThread("MeshTakEngine");
    private final Handler h;
    private final SecureRandom rng = new SecureRandom();

    private volatile MeshRadio radio;
    private volatile MediaBackend media;
    private final Blob.Reassembler blobs = new Blob.Reassembler();
    private final Map<String, Member> members = Collections
            .synchronizedMap(new LinkedHashMap<String, Member>());
    private final List<MediaItem> inbox = Collections
            .synchronizedList(new ArrayList<MediaItem>());

    private final Map<String, Long> recentOut = new HashMap<>();
    private final Map<String, Long> recentPayloads = new HashMap<>();
    /** ATAK uid -> [kind, itemId] of items this phone shared. */
    private final Map<String, long[]> shared = new HashMap<>();

    private TeamWire.BeaconPolicy policy = new TeamWire.BeaconPolicy();
    private long lastBeaconAt = -1;
    private double lastBeaconLat, lastBeaconLon, lastBeaconCourse;
    private long lastPublishAt;
    private XNode lastSelfPli;
    private long lastSelfPliAt;
    private int alertId = -1;
    private int alertType;
    private volatile int beacons, received;

    public MeshTakEngine(Context ctx, Settings settings, TakSink sink) {
        this.ctx = ctx;
        this.settings = settings;
        this.sink = sink;
        thread.start();
        h = new Handler(thread.getLooper());
    }

    // ------------------------------------------------------------ lifecycle

    public void start() {
        h.post(() -> {
            connect();
            h.postDelayed(this::tick, BEACON_TICK_MS);
        });
    }

    public void stop() {
        h.post(() -> {
            disconnect();
            thread.quitSafely();
        });
    }

    /** Applies changed link settings. */
    public void reconnect() {
        h.post(() -> {
            disconnect();
            connect();
        });
    }

    private void connect() {
        MeshRadio r = createRadio();
        if (r == null) {
            log.add("Link off");
            sink.onEngineChanged();
            return;
        }
        radio = r;
        MediaBackend m = r instanceof AppRadio
                ? new AppMedia((AppRadio) r, log)
                : new LocalMedia(ctx, (DirectRadio) r, log, settings);
        media = m;
        m.setListener(this);
        r.setListener(this);
        log.add("Connecting: " + r.name());
        r.start();
        m.start();
        sink.onEngineChanged();
    }

    private void disconnect() {
        MeshRadio r = radio;
        MediaBackend m = media;
        radio = null;
        media = null;
        if (m != null)
            m.stop();
        if (r != null) {
            r.setListener(null);
            r.stop();
        }
    }

    private MeshRadio createRadio() {
        Settings.LinkMode mode = settings.linkMode();
        String pkg = settings.appPackage();
        switch (mode) {
            case OFF:
                return null;
            case APP:
                return new AppRadio(ctx, pkg);
            case BLUETOOTH:
                return bleRadio();
            case USB:
                return usbRadio();
            default:
                if (AppRadio.isAppInstalled(ctx, pkg))
                    return new AppRadio(ctx, pkg);
                if (!settings.usbDevice().isEmpty()) {
                    for (String[] d : UsbTransport.listDevices(ctx))
                        if (d[0].equals(settings.usbDevice()))
                            return usbRadio();
                }
                return bleRadio();
        }
    }

    private MeshRadio bleRadio() {
        if (settings.bleAddress().isEmpty())
            return null;
        return new DirectRadio(new BleTransport(ctx, settings.bleAddress(),
                settings.bleName()), this::teamChannelFor);
    }

    private MeshRadio usbRadio() {
        if (settings.usbDevice().isEmpty())
            return null;
        return new DirectRadio(new UsbTransport(ctx, settings.usbDevice()),
                this::teamChannelFor);
    }

    /** Direct mode: the saved team channel, or the only private channel. */
    private int teamChannelFor(String selfKeyHex, List<Companion.Channel> chs) {
        String want = settings.teamChannelName(selfKeyHex);
        Companion.Channel onlyPrivate = null;
        int privates = 0;
        for (Companion.Channel c : chs) {
            if (!want.isEmpty() && c.name.equals(want))
                return c.index;
            if (c.isPrivate()) {
                privates++;
                onlyPrivate = c;
            }
        }
        return want.isEmpty() && privates == 1 ? onlyPrivate.index : -1;
    }

    public void setTeamChannel(String name) {
        h.post(() -> {
            MeshRadio r = radio;
            Companion.SelfInfo s = r == null ? null : r.self();
            if (s == null)
                return;
            settings.setTeamChannelName(Bytes.hex(s.publicKey), name);
            if (r instanceof DirectRadio)
                ((DirectRadio) r).reloadTeamChannel();
        });
    }

    // ------------------------------------------------------------ getters

    public MeshRadio radio() {
        return radio;
    }

    public MediaBackend media() {
        return media;
    }

    public Settings settings() {
        return settings;
    }

    public List<Member> members() {
        synchronized (members) {
            return new ArrayList<>(members.values());
        }
    }

    public List<MediaItem> inbox() {
        synchronized (inbox) {
            return new ArrayList<>(inbox);
        }
    }

    public int beaconsSent() {
        return beacons;
    }

    public int teamMessagesReceived() {
        return received;
    }

    public String selfKey4() {
        MeshRadio r = radio;
        Companion.SelfInfo s = r == null ? null : r.self();
        return s == null ? null : Bytes.hex(s.publicKey, 0, 4);
    }

    /** Why team traffic can't flow right now, or null. */
    public String problem() {
        MeshRadio r = radio;
        if (r == null)
            return settings.linkMode() == Settings.LinkMode.OFF ? "Mesh link is off"
                    : "Pick a radio in the MeshCore pane";
        if (!r.isConnected())
            return r.stateDetail().isEmpty() ? "Connecting…" : r.stateDetail();
        if (!r.supportsChannelData())
            return "Radio firmware too old for team data (needs 1.15+)";
        if (r.teamChannel() < 0)
            return r instanceof AppRadio ? "Pick a team channel in MeshCore Open TAK"
                    : "Pick a private team channel";
        return null;
    }

    public boolean ready() {
        return problem() == null;
    }

    // -------------------------------------------------------- radio events

    @Override
    public void onStateChanged(MeshRadio.State state, String detail) {
        log.add("Radio " + state.name().toLowerCase(Locale.US)
                + (detail.isEmpty() ? "" : ": " + detail));
        sink.onEngineChanged();
        if (state == MeshRadio.State.ERROR && radio instanceof DirectRadio) {
            // Retry a lost direct link.
            h.postDelayed(() -> {
                MeshRadio r = radio;
                if (r instanceof DirectRadio && r.state() == MeshRadio.State.ERROR)
                    reconnect();
            }, 15_000);
        }
    }

    @Override
    public void onRadioInfoChanged() {
        h.post(this::maybeShowRadioContacts);
        sink.onEngineChanged();
    }

    @Override
    public void onChannelData(int channel, int dataType, byte[] payload,
            int hops) {
        h.post(() -> {
            MeshRadio r = radio;
            if (r == null)
                return;
            if (dataType == TeamWire.DATA_TYPE && channel == r.teamChannel()
                    && !r.appOwnsTeam()) {
                onTeamPayload(payload, false);
            } else if (dataType == VoiceWire.CHANNEL_DATA_TYPE) {
                MediaBackend m = media;
                if (m != null)
                    m.onChannelData(channel, payload);
            }
        });
    }

    @Override
    public void onTeamPayload(byte[] payload, boolean own) {
        h.post(() -> handleTeamPayload(payload, own));
    }

    @Override
    public void onChannelText(int channel, String senderName, String text,
            long timestampSec, int hops) {
        h.post(() -> {
            MeshRadio r = radio;
            if (r == null || channel != r.teamChannel())
                return;
            handleTeamChat(senderName, text, timestampSec);
        });
    }

    @Override
    public void onDirectText(String senderPrefixHex, String text,
            long timestampSec) {
        h.post(() -> {
            MediaBackend m = media;
            if (m != null && m.onDirectControlText(senderPrefixHex, text))
                return;
            handleDirectChat(senderPrefixHex, text, timestampSec);
        });
    }

    @Override
    public void onRawData(byte[] payload) {
        MediaBackend m = media;
        if (m != null)
            m.onRawData(payload);
    }

    // --------------------------------------------------- mesh -> ATAK

    private void handleTeamPayload(byte[] p, boolean own) {
        if (p == null)
            return;
        if (sentByUs(p))
            return; // our own item, echoed back by the app
        long now = System.currentTimeMillis();
        String self = selfKey4();
        received++;
        switch (TeamWire.peekType(p)) {
            case TeamWire.MSG_POSITION: {
                TeamWire.Position pos = TeamWire.Position.parse(p);
                if (pos == null || pos.senderKey4.equals(self))
                    return;
                Member m = new Member();
                m.position = pos;
                m.heardMs = now;
                members.put(pos.senderKey4, m);
                sink.dispatch(CotConvert.position(pos, now));
                break;
            }
            case TeamWire.MSG_ALERT: {
                TeamWire.Alert a = TeamWire.Alert.parse(p);
                if (a == null || a.senderKey4.equals(self))
                    return;
                sink.dispatch(CotConvert.alert(a, now));
                log.add((a.active ? "ALERT " : "Alert cancelled ")
                        + TeamWire.ALERT_TYPES[a.type] + " from " + a.callsign);
                if (a.active)
                    sink.toast(TeamWire.ALERT_TYPES[a.type] + " from " + a.callsign);
                break;
            }
            case TeamWire.MSG_MARKER: {
                TeamWire.Marker m = TeamWire.Marker.parse(p);
                if (m == null)
                    return;
                String uid = CotConvert.markerUid(m.authorKey4, m.markerId);
                sink.dispatch(CotConvert.marker(m, now));
                noteAttachment(m.attachment, m.authorKey4, uid, m.label);
                break;
            }
            case TeamWire.MSG_REPORT: {
                TeamWire.Report r = TeamWire.Report.parse(p);
                if (r == null)
                    return;
                sink.dispatch(CotConvert.report(r, now));
                noteAttachment(r.attachment, r.authorKey4,
                        CotConvert.reportUid(r.authorKey4, r.reportId), "SALUTE");
                break;
            }
            case TeamWire.MSG_POINT: {
                TeamWire.Point pt = TeamWire.Point.parse(p);
                if (pt == null)
                    return;
                sink.dispatch(CotConvert.point(pt, now));
                noteAttachment(pt.attachment, pt.authorKey4,
                        CotConvert.pointUid(pt.authorKey4, pt.itemId), pt.callsign);
                break;
            }
            case TeamWire.MSG_SHAPE: {
                TeamWire.Shape s = TeamWire.Shape.parse(p);
                if (s != null)
                    sink.dispatch(CotConvert.shape(s, now));
                break;
            }
            case TeamWire.MSG_CHUNK: {
                byte[] whole = blobs.accept(p, SystemClock.elapsedRealtime());
                if (whole != null)
                    onBlob(TeamWire.peekSender(p), whole);
                break;
            }
            default:
                break;
        }
        sink.onEngineChanged();
    }

    private void onBlob(String senderKey4, byte[] payload) {
        Blob.Content c = Blob.unpack(payload);
        if (c == null) {
            log.add("Dropped a damaged transfer from " + senderKey4);
            return;
        }
        if (c.kind == Blob.KIND_COT) {
            XNode ev = XNode.parse(Bytes.utf8(c.data, 0, c.data.length));
            if (ev == null || !"event".equals(ev.name)) {
                log.add("Bad CoT from " + senderKey4);
                return;
            }
            log.add("CoT " + CotConvert.type(ev) + " from " + callsignFor(senderKey4));
            sink.dispatch(ev);
        } else if (c.kind == Blob.KIND_FILE) {
            String name = new File(c.name.isEmpty() ? "mesh-file.bin" : c.name)
                    .getName();
            File dir = new File(sink.mediaDir(), "files");
            dir.mkdirs();
            File f = new File(dir, name);
            try (FileOutputStream o = new FileOutputStream(f)) {
                o.write(c.data);
            } catch (Exception e) {
                log.add("Could not save " + name + ": " + e.getMessage());
                return;
            }
            log.add("File " + name + " (" + c.data.length + " B) from "
                    + callsignFor(senderKey4));
            sink.toast("Mesh file from " + callsignFor(senderKey4) + ": " + name);
            String lower = name.toLowerCase(Locale.US);
            if (lower.endsWith(".zip") || lower.endsWith(".kml")
                    || lower.endsWith(".kmz") || lower.endsWith(".gpx")
                    || lower.endsWith(".cot"))
                sink.importFile(f);
        }
    }

    private void noteAttachment(TeamWire.Attachment a, String authorKey4,
            String itemUid, String label) {
        if (a == null)
            return;
        VoiceWire.Mode mode = VoiceWire.Mode.fromWireId(a.modeWireId);
        if (mode == null)
            return;
        VoiceWire.Envelope env = new VoiceWire.Envelope(a.sessionId, mode,
                a.packets, a.extra);
        MediaItem it = findItem(env.sessionId);
        if (it == null) {
            it = new MediaItem();
            it.env = env;
            it.fromKeyHex = authorKey4;
            it.fromCallsign = callsignFor(authorKey4);
            it.timeMs = System.currentTimeMillis();
            it.itemUid = itemUid;
            MeshRadio r = radio;
            it.channel = r == null ? -1 : r.teamChannel();
            inbox.add(0, it);
            MediaBackend m = media;
            if (m != null)
                m.onEnvelope(env, authorKey4, it.channel);
        }
    }

    private void handleTeamChat(String senderName, String text, long tsSec) {
        String key4 = keyForName(senderName);
        String uid = key4 != null ? CotConvert.memberUid(key4)
                : "MC-" + Long.toHexString(Bytes.fnv1a32(senderName));
        String callsign = key4 != null ? callsignFor(key4) : senderName;
        MeshRadio r = radio;
        int ch = r == null ? -1 : r.teamChannel();
        if (VoiceWire.Envelope.looksLikeEnvelope(text)) {
            VoiceWire.Envelope env = VoiceWire.Envelope.parse(text);
            if (env != null) {
                onIncomingEnvelope(env, key4, callsign, ch);
                text = env.isImage() ? "📷 Photo — open the MeshCore pane"
                        : "🎙 Voice " + env.durationSeconds
                                + " s — open the MeshCore pane";
            }
        }
        double[] at = positionFor(key4);
        sink.dispatch(CotConvert.chat(uid, callsign, null, text,
                "mc-" + Long.toHexString(rng.nextLong()), tsMs(tsSec), at[0], at[1]));
    }

    private void handleDirectChat(String prefixHex, String text, long tsSec) {
        Companion.Contact c = contactByPrefix(prefixHex);
        String key4 = prefixHex.substring(0, 8);
        String callsign = members.containsKey(key4) ? callsignFor(key4)
                : c != null ? c.name : key4.toUpperCase(Locale.US);
        if (VoiceWire.Envelope.looksLikeEnvelope(text)) {
            VoiceWire.Envelope env = VoiceWire.Envelope.parse(text);
            if (env != null) {
                onIncomingEnvelope(env, prefixHex, callsign, -1);
                text = env.isImage() ? "📷 Photo — open the MeshCore pane"
                        : "🎙 Voice " + env.durationSeconds
                                + " s — open the MeshCore pane";
            }
        }
        double[] at = positionFor(key4);
        sink.dispatch(CotConvert.chat(CotConvert.memberUid(key4), callsign,
                sink.selfUid(), text, "mc-" + Long.toHexString(rng.nextLong()),
                tsMs(tsSec), at[0], at[1]));
    }

    private void onIncomingEnvelope(VoiceWire.Envelope env, String keyHex,
            String callsign, int channel) {
        if (findItem(env.sessionId) != null)
            return;
        MediaItem it = new MediaItem();
        it.env = env;
        it.fromKeyHex = keyHex;
        it.fromCallsign = callsign;
        it.channel = channel;
        it.timeMs = System.currentTimeMillis();
        inbox.add(0, it);
        trimInbox();
        MediaBackend m = media;
        if (m == null)
            return;
        m.onEnvelope(env, keyHex, channel);
        boolean dm = channel < 0;
        if (dm || settings.autoFetchTeamMedia()) {
            it.autoPlay = !env.isImage() && settings.autoPlayVoice();
            m.fetch(env, keyHex, channel);
        }
        sink.onEngineChanged();
    }

    private void trimInbox() {
        synchronized (inbox) {
            while (inbox.size() > 100)
                inbox.remove(inbox.size() - 1);
        }
    }

    private static long tsMs(long sec) {
        long now = System.currentTimeMillis();
        long t = sec * 1000;
        // Radio clocks drift; never show a message from the future.
        return t <= 0 || t > now ? now : t;
    }

    private double[] positionFor(String key4) {
        Member m = key4 == null ? null : members.get(key4);
        if (m != null)
            return new double[] { m.position.lat, m.position.lon };
        TakSink.SelfFix f = sink.selfFix();
        return f == null ? new double[] { 0, 0 } : new double[] { f.lat, f.lon };
    }

    public String callsignFor(String key4) {
        if (key4 == null)
            return "?";
        if (key4.length() > 8)
            key4 = key4.substring(0, 8);
        Member m = members.get(key4);
        if (m != null)
            return m.callsign();
        MeshRadio r = radio;
        if (r != null)
            for (Companion.Contact c : r.contacts())
                if (c.key4().equals(key4))
                    return c.name;
        return key4.toUpperCase(Locale.US);
    }

    private String keyForName(String name) {
        MeshRadio r = radio;
        if (r == null || name == null)
            return null;
        for (Companion.Contact c : r.contacts())
            if (c.name.equals(name))
                return c.key4();
        return null;
    }

    private Companion.Contact contactByPrefix(String hex) {
        MeshRadio r = radio;
        if (r == null || hex == null)
            return null;
        for (Companion.Contact c : r.contacts())
            if (c.keyHex().startsWith(hex))
                return c;
        return null;
    }

    private void maybeShowRadioContacts() {
        MeshRadio r = radio;
        if (r == null || !settings.showRadioContacts())
            return;
        long now = System.currentTimeMillis();
        for (Companion.Contact c : r.contacts()) {
            if (c.type != Companion.ADV_CHAT || c.lat == null
                    || members.containsKey(c.key4()))
                continue;
            XNode ev = CotConvert.event(CotConvert.memberUid(c.key4()),
                    "a-f-G-U-C", "h-e", c.lat, c.lon, null, null, now,
                    2 * 3600_000L);
            XNode d = CotConvert.detail(ev);
            d.add("contact").attr("callsign", c.name).attr("endpoint",
                    CotConvert.MESH_ENDPOINT);
            d.add("remarks").text("MeshCore companion (advert position)");
            sink.dispatch(ev);
        }
    }

    // --------------------------------------------------- ATAK -> mesh

    /**
     * Called for every CoT event ATAK sends (PreSendProcessor). toUids is
     * null for broadcasts.
     */
    public void onAtakSend(String xml, String[] toUids) {
        h.post(() -> {
            XNode ev = XNode.parse(xml);
            if (ev == null || !"event".equals(ev.name))
                return;
            try {
                handleOutgoing(ev, toUids);
            } catch (RuntimeException e) {
                log.add("Could not forward " + CotConvert.type(ev) + ": " + e);
            }
        });
    }

    private void handleOutgoing(XNode ev, String[] toUids) {
        String type = CotConvert.type(ev);
        String uid = CotConvert.uid(ev);
        String self = sink.selfUid();
        if (uid.startsWith(CotConvert.UID_PREFIX)
                || uid.startsWith("GeoChat." + CotConvert.UID_PREFIX)
                || uid.startsWith("MC-"))
            return; // came from the mesh
        if (uid.equals(self) && type.startsWith("a-")) {
            lastSelfPli = ev;
            lastSelfPliAt = SystemClock.elapsedRealtime();
            return;
        }
        MeshRadio r = radio;
        if (r == null || !r.isConnected())
            return;
        if ("b-t-f".equals(type)) {
            sendChat(ev, toUids);
            return;
        }
        if (type.startsWith("b-a-")) {
            onAtakAlert(ev, type);
            return;
        }
        if (type.equals("t-x-d-d")) {
            String target = CotConvert.deleteTarget(ev);
            if (target != null)
                sendDelete(target);
            return;
        }
        if (type.startsWith("t-") || type.startsWith("b-f-t"))
            return; // pings, takcontrol, file-transfer notices: not for the mesh
        if (!settings.shareItems() || !ready())
            return;
        String key4 = selfKey4();
        long nowSec = System.currentTimeMillis() / 1000;
        if (CotConvert.isShapeType(type)) {
            TeamWire.Shape s = CotConvert.shapeOut(ev, key4, nowSec);
            if (s != null) {
                byte[] p = s.encode();
                if (p != null && notDuplicate(uid, p)) {
                    if (s.needsSimplifying())
                        sink.toast("Shape simplified to fit one mesh packet");
                    shared.put(uid, new long[] { TeamWire.MSG_SHAPE, s.itemId });
                    sendTeam(Collections.singletonList(p), "shape " + s.label);
                }
                return;
            }
        } else if (CotConvert.isPointType(type) && !type.startsWith("a-f-G-U-C")) {
            TeamWire.Point p = CotConvert.pointOut(ev, key4, nowSec);
            byte[] b = p.encode();
            if (notDuplicate(uid, b)) {
                shared.put(uid, new long[] { TeamWire.MSG_POINT, p.itemId });
                sendTeam(Collections.singletonList(b), "point " + p.callsign);
            }
            return;
        }
        if (settings.relayOtherCot())
            relayWhole(ev, uid, type);
    }

    private void relayWhole(XNode ev, String uid, String type) {
        String xml = CotConvert.compactForMesh(ev);
        byte[] payload = Blob.pack(new Blob.Content(Blob.KIND_COT, "",
                Bytes.utf8(xml)));
        int packets = Blob.packetsFor(payload.length);
        if (packets > settings.maxCotPackets()) {
            log.add("Not relaying " + type + ": " + packets + " packets");
            sink.toast("Too large for the mesh: " + type + " (" + packets
                    + " packets)");
            return;
        }
        if (!notDuplicate(uid, payload))
            return;
        List<byte[]> chunks = Blob.chunk(selfKey4(), rng.nextInt(0x10000), payload);
        sendTeam(chunks, type + " (" + chunks.size() + " packets)");
    }

    /** Sends a small file to the team. */
    public void sendFile(File f) {
        h.post(() -> {
            if (!ready()) {
                sink.toast(problem());
                return;
            }
            byte[] data;
            try (java.io.FileInputStream in = new java.io.FileInputStream(f)) {
                if (f.length() > 1024 * 1024)
                    throw new java.io.IOException("too large");
                data = new byte[(int) f.length()];
                int off = 0;
                while (off < data.length) {
                    int n = in.read(data, off, data.length - off);
                    if (n < 0)
                        break;
                    off += n;
                }
            } catch (Exception e) {
                sink.toast("Could not read " + f.getName());
                return;
            }
            byte[] payload = Blob.pack(new Blob.Content(Blob.KIND_FILE,
                    f.getName(), data));
            if (payload.length > Blob.MAX_PAYLOAD_BYTES) {
                sink.toast(f.getName() + " is too large for the mesh (max "
                        + Blob.MAX_PAYLOAD_BYTES / 1024 + " KB compressed)");
                return;
            }
            List<byte[]> chunks = Blob.chunk(selfKey4(), rng.nextInt(0x10000),
                    payload);
            sendTeam(chunks, "file " + f.getName() + " (" + chunks.size()
                    + " packets)");
        });
    }

    private boolean notDuplicate(String uid, byte[] payload) {
        String key = uid + "#" + Bytes.hex(payload).hashCode();
        long now = SystemClock.elapsedRealtime();
        Long last = recentOut.get(key);
        for (Iterator<Map.Entry<String, Long>> it = recentOut.entrySet()
                .iterator(); it.hasNext();)
            if (now - it.next().getValue() > DEDUP_MS)
                it.remove();
        if (last != null && now - last < DEDUP_MS)
            return false;
        recentOut.put(key, now);
        return true;
    }

    private boolean sentByUs(byte[] p) {
        String k = Bytes.hex(p);
        long now = SystemClock.elapsedRealtime();
        for (Iterator<Map.Entry<String, Long>> it = recentPayloads.entrySet()
                .iterator(); it.hasNext();)
            if (now - it.next().getValue() > 5 * 60_000)
                it.remove();
        return recentPayloads.containsKey(k);
    }

    private void sendTeam(List<byte[]> blobs, String what) {
        MeshRadio r = radio;
        if (r == null)
            return;
        long now = SystemClock.elapsedRealtime();
        for (byte[] b : blobs)
            recentPayloads.put(Bytes.hex(b), now);
        r.sendTeam(blobs, blobs.size() > 1 ? TEAM_GAP_MS : 0, (ok, msg) -> {
            log.add((ok ? "Sent " : "Failed to send ") + what
                    + (ok ? "" : ": " + msg));
            if (!ok)
                sink.toast("Mesh send failed: " + msg);
        });
    }

    private void sendDelete(String uid) {
        long[] s = shared.remove(uid);
        if (s == null)
            return;
        String key4 = selfKey4();
        byte[] p;
        if (s[0] == TeamWire.MSG_SHAPE) {
            TeamWire.Shape d = new TeamWire.Shape();
            d.authorKey4 = key4;
            d.itemId = s[1];
            d.deleted = true;
            p = d.encode();
        } else {
            TeamWire.Point d = new TeamWire.Point();
            d.authorKey4 = key4;
            d.itemId = s[1];
            d.deleted = true;
            p = d.encode();
        }
        sendTeam(Collections.singletonList(p), "delete " + uid);
    }

    private void sendChat(XNode ev, String[] toUids) {
        CotConvert.ChatOut c = CotConvert.chatOut(ev);
        MeshRadio r = radio;
        if (c == null || r == null)
            return;
        if (!notDuplicate("chat:" + c.messageId + ":"
                + (toUids == null ? "*" : java.util.Arrays.toString(toUids)),
                Bytes.utf8(c.text)))
            return;
        if (c.toAll) {
            if (!settings.bridgeAllChat() || r.teamChannel() < 0)
                return;
            Companion.SelfInfo s = r.self();
            int max = Companion.maxChannelTextBytes(s == null ? null : s.name);
            for (String part : split(c.text, max))
                r.sendChannelText(r.teamChannel(), part, (ok, msg) -> {
                    if (!ok)
                        sink.toast("Team chat not sent: " + msg);
                });
            log.add("Chat to team: " + c.text);
            return;
        }
        List<String> targets = new ArrayList<>();
        if (toUids != null)
            Collections.addAll(targets, toUids);
        if (targets.isEmpty())
            targets.add(c.roomId);
        for (String t : targets) {
            String key4 = CotConvert.key4FromMemberUid(t);
            if (key4 == null)
                continue; // a TAK contact, not someone on the mesh
            Companion.Contact contact = null;
            for (Companion.Contact cc : r.contacts())
                if (cc.key4().equals(key4))
                    contact = cc;
            if (contact == null) {
                sink.toast(callsignFor(key4)
                        + " is not in the radio's contacts yet; message not sent");
                continue;
            }
            for (String part : split(c.text, Companion.maxDirectTextBytes())) {
                final String who = contact.name;
                r.sendDirectText(contact.publicKey, part, (ok, msg) -> {
                    if (!ok)
                        sink.toast("Message to " + who + " not sent: " + msg);
                });
            }
            log.add("DM to " + contact.name + ": " + c.text);
        }
    }

    /** Splits text into parts of at most maxBytes UTF-8 bytes, "(1/2) " tagged. */
    static List<String> split(String text, int maxBytes) {
        List<String> out = new ArrayList<>();
        if (Bytes.utf8(text).length <= maxBytes) {
            out.add(text);
            return out;
        }
        int room = maxBytes - 7;
        String rest = text;
        while (!rest.isEmpty()) {
            byte[] cut = Bytes.truncateUtf8(rest, room);
            String part = Bytes.utf8(cut, 0, cut.length);
            if (part.isEmpty())
                break;
            out.add(part);
            rest = rest.trim().substring(part.length()).trim();
        }
        for (int i = 0; i < out.size(); i++)
            out.set(i, "(" + (i + 1) + "/" + out.size() + ") " + out.get(i));
        return out;
    }

    private void onAtakAlert(XNode ev, String type) {
        boolean cancel = type.equals("b-a-o-can");
        if (!cancel && CotConvert.alertTypeFromCot(type) < 0)
            return;
        if (!ready())
            return;
        if (cancel) {
            if (alertId < 0)
                return;
            TeamWire.Alert a = CotConvert.alertOut(ev, selfKey4(), alertId, true);
            a.type = alertType;
            alertId = -1;
            sendRepeated(a.encode(), "alert cancel", 2, 10_000);
        } else {
            if (alertId < 0)
                alertId = rng.nextInt(0x10000);
            TeamWire.Alert a = CotConvert.alertOut(ev, selfKey4(), alertId, false);
            alertType = a.type;
            sendRepeated(a.encode(), "ALERT " + TeamWire.ALERT_TYPES[a.type], 3,
                    20_000);
        }
        lastBeaconAt = -1; // beacon now, with the SOS flag
    }

    private void sendRepeated(byte[] p, String what, int times, long gapMs) {
        for (int i = 0; i < times; i++) {
            final int n = i;
            h.postDelayed(() -> sendTeam(Collections.singletonList(p),
                    what + (n > 0 ? " (repeat " + n + ")" : "")), i * gapMs);
        }
    }

    // --------------------------------------------------------- beacons

    private void tick() {
        try {
            beaconTick();
            expireMembers();
        } catch (RuntimeException e) {
            log.add("Beacon error: " + e);
        }
        h.postDelayed(this::tick, BEACON_TICK_MS);
    }

    private void beaconTick() {
        MeshRadio r = radio;
        if (r == null || !r.isConnected() || !settings.sharePosition())
            return;
        TeamWire.Position p = selfPosition();
        if (p == null)
            return;
        long now = SystemClock.elapsedRealtime();
        if (r.appOwnsTeam()) {
            // The app beacons for this radio; keep it fed with ATAK's identity.
            if (now - lastPublishAt >= 10_000) {
                lastPublishAt = now;
                r.publishSelf(p.encode());
            }
            return;
        }
        if (!ready())
            return;
        long since = lastBeaconAt < 0 ? -1 : now - lastBeaconAt;
        double moved = lastBeaconAt < 0 ? 0
                : TeamWire.distanceMeters(lastBeaconLat, lastBeaconLon, p.lat, p.lon);
        double speed = p.speedMps == null ? 0 : p.speedMps;
        double turn = p.headingDeg == null ? 0
                : Math.abs(((p.headingDeg - lastBeaconCourse + 540) % 360) - 180);
        if (!policy.shouldSend(since, moved, speed, turn))
            return;
        lastBeaconAt = now;
        lastBeaconLat = p.lat;
        lastBeaconLon = p.lon;
        lastBeaconCourse = p.headingDeg == null ? lastBeaconCourse : p.headingDeg;
        byte[] b = p.encode();
        recentPayloads.put(Bytes.hex(b), now);
        r.sendTeam(Collections.singletonList(b), 0, (ok, msg) -> {
            if (ok)
                beacons++;
            else
                log.add("Beacon failed: " + msg);
            sink.onEngineChanged();
        });
    }

    /** ATAK's self PLI as a team position, or null without a fix. */
    public TeamWire.Position selfPosition() {
        String key4 = selfKey4();
        if (key4 == null)
            return null;
        TeamWire.Position p;
        XNode pli = lastSelfPli;
        if (pli != null && SystemClock.elapsedRealtime() - lastSelfPliAt < 60_000) {
            p = CotConvert.selfPosition(pli, key4);
        } else {
            TakSink.SelfFix f = sink.selfFix();
            if (f == null)
                return null;
            p = new TeamWire.Position();
            p.senderKey4 = key4;
            p.lat = f.lat;
            p.lon = f.lon;
            if (f.hae != null)
                p.altitudeM = (int) Math.round(f.hae);
            p.accuracyM = f.ce == null ? 0 : (int) Math.min(255, Math.round(f.ce));
            if (f.speedMps != null && f.courseDeg != null) {
                p.speedMps = f.speedMps;
                p.headingDeg = f.courseDeg;
            }
            p.callsign = f.callsign;
            p.color = CotConvert.colorFromTak(f.team);
            p.role = CotConvert.roleFromTak(f.role);
            p.batteryPct = f.battery;
        }
        if (p.lat == 0 && p.lon == 0)
            return null;
        p.status = settings.status();
        p.sosActive = alertId >= 0;
        return p;
    }

    /** Sends a beacon now (status change, or the user asked). */
    public void beaconNow() {
        h.post(() -> {
            lastBeaconAt = -1;
            lastPublishAt = 0;
            beaconTick();
        });
    }

    private void expireMembers() {
        long cutoff = System.currentTimeMillis() - 2 * 3600_000L;
        synchronized (members) {
            for (Iterator<Member> it = members.values().iterator(); it.hasNext();)
                if (it.next().heardMs < cutoff)
                    it.remove();
        }
    }

    // ------------------------------------------------------------ media

    private MediaItem findItem(String sid) {
        synchronized (inbox) {
            for (MediaItem m : inbox)
                if (m.env.sessionId.equals(sid))
                    return m;
        }
        return null;
    }

    @Override
    public void onClipChanged(String sid, MediaBackend.Status status, int have,
            int total, String message) {
        h.post(() -> {
            MediaItem it = findItem(sid);
            if (it == null)
                return;
            MediaBackend.Status was = it.status;
            it.status = status;
            it.have = have;
            it.total = total;
            it.message = message;
            if (status == MediaBackend.Status.COMPLETE
                    && was != MediaBackend.Status.COMPLETE)
                onClipComplete(it);
            sink.onEngineChanged();
        });
    }

    private void onClipComplete(MediaItem it) {
        MediaBackend m = media;
        if (m == null)
            return;
        if (it.env.isImage()) {
            m.image(it.env, (jpeg, msg) -> h.post(() -> saveImage(it, jpeg)));
        } else if (it.autoPlay) {
            it.autoPlay = false;
            play(it);
        }
    }

    private void saveImage(MediaItem it, byte[] jpeg) {
        if (jpeg == null)
            return;
        File dir = it.itemUid != null ? sink.attachmentsDir(it.itemUid)
                : new File(sink.mediaDir(), "photos");
        dir.mkdirs();
        File f = new File(dir, "mesh-" + it.env.sessionId + ".jpg");
        try (FileOutputStream o = new FileOutputStream(f)) {
            o.write(jpeg);
            it.savedFile = f;
            log.add("Photo from " + it.fromCallsign + " saved to " + f.getPath());
            sink.onEngineChanged();
        } catch (Exception e) {
            log.add("Could not save photo: " + e.getMessage());
        }
    }

    public void fetch(MediaItem it) {
        h.post(() -> {
            MediaBackend m = media;
            if (m != null)
                m.fetch(it.env, it.fromKeyHex, it.channel);
        });
    }

    /** Plays a complete clip (fetching first if needed). */
    public void play(MediaItem it) {
        MediaBackend m = media;
        if (m == null)
            return;
        if (m.status(it.env.sessionId) != MediaBackend.Status.COMPLETE) {
            it.autoPlay = true;
            fetch(it);
            return;
        }
        m.audio(it.env, (pcm, rate, msg) -> {
            if (pcm == null) {
                sink.toast("Can't play: " + msg);
                return;
            }
            com.jadeonmesh.meshcore.atak.media.AudioIO.play(pcm, rate);
        });
    }

    /** Recordings are 48 kHz mono; target null = team channel. */
    public void sendVoice(short[] pcm48k, MediaBackend.Target target) {
        h.post(() -> {
            MediaBackend m = media;
            MeshRadio r = radio;
            if (m == null || r == null || !r.isConnected()) {
                sink.toast(problem() == null ? "Not connected" : problem());
                return;
            }
            MediaBackend.Target t = target != null ? target
                    : MediaBackend.Target.channel(r.teamChannel());
            if (t.isChannel() && t.channel < 0) {
                sink.toast(problem());
                return;
            }
            m.sendVoice(pcm48k, t, (env, msg) -> h.post(() -> {
                if (env == null) {
                    sink.toast("Voice not sent: " + msg);
                    return;
                }
                addOutgoing(env, t);
                log.add("Voice clip sent (" + env.totalPackets + " packets, "
                        + env.mode.label + ")");
            }));
        });
    }

    public void sendImage(byte[] image, MediaBackend.Target target) {
        h.post(() -> {
            MediaBackend m = media;
            MeshRadio r = radio;
            if (m == null || r == null || !r.isConnected()) {
                sink.toast(problem() == null ? "Not connected" : problem());
                return;
            }
            MediaBackend.Target t = target != null ? target
                    : MediaBackend.Target.channel(r.teamChannel());
            if (t.isChannel() && t.channel < 0) {
                sink.toast(problem());
                return;
            }
            m.sendImage(image, t, settings.photoDetail(), (env, msg) -> h.post(() -> {
                if (env == null) {
                    sink.toast("Photo not sent: " + msg);
                    return;
                }
                addOutgoing(env, t);
                log.add("Photo announced (" + env.totalPackets + " packets)");
            }));
        });
    }

    /**
     * Shares a point with a photo attached: the pin goes to the team at
     * once, the photo is fetched by whoever opens it.
     */
    public void sharePointWithPhoto(String uid, String xml, byte[] image) {
        h.post(() -> {
            MediaBackend m = media;
            if (m == null || !ready()) {
                sink.toast(problem());
                return;
            }
            XNode ev = XNode.parse(xml);
            if (ev == null)
                return;
            m.registerImage(image, settings.photoDetail(), (att, msg) -> h.post(() -> {
                if (att == null) {
                    sink.toast("Photo not attached: " + msg);
                    return;
                }
                TeamWire.Point p = CotConvert.pointOut(ev, selfKey4(),
                        System.currentTimeMillis() / 1000);
                p.attachment = att;
                shared.put(uid, new long[] { TeamWire.MSG_POINT, p.itemId });
                sendTeam(Collections.singletonList(p.encode()),
                        "point " + p.callsign + " with photo");
                MeshRadio r = radio;
                VoiceWire.Envelope env = new VoiceWire.Envelope(att.sessionId,
                        VoiceWire.Mode.fromWireId(att.modeWireId), att.packets,
                        att.extra);
                addOutgoing(env, MediaBackend.Target.channel(
                        r == null ? -1 : r.teamChannel()));
            }));
        });
    }

    private void addOutgoing(VoiceWire.Envelope env, MediaBackend.Target t) {
        MediaItem it = new MediaItem();
        it.env = env;
        it.outgoing = true;
        it.fromCallsign = "Me";
        it.channel = t.isChannel() ? t.channel : -1;
        it.timeMs = System.currentTimeMillis();
        it.status = MediaBackend.Status.COMPLETE;
        inbox.add(0, it);
        trimInbox();
        sink.onEngineChanged();
    }
}
