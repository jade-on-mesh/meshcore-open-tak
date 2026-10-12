package com.jadeonmesh.meshcore.atak.core;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Byte helpers shared by the wire formats. Pure Java, no Android. */
public final class Bytes {
    private Bytes() {
    }

    private static final char[] HEX = "0123456789abcdef".toCharArray();

    public static String hex(byte[] b) {
        return hex(b, 0, b.length);
    }

    public static String hex(byte[] b, int off, int len) {
        char[] out = new char[len * 2];
        for (int i = 0; i < len; i++) {
            int v = b[off + i] & 0xFF;
            out[i * 2] = HEX[v >>> 4];
            out[i * 2 + 1] = HEX[v & 0x0F];
        }
        return new String(out);
    }

    public static byte[] unhex(String s) {
        int n = s.length() / 2;
        byte[] out = new byte[n];
        for (int i = 0; i < n; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }

    public static boolean isHex(String s, int len) {
        if (s == null || s.length() != len)
            return false;
        for (int i = 0; i < len; i++) {
            char c = s.charAt(i);
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
                return false;
        }
        return true;
    }

    public static byte[] utf8(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }

    public static String utf8(byte[] b, int off, int len) {
        return new String(b, off, len, StandardCharsets.UTF_8);
    }

    /** UTF-8 bytes of the trimmed string, cut to maxBytes on a character boundary. */
    public static byte[] truncateUtf8(String s, int maxBytes) {
        byte[] out = utf8(s == null ? "" : s.trim());
        if (out.length <= maxBytes)
            return out;
        int cut = maxBytes;
        while (cut > 0 && (out[cut] & 0xC0) == 0x80)
            cut--;
        return Arrays.copyOf(out, cut);
    }

    public static int u8(byte[] b, int off) {
        return b[off] & 0xFF;
    }

    public static int u16le(byte[] b, int off) {
        return (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8);
    }

    public static long u32le(byte[] b, int off) {
        return ((long) (b[off] & 0xFF)) | ((long) (b[off + 1] & 0xFF) << 8)
                | ((long) (b[off + 2] & 0xFF) << 16)
                | ((long) (b[off + 3] & 0xFF) << 24);
    }

    public static int i32le(byte[] b, int off) {
        return (int) u32le(b, off);
    }

    public static void putU32le(byte[] b, int off, long v) {
        b[off] = (byte) v;
        b[off + 1] = (byte) (v >>> 8);
        b[off + 2] = (byte) (v >>> 16);
        b[off + 3] = (byte) (v >>> 24);
    }

    /** Signed byte as int. */
    public static int s8(byte[] b, int off) {
        return b[off];
    }

    /** Null-terminated (or end-of-range) UTF-8 string. */
    public static String cstring(byte[] b, int off, int maxLen) {
        int end = Math.min(b.length, off + maxLen);
        int z = off;
        while (z < end && b[z] != 0)
            z++;
        return utf8(b, off, z - off);
    }

    public static boolean startsWith(byte[] a, byte[] prefix) {
        if (a.length < prefix.length)
            return false;
        for (int i = 0; i < prefix.length; i++)
            if (a[i] != prefix[i])
                return false;
        return true;
    }

    /** Big-endian writer (team and voice formats). */
    public static final class W {
        private final ByteArrayOutputStream b = new ByteArrayOutputStream(64);

        public W u8(int v) {
            b.write(v & 0xFF);
            return this;
        }

        public W u16(int v) {
            u8(v >> 8);
            return u8(v);
        }

        public W u32(long v) {
            u16((int) (v >>> 16));
            return u16((int) v);
        }

        public W i32(int v) {
            return u32(v & 0xFFFFFFFFL);
        }

        public W i16(int v) {
            return u16(v & 0xFFFF);
        }

        public W bytes(byte[] v) {
            b.write(v, 0, v.length);
            return this;
        }

        public W bytes(byte[] v, int off, int len) {
            b.write(v, off, len);
            return this;
        }

        /** Length-prefixed UTF-8, at most maxBytes. */
        public W str(String s, int maxBytes) {
            byte[] e = truncateUtf8(s, maxBytes);
            u8(e.length);
            return bytes(e);
        }

        /** Unsigned LEB128 varint. */
        public W uvar(long v) {
            while ((v & ~0x7FL) != 0) {
                u8((int) ((v & 0x7F) | 0x80));
                v >>>= 7;
            }
            return u8((int) v);
        }

        /** Zigzag signed varint. */
        public W svar(long v) {
            return uvar((v << 1) ^ (v >> 63));
        }

        public int size() {
            return b.size();
        }

        public byte[] done() {
            return b.toByteArray();
        }
    }

    /** Big-endian reader. Methods throw IndexOutOfBounds past the end; callers guard with has(). */
    public static final class R {
        public final byte[] d;
        public int o;

        public R(byte[] d) {
            this.d = d;
        }

        public R(byte[] d, int offset) {
            this.d = d;
            this.o = offset;
        }

        public boolean has(int n) {
            return o + n <= d.length;
        }

        public int remaining() {
            return d.length - o;
        }

        public int u8() {
            if (o >= d.length)
                throw new IndexOutOfBoundsException();
            return d[o++] & 0xFF;
        }

        public int u16() {
            return (u8() << 8) | u8();
        }

        public long u32() {
            return ((long) u16() << 16) | u16();
        }

        public int i32() {
            return (int) u32();
        }

        public int i16() {
            return (short) u16();
        }

        public byte[] take(int n) {
            if (!has(n))
                throw new IndexOutOfBoundsException();
            byte[] v = Arrays.copyOfRange(d, o, o + n);
            o += n;
            return v;
        }

        /** Length-prefixed UTF-8, or null if truncated. */
        public String str() {
            if (!has(1))
                return null;
            int n = u8();
            if (!has(n))
                return null;
            String s = utf8(d, o, n);
            o += n;
            return s;
        }

        public long uvar() {
            long v = 0;
            int shift = 0;
            while (true) {
                int b = u8();
                v |= (long) (b & 0x7F) << shift;
                if ((b & 0x80) == 0)
                    return v;
                shift += 7;
                if (shift > 63)
                    throw new IndexOutOfBoundsException("varint too long");
            }
        }

        public long svar() {
            long u = uvar();
            return (u >>> 1) ^ -(u & 1);
        }
    }

    /** 32-bit FNV-1a of a string, for stable mesh ids derived from TAK uids. */
    public static long fnv1a32(String s) {
        long h = 0x811C9DC5L;
        for (int i = 0; i < s.length(); i++) {
            h ^= s.charAt(i);
            h = (h * 0x01000193L) & 0xFFFFFFFFL;
        }
        return h;
    }
}
