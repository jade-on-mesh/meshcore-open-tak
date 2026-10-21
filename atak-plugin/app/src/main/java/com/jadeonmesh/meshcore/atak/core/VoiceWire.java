package com.jadeonmesh.meshcore.atak.core;

import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.TreeSet;

/**
 * Voice and photo clip formats (Java port of lib/vox/voice_wire.dart).
 *
 * <pre>
 *   Control plane (text message, DM or channel):
 *     VE3:{sid}:{mode}:{total}:{durS}   Codec2 (standard VE3)
 *     VM1:...                            Mimi neural codec
 *     VI1:{sid}:{mode}:{total}:{aspect}  AV1 still image
 *   Data plane (raw data on a direct path, or GRP_DATA 0x5643 on a channel):
 *     packet  [0x56][sid:4][index][codec...]   (0x57: one salt byte appended)
 *     fetch   [0x72][sid:4][flags][key6][count][indices...]
 *   Text fetch request (DM, no route): VR3:{sid}:{a|m ranges}:{key6}
 * </pre>
 */
public final class VoiceWire {
    private VoiceWire() {
    }

    public enum Mode {
        MODE_700C(0, 8, "700C", 4, 40),
        MODE_1200(1, 5, "1200", 6, 40),
        MODE_2400(2, 1, "2400", 6, 20),
        MODE_1300(3, 4, "1300", 7, 40),
        MODE_1400(4, 3, "1400", 7, 40),
        MODE_1600(5, 2, "1600", 8, 40),
        MODE_3200(6, 0, "3200", 8, 20),
        MIMI(32, -1, "Mimi", 11, 80),
        AV1_IMAGE(40, -1, "AV1 image", 1, 1);

        public final int wireId;
        public final int codec2Id;
        public final String label;
        public final int bytesPerFrame;
        public final int frameMs;

        Mode(int wireId, int codec2Id, String label, int bytesPerFrame,
                int frameMs) {
            this.wireId = wireId;
            this.codec2Id = codec2Id;
            this.label = label;
            this.bytesPerFrame = bytesPerFrame;
            this.frameMs = frameMs;
        }

        public boolean isMimi() {
            return this == MIMI;
        }

        public boolean isImage() {
            return this == AV1_IMAGE;
        }

        public boolean isAudio() {
            return !isImage();
        }

        public boolean isCodec2() {
            return !isMimi() && !isImage();
        }

        /** Codec2 works at 8 kHz; Mimi at {@link #MIMI_SAMPLE_RATE}. */
        public int samplesPerFrame() {
            return CODEC2_SAMPLE_RATE * frameMs / 1000;
        }

        public int bytesPerSecond() {
            return bytesPerFrame * 1000 / frameMs;
        }

        public int framesPerPacket() {
            return MAX_CODEC_BYTES_PER_PACKET / bytesPerFrame;
        }

        public int bytesPerPacket() {
            return framesPerPacket() * bytesPerFrame;
        }

        public static Mode fromWireId(int id) {
            for (Mode m : values())
                if (m.wireId == id)
                    return m;
            return null;
        }
    }

    public static final int CODEC2_SAMPLE_RATE = 8000;
    public static final Mode DEFAULT_CODEC2 = Mode.MODE_1200;
    public static final int MAX_CODEC_BYTES_PER_PACKET = 156;
    public static final int MAX_PACKETS = 255;
    public static final int MAX_DURATION_S = 600;

    public static final int PACKET_MAGIC = 0x56;
    public static final int PACKET_SALTED_MAGIC = 0x57;
    public static final int FETCH_MAGIC = 0x72;
    public static final int FETCH_MISSING_ONLY = 0x01;
    public static final int FETCH_SALT_OK = 0x02;

    /** GRP_DATA type for clip transfers on a channel ('VC'). */
    public static final int CHANNEL_DATA_TYPE = 0x5643;

    // Mimi (Kyutai), as exported by tool/vox/mimi_export.py.
    public static final int MIMI_SAMPLE_RATE = 24000;
    public static final int MIMI_FRAME_SAMPLES = 1920;
    public static final int MIMI_CODEBOOKS = 8;
    public static final int MIMI_BITS = 11;
    public static final int MIMI_BYTES_PER_FRAME = 11;
    public static final int MIMI_MAX_FRAMES = 250;
    public static final int MIMI_MAX_SAMPLES = MIMI_MAX_FRAMES * MIMI_FRAME_SAMPLES;

    private static final SecureRandom RNG = new SecureRandom();

    public static String newSessionId() {
        return String.format(Locale.US, "%08x", RNG.nextInt());
    }

    public static boolean isSessionId(String s) {
        return Bytes.isHex(s, 8);
    }

    public static String key6Hex(byte[] publicKey) {
        return Bytes.hex(publicKey, 0, Math.min(6, publicKey.length));
    }

    static Long base36(String s) {
        if (s.isEmpty() || s.length() > 7)
            return null;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z')))
                return null;
        }
        return Long.parseLong(s, 36);
    }

    // ------------------------------------------------------------ envelope

    public static final class Envelope {
        public static final String PREFIX = "VE3:";
        public static final String MIMI_PREFIX = "VM1:";
        public static final String IMAGE_PREFIX = "VI1:";

        public final String sessionId;
        public final Mode mode;
        public final int totalPackets;
        /** Seconds for audio; width*100/height for images. */
        public final int durationSeconds;
        /**
         * Text sent with the photo or clip, after a space in the same
         * message ("VI1:... Look at this"); empty for none.
         */
        public final String caption;

        public Envelope(String sessionId, Mode mode, int totalPackets,
                int durationSeconds) {
            this(sessionId, mode, totalPackets, durationSeconds, "");
        }

        public Envelope(String sessionId, Mode mode, int totalPackets,
                int durationSeconds, String caption) {
            this.sessionId = sessionId;
            this.mode = mode;
            this.totalPackets = totalPackets;
            this.durationSeconds = durationSeconds;
            this.caption = caption == null ? "" : caption.trim();
        }

        public static String prefixFor(Mode m) {
            return m.isImage() ? IMAGE_PREFIX : m.isMimi() ? MIMI_PREFIX : PREFIX;
        }

        public static boolean looksLikeEnvelope(String t) {
            return t.startsWith(PREFIX) || t.startsWith(MIMI_PREFIX)
                    || t.startsWith(IMAGE_PREFIX);
        }

        public static Envelope parse(String text) {
            String t = text.trim();
            if (t.length() < PREFIX.length())
                return null;
            String head = t.substring(0, PREFIX.length());
            if (!head.equals(PREFIX) && !head.equals(MIMI_PREFIX)
                    && !head.equals(IMAGE_PREFIX))
                return null;
            // The envelope ends at the first whitespace; the rest is the
            // caption.
            int gap = -1;
            for (int i = 0; i < t.length() && gap < 0; i++)
                if (Character.isWhitespace(t.charAt(i)))
                    gap = i;
            String fields = gap < 0 ? t : t.substring(0, gap);
            String caption = gap < 0 ? "" : t.substring(gap + 1);
            String[] parts = fields.substring(PREFIX.length()).split(":", -1);
            if (parts.length != 4)
                return null;
            Long sid = base36(parts[0]), modeId = base36(parts[1]),
                    total = base36(parts[2]), dur = base36(parts[3]);
            if (sid == null || modeId == null || total == null || dur == null)
                return null;
            if (sid > 0xFFFFFFFFL)
                return null;
            Mode mode = Mode.fromWireId(modeId.intValue());
            if (mode == null || !prefixFor(mode).equals(head))
                return null;
            if (total < 1 || total > MAX_PACKETS)
                return null;
            if (dur < 0 || dur > MAX_DURATION_S)
                return null;
            return new Envelope(String.format(Locale.US, "%08x", sid), mode,
                    total.intValue(), dur.intValue(), caption);
        }

        public String encode() {
            long sid = Long.parseLong(sessionId, 16);
            return prefixFor(mode) + Long.toString(sid, 36) + ":"
                    + Integer.toString(mode.wireId, 36) + ":"
                    + Integer.toString(totalPackets, 36) + ":"
                    + Integer.toString(durationSeconds, 36)
                    + (caption.isEmpty() ? "" : " " + caption);
        }

        public boolean isImage() {
            return mode.isImage();
        }

        public double imageAspect() {
            return isImage() && durationSeconds > 0 ? durationSeconds / 100.0 : 1;
        }
    }

    // -------------------------------------------------------------- packet

    public static final class Packet {
        public static final int HEADER = 6;
        public final String sessionId;
        public final int index;
        public final byte[] codecData;

        public Packet(String sessionId, int index, byte[] codecData) {
            this.sessionId = sessionId;
            this.index = index;
            this.codecData = codecData;
        }

        public static boolean isPacket(byte[] p) {
            return p.length > 0 && ((p[0] & 0xFF) == PACKET_MAGIC
                    || (p[0] & 0xFF) == PACKET_SALTED_MAGIC);
        }

        public static Packet parse(byte[] p) {
            if (!isPacket(p))
                return null;
            boolean salted = (p[0] & 0xFF) == PACKET_SALTED_MAGIC;
            int end = salted ? p.length - 1 : p.length;
            if (end <= HEADER)
                return null;
            return new Packet(Bytes.hex(p, 1, 4), p[5] & 0xFF,
                    java.util.Arrays.copyOfRange(p, HEADER, end));
        }

        /** Standard packet, or with salt >= 0 a salted (0x57) one. */
        public byte[] encode(int salt) {
            int extra = salt < 0 ? 0 : 1;
            byte[] out = new byte[HEADER + codecData.length + extra];
            out[0] = (byte) (salt < 0 ? PACKET_MAGIC : PACKET_SALTED_MAGIC);
            System.arraycopy(Bytes.unhex(sessionId), 0, out, 1, 4);
            out[5] = (byte) index;
            System.arraycopy(codecData, 0, out, HEADER, codecData.length);
            if (salt >= 0)
                out[out.length - 1] = (byte) salt;
            return out;
        }
    }

    public static List<Packet> packetize(String sid, byte[] bits, Mode mode) {
        int per = mode.bytesPerPacket();
        List<Packet> out = new ArrayList<>();
        for (int off = 0, i = 0; off < bits.length && i < MAX_PACKETS; off += per, i++) {
            int end = Math.min(off + per, bits.length);
            out.add(new Packet(sid, i,
                    java.util.Arrays.copyOfRange(bits, off, end)));
        }
        return out;
    }

    // --------------------------------------------------------------- fetch

    public static final class FetchRequest {
        public static final int MIN_LENGTH = 13;
        public final String sessionId;
        public final String requesterKey6;
        /** Null = all packets. */
        public final List<Integer> missing;
        public final boolean saltOk;

        public FetchRequest(String sessionId, String requesterKey6,
                List<Integer> missing, boolean saltOk) {
            this.sessionId = sessionId;
            this.requesterKey6 = requesterKey6;
            this.missing = missing;
            this.saltOk = saltOk;
        }

        public static FetchRequest parse(byte[] p) {
            if (p.length < MIN_LENGTH || (p[0] & 0xFF) != FETCH_MAGIC)
                return null;
            int flags = p[5] & 0xFF;
            String key = Bytes.hex(p, 6, 6);
            int count = p[12] & 0xFF;
            List<Integer> missing = null;
            if ((flags & FETCH_MISSING_ONLY) != 0) {
                if (p.length < MIN_LENGTH + count)
                    return null;
                missing = new ArrayList<>();
                for (int i = 0; i < count; i++) {
                    int v = p[MIN_LENGTH + i] & 0xFF;
                    if (v < MAX_PACKETS)
                        missing.add(v);
                }
            }
            return new FetchRequest(Bytes.hex(p, 1, 4), key, missing,
                    (flags & FETCH_SALT_OK) != 0);
        }

        public byte[] encode() {
            return encode(null);
        }

        /**
         * With {@code salt}, a missing-only request repeats one of its indices
         * 1-8 times, so a retry is never byte-identical to an earlier one
         * (radios drop payloads they have seen). The layout stays plain VE3,
         * which firmware that routes photo traffic by shape still recognises.
         */
        public byte[] encode(Integer salt) {
            List<Integer> m = new ArrayList<>();
            if (missing != null) {
                TreeSet<Integer> s = new TreeSet<>();
                for (int v : missing)
                    if (v >= 0 && v < MAX_PACKETS)
                        s.add(v);
                m.addAll(s);
            }
            int room = salt == null ? 150 : 132;
            if (m.size() > room)
                m = new ArrayList<>(m.subList(0, room));
            if (salt != null && !m.isEmpty()) {
                int v = m.get(((salt & 0xFF) >> 3) % m.size());
                for (int i = 0; i <= (salt & 7); i++)
                    m.add(v);
            }
            byte[] out = new byte[MIN_LENGTH + m.size()];
            out[0] = (byte) FETCH_MAGIC;
            System.arraycopy(Bytes.unhex(sessionId), 0, out, 1, 4);
            out[5] = (byte) ((missing == null ? 0 : FETCH_MISSING_ONLY)
                    | (saltOk ? FETCH_SALT_OK : 0));
            System.arraycopy(Bytes.unhex(requesterKey6), 0, out, 6, 6);
            out[12] = (byte) m.size();
            for (int i = 0; i < m.size(); i++)
                out[MIN_LENGTH + i] = (byte) (int) m.get(i);
            return out;
        }
    }

    /** VR3 text fetch request, sent as a DM when there is no direct route. */
    public static final class TextRequest {
        public static final String PREFIX = "VR3:";

        public static boolean looksLikeRequest(String t) {
            return t.startsWith(PREFIX);
        }

        public static FetchRequest parse(String text) {
            String t = text.trim();
            if (!t.startsWith(PREFIX))
                return null;
            String[] parts = t.substring(PREFIX.length()).split(":", -1);
            if (parts.length != 3)
                return null;
            Long sid = base36(parts[0]);
            if (sid == null || sid > 0xFFFFFFFFL)
                return null;
            String key = parts[2].toLowerCase(Locale.US);
            if (!Bytes.isHex(key, 12))
                return null;
            String want = parts[1];
            List<Integer> missing;
            if (want.equals("a")) {
                missing = null;
            } else if (want.startsWith("m") && want.length() > 1) {
                missing = decodeRanges(want.substring(1));
                if (missing == null || missing.isEmpty())
                    return null;
            } else {
                return null;
            }
            return new FetchRequest(String.format(Locale.US, "%08x", sid), key,
                    missing, false);
        }

        public static String encode(FetchRequest req) {
            long sid = Long.parseLong(req.sessionId, 16);
            String want = req.missing == null || req.missing.isEmpty() ? "a"
                    : "m" + encodeRanges(req.missing);
            return PREFIX + Long.toString(sid, 36) + ":" + want + ":"
                    + req.requesterKey6.toLowerCase(Locale.US);
        }

        static String encodeRanges(List<Integer> indices) {
            List<Integer> s = new ArrayList<>();
            for (int v : new TreeSet<>(indices))
                if (v >= 0 && v < MAX_PACKETS)
                    s.add(v);
            StringBuilder sb = new StringBuilder();
            int i = 0;
            while (i < s.size()) {
                int j = i;
                while (j + 1 < s.size() && s.get(j + 1) == s.get(j) + 1)
                    j++;
                if (sb.length() > 0)
                    sb.append('.');
                sb.append(Integer.toString(s.get(i), 36));
                if (j > i)
                    sb.append('-').append(Integer.toString(s.get(j), 36));
                i = j + 1;
            }
            return sb.toString();
        }

        static List<Integer> decodeRanges(String s) {
            List<Integer> out = new ArrayList<>();
            for (String tok : s.split("\\.")) {
                if (tok.isEmpty())
                    continue;
                String[] ends = tok.split("-", -1);
                if (ends.length > 2)
                    return null;
                Long a = base36(ends[0]);
                Long b = ends.length == 2 ? base36(ends[1]) : a;
                if (a == null || b == null || a > b || b >= MAX_PACKETS)
                    return null;
                for (long v = a; v <= b; v++)
                    out.add((int) v);
            }
            return out;
        }
    }

    // ---------------------------------------------------------------- Mimi

    /** Packs [codebook][frame] codes into 11 bytes per frame, MSB first. */
    public static byte[] packMimi(long[] codes, int frames, int stride) {
        byte[] out = new byte[frames * MIMI_BYTES_PER_FRAME];
        int bitPos = 0;
        for (int f = 0; f < frames; f++) {
            for (int q = 0; q < MIMI_CODEBOOKS; q++) {
                int v = (int) (codes[q * stride + f] & 0x7FF);
                for (int b = MIMI_BITS - 1; b >= 0; b--) {
                    if (((v >> b) & 1) == 1)
                        out[bitPos >> 3] |= (byte) (0x80 >> (bitPos & 7));
                    bitPos++;
                }
            }
        }
        return out;
    }

    /** Inverse of {@link #packMimi}: [codebook][frame] with [stride] columns. */
    public static long[] unpackMimi(byte[] bytes, int stride) {
        int frames = Math.min(stride, bytes.length / MIMI_BYTES_PER_FRAME);
        long[] out = new long[MIMI_CODEBOOKS * stride];
        int bitPos = 0;
        for (int f = 0; f < frames; f++) {
            for (int q = 0; q < MIMI_CODEBOOKS; q++) {
                int v = 0;
                for (int b = 0; b < MIMI_BITS; b++) {
                    int bit = (bytes[bitPos >> 3] >> (7 - (bitPos & 7))) & 1;
                    v = (v << 1) | bit;
                    bitPos++;
                }
                out[q * stride + f] = v;
            }
        }
        return out;
    }

    // ------------------------------------------------------------- airtime

    /** LoRa airtime for [packets] packets carrying [codecBytes] each. */
    public static long airtimeMs(int packets, int codecBytes, int sf,
            double bwKhz, int cr, int pathLength) {
        if (packets <= 0 || sf <= 0 || bwKhz <= 0)
            return 0;
        int payload = 2 + pathLength + Packet.HEADER + codecBytes;
        double tSym = Math.pow(2, sf) / (bwKhz * 1000);
        int de = (sf >= 11 && bwKhz <= 125) ? 1 : 0;
        int c = Math.max(5, Math.min(8, cr)) - 4;
        double num = 8.0 * payload - 4 * sf + 28 + 16;
        double den = 4.0 * (sf - 2 * de);
        double nPayload = 8 + Math.max(Math.ceil(num / den) * (c + 4), 0);
        double perPacket = (8 + 4.25 + nPayload) * tSym;
        return Math.round(perPacket * packets * 1000);
    }
}
