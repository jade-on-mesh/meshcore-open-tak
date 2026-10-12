package com.jadeonmesh.meshcore.atak.radio;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * Messenger IPC between this plugin (inside ATAK) and the MeshCore Open TAK
 * app's TakBridgeService. Mirrored in the app's TakBridgeService.kt; bump
 * {@link #VERSION} on incompatible changes.
 *
 * Every message carries a Bundle. Large media moves in {@link #CHUNK}-sized
 * MEDIA_CHUNK messages so no single Binder transaction gets near 1 MB.
 */
public final class BridgeProtocol {
    private BridgeProtocol() {
    }

    public static final int VERSION = 1;
    public static final String ACTION = "com.jadeonmesh.meshcore.TAK_BRIDGE";
    public static final String DEFAULT_PACKAGE = "com.jadeonmesh.meshcore_open_vox";
    public static final int CHUNK = 64 * 1024;

    // Plugin -> app
    public static final int HELLO = 1;
    public static final int SEND_CHANNEL_DATA = 2;
    public static final int SEND_CHANNEL_TEXT = 3;
    public static final int SEND_DIRECT_TEXT = 4;
    public static final int SEND_TEAM = 5;
    public static final int PUBLISH_SELF = 6;
    public static final int REFRESH_CONTACTS = 7;
    public static final int BYE = 8;
    public static final int MEDIA_CHUNK_IN = 20;
    public static final int MEDIA_SEND = 21;
    public static final int MEDIA_FETCH = 22;
    public static final int MEDIA_GET = 23;
    public static final int MEDIA_REGISTER = 24;

    // App -> plugin
    public static final int STATE = 101;
    public static final int CHANNEL_DATA = 102;
    public static final int CHANNEL_TEXT = 103;
    public static final int DIRECT_TEXT = 104;
    public static final int TEAM_PAYLOAD = 105;
    public static final int RESULT = 106;
    public static final int MEDIA_STATE = 110;
    public static final int MEDIA_CHUNK_OUT = 111;
    public static final int MEDIA_REGISTERED = 112;

    // Bundle keys
    public static final String K_VERSION = "v";
    public static final String K_ID = "id";
    public static final String K_OK = "ok";
    public static final String K_MESSAGE = "msg";
    public static final String K_CHANNEL = "ch";
    public static final String K_TYPE = "type";
    public static final String K_PAYLOAD = "payload";
    public static final String K_BLOBS = "blobs";
    public static final String K_GAP = "gap";
    public static final String K_TEXT = "text";
    public static final String K_KEY = "key";
    public static final String K_SENDER = "sender";
    public static final String K_TS = "ts";
    public static final String K_HOPS = "hops";
    public static final String K_OWN = "own";

    public static final String K_CONNECTED = "connected";
    public static final String K_DETAIL = "detail";
    public static final String K_SELF_KEY = "selfKey";
    public static final String K_SELF_NAME = "selfName";
    public static final String K_SF = "sf";
    public static final String K_BW = "bw";
    public static final String K_CR = "cr";
    public static final String K_CHANNEL_DATA_OK = "channelData";
    public static final String K_TEAM_CHANNEL = "teamChannel";
    public static final String K_APP_OWNS_TEAM = "appOwnsTeam";
    public static final String K_CH_INDEX = "chIndex";
    public static final String K_CH_NAME = "chName";
    public static final String K_CH_PRIVATE = "chPrivate";
    public static final String K_CONTACT_KEYS = "cKeys";
    public static final String K_CONTACT_NAMES = "cNames";
    public static final String K_CONTACT_PATH = "cPath";
    public static final String K_CONTACT_TYPE = "cType";
    public static final String K_CODEC_MIMI = "mimi";
    public static final String K_CODEC_AV1 = "av1";
    public static final String K_CODEC_CODEC2 = "codec2";

    // Media
    public static final String K_XFER = "xfer";
    public static final String K_INDEX = "index";
    public static final String K_LAST = "last";
    public static final String K_BYTES = "bytes";
    /** "pcm16" (mono LE; uploads are 48 kHz, downloads carry K_RATE) or "jpeg". */
    public static final String K_KIND = "kind";
    public static final String K_RATE = "rate";
    public static final String K_SID = "sid";
    public static final String K_ENVELOPE = "env";
    public static final String K_STATUS = "status";
    public static final String K_HAVE = "have";
    public static final String K_TOTAL = "total";
    public static final String K_MODE = "mode";
    public static final String K_PACKETS = "packets";
    public static final String K_EXTRA = "extra";
    /** Image detail preset for MEDIA_SEND/REGISTER: 0 small .. 2 large. */
    public static final String K_DETAIL_LEVEL = "detailLevel";

    public static final int UPLOAD_PCM_RATE = 48000;

    /** Packs blobs as [len u8][blob]... (each blob is at most 255 bytes). */
    public static byte[] packBlobs(List<byte[]> blobs) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte[] b : blobs) {
            if (b.length > 255)
                throw new IllegalArgumentException("blob too long");
            out.write(b.length);
            out.write(b, 0, b.length);
        }
        return out.toByteArray();
    }

    public static List<byte[]> unpackBlobs(byte[] packed) {
        List<byte[]> out = new ArrayList<>();
        int i = 0;
        while (packed != null && i < packed.length) {
            int n = packed[i++] & 0xFF;
            if (i + n > packed.length)
                break;
            byte[] b = new byte[n];
            System.arraycopy(packed, i, b, 0, n);
            out.add(b);
            i += n;
        }
        return out;
    }
}
