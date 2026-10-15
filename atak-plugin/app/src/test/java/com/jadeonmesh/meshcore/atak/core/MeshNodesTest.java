package com.jadeonmesh.meshcore.atak.core;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.junit.Test;

public class MeshNodesTest {

    static final long NOW_MS = 1_790_000_000_000L;
    static final long NOW_S = NOW_MS / 1000;

    static Companion.Contact node(int keyByte, int type, String name, Double lat,
            Double lon, long advertSec) {
        Companion.Contact c = new Companion.Contact();
        c.publicKey = new byte[32];
        Arrays.fill(c.publicKey, (byte) keyByte);
        c.type = type;
        c.name = name;
        c.lat = lat;
        c.lon = lon;
        c.lastAdvert = advertSec;
        return c;
    }

    static Companion.Channel channel(int index, String name, byte[] psk) {
        Companion.Channel c = new Companion.Channel();
        c.index = index;
        c.name = name;
        c.psk = psk;
        return c;
    }

    static byte[] privateKey() {
        byte[] k = new byte[16];
        Arrays.fill(k, (byte) 0x5a);
        return k;
    }

    static Map<String, XNode> byUid(List<XNode> evs) {
        Map<String, XNode> m = new HashMap<>();
        for (XNode e : evs)
            m.put(e.get("uid"), e);
        return m;
    }

    @Test
    public void channelKinds() {
        Companion.Channel pub = channel(0, "Public",
                Bytes.unhex(Companion.PUBLIC_CHANNEL_PSK));
        assertTrue(pub.isPublic());
        assertFalse(pub.isPrivate());
        Companion.Channel tag = channel(1, "#den",
                Companion.Channel.hashtagKey("#den"));
        assertTrue(tag.isHashtag());
        assertFalse(tag.isPrivate());
        // A #name with its own key is private.
        Companion.Channel ownKey = channel(2, "#ops", privateKey());
        assertFalse(ownKey.isHashtag());
        assertTrue(ownKey.isPrivate());
        // A key derived from a lower-cased name still counts as hashtag
        // (when unsure, treat it as readable by strangers).
        Companion.Channel cased = channel(3, "#Den",
                Companion.Channel.hashtagKey("#den"));
        assertTrue(cased.isHashtag());
        // Known value: SHA-256("#test")[0..16].
        assertEquals("9cd8fcf22a47333b591d96a2b848b73f",
                Bytes.hex(Companion.Channel.hashtagKey("#test")));
    }

    @Test
    public void channelCallsigns() {
        List<Companion.Channel> all = new ArrayList<>();
        all.add(channel(0, "Public", Bytes.unhex(Companion.PUBLIC_CHANNEL_PSK)));
        all.add(channel(1, "#den", Companion.Channel.hashtagKey("#den")));
        all.add(channel(2, "SAR Team", privateKey()));
        all.add(channel(3, "Dup", privateKey()));
        all.add(channel(4, "Dup", privateKey()));
        assertEquals("#Public", MeshNodes.channelCallsign(all.get(0), all));
        assertEquals("#den", MeshNodes.channelCallsign(all.get(1), all));
        assertEquals("#" + MeshNodes.LOCK + " SAR Team",
                MeshNodes.channelCallsign(all.get(2), all));
        assertEquals("#" + MeshNodes.LOCK + " Dup (4)",
                MeshNodes.channelCallsign(all.get(4), all));
        assertEquals(3, MeshNodes.channelIndex(MeshNodes.channelUid(3)));
        assertEquals(-1, MeshNodes.channelIndex("VOX-0a1b2c3d"));
        assertEquals(-1, MeshNodes.channelIndex("VOX-CH-x"));
        // A channel uid is never mistaken for a member uid.
        assertNull(CotConvert.key4FromMemberUid(MeshNodes.channelUid(255)));
    }

    @Test
    public void filters() {
        MeshNodes.Filter f = new MeshNodes.Filter();
        Companion.Contact fresh = node(1, Companion.ADV_REPEATER, "R", 40.0, -105.0,
                NOW_S - 3600);
        Companion.Contact old = node(2, Companion.ADV_REPEATER, "Old", 40.0, -105.0,
                NOW_S - 8 * 86400);
        Companion.Contact future = node(3, Companion.ADV_CHAT, "Clock", 40.0,
                -105.0, NOW_S + 86400 * 30);
        Companion.Contact nowhere = node(4, Companion.ADV_CHAT, "NoGps", null, null,
                NOW_S);
        Companion.Contact zero = node(5, Companion.ADV_CHAT, "Zero", 0.0, 0.0, NOW_S);
        assertTrue(MeshNodes.shown(fresh, f, NOW_S));
        assertFalse(MeshNodes.shown(old, f, NOW_S));
        assertTrue(MeshNodes.shown(future, f, NOW_S));
        assertFalse(MeshNodes.shown(nowhere, f, NOW_S));
        assertFalse(MeshNodes.shown(zero, f, NOW_S));
        f.maxAgeSec = 0;
        assertTrue(MeshNodes.shown(old, f, NOW_S));
        f.repeaters = false;
        assertFalse(MeshNodes.shown(fresh, f, NOW_S));
    }

    @Test
    public void markersByKindAndReachability() {
        MeshNodes.Input in = new MeshNodes.Input();
        Companion.Contact comp = node(0x11, Companion.ADV_CHAT, "Alice", 39.7, -105.0,
                NOW_S);
        Companion.Contact rpt = node(0x22, Companion.ADV_REPEATER, "Peak", 39.8,
                -105.5, NOW_S);
        Companion.Contact room = node(0x33, Companion.ADV_ROOM, "BBS", 39.9, -105.1,
                NOW_S);
        Companion.Contact sensor = node(0x44, Companion.ADV_SENSOR, "Wx", 39.6,
                -105.2, NOW_S);
        Companion.Contact heard = node(0x55, Companion.ADV_CHAT, "Bob", 39.5, -105.3,
                NOW_S);
        in.contacts.addAll(Arrays.asList(comp, rpt, room, sensor));
        in.heard.add(heard);
        Map<String, XNode> m = byUid(new MeshNodes().update(in, NOW_MS));
        assertEquals(5, m.size());

        XNode a = m.get(CotConvert.memberUid(comp.key4()));
        assertEquals("a-f-G-U-C", a.get("type"));
        assertEquals(CotConvert.MESH_ENDPOINT, a.path("detail/contact").get("endpoint"));

        XNode r = m.get(CotConvert.memberUid(rpt.key4()));
        assertEquals("a-f-G-I", r.get("type"));
        // Repeaters and room servers are never reachable for chat.
        assertNull(r.path("detail/contact").get("endpoint"));
        XNode bbs = m.get(CotConvert.memberUid(room.key4()));
        assertEquals("a-f-G-I", bbs.get("type"));
        assertNull(bbs.path("detail/contact").get("endpoint"));
        assertEquals("a-f-G-E-S", m.get(CotConvert.memberUid(sensor.key4())).get("type"));

        // Heard but not saved on the radio: shown, but can't be messaged.
        XNode b = m.get(CotConvert.memberUid(heard.key4()));
        assertNull(b.path("detail/contact").get("endpoint"));
        assertTrue(CotConvert.remarks(b).contains("not saved"));
        assertTrue(CotConvert.remarks(a).startsWith("MeshCore companion"));
        assertTrue(CotConvert.remarks(a).contains("UTC"));
    }

    @Test
    public void channelsAsContactsSkipTeamChannel() {
        MeshNodes.Input in = new MeshNodes.Input();
        in.channels.add(channel(0, "Public", Bytes.unhex(Companion.PUBLIC_CHANNEL_PSK)));
        in.channels.add(channel(1, "Team", privateKey()));
        in.channels.add(channel(2, "", new byte[16])); // empty slot
        in.teamChannel = 1;
        Map<String, XNode> m = byUid(new MeshNodes().update(in, NOW_MS));
        assertEquals(1, m.size());
        XNode pub = m.get(MeshNodes.channelUid(0));
        assertNotNull(pub);
        assertEquals("#Public", CotConvert.callsign(pub));
        assertEquals(CotConvert.MESH_ENDPOINT,
                pub.path("detail/contact").get("endpoint"));
        in.channelContacts = false;
        MeshNodes mn = new MeshNodes();
        assertTrue(mn.update(in, NOW_MS).isEmpty());
    }

    @Test
    public void deletesAndRefresh() {
        MeshNodes mn = new MeshNodes();
        MeshNodes.Input in = new MeshNodes.Input();
        Companion.Contact a = node(0x11, Companion.ADV_CHAT, "Alice", 39.7, -105.0,
                NOW_S);
        Companion.Contact r = node(0x22, Companion.ADV_REPEATER, "Peak", 39.8, -105.5,
                NOW_S);
        in.contacts.addAll(Arrays.asList(a, r));
        assertEquals(2, mn.update(in, NOW_MS).size());
        // Nothing changed, refresh not due: nothing sent.
        assertTrue(mn.update(in, NOW_MS + 60_000).isEmpty());
        // Refresh due: everything again, before ATAK's 10 minute stale.
        assertEquals(2, mn.update(in, NOW_MS + MeshNodes.REFRESH_MS).size());
        // Filtered out: deleted at once.
        in.filter.repeaters = false;
        List<XNode> out = mn.update(in, NOW_MS + MeshNodes.REFRESH_MS + 1000);
        assertEquals(1, out.size());
        assertEquals("t-x-d-d", out.get(0).get("type"));
        assertEquals(CotConvert.memberUid(r.key4()),
                out.get(0).path("detail/link").get("uid"));
        // A node that became a team member keeps its uid: not deleted.
        in.skipKey4.add(a.key4());
        assertTrue(mn.update(in, NOW_MS + MeshNodes.REFRESH_MS + 2000).isEmpty());
        assertEquals(0, mn.count());
    }

    @Test
    public void talkedToCompanionStaysReachable() {
        MeshNodes mn = new MeshNodes();
        MeshNodes.Input in = new MeshNodes.Input();
        Companion.Contact c = node(0x66, Companion.ADV_CHAT, "Carol", null, null,
                NOW_S);
        Companion.Contact rpt = node(0x77, Companion.ADV_REPEATER, "Hill", null, null,
                NOW_S);
        in.contacts.addAll(Arrays.asList(c, rpt));
        assertTrue(mn.update(in, NOW_MS).isEmpty());
        in.talkedTo.add(c.keyHex());
        in.talkedTo.add(rpt.keyHex());
        Map<String, XNode> m = byUid(mn.update(in, NOW_MS + 1000));
        assertEquals(1, m.size()); // never a repeater
        XNode x = m.get(CotConvert.memberUid(c.key4()));
        assertEquals(CotConvert.MESH_ENDPOINT, x.path("detail/contact").get("endpoint"));
        assertEquals(0.0, CotConvert.lat(x), 0);
    }

    @Test
    public void recentKeysDropRepeatsWithinWindow() {
        long[] t = { 0 };
        RecentKeys k = new RecentKeys(3, 1000, () -> t[0]);
        assertTrue(k.firstTime("a"));
        assertFalse(k.firstTime("a"));
        t[0] = 1001;
        assertTrue(k.firstTime("a")); // forgotten after the window
        assertTrue(k.firstTime("b"));
        assertTrue(k.firstTime("c"));
        assertTrue(k.firstTime("d"));
        assertTrue(k.size() <= 3);
    }

    @Test
    public void chatRetryKeepsTimestampAndCountsAttempts() {
        byte[] key = new byte[32];
        Arrays.fill(key, (byte) 0xab);
        byte[] f0 = Companion.sendText(key, "hi", 0, 0x01020304L);
        byte[] f2 = Companion.sendText(key, "hi", 2, 0x01020304L);
        assertEquals(Companion.CMD_SEND_TXT_MSG, f0[0] & 0xFF);
        assertEquals(0, f0[2]);
        assertEquals(2, f2[2]);
        assertArrayEquals(Arrays.copyOfRange(f0, 3, 7), Arrays.copyOfRange(f2, 3, 7));
        assertEquals(0x04, f0[3]);
        // Attempt is clamped to the protocol's two bits.
        assertEquals(3, Companion.sendText(key, "hi", 9, 1)[2]);
        assertArrayEquals(new byte[] { 4, 0x10, 0, 0, 0 }, Companion.getContacts(16));
        assertArrayEquals(new byte[] { 4 }, Companion.getContacts(0));
        assertEquals(0x0a0b0c0dL, Companion.endOfContactsLastMod(
                new byte[] { 4, 0x0d, 0x0c, 0x0b, 0x0a }));
        long[] ack = Companion.sendConfirmed(new byte[] { (byte) 0x82, 1, 2, 3, 4,
                (byte) 0xe8, 3, 0, 0 });
        assertEquals(0x04030201L, ack[0]);
        assertEquals(1000L, ack[1]);
    }
}
