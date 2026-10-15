package com.jadeonmesh.meshcore.atak.core;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;

/**
 * Plain MeshCore on the ATAK map: every node the radio knows that shares a
 * position, drawn by what it is, and every channel as an ATAK contact so
 * GeoChat can carry it. This is for the mesh beyond the team; team members
 * have their own markers and are skipped here.
 *
 * Ideas from the Colorado Mesh TAK bridge
 * (github.com/Colorado-Mesh/meshcore-tak-bridge), found by testing with ATAK:
 * - Channels and companions are contacts with an endpoint, not chat rooms:
 *   ATAK only lets you message a reachable contact, and its reply names that
 *   contact, so the plugin knows exactly which channel or node it is for.
 *   A contact needs a point; a channel has no place, so it sits at 0, 0.
 * - Channel names all start with "#" so ATAK's alphabetical contact list
 *   keeps them together; private channels get a lock after the "#".
 * - Only companions are reachable. Repeaters and room servers read plain
 *   text from their admin as commands, so they never get an endpoint.
 * - Markers go stale after 10 minutes and are re-sent every 5; a node the
 *   filters drop is deleted at once rather than left to go stale.
 * - A companion with no position on the map becomes a contact at 0, 0 once
 *   a direct message has passed with it, so the conversation can go on.
 *
 * Not thread-safe: the engine calls it from its own thread.
 */
public final class MeshNodes {

    public static final long STALE_MS = 10 * 60_000L;
    public static final long REFRESH_MS = 5 * 60_000L;
    public static final String CHANNEL_UID_PREFIX = CotConvert.UID_PREFIX + "CH-";
    static final String LOCK = "🔒";

    /** Which nodes go on the map. */
    public static final class Filter {
        public boolean companions = true, repeaters = true, rooms = true,
                sensors = true;
        /** Hide nodes whose last advert is older than this; 0 shows all. */
        public long maxAgeSec = 7 * 86400L;
    }

    /** What the map should show, from the radio's current state. */
    public static final class Input {
        public List<Companion.Contact> contacts = new ArrayList<>();
        /** Heard but not saved on the radio: shown, never reachable. */
        public List<Companion.Contact> heard = new ArrayList<>();
        public List<Companion.Channel> channels = new ArrayList<>();
        /** Carried by All Chat Rooms instead; -1 for none. */
        public int teamChannel = -1;
        public boolean showNodes = true;
        public boolean channelContacts = true;
        public Filter filter = new Filter();
        /** Team members and this radio: they have markers of their own. */
        public Set<String> skipKey4 = new HashSet<>();
        /** Full keys (hex) of companions a direct message passed with. */
        public Set<String> talkedTo = new HashSet<>();
    }

    /** Uids we put on the map, with what was sent, to re-send or delete. */
    private final Map<String, String> onMap = new HashMap<>();
    private long lastFullMs = -1;

    public static String channelUid(int index) {
        return CHANNEL_UID_PREFIX + index;
    }

    /** Channel index from a channel contact uid, or -1. */
    public static int channelIndex(String uid) {
        if (uid == null || !uid.startsWith(CHANNEL_UID_PREFIX))
            return -1;
        try {
            int i = Integer.parseInt(uid.substring(CHANNEL_UID_PREFIX.length()));
            return i >= 0 && i < 256 ? i : -1;
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** "#Public", "#name" for hashtag channels, "#🔒 name" for private ones. */
    public static String channelCallsign(Companion.Channel c,
            Collection<Companion.Channel> all) {
        String name = c.name.trim();
        String cs;
        if (c.isPrivate())
            cs = "#" + LOCK + " " + (name.startsWith("#") ? name.substring(1) : name);
        else
            cs = name.startsWith("#") ? name : "#" + name;
        int same = 0;
        for (Companion.Channel o : all)
            if (o.name.trim().equals(name))
                same++;
        return same > 1 ? cs + " (" + c.index + ")" : cs;
    }

    public static boolean isCompanion(Companion.Contact c) {
        return c.type == Companion.ADV_CHAT;
    }

    public static boolean typeShown(int type, Filter f) {
        switch (type) {
            case Companion.ADV_CHAT:
                return f.companions;
            case Companion.ADV_REPEATER:
                return f.repeaters;
            case Companion.ADV_ROOM:
                return f.rooms;
            case Companion.ADV_SENSOR:
                return f.sensors;
            default:
                return true;
        }
    }

    public static boolean hasPosition(Companion.Contact c) {
        return c.lat != null && c.lon != null && (c.lat != 0 || c.lon != 0)
                && Math.abs(c.lat) <= 90 && Math.abs(c.lon) <= 180;
    }

    /** On the map under [f]? An advert dated in the future counts as fresh. */
    public static boolean shown(Companion.Contact c, Filter f, long nowSec) {
        if (!hasPosition(c) || !typeShown(c.type, f))
            return false;
        return f.maxAgeSec <= 0 || nowSec - c.lastAdvert <= f.maxAgeSec;
    }

    static String cotType(int type) {
        switch (type) {
            case Companion.ADV_CHAT:
                return "a-f-G-U-C";
            case Companion.ADV_REPEATER:
            case Companion.ADV_ROOM:
                return "a-f-G-I";
            case Companion.ADV_SENSOR:
                return "a-f-G-E-S";
            default:
                return "a-f-G";
        }
    }

    static String kind(int type) {
        switch (type) {
            case Companion.ADV_CHAT:
                return "companion";
            case Companion.ADV_REPEATER:
                return "repeater";
            case Companion.ADV_ROOM:
                return "room server";
            case Companion.ADV_SENSOR:
                return "sensor";
            default:
                return "node";
        }
    }

    private static String utc(long sec) {
        SimpleDateFormat f = new SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US);
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return f.format(new Date(sec * 1000));
    }

    /**
     * The events that bring ATAK up to date: changed or new items, everything
     * again when [REFRESH_MS] has passed (so nothing goes stale), and deletes
     * for items no longer shown.
     */
    public List<XNode> update(Input in, long nowMs) {
        boolean full = lastFullMs < 0 || nowMs - lastFullMs >= REFRESH_MS;
        if (full)
            lastFullMs = nowMs;
        long nowSec = nowMs / 1000;
        Map<String, XNode> want = new HashMap<>();
        Map<String, String> sig = new HashMap<>();

        if (in.channelContacts) {
            for (Companion.Channel ch : in.channels) {
                if (ch.isEmpty() || ch.index == in.teamChannel)
                    continue;
                String uid = channelUid(ch.index);
                String cs = channelCallsign(ch, in.channels);
                XNode ev = CotConvert.event(uid, "a-f-G-U-C", "h-e", 0, 0, null,
                        null, nowMs, STALE_MS);
                XNode d = CotConvert.detail(ev);
                d.add("contact").attr("callsign", cs).attr("endpoint",
                        CotConvert.MESH_ENDPOINT);
                d.add("remarks").text("MeshCore channel " + ch.index
                        + (ch.isPrivate() ? " (private)" : ch.isPublic()
                                ? " (public: anyone can read it)"
                                : " (hashtag: anyone can join it)"));
                want.put(uid, ev);
                sig.put(uid, "ch|" + cs);
            }
        }

        Set<String> seen = new HashSet<>();
        List<Companion.Contact> all = new ArrayList<>(in.contacts);
        all.addAll(in.heard);
        for (Companion.Contact c : all) {
            String key4 = c.key4();
            if (!seen.add(key4) || in.skipKey4.contains(key4))
                continue;
            boolean onRadio = in.contacts.contains(c);
            boolean reachable = onRadio && isCompanion(c);
            String uid = CotConvert.memberUid(key4);
            String name = c.name.isEmpty() ? key4.toUpperCase(Locale.US) : c.name;
            if (in.showNodes && shown(c, in.filter, nowSec)) {
                XNode ev = CotConvert.event(uid, cotType(c.type), "h-e", c.lat,
                        c.lon, null, null, nowMs, STALE_MS);
                XNode d = CotConvert.detail(ev);
                XNode contact = d.add("contact").attr("callsign", name);
                if (reachable)
                    contact.attr("endpoint", CotConvert.MESH_ENDPOINT);
                String remarks = "MeshCore " + kind(c.type) + " \u00b7 advert "
                        + utc(c.lastAdvert) + " UTC"
                        + (onRadio ? "" : " (heard, not saved on the radio)");
                d.add("remarks").text(remarks);
                want.put(uid, ev);
                sig.put(uid, "n|" + c.type + "|" + name + "|" + c.lat + "|" + c.lon
                        + "|" + c.lastAdvert + "|" + reachable);
            } else if (reachable && in.talkedTo.contains(c.keyHex())) {
                // Off the map but in a conversation: keep it reachable.
                XNode ev = CotConvert.event(uid, "a-f-G-U-C", "h-e", 0, 0, null,
                        null, nowMs, STALE_MS);
                XNode d = CotConvert.detail(ev);
                d.add("contact").attr("callsign", name).attr("endpoint",
                        CotConvert.MESH_ENDPOINT);
                d.add("remarks").text("MeshCore companion (no position shared);"
                        + " kept here so you can reply");
                want.put(uid, ev);
                sig.put(uid, "dm|" + name);
            }
        }

        List<XNode> out = new ArrayList<>();
        for (Map.Entry<String, XNode> e : want.entrySet()) {
            String s = sig.get(e.getKey());
            if (full || !s.equals(onMap.get(e.getKey())))
                out.add(e.getValue());
            onMap.put(e.getKey(), s);
        }
        for (String uid : new ArrayList<>(onMap.keySet())) {
            if (want.containsKey(uid))
                continue;
            onMap.remove(uid);
            // A node that became a team member keeps its uid: the team marker
            // replaces ours, so it must not be deleted.
            String k4 = CotConvert.key4FromMemberUid(uid);
            if (k4 == null || !in.skipKey4.contains(k4))
                out.add(CotConvert.delete(uid, nowMs));
        }
        return out;
    }

    /** Deletes everything this put on the map (radio changed or link off). */
    public List<XNode> clear(long nowMs) {
        List<XNode> out = new ArrayList<>();
        for (String uid : onMap.keySet())
            out.add(CotConvert.delete(uid, nowMs));
        onMap.clear();
        lastFullMs = -1;
        return out;
    }

    public boolean has(String uid) {
        return onMap.containsKey(uid);
    }

    public int count() {
        return onMap.size();
    }
}
