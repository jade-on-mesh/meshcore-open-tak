package com.jadeonmesh.meshcore.atak.core;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * MeshCore Open TAK team wire formats (Java port of lib/team/team_wire.dart),
 * plus the ATAK plugin's additions. Every message is one GRP_DATA blob on the
 * team channel with data type {@link #DATA_TYPE}. Integers are big-endian,
 * coordinates are degrees x 1e7 unless noted.
 *
 * <pre>
 *   position [0x50][key4][flags][lat][lon][alt i16][speed][heading][acc]
 *            [battery][role&lt;&lt;4|colour][status][callsign]
 *   alert    [0x53][key4][alertId u16][type&lt;&lt;4|flags][lat][lon][acc]
 *            [callsign][note]
 *   marker   [0x4D][key4][markerId u32][op][kind][lat][lon][time u32]
 *            [label][note][attachMode][sid4][packets][extra u16]
 *   report   [0x52][key4][reportId u32][kind&lt;&lt;4|urgency][affiliation]
 *            [lat][lon][observed u32][vehicles][people][place][size]
 *            [activity][unit][equipment][attachment]
 *
 *   ATAK plugin additions:
 *   point    [0x4F][key4][itemId u32][op][flags][lat][lon][time u32]
 *            [hae i16]? [argb u32]? [type][callsign][remarks][iconset]?
 *            [attachment]?            (any single-point CoT: spot markers,
 *                                      waypoints, 2525 units, SPIs)
 *   shape    [0x47][key4][itemId u32][op][kind][flags][stroke argb u32]
 *            [fill argb u32]? [time u32][width*2 u8][label][note]
 *            [radius uvar m]? [n uvar][lat0 i32 1e6][lon0 i32 1e6]
 *            [n-1 x (dlat svar, dlon svar) 1e6]
 *   chunk    [0x58][key4][xferId u16][idx][total][body]  (see {@link Blob})
 * </pre>
 */
public final class TeamWire {
    private TeamWire() {
    }

    /** GRP_DATA data type for team traffic ('VT'). */
    public static final int DATA_TYPE = 0x5654;

    public static final int MSG_POSITION = 0x50;
    public static final int MSG_ALERT = 0x53;
    public static final int MSG_MARKER = 0x4D;
    public static final int MSG_REPORT = 0x52;
    public static final int MSG_POINT = 0x4F;   // 0x43 is the app's CASEVAC 9-line
    public static final int MSG_SHAPE = 0x47;
    public static final int MSG_CHUNK = 0x58;

    /** Largest GRP_DATA payload the firmware accepts. */
    public static final int MAX_PAYLOAD = 163;

    public static final int MAX_CALLSIGN = 20;
    public static final int MAX_LABEL = 32;
    public static final int MAX_NOTE = 60;
    public static final int MAX_ALERT_NOTE = 80;
    public static final int MAX_COT_TYPE = 24;
    public static final int MAX_ICONSET = 48;

    // -------------------------------------------------------------- enums

    public static final String[] ROLES = { "Team member", "Team lead", "Medic",
            "Navigator", "Comms", "Driver / vehicle", "K9", "Observer",
            "Command / HQ" };
    public static final int ROLE_MEMBER = 0, ROLE_LEAD = 1, ROLE_MEDIC = 2,
            ROLE_NAVIGATOR = 3, ROLE_COMMS = 4, ROLE_DRIVER = 5, ROLE_K9 = 6,
            ROLE_OBSERVER = 7, ROLE_COMMAND = 8;

    /** ATAK team colours, in wire order, as the __group name. */
    public static final String[] COLOR_NAMES = { "Cyan", "White", "Yellow",
            "Orange", "Magenta", "Red", "Maroon", "Purple", "Dark Blue", "Blue",
            "Teal", "Green", "Dark Green", "Brown" };
    public static final int[] COLOR_ARGB = { 0xFF00BCD4, 0xFFFFFFFF, 0xFFFFEB3B,
            0xFFFF9800, 0xFFE040FB, 0xFFF44336, 0xFF8B1A1A, 0xFF7E57C2,
            0xFF1A237E, 0xFF2196F3, 0xFF009688, 0xFF4CAF50, 0xFF1B5E20,
            0xFF795548 };

    public static final String[] STATUSES = { "", "OK", "Busy", "Need help",
            "Returning", "Resting" };

    public static final String[] MARKER_KINDS = { "Point", "Last known point",
            "Staging / command post", "Clue", "Hazard", "Landing zone",
            "Medical", "Subject found", "Water / resources", "Area searched" };

    public static final String[] ALERT_TYPES = { "SOS / 911", "In contact",
            "Ring the bell", "Geofence breached", "Alert" };
    public static final int ALERT_SOS = 0, ALERT_IN_CONTACT = 1,
            ALERT_RING_THE_BELL = 2, ALERT_GEOFENCE = 3, ALERT_CUSTOM = 4;

    public static final String[] AFFILIATIONS = { "Unknown", "Hostile",
            "Neutral", "Friendly" };
    public static final String[] URGENCIES = { "OTHER", "OBSERVED", "ACTIVE",
            "CRITICAL" };

    static int clampIndex(int i, int n, int def) {
        return i >= 0 && i < n ? i : def;
    }

    // ----------------------------------------------------------- helpers

    static int deg7(double v) {
        return (int) dround(v * 1e7);
    }

    /** Dart's round(): halves round away from zero (Java rounds them up). */
    public static long dround(double v) {
        return (long) (Math.signum(v) * Math.floor(Math.abs(v) + 0.5));
    }

    static double undeg7(int v) {
        return v / 1e7;
    }

    static int clamp(long v, int lo, int hi) {
        return (int) Math.max(lo, Math.min(hi, v));
    }

    public static String key4Hex(byte[] b, int off) {
        return Bytes.hex(b, off, 4);
    }

    static byte[] key4(String hex) {
        if (!Bytes.isHex(hex, 8))
            throw new IllegalArgumentException("bad key4 " + hex);
        return Bytes.unhex(hex);
    }

    /** The message type of a team payload, or -1 if it isn't one. */
    public static int peekType(byte[] p) {
        if (p == null || p.length < 5)
            return -1;
        int t = p[0] & 0xFF;
        switch (t) {
            case MSG_POSITION:
            case MSG_ALERT:
            case MSG_MARKER:
            case MSG_REPORT:
            case MSG_POINT:
            case MSG_SHAPE:
            case MSG_CHUNK:
                return t;
            default:
                return -1;
        }
    }

    /** Sender (or author) key4 of a team payload. */
    public static String peekSender(byte[] p) {
        return key4Hex(p, 1);
    }

    // ---------------------------------------------------------- attachment

    /** A VOX clip (photo or voice) fetched on demand from the item's author. */
    public static final class Attachment {
        public final int modeWireId;
        public final String sessionId; // 8 hex chars
        public final int packets;
        public final int extra; // duration (voice) or aspect code (image)

        public Attachment(int modeWireId, String sessionId, int packets,
                int extra) {
            this.modeWireId = modeWireId;
            this.sessionId = sessionId;
            this.packets = packets;
            this.extra = extra;
        }

        void write(Bytes.W w) {
            w.u8(modeWireId).bytes(key4(sessionId)).u8(packets).u16(extra);
        }

        static Attachment read(Bytes.R r) {
            if (!r.has(1))
                return null;
            int mode = r.u8();
            if (mode == 0 || !r.has(7))
                return null;
            return new Attachment(mode, Bytes.hex(r.take(4)), r.u8(), r.u16());
        }
    }

    // ------------------------------------------------------------ position

    public static final class Position {
        public String senderKey4;
        public double lat, lon;
        public Integer altitudeM;
        public Double speedMps;
        public Double headingDeg;
        public int accuracyM;
        public Integer batteryPct;
        public int role;
        public int color;
        public int status;
        public String callsign = "";
        public boolean fromRadio;
        public boolean sosActive;
        public boolean relayed;

        public byte[] encode() {
            boolean motion = speedMps != null && headingDeg != null;
            Bytes.W w = new Bytes.W().u8(MSG_POSITION).bytes(key4(senderKey4))
                    .u8((altitudeM != null ? 0x01 : 0) | (motion ? 0x02 : 0)
                            | (fromRadio ? 0x04 : 0) | (sosActive ? 0x08 : 0)
                            | (relayed ? 0x10 : 0))
                    .i32(deg7(lat)).i32(deg7(lon))
                    .i16(clamp(altitudeM == null ? 0 : altitudeM, -32768, 32767))
                    .u8(clamp(dround((speedMps == null ? 0 : speedMps) * 2), 0,
                            255))
                         .u8((int) dround(
                            ((((headingDeg == null ? 0 : headingDeg) % 360) + 360)
                                    % 360) * 256 / 360)
                            & 0xFF)
                    .u8(clamp(accuracyM, 0, 255))
                    .u8(batteryPct == null ? 255 : clamp(batteryPct, 0, 100))
                    .u8((role << 4) | (color & 0x0F)).u8(status)
                    .str(callsign, MAX_CALLSIGN);
            return w.done();
        }

        public static Position parse(byte[] p) {
            try {
                Bytes.R r = new Bytes.R(p);
                if (!r.has(25) || r.u8() != MSG_POSITION)
                    return null;
                Position x = new Position();
                x.senderKey4 = Bytes.hex(r.take(4));
                int flags = r.u8();
                x.lat = undeg7(r.i32());
                x.lon = undeg7(r.i32());
                if (Math.abs(x.lat) > 90 || Math.abs(x.lon) > 180)
                    return null;
                int alt = r.i16();
                double speed = r.u8() / 2.0;
                double heading = r.u8() * 360.0 / 256;
                x.accuracyM = r.u8();
                int batt = r.u8();
                int rc = r.u8();
                x.status = clampIndex(r.u8(), STATUSES.length, 0);
                String cs = r.str();
                x.callsign = cs == null ? "" : cs;
                x.altitudeM = (flags & 0x01) != 0 ? alt : null;
                if ((flags & 0x02) != 0) {
                    x.speedMps = speed;
                    x.headingDeg = heading;
                }
                x.batteryPct = batt == 255 ? null : batt;
                x.role = clampIndex(rc >> 4, ROLES.length, 0);
                x.color = clampIndex(rc & 0x0F, COLOR_NAMES.length, 0);
                x.fromRadio = (flags & 0x04) != 0;
                x.sosActive = (flags & 0x08) != 0;
                x.relayed = (flags & 0x10) != 0;
                return x;
            } catch (IndexOutOfBoundsException e) {
                return null;
            }
        }
    }

    // --------------------------------------------------------------- alert

    public static final class Alert {
        public String senderKey4;
        public int alertId;
        public boolean active;
        public int type;
        public Double lat, lon;
        public int accuracyM;
        public String callsign = "";
        public String note = "";

        public String key() {
            return senderKey4 + ":" + alertId;
        }

        public byte[] encode() {
            boolean hasPos = lat != null && lon != null;
            return new Bytes.W().u8(MSG_ALERT).bytes(key4(senderKey4))
                    .u16(alertId)
                    .u8((active ? 0x01 : 0) | (hasPos ? 0x02 : 0) | (type << 4))
                    .i32(hasPos ? deg7(lat) : 0).i32(hasPos ? deg7(lon) : 0)
                    .u8(clamp(accuracyM, 0, 255)).str(callsign, MAX_CALLSIGN)
                    .str(note, MAX_ALERT_NOTE).done();
        }

        public static Alert parse(byte[] p) {
            try {
                Bytes.R r = new Bytes.R(p);
                if (!r.has(18) || r.u8() != MSG_ALERT)
                    return null;
                Alert a = new Alert();
                a.senderKey4 = Bytes.hex(r.take(4));
                a.alertId = r.u16();
                int state = r.u8();
                double lat = undeg7(r.i32()), lon = undeg7(r.i32());
                a.accuracyM = r.u8();
                boolean hasPos = (state & 0x02) != 0 && Math.abs(lat) <= 90
                        && Math.abs(lon) <= 180;
                a.active = (state & 0x01) != 0;
                a.type = clampIndex(state >> 4, ALERT_TYPES.length, 0);
                if (hasPos) {
                    a.lat = lat;
                    a.lon = lon;
                }
                String cs = r.str();
                a.callsign = cs == null ? "" : cs;
                String n = r.str();
                a.note = n == null ? "" : n;
                return a;
            } catch (IndexOutOfBoundsException e) {
                return null;
            }
        }
    }

    // -------------------------------------------------------------- marker

    public static final class Marker {
        public String authorKey4;
        public long markerId;
        public boolean deleted;
        public int kind;
        public double lat, lon;
        public long timeSec;
        public String label = "";
        public String note = "";
        public Attachment attachment;

        public String key() {
            return authorKey4 + ":" + Long.toHexString(markerId);
        }

        public byte[] encode() {
            Bytes.W w = new Bytes.W().u8(MSG_MARKER).bytes(key4(authorKey4))
                    .u32(markerId).u8(deleted ? 1 : 0).u8(kind).i32(deg7(lat))
                    .i32(deg7(lon)).u32(timeSec).str(label, MAX_LABEL)
                    .str(note, MAX_NOTE);
            if (attachment == null)
                w.u8(0);
            else
                attachment.write(w);
            return w.done();
        }

        public static Marker parse(byte[] p) {
            try {
                Bytes.R r = new Bytes.R(p);
                if (!r.has(23) || r.u8() != MSG_MARKER)
                    return null;
                Marker m = new Marker();
                m.authorKey4 = Bytes.hex(r.take(4));
                m.markerId = r.u32();
                m.deleted = r.u8() == 1;
                m.kind = clampIndex(r.u8(), MARKER_KINDS.length, 0);
                m.lat = undeg7(r.i32());
                m.lon = undeg7(r.i32());
                if (Math.abs(m.lat) > 90 || Math.abs(m.lon) > 180)
                    return null;
                m.timeSec = r.u32();
                m.label = r.str();
                m.note = r.str();
                if (m.label == null || m.note == null)
                    return null;
                m.attachment = Attachment.read(r);
                return m;
            } catch (IndexOutOfBoundsException e) {
                return null;
            }
        }
    }

    // -------------------------------------------------------------- report

    public static final class Report {
        public String authorKey4;
        public long reportId;
        public int kind; // 0 = SALUTE
        public int affiliation;
        public int urgency = 1;
        public double lat, lon;
        public long observedSec;
        public int vehicles, people;
        public String place = "", size = "", activity = "", unit = "",
                equipment = "";
        public Attachment attachment;

        public String key() {
            return authorKey4 + ":" + Long.toHexString(reportId);
        }

        public byte[] encode() {
            Bytes.W w = new Bytes.W().u8(MSG_REPORT).bytes(key4(authorKey4))
                    .u32(reportId).u8((kind << 4) | (urgency & 0x0F))
                    .u8(affiliation).i32(deg7(lat)).i32(deg7(lon))
                    .u32(observedSec).u8(clamp(vehicles, 0, 255))
                    .u8(clamp(people, 0, 255)).str(place, 24).str(size, 12)
                    .str(activity, 32).str(unit, 24).str(equipment, 28);
            if (attachment == null)
                w.u8(0);
            else
                attachment.write(w);
            return w.done();
        }

        public static Report parse(byte[] p) {
            try {
                Bytes.R r = new Bytes.R(p);
                if (!r.has(25) || r.u8() != MSG_REPORT)
                    return null;
                Report x = new Report();
                x.authorKey4 = Bytes.hex(r.take(4));
                x.reportId = r.u32();
                int ku = r.u8();
                x.kind = clampIndex(ku >> 4, 1, 0);
                x.urgency = clampIndex(ku & 0x0F, URGENCIES.length, 1);
                x.affiliation = clampIndex(r.u8(), AFFILIATIONS.length, 0);
                x.lat = undeg7(r.i32());
                x.lon = undeg7(r.i32());
                if (Math.abs(x.lat) > 90 || Math.abs(x.lon) > 180)
                    return null;
                x.observedSec = r.u32();
                x.vehicles = r.u8();
                x.people = r.u8();
                x.place = r.str();
                x.size = r.str();
                x.activity = r.str();
                x.unit = r.str();
                x.equipment = r.str();
                if (x.place == null || x.size == null || x.activity == null
                        || x.unit == null || x.equipment == null)
                    return null;
                x.attachment = Attachment.read(r);
                return x;
            } catch (IndexOutOfBoundsException e) {
                return null;
            }
        }

        /** One-line SALUTE summary (matches the app's TeamReport.summary()). */
        public String summary() {
            StringBuilder sb = new StringBuilder(URGENCIES[urgency]);
            if (affiliation != 0)
                sb.append(' ').append(AFFILIATIONS[affiliation].toLowerCase());
            String counts = countsLabel();
            if (!counts.isEmpty())
                sb.append(" / S: ").append(counts);
            if (!activity.isEmpty())
                sb.append(" / A: ").append(activity);
            sb.append(" / L: ");
            if (!place.isEmpty())
                sb.append(place).append(' ');
            sb.append(String.format(java.util.Locale.US, "(%.5f, %.5f)", lat,
                    lon));
            if (!unit.isEmpty())
                sb.append(" / U: ").append(unit);
            sb.append(" / T: ").append(isoMinute(observedSec)).append('Z');
            if (!equipment.isEmpty())
                sb.append(" / E: ").append(equipment);
            return sb.toString();
        }

        public String countsLabel() {
            List<String> parts = new ArrayList<>();
            if (vehicles > 0)
                parts.add(vehicles + "-🚗");
            if (people > 0)
                parts.add(people + "-🥾");
            if (!size.isEmpty())
                parts.add(size);
            return join(parts, " ");
        }
    }

    static String isoMinute(long sec) {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat(
                "yyyy-MM-dd'T'HH:mm", java.util.Locale.US);
        f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
        return f.format(new java.util.Date(sec * 1000));
    }

    static String join(List<String> parts, String sep) {
        StringBuilder sb = new StringBuilder();
        for (String s : parts) {
            if (sb.length() > 0)
                sb.append(sep);
            sb.append(s);
        }
        return sb.toString();
    }

    // --------------------------------------------------------------- point

    /** Any single-point CoT item (spot marker, waypoint, 2525 unit, SPI...). */
    public static final class Point {
        public String authorKey4;
        public long itemId;
        public boolean deleted;
        public double lat, lon;
        public Integer haeM;
        public Integer argb;
        public long timeSec;
        public String cotType = "";
        public String callsign = "";
        public String remarks = "";
        public String iconset = "";
        public Attachment attachment;

        public String key() {
            return authorKey4 + ":" + Long.toHexString(itemId);
        }

        public byte[] encode() {
            boolean hasIcon = iconset != null && !iconset.isEmpty();
            int flags = (haeM != null ? 0x01 : 0) | (argb != null ? 0x02 : 0)
                    | (attachment != null ? 0x04 : 0) | (hasIcon ? 0x08 : 0);
            Bytes.W w = new Bytes.W().u8(MSG_POINT).bytes(key4(authorKey4))
                    .u32(itemId).u8(deleted ? 1 : 0).u8(flags).i32(deg7(lat))
                    .i32(deg7(lon)).u32(timeSec);
            if (haeM != null)
                w.i16(clamp(haeM, -32768, 32767));
            if (argb != null)
                w.i32(argb);
            w.str(cotType, MAX_COT_TYPE).str(callsign, MAX_LABEL);
            // Remarks get whatever room is left (iconset/attachment first).
            int tail = (hasIcon ? 1 + Math.min(Bytes.utf8(iconset).length,
                    MAX_ICONSET) : 0) + (attachment != null ? 8 : 0);
            int room = MAX_PAYLOAD - w.size() - 1 - tail;
            w.str(remarks, Math.max(0, Math.min(room, 120)));
            if (hasIcon)
                w.str(iconset, MAX_ICONSET);
            if (attachment != null)
                attachment.write(w);
            return w.done();
        }

        public static Point parse(byte[] p) {
            try {
                Bytes.R r = new Bytes.R(p);
                if (!r.has(23) || r.u8() != MSG_POINT)
                    return null;
                Point x = new Point();
                x.authorKey4 = Bytes.hex(r.take(4));
                x.itemId = r.u32();
                x.deleted = r.u8() == 1;
                int flags = r.u8();
                x.lat = undeg7(r.i32());
                x.lon = undeg7(r.i32());
                if (Math.abs(x.lat) > 90 || Math.abs(x.lon) > 180)
                    return null;
                x.timeSec = r.u32();
                if ((flags & 0x01) != 0)
                    x.haeM = r.i16();
                if ((flags & 0x02) != 0)
                    x.argb = r.i32();
                x.cotType = r.str();
                x.callsign = r.str();
                x.remarks = r.str();
                if (x.cotType == null || x.callsign == null || x.remarks == null)
                    return null;
                if ((flags & 0x08) != 0) {
                    x.iconset = r.str();
                    if (x.iconset == null)
                        return null;
                }
                if ((flags & 0x04) != 0)
                    x.attachment = Attachment.read(r);
                return x;
            } catch (IndexOutOfBoundsException e) {
                return null;
            }
        }
    }

    // --------------------------------------------------------------- shape

    public static final int SHAPE_POLYLINE = 0, SHAPE_POLYGON = 1,
            SHAPE_RECTANGLE = 2, SHAPE_CIRCLE = 3, SHAPE_ROUTE = 4;
    public static final String[] SHAPE_KINDS = { "Line", "Polygon", "Rectangle",
            "Circle", "Route" };

    /** Routes, lines, polygons, rectangles and circles, delta-encoded. */
    public static final class Shape {
        public String authorKey4;
        public long itemId;
        public boolean deleted;
        public int kind;
        public int strokeArgb = 0xFFFFFFFF;
        public Integer fillArgb;
        public long timeSec;
        public double strokeWidth = 3;
        public String label = "";
        public String note = "";
        /** Circles only. */
        public long radiusM;
        /** [lat, lon] pairs. A circle has one point, its centre. */
        public List<double[]> points = new ArrayList<>();

        public String key() {
            return authorKey4 + ":" + Long.toHexString(itemId);
        }

        private byte[] encodeWith(List<double[]> pts) {
            Bytes.W w = new Bytes.W().u8(MSG_SHAPE).bytes(key4(authorKey4))
                    .u32(itemId).u8(deleted ? 1 : 0).u8(kind)
                    .u8(fillArgb != null ? 0x01 : 0).i32(strokeArgb);
            if (fillArgb != null)
                w.i32(fillArgb);
            w.u32(timeSec).u8(clamp(dround(strokeWidth * 2), 0, 255))
                    .str(label, MAX_LABEL).str(note, MAX_NOTE);
            if (kind == SHAPE_CIRCLE)
                w.uvar(radiusM);
            w.uvar(pts.size());
            long plat = 0, plon = 0;
            for (int i = 0; i < pts.size(); i++) {
                long la = dround(pts.get(i)[0] * 1e6);
                long lo = dround(pts.get(i)[1] * 1e6);
                if (i == 0) {
                    w.i32((int) la).i32((int) lo);
                } else {
                    w.svar(la - plat).svar(lo - plon);
                }
                plat = la;
                plon = lo;
            }
            return w.done();
        }

        /**
         * Encodes, dropping interior vertices (least significant first) until
         * the shape fits one packet. Returns null if even the label alone
         * doesn't fit.
         */
        public byte[] encode() {
            List<double[]> pts = new ArrayList<>(points);
            byte[] out = encodeWith(pts);
            while (out.length > MAX_PAYLOAD && pts.size() > 2) {
                pts.remove(leastSignificant(pts));
                out = encodeWith(pts);
            }
            return out.length <= MAX_PAYLOAD ? out : null;
        }

        /** True if {@link #encode()} had to simplify the geometry. */
        public boolean needsSimplifying() {
            return encodeWith(points).length > MAX_PAYLOAD;
        }

        public static Shape parse(byte[] p) {
            try {
                Bytes.R r = new Bytes.R(p);
                if (!r.has(20) || r.u8() != MSG_SHAPE)
                    return null;
                Shape s = new Shape();
                s.authorKey4 = Bytes.hex(r.take(4));
                s.itemId = r.u32();
                s.deleted = r.u8() == 1;
                s.kind = clampIndex(r.u8(), SHAPE_KINDS.length, 0);
                int flags = r.u8();
                s.strokeArgb = r.i32();
                if ((flags & 0x01) != 0)
                    s.fillArgb = r.i32();
                s.timeSec = r.u32();
                s.strokeWidth = r.u8() / 2.0;
                s.label = r.str();
                s.note = r.str();
                if (s.label == null || s.note == null)
                    return null;
                if (s.kind == SHAPE_CIRCLE)
                    s.radiusM = r.uvar();
                long n = r.uvar();
                if (n > 200)
                    return null;
                long la = 0, lo = 0;
                for (int i = 0; i < n; i++) {
                    if (i == 0) {
                        la = r.i32();
                        lo = r.i32();
                    } else {
                        la += r.svar();
                        lo += r.svar();
                    }
                    double lat = la / 1e6, lon = lo / 1e6;
                    if (Math.abs(lat) > 90 || Math.abs(lon) > 180)
                        return null;
                    s.points.add(new double[] { lat, lon });
                }
                if (!s.deleted && s.points.isEmpty())
                    return null;
                return s;
            } catch (IndexOutOfBoundsException e) {
                return null;
            }
        }

        /** Interior vertex whose removal changes the line least. */
        static int leastSignificant(List<double[]> pts) {
            int best = 1;
            double bestErr = Double.MAX_VALUE;
            for (int i = 1; i < pts.size() - 1; i++) {
                double e = crossTrack(pts.get(i), pts.get(i - 1), pts.get(i + 1));
                if (e < bestErr) {
                    bestErr = e;
                    best = i;
                }
            }
            return best;
        }

        /** Planar distance of p from segment a-b (degrees, lon scaled by cos lat). */
        static double crossTrack(double[] p, double[] a, double[] b) {
            double k = Math.cos(Math.toRadians(p[0]));
            double ax = a[1] * k, ay = a[0], bx = b[1] * k, by = b[0];
            double px = p[1] * k, py = p[0];
            double dx = bx - ax, dy = by - ay;
            double len2 = dx * dx + dy * dy;
            double t = len2 == 0 ? 0
                    : Math.max(0, Math.min(1,
                            ((px - ax) * dx + (py - ay) * dy) / len2));
            double cx = ax + t * dx, cy = ay + t * dy;
            return Math.hypot(px - cx, py - cy);
        }
    }

    // ------------------------------------------------------- smart beacon

    /** APRS-style smart beaconing, same defaults as the app. */
    public static final class BeaconPolicy {
        public long minIntervalMs = 30_000;
        public long movingIntervalMs = 90_000;
        public long stillIntervalMs = 600_000;
        public double movingSpeedMps = 0.8;
        public double turnDegrees = 35;
        public double distanceMeters = 75;

        /** sinceLastMs < 0 means nothing has been sent yet. */
        public boolean shouldSend(long sinceLastMs, double metersSinceLast,
                double speedMps, double headingChangeDeg) {
            if (sinceLastMs < 0)
                return true;
            if (sinceLastMs < minIntervalMs)
                return false;
            boolean moving = speedMps >= movingSpeedMps;
            if (moving && Math.abs(headingChangeDeg) >= turnDegrees)
                return true;
            if (metersSinceLast >= distanceMeters
                    && sinceLastMs >= movingIntervalMs / 2)
                return true;
            if (moving && sinceLastMs >= movingIntervalMs)
                return true;
            return sinceLastMs >= stillIntervalMs;
        }
    }

    public static double distanceMeters(double lat1, double lon1, double lat2,
            double lon2) {
        double r = 6371000.0;
        double p1 = Math.toRadians(lat1), p2 = Math.toRadians(lat2);
        double dp = Math.toRadians(lat2 - lat1), dl = Math.toRadians(lon2 - lon1);
        double a = Math.sin(dp / 2) * Math.sin(dp / 2)
                + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2);
        return 2 * r * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    }

    public static List<double[]> unmodifiable(List<double[]> l) {
        return Collections.unmodifiableList(l);
    }
}
