package com.jadeonmesh.meshcore.atak.core;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;

/**
 * MeshCore companion-radio protocol: the frames the plugin exchanges with a
 * radio over BLE (Nordic UART) or USB serial in direct mode. Frames are at
 * most {@link #MAX_FRAME} bytes; byte 0 is the command, response or push code.
 * Multi-byte integers in this protocol are little-endian.
 */
public final class Companion {
    private Companion() {
    }

    public static final int MAX_FRAME = 172;
    public static final int APP_PROTOCOL_VERSION = 4;
    public static final int PUB_KEY_SIZE = 32;
    public static final int MAX_PATH = 64;
    public static final int MAX_NAME = 32;
    public static final int MAX_TEXT = 160;

    // Commands
    public static final int CMD_APP_START = 1;
    public static final int CMD_SEND_TXT_MSG = 2;
    public static final int CMD_SEND_CHANNEL_TXT_MSG = 3;
    public static final int CMD_GET_CONTACTS = 4;
    public static final int CMD_GET_DEVICE_TIME = 5;
    public static final int CMD_SET_DEVICE_TIME = 6;
    public static final int CMD_SEND_SELF_ADVERT = 7;
    public static final int CMD_SYNC_NEXT_MESSAGE = 10;
    public static final int CMD_RESET_PATH = 13;
    public static final int CMD_DEVICE_QUERY = 22;
    public static final int CMD_SEND_RAW_DATA = 25;
    public static final int CMD_GET_CHANNEL = 31;
    public static final int CMD_SEND_CHANNEL_DATA = 62;

    // Responses
    public static final int RESP_OK = 0;
    public static final int RESP_ERR = 1;
    public static final int RESP_CONTACTS_START = 2;
    public static final int RESP_CONTACT = 3;
    public static final int RESP_END_OF_CONTACTS = 4;
    public static final int RESP_SELF_INFO = 5;
    public static final int RESP_SENT = 6;
    public static final int RESP_CONTACT_MSG_RECV = 7;
    public static final int RESP_CHANNEL_MSG_RECV = 8;
    public static final int RESP_CURR_TIME = 9;
    public static final int RESP_NO_MORE_MESSAGES = 10;
    public static final int RESP_DEVICE_INFO = 13;
    public static final int RESP_CONTACT_MSG_RECV_V3 = 16;
    public static final int RESP_CHANNEL_MSG_RECV_V3 = 17;
    public static final int RESP_CHANNEL_INFO = 18;
    public static final int RESP_CHANNEL_DATA_RECV = 27;

    // Pushes
    public static final int PUSH_ADVERT = 0x80;
    public static final int PUSH_PATH_UPDATED = 0x81;
    public static final int PUSH_SEND_CONFIRMED = 0x82;
    public static final int PUSH_MSG_WAITING = 0x83;
    public static final int PUSH_RAW_DATA = 0x84;
    public static final int PUSH_LOG_RX_DATA = 0x88;
    public static final int PUSH_NEW_ADVERT = 0x8A;

    public static final int TXT_PLAIN = 0;
    public static final int TXT_SIGNED = 2;

    public static final int ADV_CHAT = 1, ADV_REPEATER = 2, ADV_ROOM = 3,
            ADV_SENSOR = 4;

    /** Channel data (GRP_DATA) arrived in firmware ver code 11. */
    public static final int MIN_FW_FOR_CHANNEL_DATA = 11;

    /** Flood. */
    public static final int OUT_PATH_UNKNOWN = 0xFF;

    public static final String PUBLIC_CHANNEL_PSK = "8b3387e9c5cdea6ac9e5edbaa115cd72";

    public static boolean isPush(int code) {
        return code >= 0x80;
    }

    // ------------------------------------------------------------ builders

    private static final class LE {
        final ByteArrayOutputStream b = new ByteArrayOutputStream(64);

        LE u8(int v) {
            b.write(v & 0xFF);
            return this;
        }

        LE u32(long v) {
            u8((int) v).u8((int) (v >>> 8)).u8((int) (v >>> 16));
            return u8((int) (v >>> 24));
        }

        LE bytes(byte[] v) {
            b.write(v, 0, v.length);
            return this;
        }

        LE cstr(String s) {
            return bytes(Bytes.utf8(s)).u8(0);
        }

        byte[] done() {
            return b.toByteArray();
        }
    }

    public static long nowSec() {
        return System.currentTimeMillis() / 1000L;
    }

    public static byte[] deviceQuery() {
        return new byte[] { (byte) CMD_DEVICE_QUERY, (byte) APP_PROTOCOL_VERSION };
    }

    public static byte[] appStart(String appName) {
        return new LE().u8(CMD_APP_START).u8(1).bytes(new byte[6]).cstr(appName)
                .done();
    }

    public static byte[] getContacts() {
        return new byte[] { (byte) CMD_GET_CONTACTS };
    }

    public static byte[] getChannel(int idx) {
        return new byte[] { (byte) CMD_GET_CHANNEL, (byte) idx };
    }

    public static byte[] syncNextMessage() {
        return new byte[] { (byte) CMD_SYNC_NEXT_MESSAGE };
    }

    public static byte[] getDeviceTime() {
        return new byte[] { (byte) CMD_GET_DEVICE_TIME };
    }

    public static byte[] setDeviceTime(long sec) {
        return new LE().u8(CMD_SET_DEVICE_TIME).u32(sec).done();
    }

    public static byte[] resetPath(byte[] pubKey) {
        return new LE().u8(CMD_RESET_PATH).bytes(pubKey).done();
    }

    /** [cmd][txt_type][attempt][ts x4][pubkey prefix x6][text]\0 */
    public static byte[] sendText(byte[] pubKey, String text, int attempt) {
        return new LE().u8(CMD_SEND_TXT_MSG).u8(TXT_PLAIN)
                .u8(Math.max(0, Math.min(255, attempt))).u32(nowSec())
                .bytes(Arrays.copyOf(pubKey, 6)).cstr(text).done();
    }

    /** [cmd][txt_type][channel][ts x4][text]\0 */
    public static byte[] sendChannelText(int channel, String text) {
        return new LE().u8(CMD_SEND_CHANNEL_TXT_MSG).u8(TXT_PLAIN).u8(channel)
                .u32(nowSec()).cstr(text).done();
    }

    /** Flooded: [62][channel][0xFF][type lo][type hi][blob]. Reply is OK, not SENT. */
    public static byte[] sendChannelData(int channel, int dataType, byte[] blob) {
        return new LE().u8(CMD_SEND_CHANNEL_DATA).u8(channel)
                .u8(OUT_PATH_UNKNOWN).u8(dataType).u8(dataType >> 8).bytes(blob)
                .done();
    }

    /** Direct path only: [25][path_len][path][payload]. */
    public static byte[] sendRawData(byte[] path, byte[] payload) {
        return new LE().u8(CMD_SEND_RAW_DATA).u8(path.length).bytes(path)
                .bytes(payload).done();
    }

    /** Longest channel text that fits after the firmware adds "name: ". */
    public static int maxChannelTextBytes(String nodeName) {
        int name = nodeName == null || nodeName.isEmpty() ? MAX_NAME - 1
                : Math.min(Bytes.utf8(nodeName).length, MAX_NAME - 1);
        int byPayload = MAX_TEXT - (name + 2);
        int byFrame = MAX_FRAME - (1 + 1 + 1 + 4 + 1 + 2);
        return Math.max(0, Math.min(byPayload, byFrame));
    }

    public static int maxDirectTextBytes() {
        return Math.min(MAX_FRAME - (1 + 1 + 1 + 4 + 6 + 1 + 2), MAX_TEXT);
    }

    // ------------------------------------------------------------- parsers

    public static final class SelfInfo {
        public byte[] publicKey;
        public double lat, lon;
        public long freqHz, bwHz;
        public int sf, cr, txPower;
        public String name = "";

        public static SelfInfo parse(byte[] f) {
            if (f.length < 58 || (f[0] & 0xFF) != RESP_SELF_INFO)
                return null;
            SelfInfo s = new SelfInfo();
            s.txPower = f[2];
            s.publicKey = Arrays.copyOfRange(f, 4, 36);
            s.lat = Bytes.i32le(f, 36) / 1e6;
            s.lon = Bytes.i32le(f, 40) / 1e6;
            s.freqHz = Bytes.u32le(f, 48);
            s.bwHz = Bytes.u32le(f, 52);
            s.sf = f[56] & 0xFF;
            s.cr = f[57] & 0xFF;
            s.name = Bytes.cstring(f, 58, f.length - 58);
            return s;
        }
    }

    public static final class DeviceInfo {
        public int fwVerCode;
        public int maxContacts, maxChannels;
        public String model, version;
        public int pathHashWidth = 1;

        public static DeviceInfo parse(byte[] f) {
            if (f.length < 4 || (f[0] & 0xFF) != RESP_DEVICE_INFO)
                return null;
            DeviceInfo d = new DeviceInfo();
            d.fwVerCode = f[1] & 0xFF;
            d.maxContacts = (f[2] & 0xFF) * 2;
            d.maxChannels = f[3] & 0xFF;
            if (f.length >= 60)
                d.model = Bytes.cstring(f, 20, 40).trim();
            if (f.length >= 80)
                d.version = Bytes.cstring(f, 60, 20).trim();
            if (f.length >= 82)
                d.pathHashWidth = Math.min(2, f[81] & 0xFF) + 1;
            return d;
        }
    }

    public static final class Contact {
        public byte[] publicKey;
        public int type;
        public int flags;
        /** Hops, or -1 for no known path (flood). */
        public int pathLength;
        public int pathHashWidth = 1;
        public byte[] path = new byte[0];
        public String name = "";
        public long lastAdvert;
        public Double lat, lon;

        public String keyHex() {
            return Bytes.hex(publicKey);
        }

        public String key4() {
            return Bytes.hex(publicKey, 0, 4);
        }

        /** Path bytes for raw data, or null without a usable 1-byte-hash path. */
        public byte[] directRoute() {
            if (pathHashWidth != 1 || pathLength < 0 || path.length < pathLength)
                return null;
            return Arrays.copyOf(path, pathLength);
        }

        public static Contact parse(byte[] f) {
            if (f.length < 1 + 32 + 3 + 64 + 32 + 4)
                return null;
            int code = f[0] & 0xFF;
            if (code != RESP_CONTACT && code != PUSH_NEW_ADVERT)
                return null;
            Contact c = new Contact();
            c.publicKey = Arrays.copyOfRange(f, 1, 33);
            int zeros = 0;
            for (byte b : c.publicKey)
                if (b == 0)
                    zeros++;
            if (zeros > 16)
                return null;
            c.type = f[33] & 0xFF;
            c.flags = f[34] & 0xFF;
            int pl = f[35] & 0xFF;
            int byteLen = 0;
            if (pl == 0xFF) {
                c.pathLength = -1;
            } else {
                c.pathHashWidth = ((pl & 0xC0) >> 6) + 1;
                c.pathLength = pl & 0x3F;
                byteLen = Math.min(MAX_PATH, c.pathLength * c.pathHashWidth);
            }
            c.path = Arrays.copyOfRange(f, 36, 36 + byteLen);
            c.name = Bytes.cstring(f, 100, 32);
            c.lastAdvert = Bytes.u32le(f, 132);
            if (f.length >= 144) {
                int la = Bytes.i32le(f, 136), lo = Bytes.i32le(f, 140);
                if (la != 0 || lo != 0) {
                    c.lat = la / 1e6;
                    c.lon = lo / 1e6;
                }
            }
            return c;
        }
    }

    public static final class Channel {
        public int index;
        public String name = "";
        public byte[] psk;

        public boolean isEmpty() {
            return name.isEmpty();
        }

        public boolean isPublic() {
            return Bytes.hex(psk).equals(PUBLIC_CHANNEL_PSK);
        }

        public boolean isHashtag() {
            return name.startsWith("#");
        }

        /** Private channels only: public and hashtag channels reach strangers. */
        public boolean isPrivate() {
            return !isPublic() && !isHashtag();
        }

        public static Channel parse(byte[] f) {
            if (f.length < 50 || (f[0] & 0xFF) != RESP_CHANNEL_INFO)
                return null;
            Channel c = new Channel();
            c.index = f[1] & 0xFF;
            c.name = Bytes.cstring(f, 2, 32).trim();
            c.psk = Arrays.copyOfRange(f, 34, 50);
            return c;
        }
    }

    /** RESP_CODE_SENT: [6][is_flood][expected_ack x4][timeout x4]. */
    public static final class Sent {
        public boolean flood;
        public long ackCode;
        public long timeoutMs;

        public static Sent parse(byte[] f) {
            if (f.length < 10 || (f[0] & 0xFF) != RESP_SENT)
                return null;
            Sent s = new Sent();
            s.flood = f[1] != 0;
            s.ackCode = Bytes.u32le(f, 2);
            s.timeoutMs = Bytes.u32le(f, 6);
            return s;
        }
    }

    public static final class ChannelText {
        public int channel;
        /** Hops when flooded, else -1. */
        public int hops = -1;
        public long timestamp;
        public String senderName = "";
        public String text = "";
        public double snr;

        public static ChannelText parse(byte[] f) {
            try {
                int code = f[0] & 0xFF;
                int o;
                ChannelText m = new ChannelText();
                int txtType;
                if (code == RESP_CHANNEL_MSG_RECV_V3) {
                    m.snr = f[1] / 4.0;
                    boolean hasPath = (f[2] & 0x01) != 0;
                    m.channel = f[4] & 0xFF;
                    int pb = f[5] & 0xFF;
                    o = 6;
                    if (pb != 0xFF) {
                        int width = ((pb & 0xC0) >> 6) + 1;
                        m.hops = pb & 0x3F;
                        if (hasPath && m.hops > 0)
                            o += m.hops * width;
                    }
                    txtType = f[o++] & 0xFF;
                } else if (code == RESP_CHANNEL_MSG_RECV) {
                    m.channel = f[1] & 0xFF;
                    int pb = f[2] & 0xFF;
                    m.hops = pb == 0xFF ? -1 : pb & 0x3F;
                    txtType = f[3] & 0xFF;
                    o = 4;
                } else {
                    return null;
                }
                if (txtType != TXT_PLAIN)
                    return null;
                m.timestamp = Bytes.u32le(f, o);
                o += 4;
                String full = Bytes.cstring(f, o, f.length - o);
                int colon = full.indexOf(':');
                if (colon > 0 && colon < full.length() - 1 && colon < 50) {
                    String who = full.substring(0, colon);
                    if (who.indexOf('[') < 0 && who.indexOf(']') < 0) {
                        m.senderName = who;
                        int off = colon + 1;
                        if (off < full.length() && full.charAt(off) == ' ')
                            off++;
                        m.text = full.substring(off);
                        return m;
                    }
                }
                m.text = full;
                return m;
            } catch (ArrayIndexOutOfBoundsException e) {
                return null;
            }
        }
    }

    public static final class DirectText {
        public byte[] senderPrefix; // 6 bytes
        public long timestamp;
        public String text = "";
        public int txtType;

        public String senderPrefixHex() {
            return Bytes.hex(senderPrefix);
        }

        /** [code][snr][res][res]? [prefix x6][path_len][txt_type][ts x4][sig x4]?[text] */
        public static DirectText parse(byte[] f) {
            try {
                int code = f[0] & 0xFF;
                int o;
                if (code == RESP_CONTACT_MSG_RECV_V3)
                    o = 4;
                else if (code == RESP_CONTACT_MSG_RECV)
                    o = 1;
                else
                    return null;
                DirectText m = new DirectText();
                m.senderPrefix = Arrays.copyOfRange(f, o, o + 6);
                o += 6;
                o += 1; // path length
                m.txtType = f[o++] & 0xFF;
                m.timestamp = Bytes.u32le(f, o);
                o += 4;
                int shifted = m.txtType >> 2;
                if (shifted == TXT_SIGNED || m.txtType == TXT_SIGNED)
                    o += 4;
                if (m.txtType != TXT_PLAIN && shifted != TXT_PLAIN
                        && shifted != TXT_SIGNED && m.txtType != TXT_SIGNED)
                    return null;
                m.text = Bytes.cstring(f, o, f.length - o);
                return m.text.isEmpty() ? null : m;
            } catch (ArrayIndexOutOfBoundsException e) {
                return null;
            }
        }
    }

    /** RESP_CODE_CHANNEL_DATA_RECV: 9-byte header, no sender identity. */
    public static final class ChannelData {
        public int snrRaw;
        public int channel;
        public int pathLenByte;
        public int dataType;
        public byte[] payload;

        public boolean flooded() {
            return pathLenByte != 0xFF;
        }

        public int hops() {
            return flooded() ? pathLenByte & 0x3F : 0;
        }

        public static ChannelData parse(byte[] f) {
            if (f.length < 9 || (f[0] & 0xFF) != RESP_CHANNEL_DATA_RECV)
                return null;
            int len = f[8] & 0xFF;
            if (f.length < 9 + len)
                return null;
            ChannelData d = new ChannelData();
            d.snrRaw = f[1];
            d.channel = f[4] & 0xFF;
            d.pathLenByte = f[5] & 0xFF;
            d.dataType = (f[6] & 0xFF) | ((f[7] & 0xFF) << 8);
            d.payload = Arrays.copyOfRange(f, 9, 9 + len);
            return d;
        }
    }

    /** PUSH_CODE_RAW_DATA: [0x84][snr*4][rssi][0xFF][payload]. */
    public static final class RawData {
        public double snr;
        public int rssi;
        public byte[] payload;

        public static RawData parse(byte[] f) {
            if (f.length < 5 || (f[0] & 0xFF) != PUSH_RAW_DATA)
                return null;
            RawData r = new RawData();
            r.snr = f[1] / 4.0;
            r.rssi = f[2];
            r.payload = Arrays.copyOfRange(f, 4, f.length);
            return r;
        }
    }

    /** Serial framing (USB/TCP): [marker][len u16 LE][payload]. */
    public static final int SERIAL_TO_RADIO = '<';
    public static final int SERIAL_FROM_RADIO = '>';

    public static byte[] serialFrame(byte[] payload) {
        byte[] out = new byte[3 + payload.length];
        out[0] = (byte) SERIAL_TO_RADIO;
        out[1] = (byte) payload.length;
        out[2] = (byte) (payload.length >> 8);
        System.arraycopy(payload, 0, out, 3, payload.length);
        return out;
    }
}
