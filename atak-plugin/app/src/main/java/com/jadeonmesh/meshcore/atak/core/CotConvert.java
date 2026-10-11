package com.jadeonmesh.meshcore.atak.core;

import java.text.ParseException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;

/**
 * Conversions between team wire messages and Cursor on Target.
 *
 * Mesh -&gt; CoT follows lib/team/tak/cot.dart so a phone running both the app's
 * TAK gateway and this plugin produces identical uids (no duplicates):
 * members are {@code VOX-<key4>}, pins {@code VOX-M-<key4>-<id>}, reports
 * {@code VOX-R-...}, and the plugin's points and shapes {@code VOX-C-...} and
 * {@code VOX-G-...}.
 */
public final class CotConvert {
    private CotConvert() {
    }

    public static final String UID_PREFIX = "VOX-";
    public static final String NO_VAL = "9999999.0";
    /** Mesh contacts get a dummy endpoint so ATAK offers chat with them. */
    public static final String MESH_ENDPOINT = "0.0.0.0:4242:tcp";
    public static final String ALL_CHAT = "All Chat Rooms";

    public static String memberUid(String key4) {
        return UID_PREFIX + key4;
    }

    public static String markerUid(String key4, long id) {
        return UID_PREFIX + "M-" + key4 + "-" + Long.toHexString(id);
    }

    public static String reportUid(String key4, long id) {
        return UID_PREFIX + "R-" + key4 + "-" + Long.toHexString(id);
    }

    public static String pointUid(String key4, long id) {
        return UID_PREFIX + "C-" + key4 + "-" + Long.toHexString(id);
    }

    public static String shapeUid(String key4, long id) {
        return UID_PREFIX + "G-" + key4 + "-" + Long.toHexString(id);
    }

    /** key4 of a member uid ("VOX-0a1b2c3d"), or null. */
    public static String key4FromMemberUid(String uid) {
        if (uid == null || !uid.startsWith(UID_PREFIX)
                || uid.length() != UID_PREFIX.length() + 8)
            return null;
        String k = uid.substring(UID_PREFIX.length());
        return Bytes.isHex(k, 8) ? k : null;
    }

    // ---------------------------------------------------------------- time

    private static SimpleDateFormat iso() {
        SimpleDateFormat f = new SimpleDateFormat(
                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return f;
    }

    public static String isoTime(long ms) {
        return iso().format(new Date(ms));
    }

    public static long parseTime(String s, long def) {
        if (s == null)
            return def;
        String[] fmts = { "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.SS'Z'",
                "yyyy-MM-dd'T'HH:mm:ss.S'Z'" };
        for (String fm : fmts) {
            SimpleDateFormat f = new SimpleDateFormat(fm, Locale.US);
            f.setTimeZone(TimeZone.getTimeZone("UTC"));
            f.setLenient(false);
            try {
                return f.parse(s).getTime();
            } catch (ParseException ignored) {
            }
        }
        return def;
    }

    static String fmt7(double v) {
        return String.format(Locale.US, "%.7f", v);
    }

    static String fmt1(double v) {
        return String.format(Locale.US, "%.1f", v);
    }

    // ------------------------------------------------------------ building

    public static XNode event(String uid, String type, String how, double lat,
            double lon, Double hae, Double ce, long timeMs, long staleAfterMs) {
        XNode e = new XNode("event").attr("version", "2.0").attr("uid", uid)
                .attr("type", type).attr("how", how)
                .attr("time", isoTime(timeMs)).attr("start", isoTime(timeMs))
                .attr("stale", isoTime(timeMs + staleAfterMs));
        e.add("point").attr("lat", fmt7(lat)).attr("lon", fmt7(lon))
                .attr("hae", hae == null ? NO_VAL : fmt1(hae))
                .attr("ce", ce == null || ce <= 0 ? NO_VAL : fmt1(ce))
                .attr("le", NO_VAL);
        e.add("detail");
        return e;
    }

    public static XNode detail(XNode event) {
        return event.child("detail");
    }

    // ------------------------------------------------------- team <-> TAK

    public static String takRoleName(int role) {
        switch (role) {
            case TeamWire.ROLE_LEAD:
                return "Team Lead";
            case TeamWire.ROLE_MEDIC:
                return "Medic";
            case TeamWire.ROLE_COMMS:
                return "RTO";
            case TeamWire.ROLE_K9:
                return "K9";
            case TeamWire.ROLE_OBSERVER:
                return "Forward Observer";
            case TeamWire.ROLE_COMMAND:
                return "HQ";
            default:
                return "Team Member";
        }
    }

    public static int roleFromTak(String r) {
        String s = r == null ? "" : r.toLowerCase(Locale.US);
        switch (s) {
            case "team lead":
                return TeamWire.ROLE_LEAD;
            case "medic":
                return TeamWire.ROLE_MEDIC;
            case "rto":
                return TeamWire.ROLE_COMMS;
            case "k9":
                return TeamWire.ROLE_K9;
            case "forward observer":
            case "sniper":
                return TeamWire.ROLE_OBSERVER;
            case "hq":
                return TeamWire.ROLE_COMMAND;
            default:
                return TeamWire.ROLE_MEMBER;
        }
    }

    public static int colorFromTak(String name) {
        for (int i = 0; i < TeamWire.COLOR_NAMES.length; i++)
            if (TeamWire.COLOR_NAMES[i].equalsIgnoreCase(name == null ? "" : name))
                return i;
        return 0;
    }

    /** CoT event type and ATAK emergency name for an alert type. */
    public static String[] alertType(int t) {
        switch (t) {
            case TeamWire.ALERT_IN_CONTACT:
                return new String[] { "b-a-o-opn", "In Contact" };
            case TeamWire.ALERT_RING_THE_BELL:
                return new String[] { "b-a-o-pan", "Ring The Bell" };
            case TeamWire.ALERT_GEOFENCE:
                return new String[] { "b-a-g", "Geo-fence Breached" };
            case TeamWire.ALERT_CUSTOM:
                return new String[] { "b-a-o-c", "Custom" };
            default:
                return new String[] { "b-a-o-tbl", "911 Alert" };
        }
    }

    /** Alert type for a CoT type, or -1 if it isn't an alert start. */
    public static int alertTypeFromCot(String type) {
        if (type == null)
            return -1;
        switch (type) {
            case "b-a-o-tbl":
                return TeamWire.ALERT_SOS;
            case "b-a-o-opn":
                return TeamWire.ALERT_IN_CONTACT;
            case "b-a-o-pan":
                return TeamWire.ALERT_RING_THE_BELL;
            case "b-a-g":
                return TeamWire.ALERT_GEOFENCE;
            case "b-a-o-c":
                return TeamWire.ALERT_CUSTOM;
            default:
                return -1;
        }
    }

    public static int markerArgb(int kind) {
        switch (kind) {
            case 1:
                return 0xFFFF0000;
            case 2:
                return 0xFF0000FF;
            case 3:
                return 0xFFFFFF00;
            case 4:
                return 0xFFFF7F00;
            case 5:
                return 0xFF00FF00;
            case 6:
                return 0xFFFF00FF;
            case 7:
                return 0xFF00FFFF;
            case 8:
                return 0xFF3399FF;
            case 9:
                return 0xFF888888;
            default:
                return 0xFFFFFFFF;
        }
    }

    // ----------------------------------------------------- mesh -> CoT XML

    /** A team member's position (PLI). */
    public static XNode position(TeamWire.Position p, long nowMs) {
        XNode e = event(memberUid(p.senderKey4), "a-f-G-U-C", "m-g", p.lat,
                p.lon, p.altitudeM == null ? null : (double) p.altitudeM,
                p.accuracyM > 0 ? (double) p.accuracyM : null, nowMs,
                15 * 60_000L);
        XNode d = detail(e);
        String cs = p.callsign.isEmpty() ? p.senderKey4.toUpperCase(Locale.US)
                : p.callsign;
        d.add("contact").attr("callsign", cs).attr("endpoint", MESH_ENDPOINT);
        d.add("uid").attr("Droid", cs);
        d.add("__group").attr("name", TeamWire.COLOR_NAMES[p.color])
                .attr("role", takRoleName(p.role));
        if (p.batteryPct != null)
            d.add("status").attr("battery", String.valueOf(p.batteryPct));
        if (p.speedMps != null && p.headingDeg != null)
            d.add("track").attr("course", fmt1(p.headingDeg))
                    .attr("speed", fmt1(p.speedMps));
        d.add("takv").attr("device", "MeshCore radio")
                .attr("platform", "MeshCore Open TAK").attr("os", "LoRa mesh")
                .attr("version", "1");
        List<String> rem = new ArrayList<>();
        rem.add("Via MeshCore mesh");
        if (p.status != 0)
            rem.add(TeamWire.STATUSES[p.status]);
        if (p.fromRadio)
            rem.add("radio GPS");
        if (p.relayed)
            rem.add("relayed from TAK");
        d.add("remarks").text(TeamWire.join(rem, " · "));
        return e;
    }

    public static XNode marker(TeamWire.Marker m, long nowMs) {
        String uid = markerUid(m.authorKey4, m.markerId);
        if (m.deleted)
            return delete(uid, nowMs);
        XNode e = event(uid, "b-m-p-s-m", "h-g-i-g-o", m.lat, m.lon, null, null,
                m.timeSec * 1000, 24 * 3600_000L);
        XNode d = detail(e);
        String kind = TeamWire.MARKER_KINDS[m.kind];
        d.add("contact").attr("callsign",
                m.label.isEmpty() ? kind : m.label + " (" + kind + ")");
        d.add("color").attr("argb", String.valueOf(markerArgb(m.kind)));
        d.add("link").attr("uid", memberUid(m.authorKey4)).attr("relation", "p-p")
                .attr("type", "a-f-G-U-C");
        d.add("archive");
        if (!m.note.isEmpty() || m.attachment != null) {
            String r = m.note;
            if (m.attachment != null)
                r = (r.isEmpty() ? "" : r + " ") + "[attachment on the mesh]";
            d.add("remarks").text(r);
        }
        return e;
    }

    public static XNode report(TeamWire.Report r, long nowMs) {
        String type;
        switch (r.affiliation) {
            case 1:
                type = "a-h-G";
                break;
            case 2:
                type = "a-n-G";
                break;
            case 3:
                type = "a-f-G";
                break;
            default:
                type = "a-u-G";
        }
        XNode e = event(reportUid(r.authorKey4, r.reportId), type, "h-g-i-g-o",
                r.lat, r.lon, null, null, r.observedSec * 1000, 6 * 3600_000L);
        XNode d = detail(e);
        String hhmm = isoTime(r.observedSec * 1000).substring(11, 16);
        d.add("contact").attr("callsign", "SALUTE " + hhmm + "Z");
        d.add("link").attr("uid", memberUid(r.authorKey4)).attr("relation", "p-p")
                .attr("type", "a-f-G-U-C");
        d.add("archive");
        d.add("remarks").text("SALUTE " + r.summary());
        return e;
    }

    public static XNode alert(TeamWire.Alert a, long nowMs) {
        String member = memberUid(a.senderKey4);
        String[] t = alertType(a.type);
        XNode e = event(member + "-9-1-1", a.active ? t[0] : "b-a-o-can", "m-g",
                a.lat == null ? 0 : a.lat, a.lon == null ? 0 : a.lon, null, null,
                nowMs, 10 * 60_000L);
        XNode d = detail(e);
        d.add("link").attr("uid", member).attr("relation", "p-p").attr("type",
                "a-f-G-U-C");
        d.add("contact").attr("callsign", a.callsign + "-Alert");
        XNode em = d.add("emergency").text(a.callsign);
        if (a.active)
            em.attr("type", t[1]);
        else
            em.attr("cancel", "true");
        if (!a.note.isEmpty())
            d.add("remarks").text(a.note);
        return e;
    }

    public static XNode point(TeamWire.Point p, long nowMs) {
        String uid = pointUid(p.authorKey4, p.itemId);
        if (p.deleted)
            return delete(uid, nowMs);
        String type = p.cotType.isEmpty() ? "b-m-p-s-m" : p.cotType;
        XNode e = event(uid, type, "h-g-i-g-o", p.lat, p.lon,
                p.haeM == null ? null : (double) p.haeM, null, p.timeSec * 1000,
                24 * 3600_000L);
        XNode d = detail(e);
        d.add("contact").attr("callsign",
                p.callsign.isEmpty() ? "Mesh point" : p.callsign);
        if (p.argb != null)
            d.add("color").attr("argb", String.valueOf(p.argb));
        if (!p.iconset.isEmpty())
            d.add("usericon").attr("iconsetpath", p.iconset);
        d.add("link").attr("uid", memberUid(p.authorKey4)).attr("relation", "p-p")
                .attr("type", "a-f-G-U-C");
        d.add("archive");
        String r = p.remarks;
        if (p.attachment != null)
            r = (r.isEmpty() ? "" : r + " ") + "[attachment on the mesh]";
        if (!r.isEmpty())
            d.add("remarks").text(r);
        return e;
    }

    static String kmlColor(int argb) {
        // KML is aabbggrr.
        int a = (argb >>> 24) & 0xFF, r = (argb >> 16) & 0xFF,
                g = (argb >> 8) & 0xFF, b = argb & 0xFF;
        return String.format(Locale.US, "%02x%02x%02x%02x", a, b, g, r);
    }

    public static XNode shape(TeamWire.Shape s, long nowMs) {
        String uid = shapeUid(s.authorKey4, s.itemId);
        if (s.deleted)
            return delete(uid, nowMs);
        double[] c = centroid(s.points);
        String type;
        switch (s.kind) {
            case TeamWire.SHAPE_RECTANGLE:
                type = "u-d-r";
                break;
            case TeamWire.SHAPE_CIRCLE:
                type = "u-d-c-c";
                break;
            case TeamWire.SHAPE_ROUTE:
                type = "b-m-r";
                break;
            default:
                type = "u-d-f";
        }
        XNode e = event(uid, type, "h-e", c[0], c[1], null, null,
                s.timeSec * 1000, 24 * 3600_000L);
        XNode d = detail(e);
        String label = s.label.isEmpty() ? TeamWire.SHAPE_KINDS[s.kind]
                : s.label;
        if (s.kind == TeamWire.SHAPE_ROUTE) {
            int n = s.points.size();
            for (int i = 0; i < n; i++) {
                double[] p = s.points.get(i);
                boolean end = i == 0 || i == n - 1;
                d.add("link").attr("uid", uid + "-" + i)
                        .attr("callsign", i == 0 ? label + " SP"
                                : i == n - 1 ? "VDO" : "CP" + i)
                        .attr("type", end ? "b-m-p-w" : "b-m-p-c")
                        .attr("point", fmt7(p[0]) + "," + fmt7(p[1]))
                        .attr("remarks", "").attr("relation", "c");
            }
            d.add("link_attr").attr("planningmethod", "Infil")
                    .attr("color", String.valueOf(s.strokeArgb))
                    .attr("method", "Walking").attr("prefix", "CP")
                    .attr("type", "On Foot")
                    .attr("stroke", String.valueOf((int) Math.max(1,
                            Math.round(s.strokeWidth))))
                    .attr("direction", "Infil").attr("routetype", "Primary")
                    .attr("order", "Ascending Check Points");
            d.add("__routeinfo").add("__navcues");
        } else if (s.kind == TeamWire.SHAPE_CIRCLE) {
            String r = String.valueOf(s.radiusM);
            XNode sh = d.add("shape");
            sh.add("ellipse").attr("major", r).attr("minor", r).attr("angle",
                    "360");
            XNode st = sh.add("link").attr("uid", uid + ".Style")
                    .attr("type", "b-x-KmlStyle").attr("relation", "p-c")
                    .add("Style");
            XNode ls = st.add("LineStyle");
            ls.add("color").text(kmlColor(s.strokeArgb));
            ls.add("width").text(fmt1(s.strokeWidth));
            st.add("PolyStyle").add("color").text(kmlColor(
                    s.fillArgb == null ? (s.strokeArgb & 0x00FFFFFF) : s.fillArgb));
        } else {
            List<double[]> pts = new ArrayList<>(s.points);
            if (s.kind == TeamWire.SHAPE_POLYGON && pts.size() > 2)
                pts.add(pts.get(0)); // ATAK closes a shape by repeating the start
            for (double[] p : pts)
                d.add("link").attr("point", fmt7(p[0]) + "," + fmt7(p[1]));
        }
        d.add("strokeColor").attr("value", String.valueOf(s.strokeArgb));
        d.add("strokeWeight").attr("value", fmt1(s.strokeWidth));
        if (s.fillArgb != null)
            d.add("fillColor").attr("value", String.valueOf(s.fillArgb));
        d.add("contact").attr("callsign", label);
        if (!s.note.isEmpty())
            d.add("remarks").text(s.note);
        d.add("labels_on").attr("value", "true");
        d.add("archive");
        return e;
    }

    static double[] centroid(List<double[]> pts) {
        if (pts.isEmpty())
            return new double[] { 0, 0 };
        double la = 0, lo = 0;
        for (double[] p : pts) {
            la += p[0];
            lo += p[1];
        }
        return new double[] { la / pts.size(), lo / pts.size() };
    }

    /** Deletes [uid] on TAK clients. */
    public static XNode delete(String uid, long nowMs) {
        XNode e = event(uid + "-delete", "t-x-d-d", "h-g-i-g-o", 0, 0, null,
                null, nowMs, 20_000L);
        XNode d = detail(e);
        d.add("link").attr("uid", uid).attr("relation", "none").attr("type",
                "none");
        d.add("__forcedelete");
        return e;
    }

    /**
     * GeoChat as ATAK writes it. [toUid] null means All Chat Rooms; otherwise
     * a direct message from [senderUid] to the local user [toUid].
     */
    public static XNode chat(String senderUid, String senderCallsign,
            String toUid, String text, String messageId, long timeMs,
            double lat, double lon) {
        boolean all = toUid == null;
        String room = all ? ALL_CHAT : senderCallsign;
        String roomId = all ? ALL_CHAT : senderUid;
        String uid = "GeoChat." + senderUid + "." + (all ? ALL_CHAT : toUid)
                + "." + messageId;
        XNode e = event(uid, "b-t-f", "h-g-i-g-o", lat, lon, null, null, timeMs,
                24 * 3600_000L);
        XNode d = detail(e);
        XNode c = d.add("__chat").attr("parent", "RootContactGroup")
                .attr("groupOwner", "false").attr("messageId", messageId)
                .attr("chatroom", room).attr("id", roomId)
                .attr("senderCallsign", senderCallsign);
        c.add("chatgrp").attr("uid0", senderUid)
                .attr("uid1", all ? ALL_CHAT : toUid).attr("id", roomId);
        d.add("link").attr("uid", senderUid).attr("type", "a-f-G-U-C")
                .attr("relation", "p-p");
        d.add("remarks").attr("source", "BAO.F.ATAK." + senderUid)
                .attr("to", all ? ALL_CHAT : toUid).attr("time", isoTime(timeMs))
                .text(text);
        return e;
    }

    // ----------------------------------------------------- CoT -> mesh

    public static String type(XNode ev) {
        return ev.get("type", "");
    }

    public static String uid(XNode ev) {
        return ev.get("uid", "");
    }

    static double attrD(XNode n, String k, double def) {
        if (n == null)
            return def;
        try {
            String v = n.get(k);
            return v == null ? def : Double.parseDouble(v);
        } catch (NumberFormatException e) {
            return def;
        }
    }

    static Double optD(XNode n, String k) {
        double v = attrD(n, k, Double.NaN);
        return Double.isNaN(v) || v >= 9999999 ? null : v;
    }

    static String attrS(XNode n, String k) {
        return n == null ? null : n.get(k);
    }

    public static double lat(XNode ev) {
        return attrD(ev.child("point"), "lat", 0);
    }

    public static double lon(XNode ev) {
        return attrD(ev.child("point"), "lon", 0);
    }

    public static String callsign(XNode ev) {
        return attrS(ev.path("detail/contact"), "callsign");
    }

    public static String remarks(XNode ev) {
        XNode r = ev.path("detail/remarks");
        return r == null ? "" : r.text.trim();
    }

    /** ATAK's own PLI as a team position (sender key filled in by caller). */
    public static TeamWire.Position selfPosition(XNode ev, String key4) {
        TeamWire.Position p = new TeamWire.Position();
        p.senderKey4 = key4;
        p.lat = lat(ev);
        p.lon = lon(ev);
        XNode pt = ev.child("point");
        Double hae = optD(pt, "hae");
        if (hae != null)
            p.altitudeM = (int) Math.round(hae);
        Double ce = optD(pt, "ce");
        p.accuracyM = ce == null ? 0 : (int) Math.min(255, Math.round(ce));
        XNode d = ev.child("detail");
        String cs = callsign(ev);
        p.callsign = cs == null ? "" : cs;
        XNode g = d == null ? null : d.child("__group");
        p.color = colorFromTak(attrS(g, "name"));
        p.role = roleFromTak(attrS(g, "role"));
        XNode st = d == null ? null : d.child("status");
        Double batt = optD(st, "battery");
        if (batt != null)
            p.batteryPct = (int) Math.max(0, Math.min(100, Math.round(batt)));
        XNode tr = d == null ? null : d.child("track");
        Double speed = optD(tr, "speed"), course = optD(tr, "course");
        if (speed != null && course != null && speed >= 0) {
            p.speedMps = speed;
            p.headingDeg = course;
        }
        return p;
    }

    /** An outgoing GeoChat message. */
    public static final class ChatOut {
        public String text;
        public boolean toAll;
        public String messageId;
        public String roomId;
    }

    public static ChatOut chatOut(XNode ev) {
        if (!"b-t-f".equals(type(ev)))
            return null;
        XNode c = ev.path("detail/__chat");
        if (c == null)
            return null;
        ChatOut o = new ChatOut();
        o.text = remarks(ev);
        o.roomId = c.get("id", ALL_CHAT);
        o.toAll = ALL_CHAT.equals(o.roomId)
                || ALL_CHAT.equals(c.get("chatroom"));
        o.messageId = c.get("messageId", "");
        return o.text.isEmpty() ? null : o;
    }

    /** ATAK emergency start/cancel as a team alert, or null. */
    public static TeamWire.Alert alertOut(XNode ev, String key4, int alertId,
            boolean cancel) {
        TeamWire.Alert a = new TeamWire.Alert();
        a.senderKey4 = key4;
        a.alertId = alertId;
        a.active = !cancel;
        int t = alertTypeFromCot(type(ev));
        a.type = t < 0 ? TeamWire.ALERT_SOS : t;
        double la = lat(ev), lo = lon(ev);
        if (la != 0 || lo != 0) {
            a.lat = la;
            a.lon = lo;
        }
        XNode em = ev.path("detail/emergency");
        String cs = em == null ? "" : em.text.trim();
        if (cs.isEmpty()) {
            String c = callsign(ev);
            cs = c == null ? "" : c.replaceAll("-Alert$", "");
        }
        a.callsign = cs;
        a.note = remarks(ev);
        return a;
    }

    public static boolean isPointType(String t) {
        return t.startsWith("b-m-p") || t.startsWith("a-")
                || t.startsWith("u-d-p");
    }

    /** Someone's position report (SA), as opposed to a placed marker. */
    public static boolean isPli(XNode ev) {
        return ev.path("detail/__group") != null
                || ev.path("detail/takv") != null;
    }

    public static boolean isShapeType(String t) {
        return t.equals("u-d-f") || t.equals("u-d-r") || t.equals("u-d-c-c")
                || t.equals("b-m-r");
    }

    public static TeamWire.Point pointOut(XNode ev, String key4, long nowSec) {
        TeamWire.Point p = new TeamWire.Point();
        p.authorKey4 = key4;
        p.itemId = Bytes.fnv1a32(uid(ev));
        p.lat = lat(ev);
        p.lon = lon(ev);
        Double hae = optD(ev.child("point"), "hae");
        if (hae != null)
            p.haeM = (int) Math.round(hae);
        p.timeSec = nowSec;
        p.cotType = type(ev);
        String cs = callsign(ev);
        p.callsign = cs == null ? "" : cs;
        p.remarks = remarks(ev);
        XNode col = ev.path("detail/color");
        if (col != null && col.get("argb") != null) {
            try {
                p.argb = (int) Long.parseLong(col.get("argb"));
            } catch (NumberFormatException ignored) {
            }
        }
        XNode icon = ev.path("detail/usericon");
        if (icon != null && icon.get("iconsetpath") != null)
            p.iconset = icon.get("iconsetpath");
        return p;
    }

    static double[] parsePoint(String s) {
        if (s == null)
            return null;
        String[] parts = s.split(",");
        if (parts.length < 2)
            return null;
        try {
            return new double[] { Double.parseDouble(parts[0].trim()),
                    Double.parseDouble(parts[1].trim()) };
        } catch (NumberFormatException e) {
            return null;
        }
    }

    static Integer intValue(XNode n) {
        if (n == null || n.get("value") == null)
            return null;
        try {
            return (int) Long.parseLong(n.get("value").trim());
        } catch (NumberFormatException e) {
            try {
                return (int) Math.round(Double.parseDouble(n.get("value")));
            } catch (NumberFormatException e2) {
                return null;
            }
        }
    }

    /** A drawn shape or route as a team shape, or null if unsupported. */
    public static TeamWire.Shape shapeOut(XNode ev, String key4, long nowSec) {
        String t = type(ev);
        XNode d = ev.child("detail");
        if (d == null)
            return null;
        TeamWire.Shape s = new TeamWire.Shape();
        s.authorKey4 = key4;
        s.itemId = Bytes.fnv1a32(uid(ev));
        s.timeSec = nowSec;
        String cs = callsign(ev);
        s.label = cs == null ? "" : cs;
        s.note = remarks(ev);
        Integer stroke = intValue(d.child("strokeColor"));
        if (stroke != null)
            s.strokeArgb = stroke;
        s.fillArgb = intValue(d.child("fillColor"));
        XNode sw = d.child("strokeWeight");
        if (sw != null)
            s.strokeWidth = attrD(sw, "value", 3);
        for (XNode l : d.all("link")) {
            double[] p = parsePoint(l.get("point"));
            if (p != null)
                s.points.add(p);
        }
        switch (t) {
            case "u-d-f":
                s.kind = TeamWire.SHAPE_POLYLINE;
                if (s.points.size() >= 4) {
                    double[] a = s.points.get(0),
                            b = s.points.get(s.points.size() - 1);
                    if (Math.abs(a[0] - b[0]) < 1e-7
                            && Math.abs(a[1] - b[1]) < 1e-7) {
                        s.kind = TeamWire.SHAPE_POLYGON;
                        s.points.remove(s.points.size() - 1);
                    }
                }
                break;
            case "u-d-r":
                s.kind = TeamWire.SHAPE_RECTANGLE;
                break;
            case "b-m-r":
                s.kind = TeamWire.SHAPE_ROUTE;
                XNode la = d.child("link_attr");
                if (la != null && la.get("color") != null) {
                    try {
                        s.strokeArgb = (int) Long.parseLong(la.get("color"));
                    } catch (NumberFormatException ignored) {
                    }
                }
                break;
            case "u-d-c-c":
                s.kind = TeamWire.SHAPE_CIRCLE;
                s.points.clear();
                s.points.add(new double[] { lat(ev), lon(ev) });
                XNode el = ev.path("detail/shape/ellipse");
                double r = Math.max(attrD(el, "major", 0), attrD(el, "minor", 0));
                if (r <= 0)
                    return null;
                s.radiusM = Math.round(r);
                break;
            default:
                return null;
        }
        if (s.points.isEmpty() || (s.kind != TeamWire.SHAPE_CIRCLE
                && s.points.size() < 2))
            return null;
        return s;
    }

    /** The uid a t-x-d-d event deletes, or null. */
    public static String deleteTarget(XNode ev) {
        if (!"t-x-d-d".equals(type(ev)))
            return null;
        XNode l = ev.path("detail/link");
        return l == null ? null : l.get("uid");
    }

    /** Detail elements not worth airtime when CoT is relayed whole. */
    static final String[] STRIP = { "__serverdestination", "marti",
            "_flow-tags_", "precisionlocation", "takv", "__geofence",
            "uid", "status" };

    /** Compact XML for relaying an arbitrary event over the mesh. */
    public static String compactForMesh(XNode ev) {
        XNode d = ev.child("detail");
        if (d != null) {
            for (String s : STRIP) {
                XNode c;
                while ((c = d.child(s)) != null)
                    d.children.remove(c);
            }
        }
        ev.attrs.remove("access");
        ev.attrs.remove("qos");
        ev.attrs.remove("opex");
        return ev.toXml();
    }
}
