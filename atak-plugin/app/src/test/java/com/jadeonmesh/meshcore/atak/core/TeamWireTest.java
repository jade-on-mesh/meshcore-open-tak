package com.jadeonmesh.meshcore.atak.core;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Random;

import org.junit.Test;

public class TeamWireTest {

    static String repeat(char c, int n) {
        char[] a = new char[n];
        java.util.Arrays.fill(a, c);
        return new String(a);
    }

    // Golden vectors. test/team/atak_wire_test.dart asserts the app encodes
    // the same inputs to the same bytes, so the two implementations agree.
    static final String GOLDEN_POSITION = "50c99d98ce0b1c60218fb7159b7c00380340045"
            + "12c03044a414445";
    static final String GOLDEN_SHAPE = "470a0b0c0d00000063000101ff00ff004000ff0068e778"
            + "020506417265612042000402cd29c0f8ba6d80d00f0000a01fcf0f00";

    static TeamWire.Position samplePosition() {
        TeamWire.Position p = new TeamWire.Position();
        p.senderKey4 = "c99d98ce";
        p.lat = 47.6062095;
        p.lon = -122.3320708;
        p.altitudeM = 56;
        p.speedMps = 1.5;
        p.headingDeg = 90.0;
        p.accuracyM = 4;
        p.batteryPct = 81;
        p.role = TeamWire.ROLE_MEDIC;
        p.color = 12;
        p.status = 3;
        p.callsign = "JADE";
        p.sosActive = true;
        return p;
    }

    @Test
    public void positionRoundTrips() {
        TeamWire.Position p = samplePosition();
        byte[] b = p.encode();
        TeamWire.Position q = TeamWire.Position.parse(b);
        assertNotNull(q);
        assertEquals("c99d98ce", q.senderKey4);
        assertEquals(p.lat, q.lat, 1e-6);
        assertEquals(p.lon, q.lon, 1e-6);
        assertEquals(Integer.valueOf(56), q.altitudeM);
        assertEquals(1.5, q.speedMps, 1e-9);
        assertEquals(90, q.headingDeg, 1.5);
        assertEquals(Integer.valueOf(81), q.batteryPct);
        assertEquals(TeamWire.ROLE_MEDIC, q.role);
        assertEquals(12, q.color);
        assertEquals(3, q.status);
        assertEquals("JADE", q.callsign);
        assertTrue(q.sosActive);
        assertFalse(q.relayed);
        assertEquals(TeamWire.MSG_POSITION, TeamWire.peekType(b));
    }

    @Test
    public void positionOptionalFieldsAndTruncation() {
        TeamWire.Position p = new TeamWire.Position();
        p.senderKey4 = "00000001";
        p.lat = -33.9;
        p.lon = 151.2;
        p.callsign = repeat('x', 40);
        p.relayed = true;
        byte[] b = p.encode();
        assertTrue(b.length <= 25 + 1 + TeamWire.MAX_CALLSIGN);
        TeamWire.Position q = TeamWire.Position.parse(b);
        assertNull(q.altitudeM);
        assertNull(q.speedMps);
        assertNull(q.batteryPct);
        assertTrue(q.relayed);
        assertEquals(TeamWire.MAX_CALLSIGN, q.callsign.length());
    }

    @Test
    public void rejectsGarbage() {
        assertNull(TeamWire.Position.parse(new byte[] { 0x50, 1, 2 }));
        assertEquals(-1, TeamWire.peekType(new byte[] { (byte) 0x99, 1, 2, 3, 4 }));
        assertNull(TeamWire.Shape.parse(new byte[] { 0x47, 1, 2, 3, 4, 5 }));
        Random r = new Random(7);
        for (int i = 0; i < 2000; i++) {
            byte[] junk = new byte[r.nextInt(170)];
            r.nextBytes(junk);
            if (junk.length > 0)
                junk[0] = (byte) new int[] { 0x50, 0x53, 0x4D, 0x52, 0x4F, 0x47,
                        0x58 }[r.nextInt(7)];
            // Must never throw.
            TeamWire.Position.parse(junk);
            TeamWire.Alert.parse(junk);
            TeamWire.Marker.parse(junk);
            TeamWire.Report.parse(junk);
            TeamWire.Point.parse(junk);
            TeamWire.Shape.parse(junk);
        }
    }

    @Test
    public void utf8TruncationNeverSplitsCharacters() {
        byte[] b = Bytes.truncateUtf8("abééé", 4);
        assertEquals("abé", Bytes.utf8(b, 0, b.length));
    }

    @Test
    public void alertRoundTrips() {
        TeamWire.Alert a = new TeamWire.Alert();
        a.senderKey4 = "abcdef01";
        a.alertId = 4321;
        a.active = true;
        a.type = TeamWire.ALERT_IN_CONTACT;
        a.lat = 45.5;
        a.lon = -122.6;
        a.accuracyM = 8;
        a.callsign = "ROVER";
        a.note = "Two vehicles at the gate";
        TeamWire.Alert b = TeamWire.Alert.parse(a.encode());
        assertEquals(TeamWire.ALERT_IN_CONTACT, b.type);
        assertTrue(b.active);
        assertEquals(4321, b.alertId);
        assertEquals(45.5, b.lat, 1e-6);
        assertEquals(a.note, b.note);
        assertEquals("abcdef01:4321", b.key());

        TeamWire.Alert c = new TeamWire.Alert();
        c.senderKey4 = "abcdef01";
        c.alertId = 1;
        TeamWire.Alert d = TeamWire.Alert.parse(c.encode());
        assertNull(d.lat);
        assertFalse(d.active);
    }

    @Test
    public void markerRoundTripsWithAttachment() {
        TeamWire.Marker m = new TeamWire.Marker();
        m.authorKey4 = "01020304";
        m.markerId = 0xDEADBEEFL;
        m.kind = 5;
        m.lat = 46.85;
        m.lon = -121.76;
        m.timeSec = 1760000000L;
        m.label = "LZ Paradise";
        m.note = "Flat meadow, wind from the west";
        m.attachment = new TeamWire.Attachment(40, "a1b2c3d4", 18, 133);
        TeamWire.Marker b = TeamWire.Marker.parse(m.encode());
        assertEquals(m.key(), b.key());
        assertEquals("01020304:deadbeef", b.key());
        assertEquals(5, b.kind);
        assertEquals("LZ Paradise", b.label);
        assertEquals(1760000000L, b.timeSec);
        assertEquals("a1b2c3d4", b.attachment.sessionId);
        assertEquals(18, b.attachment.packets);
        assertEquals(133, b.attachment.extra);

        TeamWire.Marker big = new TeamWire.Marker();
        big.authorKey4 = "01020304";
        big.markerId = 1;
        big.kind = 4;
        big.label = repeat('x', 100);
        big.note = repeat('y', 200);
        big.attachment = new TeamWire.Attachment(32, "ffffffff", 255, 65535);
        assertTrue(big.encode().length <= TeamWire.MAX_PAYLOAD);
    }

    @Test
    public void reportRoundTrips() {
        TeamWire.Report r = new TeamWire.Report();
        r.authorKey4 = "11223344";
        r.reportId = 77;
        r.urgency = 3;
        r.affiliation = 1;
        r.lat = 47.3;
        r.lon = -122.2;
        r.observedSec = 1760000000L;
        r.vehicles = 3;
        r.people = 5;
        r.place = "Auburn E Main St";
        r.activity = "Moving north";
        TeamWire.Report b = TeamWire.Report.parse(r.encode());
        assertEquals(3, b.urgency);
        assertEquals(1, b.affiliation);
        assertEquals(5, b.people);
        assertEquals("Auburn E Main St", b.place);
        assertNull(b.attachment);
        assertTrue(b.summary().startsWith("CRITICAL hostile / S: 3-"));
    }

    @Test
    public void pointRoundTripsAndFits() {
        TeamWire.Point p = new TeamWire.Point();
        p.authorKey4 = "0a0b0c0d";
        p.itemId = 0x12345678L;
        p.lat = 47.1;
        p.lon = -121.9;
        p.haeM = 1234;
        p.argb = 0xFFFF0000;
        p.timeSec = 1760000001L;
        p.cotType = "a-h-G-U-C-I";
        p.callsign = "Hostile 1";
        p.remarks = "Seen near the ridge";
        p.iconset = "COT_MAPPING_2525B/a-h/a-h-G-U-C-I";
        p.attachment = new TeamWire.Attachment(40, "01020304", 3, 150);
        byte[] b = p.encode();
        assertTrue(b.length <= TeamWire.MAX_PAYLOAD);
        TeamWire.Point q = TeamWire.Point.parse(b);
        assertEquals("a-h-G-U-C-I", q.cotType);
        assertEquals("Hostile 1", q.callsign);
        assertEquals(Integer.valueOf(1234), q.haeM);
        assertEquals(Integer.valueOf(0xFFFF0000), q.argb);
        assertEquals("Seen near the ridge", q.remarks);
        assertEquals(p.iconset, q.iconset);
        assertEquals("01020304", q.attachment.sessionId);

        p.remarks = repeat('r', 300);
        b = p.encode();
        assertTrue(b.length <= TeamWire.MAX_PAYLOAD);
        q = TeamWire.Point.parse(b);
        assertNotNull(q);
        assertEquals(p.iconset, q.iconset);
        assertNotNull(q.attachment);
    }

    @Test
    public void shapeRoundTripsAndSimplifiesToFit() {
        TeamWire.Shape s = new TeamWire.Shape();
        s.authorKey4 = "0a0b0c0d";
        s.itemId = 99;
        s.kind = TeamWire.SHAPE_POLYGON;
        s.strokeArgb = 0xFF00FF00;
        s.fillArgb = 0x4000FF00;
        s.timeSec = 1760000002L;
        s.strokeWidth = 2.5;
        s.label = "Search area B";
        s.points.add(new double[] { 47.0, -122.0 });
        s.points.add(new double[] { 47.001, -122.0 });
        s.points.add(new double[] { 47.001, -121.998 });
        s.points.add(new double[] { 47.0, -121.998 });
        TeamWire.Shape q = TeamWire.Shape.parse(s.encode());
        assertEquals(4, q.points.size());
        assertEquals(47.001, q.points.get(2)[0], 1e-6);
        assertEquals(-121.998, q.points.get(2)[1], 1e-6);
        assertEquals(Integer.valueOf(0x4000FF00), q.fillArgb);
        assertEquals(2.5, q.strokeWidth, 1e-9);

        // A long wiggly route still fits one packet.
        TeamWire.Shape r = new TeamWire.Shape();
        r.authorKey4 = "0a0b0c0d";
        r.itemId = 100;
        r.kind = TeamWire.SHAPE_ROUTE;
        Random rnd = new Random(3);
        double la = 47, lo = -122;
        for (int i = 0; i < 120; i++) {
            la += (rnd.nextDouble() - 0.4) * 0.01;
            lo += (rnd.nextDouble() - 0.4) * 0.01;
            r.points.add(new double[] { la, lo });
        }
        assertTrue(r.needsSimplifying());
        byte[] b = r.encode();
        assertNotNull(b);
        assertTrue(b.length <= TeamWire.MAX_PAYLOAD);
        TeamWire.Shape rq = TeamWire.Shape.parse(b);
        assertEquals(47.0, 47.0, 0);
        assertArrayEquals(r.points.get(0), rq.points.get(0), 1e-6);
        assertArrayEquals(r.points.get(119), rq.points.get(rq.points.size() - 1),
                1e-6);

        TeamWire.Shape c = new TeamWire.Shape();
        c.authorKey4 = "0a0b0c0d";
        c.itemId = 5;
        c.kind = TeamWire.SHAPE_CIRCLE;
        c.radiusM = 1500;
        c.points.add(new double[] { 45.0, -120.0 });
        TeamWire.Shape cq = TeamWire.Shape.parse(c.encode());
        assertEquals(1500, cq.radiusM);
        assertEquals(1, cq.points.size());
    }

    @Test
    public void blobChunksReassembleAndRecoverOneLoss() {
        byte[] data = new byte[1000];
        new Random(1).nextBytes(data);
        byte[] payload = Blob.pack(new Blob.Content(Blob.KIND_FILE, "a.bin", data));
        List<byte[]> chunks = Blob.chunk("01020304", 0x4242, payload);
        assertEquals(Blob.packetsFor(payload.length), chunks.size());
        for (byte[] c : chunks)
            assertTrue(c.length <= TeamWire.MAX_PAYLOAD);

        for (int drop = 0; drop < chunks.size(); drop++) {
            Blob.Reassembler r = new Blob.Reassembler();
            List<byte[]> order = new ArrayList<>(chunks);
            order.remove(drop);
            Collections.shuffle(order, new Random(drop));
            byte[] out = null;
            for (byte[] c : order) {
                byte[] got = r.accept(c, 1000);
                if (got != null)
                    out = got;
            }
            assertNotNull("drop " + drop, out);
            Blob.Content back = Blob.unpack(out);
            assertEquals("a.bin", back.name);
            assertArrayEquals(data, back.data);
            // Duplicates after completion are ignored.
            assertNull(r.accept(chunks.get(0), 2000));
        }

        String xml = "<event version=\"2.0\" uid=\"x\" type=\"b-r-f-h-c\">"
                + repeat('a', 2000) + "</event>";
        byte[] cot = Blob.pack(new Blob.Content(Blob.KIND_COT, "",
                Bytes.utf8(xml)));
        assertTrue(cot.length < 200); // compresses
        Blob.Content c = Blob.unpack(cot);
        assertEquals(xml, Bytes.utf8(c.data, 0, c.data.length));
    }

    @Test
    public void varintsRoundTrip() {
        long[] vals = { 0, 1, -1, 63, -64, 64, 1000000, -1000000,
                Integer.MAX_VALUE, Integer.MIN_VALUE };
        Bytes.W w = new Bytes.W();
        for (long v : vals)
            w.svar(v);
        Bytes.R r = new Bytes.R(w.done());
        for (long v : vals)
            assertEquals(v, r.svar());
    }

    @Test
    public void beaconPolicy() {
        TeamWire.BeaconPolicy b = new TeamWire.BeaconPolicy();
        assertTrue(b.shouldSend(-1, 0, 0, 0));
        assertFalse(b.shouldSend(10_000, 500, 5, 90));
        assertTrue(b.shouldSend(31_000, 0, 2, 40));
        assertFalse(b.shouldSend(60_000, 10, 0, 0));
        assertTrue(b.shouldSend(600_000, 0, 0, 0));
        assertTrue(b.shouldSend(50_000, 80, 0, 0));
    }

    @Test
    public void goldenVectors() {
        assertEquals(GOLDEN_POSITION, Bytes.hex(samplePosition().encode()));
        TeamWire.Shape s = new TeamWire.Shape();
        s.authorKey4 = "0a0b0c0d";
        s.itemId = 99;
        s.kind = TeamWire.SHAPE_POLYGON;
        s.strokeArgb = 0xFF00FF00;
        s.fillArgb = 0x4000FF00;
        s.timeSec = 1760000002L;
        s.strokeWidth = 2.5;
        s.label = "Area B";
        s.points.add(new double[] { 47.0, -122.0 });
        s.points.add(new double[] { 47.001, -122.0 });
        s.points.add(new double[] { 47.001, -121.998 });
        s.points.add(new double[] { 47.0, -121.998 });
        assertEquals(GOLDEN_SHAPE, Bytes.hex(s.encode()));
    }
}
