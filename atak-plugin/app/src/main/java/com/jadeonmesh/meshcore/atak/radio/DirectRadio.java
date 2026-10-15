package com.jadeonmesh.meshcore.atak.radio;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;

import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;

import com.jadeonmesh.meshcore.atak.core.Bytes;
import com.jadeonmesh.meshcore.atak.core.Companion;
import com.jadeonmesh.meshcore.atak.core.RecentKeys;
import com.jadeonmesh.meshcore.atak.core.TeamWire;

/**
 * Talks the MeshCore companion protocol to a radio over a
 * {@link FrameTransport}. The protocol has no request ids: the firmware
 * answers commands in order, so commands go out strictly one at a time and
 * each waits for its terminal reply (or a timeout) before the next.
 */
public final class DirectRadio implements MeshRadio {

    public interface TeamChannelSource {
        /** The team channel the user picked for this radio, or -1. */
        int teamChannelFor(String selfKeyHex, List<Companion.Channel> channels);
    }

    private static final long CMD_TIMEOUT_MS = 6000;
    private static final long SEND_TIMEOUT_MS = 12000;
    private static final long QUIET_MS = 1500, QUIET_MAX_WAIT_MS = 6000;

    private final FrameTransport transport;
    private final TeamChannelSource teamSource;
    private final HandlerThread thread = new HandlerThread("MeshTakDirect");
    private Handler h;
    private volatile Listener listener;

    private volatile State state = State.OFF;
    private volatile String detail = "";
    private volatile Companion.SelfInfo self;
    private volatile Companion.DeviceInfo device;
    private final List<Companion.Channel> channels = new CopyOnWriteArrayList<>();
    private final Map<String, Companion.Contact> contacts = Collections
            .synchronizedMap(new LinkedHashMap<String, Companion.Contact>());
    private final List<Companion.Contact> contactsLoading = new ArrayList<>();
    private volatile int teamChannel = -1;

    private final ArrayDeque<Cmd> queue = new ArrayDeque<>();
    private Cmd current;
    private boolean syncing, syncAgain;
    private long lastRfRx;
    private boolean stopped;

    // Contacts: a full read on connect and every FULL_REFRESH_TICKS minutes,
    // otherwise only what changed since the radio's last lastmod.
    private static final int FULL_REFRESH_TICKS = 15;
    private long contactsSince, pendingLastMod;
    private int periodicTicks;
    /** Adverts from nodes the radio didn't save (manual-add radios). */
    private final Map<String, Companion.Contact> heard = Collections
            .synchronizedMap(new LinkedHashMap<String, Companion.Contact>());
    private static final int MAX_HEARD = 300;

    // Typed chat: acknowledged, up to MAX_CHAT_TRIES tries, the last flooded.
    private static final int MAX_CHAT_TRIES = 3;
    private static final int MAX_CHATS_WAITING = 5;
    private static final long MIN_ACK_WAIT_MS = 2_000, MAX_ACK_WAIT_MS = 60_000,
            ACK_MARGIN_MS = 2_000;
    private static final class Chat {
        byte[] pubKey;
        String text;
        long timestampSec;
        int attempt;
        final java.util.Set<Long> acks = new java.util.HashSet<>();
        long ackDeadline;
        ChatResult result;
    }
    private final Map<Integer, Chat> chats = new LinkedHashMap<>();
    private int nextChatId = 1;
    private Companion.Sent lastSent;
    private boolean ticking;
    /** A sender re-sends with the same timestamp when our ack was lost. */
    private final RecentKeys dmSeen = new RecentKeys(64, 15 * 60_000L);

    private static final class Cmd {
        final byte[] frame;
        final Done done;
        final long timeoutMs;
        final boolean waitQuiet;
        long sentAt;
        String label;

        Cmd(byte[] frame, Done done, long timeoutMs, boolean waitQuiet) {
            this.frame = frame;
            this.done = done;
            this.timeoutMs = timeoutMs;
            this.waitQuiet = waitQuiet;
        }

        int code() {
            return frame[0] & 0xFF;
        }

        /** True if [resp] ends this command. */
        boolean endedBy(int resp) {
            if (resp == Companion.RESP_ERR)
                return true;
            switch (code()) {
                case Companion.CMD_DEVICE_QUERY:
                    return resp == Companion.RESP_DEVICE_INFO;
                case Companion.CMD_APP_START:
                    return resp == Companion.RESP_SELF_INFO;
                case Companion.CMD_GET_CONTACTS:
                    return resp == Companion.RESP_END_OF_CONTACTS;
                case Companion.CMD_GET_CHANNEL:
                    return resp == Companion.RESP_CHANNEL_INFO;
                case Companion.CMD_GET_DEVICE_TIME:
                    return resp == Companion.RESP_CURR_TIME;
                case Companion.CMD_SYNC_NEXT_MESSAGE:
                    return resp == Companion.RESP_CONTACT_MSG_RECV
                            || resp == Companion.RESP_CONTACT_MSG_RECV_V3
                            || resp == Companion.RESP_CHANNEL_MSG_RECV
                            || resp == Companion.RESP_CHANNEL_MSG_RECV_V3
                            || resp == Companion.RESP_CHANNEL_DATA_RECV
                            || resp == Companion.RESP_NO_MORE_MESSAGES;
                case Companion.CMD_SEND_TXT_MSG:
                    return resp == Companion.RESP_SENT;
                default:
                    return resp == Companion.RESP_OK;
            }
        }
    }

    public DirectRadio(FrameTransport transport, TeamChannelSource teamSource) {
        this.transport = transport;
        this.teamSource = teamSource;
    }

    @Override
    public String name() {
        return transport.describe();
    }

    @Override
    public void setListener(Listener l) {
        this.listener = l;
    }

    @Override
    public void start() {
        thread.start();
        h = new Handler(thread.getLooper());
        setState(State.CONNECTING, "Connecting to " + transport.describe());
        transport.open(new FrameTransport.Listener() {
            @Override
            public void onTransportUp() {
                h.post(DirectRadio.this::handshake);
            }

            @Override
            public void onFrame(byte[] frame) {
                h.post(() -> onFrameIn(frame));
            }

            @Override
            public void onTransportDown(String reason) {
                h.post(() -> {
                    failAll(reason);
                    setState(State.ERROR, reason);
                });
            }
        });
    }

    @Override
    public void stop() {
        stopped = true;
        transport.close();
        if (h != null)
            h.post(() -> {
                failAll("Stopped");
                setState(State.OFF, "");
                thread.quitSafely();
            });
    }

    private void setState(State s, String d) {
        state = s;
        detail = d == null ? "" : d;
        Listener l = listener;
        if (l != null)
            l.onStateChanged(s, detail);
    }

    // ------------------------------------------------------------ handshake

    private void handshake() {
        enqueue(Companion.deviceQuery(), null, CMD_TIMEOUT_MS, false);
        enqueue(Companion.appStart("MeshCoreTAK"), (ok, msg) -> {
            if (!ok || self == null) {
                setState(State.ERROR, "Radio did not answer (" + msg + ")");
                return;
            }
            setState(State.CONNECTED, self.name);
            enqueue(Companion.setDeviceTime(Companion.nowSec()), null,
                    CMD_TIMEOUT_MS, false);
            loadContacts(true);
            loadChannel(0);
            h.postDelayed(this::syncMessages, 1500);
            h.postDelayed(this::periodic, 60_000);
        }, CMD_TIMEOUT_MS, false);
    }

    private void loadChannel(int idx) {
        int max = device != null && device.maxChannels > 0 ? device.maxChannels : 8;
        if (idx >= max) {
            pickTeamChannel();
            return;
        }
        if (idx == 0)
            channels.clear();
        enqueue(Companion.getChannel(idx), (ok, msg) -> {
            if (ok)
                loadChannel(idx + 1);
            else
                pickTeamChannel(); // ERR past the last channel
        }, CMD_TIMEOUT_MS, false);
    }

    private void pickTeamChannel() {
        Companion.SelfInfo s = self;
        teamChannel = s == null ? -1
                : teamSource.teamChannelFor(Bytes.hex(s.publicKey), channels());
        infoChanged();
    }

    /** Call after the user picks a different team channel. */
    public void reloadTeamChannel() {
        if (h != null)
            h.post(this::pickTeamChannel);
    }

    private void periodic() {
        if (stopped || state != State.CONNECTED)
            return;
        syncMessages();
        if (++periodicTicks % FULL_REFRESH_TICKS == 0)
            loadContacts(true); // catches contacts deleted on the radio
        h.postDelayed(this::periodic, 60_000);
    }

    @Override
    public void refreshContacts() {
        if (h != null)
            h.post(() -> loadContacts(true));
    }

    /**
     * Full: replace the list. Otherwise ask only for contacts changed since
     * the last read and merge them in (much less Bluetooth traffic on a busy
     * mesh, where adverts arrive every few seconds).
     */
    private void loadContacts(boolean full) {
        long since = full ? 0 : contactsSince;
        pendingLastMod = 0;
        enqueue(Companion.getContacts(since), (ok, msg) -> {
            if (ok) {
                synchronized (contacts) {
                    if (since <= 0)
                        contacts.clear();
                    for (Companion.Contact c : contactsLoading)
                        contacts.put(c.keyHex(), c);
                }
                synchronized (heard) {
                    for (Companion.Contact c : contactsLoading)
                        heard.remove(c.keyHex());
                }
                if (pendingLastMod > contactsSince)
                    contactsSince = pendingLastMod;
                infoChanged();
            }
            contactsLoading.clear();
        }, 15000, false);
    }

    private void syncMessages() {
        if (syncing) {
            syncAgain = true;
            return;
        }
        syncing = true;
        syncNext();
    }

    private void syncNext() {
        enqueue(Companion.syncNextMessage(), (ok, msg) -> {
            if (ok && !"none".equals(msg)) {
                syncNext();
            } else {
                syncing = false;
                if (syncAgain) {
                    syncAgain = false;
                    syncMessages();
                }
            }
        }, CMD_TIMEOUT_MS, false);
    }

    // ------------------------------------------------------------- queue

    private void enqueue(byte[] frame, Done done, long timeoutMs,
            boolean waitQuiet) {
        if (frame.length > Companion.MAX_FRAME) {
            if (done != null)
                done.done(false, "Frame too long");
            return;
        }
        queue.add(new Cmd(frame, done, timeoutMs, waitQuiet));
        pump();
    }

    private void pump() {
        if (current != null || queue.isEmpty() || stopped)
            return;
        Cmd c = queue.peek();
        if (c.waitQuiet) {
            long since = SystemClock.elapsedRealtime() - lastRfRx;
            if (since < QUIET_MS && c.sentAt == 0) {
                // Hold for radio silence (bounded), like the app does.
                c.sentAt = -SystemClock.elapsedRealtime();
                h.postDelayed(this::pump, QUIET_MS - since);
                return;
            }
            if (since < QUIET_MS && c.sentAt < 0
                    && SystemClock.elapsedRealtime() + c.sentAt < QUIET_MAX_WAIT_MS) {
                h.postDelayed(this::pump, 200);
                return;
            }
        }
        queue.poll();
        current = c;
        if (c.code() == Companion.CMD_SEND_TXT_MSG)
            lastSent = null; // so a timed-out send can't pick up an old ack code
        c.sentAt = SystemClock.elapsedRealtime();
        transport.send(c.frame);
        final Cmd sent = c;
        h.postDelayed(() -> {
            if (current == sent)
                finish(false, "timed out");
        }, c.timeoutMs);
    }

    private void finish(boolean ok, String msg) {
        Cmd c = current;
        current = null;
        if (c != null && c.done != null) {
            try {
                c.done.done(ok, msg);
            } catch (RuntimeException ignored) {
            }
        }
        pump();
    }

    private void failAll(String why) {
        Cmd c = current;
        current = null;
        if (c != null && c.done != null)
            c.done.done(false, why);
        while (!queue.isEmpty()) {
            Cmd q = queue.poll();
            if (q.done != null)
                q.done.done(false, why);
        }
        syncing = false;
        for (Chat pending : new ArrayList<>(chats.values()))
            pending.result.onResult(ChatOutcome.UNCONFIRMED,
                    "the radio link dropped before an acknowledgement");
        chats.clear();
    }

    // ---------------------------------------------------------- inbound

    private void onFrameIn(byte[] f) {
        if (f.length == 0)
            return;
        int code = f[0] & 0xFF;
        if (Companion.isPush(code)) {
            onPush(code, f);
            return;
        }
        String result = null;
        switch (code) {
            case Companion.RESP_DEVICE_INFO:
                device = Companion.DeviceInfo.parse(f);
                break;
            case Companion.RESP_SELF_INFO:
                self = Companion.SelfInfo.parse(f);
                infoChanged();
                break;
            case Companion.RESP_CONTACTS_START:
                contactsLoading.clear();
                break;
            case Companion.RESP_END_OF_CONTACTS:
                pendingLastMod = Companion.endOfContactsLastMod(f);
                break;
            case Companion.RESP_SENT:
                lastSent = Companion.Sent.parse(f);
                break;
            case Companion.RESP_CONTACT: {
                Companion.Contact c = Companion.Contact.parse(f);
                if (c != null)
                    contactsLoading.add(c);
                break;
            }
            case Companion.RESP_CHANNEL_INFO: {
                Companion.Channel ch = Companion.Channel.parse(f);
                if (ch != null && !ch.isEmpty())
                    channels.add(ch);
                break;
            }
            case Companion.RESP_CHANNEL_MSG_RECV:
            case Companion.RESP_CHANNEL_MSG_RECV_V3: {
                Companion.ChannelText m = Companion.ChannelText.parse(f);
                Listener l = listener;
                if (m != null && l != null)
                    l.onChannelText(m.channel, m.senderName, m.text,
                            m.timestamp, m.hops);
                break;
            }
            case Companion.RESP_CONTACT_MSG_RECV:
            case Companion.RESP_CONTACT_MSG_RECV_V3: {
                Companion.DirectText m = Companion.DirectText.parse(f);
                Listener l = listener;
                // Drop a re-send of a message we already have (the sender
                // retries with the same timestamp when our ack was lost).
                if (m != null && l != null && dmSeen.firstTime(
                        m.senderPrefixHex() + "|" + m.timestamp + "|" + m.text))
                    l.onDirectText(m.senderPrefixHex(), m.text, m.timestamp);
                break;
            }
            case Companion.RESP_CHANNEL_DATA_RECV: {
                Companion.ChannelData d = Companion.ChannelData.parse(f);
                Listener l = listener;
                if (d != null && l != null)
                    l.onChannelData(d.channel, d.dataType, d.payload,
                            d.flooded() ? d.hops() : -1);
                break;
            }
            case Companion.RESP_NO_MORE_MESSAGES:
                result = "none";
                break;
            case Companion.RESP_ERR:
                result = "error " + (f.length > 1 ? (f[1] & 0xFF) : 0);
                break;
            default:
                break;
        }
        Cmd c = current;
        if (c != null && c.endedBy(code))
            finish(code != Companion.RESP_ERR, result);
    }

    private void onPush(int code, byte[] f) {
        switch (code) {
            case Companion.PUSH_MSG_WAITING:
                syncMessages();
                break;
            case Companion.PUSH_RAW_DATA: {
                Companion.RawData r = Companion.RawData.parse(f);
                Listener l = listener;
                if (r != null && l != null)
                    l.onRawData(r.payload);
                break;
            }
            case Companion.PUSH_LOG_RX_DATA:
                lastRfRx = SystemClock.elapsedRealtime();
                break;
            case Companion.PUSH_NEW_ADVERT: {
                // A node the radio hasn't saved: keep it for the map.
                Companion.Contact c = Companion.Contact.parse(f);
                if (c != null && !contacts.containsKey(c.keyHex())) {
                    synchronized (heard) {
                        heard.remove(c.keyHex());
                        heard.put(c.keyHex(), c);
                        while (heard.size() > MAX_HEARD)
                            heard.remove(heard.keySet().iterator().next());
                    }
                    infoChanged();
                }
                scheduleContactRefresh();
                break;
            }
            case Companion.PUSH_ADVERT:
            case Companion.PUSH_PATH_UPDATED:
                scheduleContactRefresh();
                break;
            case Companion.PUSH_SEND_CONFIRMED: {
                long[] ack = Companion.sendConfirmed(f);
                if (ack != null)
                    confirmChat(ack[0]);
                break;
            }
            default:
                break;
        }
    }

    private boolean refreshPending;

    private void scheduleContactRefresh() {
        if (refreshPending)
            return;
        refreshPending = true;
        h.postDelayed(() -> {
            refreshPending = false;
            if (!stopped && state == State.CONNECTED)
                loadContacts(false);
        }, 3000);
    }

    private void infoChanged() {
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
        return new ArrayList<>(channels);
    }

    @Override
    public List<Companion.Contact> contacts() {
        synchronized (contacts) {
            return new ArrayList<>(contacts.values());
        }
    }

    @Override
    public boolean supportsChannelData() {
        Companion.DeviceInfo d = device;
        return d != null && d.fwVerCode >= Companion.MIN_FW_FOR_CHANNEL_DATA;
    }

    public Companion.DeviceInfo deviceInfo() {
        return device;
    }

    @Override
    public int teamChannel() {
        return teamChannel;
    }

    @Override
    public boolean appOwnsTeam() {
        return false;
    }

    private void post(Runnable r, Done done) {
        if (h == null || !isConnected()) {
            if (done != null)
                done.done(false, "Radio not connected");
            return;
        }
        h.post(r);
    }

    @Override
    public void sendChannelData(int channel, int dataType, List<byte[]> blobs,
            long gapMs, Done done) {
        if (!supportsChannelData()) {
            if (done != null)
                done.done(false, "Radio firmware too old for channel data");
            return;
        }
        post(() -> sendBlobsFrom(0, channel, dataType, blobs, gapMs, done), done);
    }

    private void sendBlobsFrom(int i, int channel, int dataType,
            List<byte[]> blobs, long gapMs, Done done) {
        if (i >= blobs.size()) {
            if (done != null)
                done.done(true, null);
            return;
        }
        enqueue(Companion.sendChannelData(channel, dataType, blobs.get(i)),
                (ok, msg) -> {
                    if (!ok) {
                        if (done != null)
                            done.done(false, msg);
                        return;
                    }
                    if (i + 1 < blobs.size())
                        h.postDelayed(() -> sendBlobsFrom(i + 1, channel,
                                dataType, blobs, gapMs, done), gapMs);
                    else if (done != null)
                        done.done(true, null);
                }, SEND_TIMEOUT_MS, true);
    }

    @Override
    public void sendChannelText(int channel, String text, Done done) {
        post(() -> enqueue(Companion.sendChannelText(channel, text), done,
                SEND_TIMEOUT_MS, true), done);
    }

    @Override
    public void sendDirectText(byte[] pubKey, String text, Done done) {
        post(() -> enqueue(Companion.sendText(pubKey, text, 0), done,
                SEND_TIMEOUT_MS, true), done);
    }

    @Override
    public List<Companion.Contact> heard() {
        synchronized (heard) {
            return new ArrayList<>(heard.values());
        }
    }

    @Override
    public void sendChatText(byte[] pubKey, String text, ChatResult result) {
        if (h == null || !isConnected()) {
            result.onResult(ChatOutcome.REFUSED, "Radio not connected");
            return;
        }
        h.post(() -> {
            if (chats.size() >= MAX_CHATS_WAITING) {
                result.onResult(ChatOutcome.REFUSED,
                        "too many messages waiting for an acknowledgement");
                return;
            }
            Chat c = new Chat();
            c.pubKey = pubKey;
            c.text = text;
            c.timestampSec = Companion.nowSec();
            c.result = result;
            int id = nextChatId++;
            chats.put(id, c);
            sendChatTry(id);
            if (!ticking) {
                ticking = true;
                h.postDelayed(this::chatTick, 1000);
            }
        });
    }

    private void sendChatTry(int id) {
        Chat c = chats.get(id);
        if (c == null)
            return;
        enqueue(Companion.sendText(c.pubKey, c.text, c.attempt, c.timestampSec),
                (ok, msg) -> {
                    Chat cc = chats.get(id);
                    if (cc == null)
                        return; // acknowledged already
                    Companion.Sent s = lastSent;
                    if (!ok || s == null) {
                        chats.remove(id);
                        cc.result.onResult(ChatOutcome.REFUSED,
                                msg == null ? "the radio refused it" : msg);
                        return;
                    }
                    cc.acks.add(s.ackCode);
                    cc.ackDeadline = SystemClock.elapsedRealtime()
                            + Math.max(MIN_ACK_WAIT_MS, Math.min(MAX_ACK_WAIT_MS,
                                    s.timeoutMs))
                            + ACK_MARGIN_MS;
                }, SEND_TIMEOUT_MS, true);
    }

    private void chatTick() {
        long now = SystemClock.elapsedRealtime();
        for (Map.Entry<Integer, Chat> e : new ArrayList<>(chats.entrySet())) {
            Chat c = e.getValue();
            if (c.ackDeadline == 0 || now < c.ackDeadline)
                continue;
            if (c.attempt + 1 < MAX_CHAT_TRIES) {
                c.attempt++;
                c.ackDeadline = 0;
                int id = e.getKey();
                if (c.attempt == MAX_CHAT_TRIES - 1)
                    // Last try: forget the stored route so it floods, as the
                    // MeshCore apps do.
                    enqueue(Companion.resetPath(c.pubKey),
                            (ok, msg) -> sendChatTry(id), CMD_TIMEOUT_MS, false);
                else
                    sendChatTry(id);
            } else {
                chats.remove(e.getKey());
                c.result.onResult(ChatOutcome.UNCONFIRMED, "no acknowledgement after "
                        + MAX_CHAT_TRIES + " tries; it may still have arrived");
            }
        }
        if (chats.isEmpty() || stopped)
            ticking = false;
        else
            h.postDelayed(this::chatTick, 1000);
    }

    /** An ack can come late and more than once; only the first counts. */
    private void confirmChat(long ackCode) {
        for (Map.Entry<Integer, Chat> e : new ArrayList<>(chats.entrySet())) {
            if (e.getValue().acks.contains(ackCode)) {
                chats.remove(e.getKey());
                e.getValue().result.onResult(ChatOutcome.DELIVERED, null);
                return;
            }
        }
    }

    @Override
    public void sendRawData(byte[] path, byte[] payload, Done done) {
        post(() -> enqueue(Companion.sendRawData(path, payload), done,
                SEND_TIMEOUT_MS, false), done);
    }

    @Override
    public void resetPath(byte[] pubKey, Done done) {
        post(() -> enqueue(Companion.resetPath(pubKey), done, CMD_TIMEOUT_MS,
                false), done);
    }

    @Override
    public void sendTeam(List<byte[]> blobs, long gapMs, Done done) {
        int ch = teamChannel;
        if (ch < 0) {
            if (done != null)
                done.done(false, "No team channel picked");
            return;
        }
        sendChannelData(ch, TeamWire.DATA_TYPE, blobs, gapMs, done);
    }

    @Override
    public void publishSelf(byte[] positionPayload) {
        // Direct mode: the plugin beacons itself.
    }
}
