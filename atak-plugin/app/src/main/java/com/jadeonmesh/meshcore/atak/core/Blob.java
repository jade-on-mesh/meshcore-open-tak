package com.jadeonmesh.meshcore.atak.core;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.zip.DataFormatException;
import java.util.zip.Deflater;
import java.util.zip.Inflater;

/**
 * Chunked transfer of a small payload over team GRP_DATA ('X' = 0x58), for
 * CoT the compact formats can't express (casevac, ranges, custom types) and
 * small files.
 *
 * <pre>
 * chunk      [0x58][key4][xferId u16][idx u8][total u8][body]
 *            idx &lt; total: data chunk, body &lt;= {@link #DATA_BODY}
 *            idx == total: XOR parity, body = [lenXor][xor of padded bodies]
 * payload    [kind u8][flags u8][crc16 u16][nameLen][name][data]
 *            kind 1 = CoT XML, 2 = file. flags bit0 = data is raw-deflated.
 *            crc16 (CCITT-FALSE) covers the data as sent (after deflate).
 * </pre>
 *
 * One parity chunk recovers any single lost chunk, as in the image transport.
 */
public final class Blob {
    private Blob() {
    }

    public static final int HEADER = 1 + 4 + 2 + 1 + 1;
    public static final int DATA_BODY = TeamWire.MAX_PAYLOAD - HEADER - 1; // 153
    public static final int MAX_CHUNKS = 32;
    public static final int MAX_PAYLOAD_BYTES = DATA_BODY * MAX_CHUNKS;

    public static final int KIND_COT = 1;
    public static final int KIND_FILE = 2;

    public static final class Content {
        public final int kind;
        public final String name;
        public final byte[] data;

        public Content(int kind, String name, byte[] data) {
            this.kind = kind;
            this.name = name == null ? "" : name;
            this.data = data;
        }
    }

    // -------------------------------------------------------------- encode

    /** Payload for [content], deflated when that is smaller. */
    public static byte[] pack(Content c) {
        byte[] z = deflate(c.data);
        boolean useZ = z.length < c.data.length;
        byte[] body = useZ ? z : c.data;
        Bytes.W w = new Bytes.W().u8(c.kind).u8(useZ ? 1 : 0).u16(crc16(body))
                .str(c.name, 64).bytes(body);
        return w.done();
    }

    public static Content unpack(byte[] payload) {
        try {
            Bytes.R r = new Bytes.R(payload);
            int kind = r.u8();
            int flags = r.u8();
            int crc = r.u16();
            String name = r.str();
            if (name == null)
                return null;
            byte[] body = r.take(r.remaining());
            if (crc16(body) != crc)
                return null;
            byte[] data = (flags & 1) != 0 ? inflate(body, 64 * 1024) : body;
            if (data == null)
                return null;
            return new Content(kind, name, data);
        } catch (IndexOutOfBoundsException e) {
            return null;
        }
    }

    /** Number of radio packets [payload] needs, parity included. */
    public static int packetsFor(int payloadBytes) {
        int n = (payloadBytes + DATA_BODY - 1) / DATA_BODY;
        return n <= 1 ? n : n + 1;
    }

    /** Splits a payload into chunk blobs (with parity when there are 2+). */
    public static List<byte[]> chunk(String key4, int xferId, byte[] payload) {
        int n = Math.max(1, (payload.length + DATA_BODY - 1) / DATA_BODY);
        if (n > MAX_CHUNKS)
            throw new IllegalArgumentException(
                    "payload too large: " + payload.length + " bytes");
        List<byte[]> out = new ArrayList<>();
        byte[] parity = new byte[DATA_BODY];
        int lenXor = 0;
        for (int i = 0; i < n; i++) {
            int off = i * DATA_BODY;
            int len = Math.min(DATA_BODY, payload.length - off);
            for (int k = 0; k < len; k++)
                parity[k] ^= payload[off + k];
            lenXor ^= len;
            out.add(header(key4, xferId, i, n).bytes(payload, off, len).done());
        }
        if (n > 1)
            out.add(header(key4, xferId, n, n).u8(lenXor).bytes(parity).done());
        return out;
    }

    private static Bytes.W header(String key4, int xferId, int idx, int total) {
        return new Bytes.W().u8(TeamWire.MSG_CHUNK)
                .bytes(TeamWire.key4(key4)).u16(xferId).u8(idx).u8(total);
    }

    // -------------------------------------------------------------- decode

    /** Reassembles chunks from many senders; call {@link #accept} per blob. */
    public static final class Reassembler {
        private static final long TTL_MS = 10 * 60_000;

        private static final class Partial {
            final int total;
            final byte[][] bodies;
            byte[] parity;
            int lenXor;
            long touched;

            Partial(int total) {
                this.total = total;
                this.bodies = new byte[total][];
            }

            int have() {
                int c = 0;
                for (byte[] b : bodies)
                    if (b != null)
                        c++;
                return c;
            }
        }

        private final Map<String, Partial> parts = new HashMap<>();
        private final Map<String, Long> done = new HashMap<>();

        /**
         * Returns the complete payload when [blob] finishes a transfer, else
         * null. Duplicates of finished transfers are ignored.
         */
        public synchronized byte[] accept(byte[] blob, long nowMs) {
            if (blob.length < HEADER || (blob[0] & 0xFF) != TeamWire.MSG_CHUNK)
                return null;
            expire(nowMs);
            String sender = Bytes.hex(blob, 1, 4);
            int xfer = ((blob[5] & 0xFF) << 8) | (blob[6] & 0xFF);
            int idx = blob[7] & 0xFF, total = blob[8] & 0xFF;
            if (total < 1 || total > MAX_CHUNKS || idx > total)
                return null;
            String key = sender + "/" + xfer;
            if (done.containsKey(key))
                return null;
            Partial p = parts.get(key);
            if (p == null || p.total != total) {
                p = new Partial(total);
                parts.put(key, p);
            }
            p.touched = nowMs;
            byte[] body = Arrays.copyOfRange(blob, HEADER, blob.length);
            if (idx == total) {
                if (body.length < 1)
                    return null;
                p.lenXor = body[0] & 0xFF;
                p.parity = Arrays.copyOfRange(body, 1, body.length);
            } else {
                if (body.length > DATA_BODY)
                    return null;
                p.bodies[idx] = body;
            }
            int have = p.have();
            if (have == total - 1 && p.parity != null) {
                recover(p);
                have = p.have();
            }
            if (have < total)
                return null;
            parts.remove(key);
            done.put(key, nowMs);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            for (byte[] b : p.bodies)
                out.write(b, 0, b.length);
            return out.toByteArray();
        }

        private static void recover(Partial p) {
            int missing = -1, lenXor = p.lenXor;
            byte[] x = Arrays.copyOf(p.parity, DATA_BODY);
            for (int i = 0; i < p.total; i++) {
                byte[] b = p.bodies[i];
                if (b == null) {
                    missing = i;
                    continue;
                }
                lenXor ^= b.length;
                for (int k = 0; k < b.length; k++)
                    x[k] ^= b[k];
            }
            if (missing < 0 || lenXor > DATA_BODY)
                return;
            p.bodies[missing] = Arrays.copyOf(x, lenXor);
        }

        /** How far along a transfer is: [have, total], or null. */
        public synchronized int[] progress(String sender, int xferId) {
            Partial p = parts.get(sender + "/" + xferId);
            return p == null ? null : new int[] { p.have(), p.total };
        }

        private void expire(long now) {
            for (Iterator<Map.Entry<String, Partial>> it = parts.entrySet()
                    .iterator(); it.hasNext();) {
                if (now - it.next().getValue().touched > TTL_MS)
                    it.remove();
            }
            for (Iterator<Map.Entry<String, Long>> it = done.entrySet()
                    .iterator(); it.hasNext();) {
                if (now - it.next().getValue() > TTL_MS)
                    it.remove();
            }
        }
    }

    // ------------------------------------------------------------- helpers

    public static byte[] deflate(byte[] data) {
        Deflater d = new Deflater(Deflater.BEST_COMPRESSION, true);
        try {
            d.setInput(data);
            d.finish();
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[1024];
            while (!d.finished()) {
                int n = d.deflate(buf);
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        } finally {
            d.end();
        }
    }

    public static byte[] inflate(byte[] data, int maxOut) {
        Inflater inf = new Inflater(true);
        try {
            // Raw inflate needs one dummy byte past the end on some zlib builds.
            byte[] in = Arrays.copyOf(data, data.length + 1);
            inf.setInput(in);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[1024];
            while (!inf.finished()) {
                int n = inf.inflate(buf);
                if (n == 0 && (inf.needsInput() || inf.needsDictionary()))
                    break;
                out.write(buf, 0, n);
                if (out.size() > maxOut)
                    return null;
            }
            return inf.finished() ? out.toByteArray() : null;
        } catch (DataFormatException e) {
            return null;
        } finally {
            inf.end();
        }
    }

    /** CRC-16/CCITT-FALSE. */
    public static int crc16(byte[] data) {
        int crc = 0xFFFF;
        for (byte b : data) {
            crc ^= (b & 0xFF) << 8;
            for (int i = 0; i < 8; i++)
                crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF
                        : (crc << 1) & 0xFFFF;
        }
        return crc;
    }
}
