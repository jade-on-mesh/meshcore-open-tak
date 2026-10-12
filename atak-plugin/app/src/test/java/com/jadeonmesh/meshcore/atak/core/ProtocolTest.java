package com.jadeonmesh.meshcore.atak.core;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.List;

import org.junit.Test;

public class ProtocolTest {

    // ---------------------------------------------------------------- voice

    @Test
    public void envelopeRoundTrips() {
        VoiceWire.Envelope e = new VoiceWire.Envelope("a1b2c3d4",
                VoiceWire.Mode.MIMI, 14, 9);
        String s = e.encode();
        assertTrue(s.startsWith("VM1:"));
        VoiceWire.Envelope b = VoiceWire.Envelope.parse(s);
        assertEquals("a1b2c3d4", b.sessionId);
        assertEquals(VoiceWire.Mode.MIMI, b.mode);
        assertEquals(14, b.totalPackets);
        assertEquals(9, b.durationSeconds);
        // A Codec2 mode id under the Mimi prefix is rejected.
        assertNull(VoiceWire.Envelope.parse("VM1:1:1:1:1"));
        assertNull(VoiceWire.Envelope.parse("VE3:zzzzzzzz:1:1:1"));
        VoiceWire.Envelope img = VoiceWire.Envelope
                .parse(new VoiceWire.Envelope("00000001",
                        VoiceWire.Mode.AV1_IMAGE, 3, 133).encode());
        assertTrue(img.isImage());
        assertEquals(1.33, img.imageAspect(), 1e-9);
        // VE3 sample from the published format: sid base36, 1200 bps.
        VoiceWire.Envelope v = VoiceWire.Envelope.parse("VE3:1z141z:1:a:9");
        assertEquals(VoiceWire.Mode.MODE_1200, v.mode);
        assertEquals(10, v.totalPackets);
    }

    @Test
    public void packetsAndFetchRequests() {
        byte[] bits = new byte[400];
        for (int i = 0; i < bits.length; i++)
            bits[i] = (byte) i;
        List<VoiceWire.Packet> ps = VoiceWire.packetize("0000abcd", bits,
                VoiceWire.Mode.MODE_1200);
        assertEquals(3, ps.size()); // 156 + 156 + 88
        byte[] salted = ps.get(1).encode(0x42);
        VoiceWire.Packet q = VoiceWire.Packet.parse(salted);
        assertEquals(1, q.index);
        assertEquals("0000abcd", q.sessionId);
        assertArrayEquals(ps.get(1).codecData, q.codecData);

        VoiceWire.FetchRequest r = new VoiceWire.FetchRequest("0000abcd",
                "010203040506", Arrays.asList(5, 2, 2, 9), true);
        VoiceWire.FetchRequest r2 = VoiceWire.FetchRequest.parse(r.encode());
        assertEquals(Arrays.asList(2, 5, 9), r2.missing);
        assertTrue(r2.saltOk);
        assertEquals("010203040506", r2.requesterKey6);

        String t = VoiceWire.TextRequest.encode(new VoiceWire.FetchRequest(
                "0000abcd", "010203040506", Arrays.asList(1, 2, 3, 7, 40), false));
        assertEquals("VR3:" + Long.toString(0xabcd, 36) + ":m1-3.7.14:010203040506",
                t);
        assertEquals(Arrays.asList(1, 2, 3, 7, 40),
                VoiceWire.TextRequest.parse(t).missing);
        assertNull(VoiceWire.TextRequest.parse("VR3:1:all:010203040506"));
    }

    @Test
    public void mimiPackingRoundTrips() {
        int frames = 13;
        long[] codes = new long[8 * VoiceWire.MIMI_MAX_FRAMES];
        for (int q = 0; q < 8; q++)
            for (int f = 0; f < frames; f++)
                codes[q * VoiceWire.MIMI_MAX_FRAMES + f] = (q * 131 + f * 17) & 0x7FF;
        byte[] packed = VoiceWire.packMimi(codes, frames, VoiceWire.MIMI_MAX_FRAMES);
        assertEquals(frames * 11, packed.length);
        long[] back = VoiceWire.unpackMimi(packed, VoiceWire.MIMI_MAX_FRAMES);
        for (int q = 0; q < 8; q++)
            for (int f = 0; f < frames; f++)
                assertEquals(codes[q * 250 + f], back[q * 250 + f]);
    }

    // ------------------------------------------------------------ companion

    @Test
    public void channelTextV3WithPath() {
        byte[] text = Bytes.utf8("Jade: hello team");
        byte[] f = new byte[6 + 2 + 1 + 4 + text.length + 1];
        f[0] = 17;
        f[1] = 8; // SNR 2.0
        f[2] = 1; // has path
        f[4] = 3; // channel
        f[5] = 2; // 2 hops, 1-byte hashes
        f[6] = (byte) 0xAA;
        f[7] = (byte) 0xBB;
        f[8] = 0; // plain
        Bytes.putU32le(f, 9, 1760000000L);
        System.arraycopy(text, 0, f, 13, text.length);
        Companion.ChannelText m = Companion.ChannelText.parse(f);
        assertEquals(3, m.channel);
        assertEquals(2, m.hops);
        assertEquals("Jade", m.senderName);
        assertEquals("hello team", m.text);
        assertEquals(1760000000L, m.timestamp);
    }

    @Test
    public void directTextV3() {
        byte[] text = Bytes.utf8("VR3:abc:a:010203040506");
        byte[] f = new byte[4 + 6 + 1 + 1 + 4 + text.length + 1];
        f[0] = 16;
        for (int i = 0; i < 6; i++)
            f[4 + i] = (byte) (i + 1);
        f[10] = 0;
        f[11] = 0;
        System.arraycopy(text, 0, f, 16, text.length);
        Companion.DirectText m = Companion.DirectText.parse(f);
        assertEquals("010203040506", m.senderPrefixHex());
        assertEquals("VR3:abc:a:010203040506", m.text);
    }

    @Test
    public void contactAndChannelFrames() {
        byte[] f = new byte[148];
        f[0] = 3;
        for (int i = 0; i < 32; i++)
            f[1 + i] = (byte) (i + 10);
        f[33] = 1;
        f[35] = 2; // 2 hops
        f[36] = 0x11;
        f[37] = 0x22;
        byte[] name = Bytes.utf8("Rover");
        System.arraycopy(name, 0, f, 100, name.length);
        Bytes.putU32le(f, 136, 47_500_000);
        Bytes.putU32le(f, 140, (long) -122_300_000);
        Companion.Contact c = Companion.Contact.parse(f);
        assertEquals("Rover", c.name);
        assertEquals("0a0b0c0d", c.key4());
        assertArrayEquals(new byte[] { 0x11, 0x22 }, c.directRoute());
        assertEquals(47.5, c.lat, 1e-9);
        assertEquals(-122.3, c.lon, 1e-9);

        byte[] ch = new byte[50];
        ch[0] = 18;
        ch[1] = 2;
        byte[] n = Bytes.utf8("Team");
        System.arraycopy(n, 0, ch, 2, n.length);
        ch[34] = 1;
        Companion.Channel cc = Companion.Channel.parse(ch);
        assertEquals("Team", cc.name);
        assertTrue(cc.isPrivate());

        byte[] d = Companion.sendChannelData(2, TeamWire.DATA_TYPE,
                new byte[] { 1, 2 });
        assertArrayEquals(new byte[] { 62, 2, (byte) 0xFF, 0x54, 0x56, 1, 2 }, d);
        byte[] rx = new byte[] { 27, 4, 0, 0, 2, (byte) 0x43, 0x54, 0x56, 2, 9, 8 };
        Companion.ChannelData cd = Companion.ChannelData.parse(rx);
        assertEquals(TeamWire.DATA_TYPE, cd.dataType);
        assertEquals(3, cd.hops());
        assertArrayEquals(new byte[] { 9, 8 }, cd.payload);
    }

    // -------------------------------------------------------------- CoT

    @Test
    public void positionCotRoundTrips() {
        TeamWire.Position p = TeamWireTest.samplePosition();
        XNode ev = CotConvert.position(p, 1760000000000L);
        String xml = ev.toXml();
        XNode back = XNode.parse(xml);
        assertEquals("VOX-c99d98ce", CotConvert.uid(back));
        assertEquals("a-f-G-U-C", CotConvert.type(back));
        TeamWire.Position q = CotConvert.selfPosition(back, "c99d98ce");
        assertEquals("JADE", q.callsign);
        assertEquals(TeamWire.ROLE_MEDIC, q.role);
        assertEquals(12, q.color);
        assertEquals(Integer.valueOf(81), q.batteryPct);
        assertEquals(p.lat, q.lat, 1e-7);
        assertEquals(1.5, q.speedMps, 1e-9);
        assertEquals("c99d98ce", CotConvert.key4FromMemberUid("VOX-c99d98ce"));
        assertNull(CotConvert.key4FromMemberUid("VOX-M-c99d98ce-1"));
    }

    @Test
    public void shapesSurviveCotRoundTrip() {
        for (int kind = 0; kind <= 4; kind++) {
            TeamWire.Shape s = new TeamWire.Shape();
            s.authorKey4 = "0a0b0c0d";
            s.itemId = 7;
            s.kind = kind;
            s.label = "S" + kind;
            s.note = "note";
            s.strokeArgb = 0xFFFF8800;
            s.strokeWidth = 4;
            if (kind == TeamWire.SHAPE_CIRCLE) {
                s.radiusM = 250;
                s.points.add(new double[] { 46.5, -121.5 });
            } else {
                s.points.add(new double[] { 46.5, -121.5 });
                s.points.add(new double[] { 46.51, -121.5 });
                s.points.add(new double[] { 46.51, -121.49 });
                s.points.add(new double[] { 46.5, -121.49 });
            }
            XNode ev = XNode.parse(CotConvert.shape(s, 0).toXml());
            assertTrue(CotConvert.isShapeType(CotConvert.type(ev)));
            TeamWire.Shape q = CotConvert.shapeOut(ev, "0a0b0c0d", 5);
            assertNotNull("kind " + kind, q);
            int expectKind = kind;
            assertEquals(expectKind, q.kind);
            assertEquals(s.points.size(), q.points.size());
            assertEquals("S" + kind, q.label);
            assertEquals(0xFFFF8800, q.strokeArgb);
            if (kind == TeamWire.SHAPE_CIRCLE)
                assertEquals(250, q.radiusM);
        }
    }

    @Test
    public void chatAndPointsAndAlerts() {
        XNode chat = XNode.parse(CotConvert.chat("VOX-01020304", "ROVER", null,
                "hi <all> & you", "m1", 1760000000000L, 47, -122).toXml());
        CotConvert.ChatOut c = CotConvert.chatOut(chat);
        assertTrue(c.toAll);
        assertEquals("hi <all> & you", c.text);

        XNode dm = XNode.parse(CotConvert.chat("VOX-01020304", "ROVER",
                "ANDROID-1", "psst", "m2", 1760000000000L, 47, -122).toXml());
        CotConvert.ChatOut d = CotConvert.chatOut(dm);
        assertFalse(d.toAll);
        assertEquals("VOX-01020304", d.roomId);

        String spot = "<event version=\"2.0\" uid=\"abc-123\" type=\"b-m-p-s-m\" how=\"h-g-i-g-o\" time=\"2026-01-01T00:00:00.000Z\" start=\"2026-01-01T00:00:00.000Z\" stale=\"2026-01-02T00:00:00.000Z\">"
                + "<point lat=\"47.1\" lon=\"-122.1\" hae=\"9999999.0\" ce=\"9999999.0\" le=\"9999999.0\"/>"
                + "<detail><contact callsign=\"R 1\"/><color argb=\"-65536\"/><usericon iconsetpath=\"COT_MAPPING_SPOTMAP/b-m-p-s-m/-65536\"/><remarks>check</remarks></detail></event>";
        XNode sp = XNode.parse(spot);
        TeamWire.Point p = CotConvert.pointOut(sp, "01020304", 100);
        assertEquals("R 1", p.callsign);
        assertEquals(Integer.valueOf(-65536), p.argb);
        assertEquals("check", p.remarks);
        assertNull(p.haeM);
        XNode back = XNode.parse(
                CotConvert.point(TeamWire.Point.parse(p.encode()), 0).toXml());
        assertEquals("b-m-p-s-m", CotConvert.type(back));
        assertEquals("R 1", CotConvert.callsign(back));

        String sos = "<event version=\"2.0\" uid=\"ANDROID-1-9-1-1\" type=\"b-a-o-tbl\" how=\"m-g\"><point lat=\"47\" lon=\"-122\" hae=\"0\" ce=\"9999999\" le=\"9999999\"/>"
                + "<detail><link uid=\"ANDROID-1\" type=\"a-f-G-U-C\" relation=\"p-p\"/><contact callsign=\"JADE-Alert\"/><emergency type=\"911 Alert\">JADE</emergency></detail></event>";
        TeamWire.Alert a = CotConvert.alertOut(XNode.parse(sos), "01020304", 7,
                false);
        assertTrue(a.active);
        assertEquals(TeamWire.ALERT_SOS, a.type);
        assertEquals("JADE", a.callsign);
        XNode ac = XNode.parse(CotConvert.alert(a, 0).toXml());
        assertEquals("VOX-01020304-9-1-1", CotConvert.uid(ac));
        assertEquals("b-a-o-tbl", CotConvert.type(ac));
    }

    @Test
    public void compactStripsNoise() {
        String xml = "<event uid=\"u\" type=\"b-r-f-h-c\" access=\"Undefined\"><point lat=\"1\" lon=\"2\"/><detail><_medevac_ title=\"MED\"/><__serverdestination destinations=\"1.2.3.4\"/><precisionlocation altsrc=\"DTED0\"/></detail></event>";
        String c = CotConvert.compactForMesh(XNode.parse(xml));
        assertTrue(c.contains("_medevac_"));
        assertFalse(c.contains("serverdestination"));
        assertFalse(c.contains("access"));
    }
}
