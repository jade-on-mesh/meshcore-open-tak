package com.jadeonmesh.meshcore.atak.media;

import java.io.ByteArrayOutputStream;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

/**
 * Photo messages in direct mode: the same AV1-still search as the app's
 * lib/vox/image_codec.dart (minus its text/face focus step), so a photo sent
 * from ATAK costs the same airtime and looks the same as one sent from the
 * app. Payload on air = [version 1][AV1 OBUs].
 */
public final class ImageCodec {
    private ImageCodec() {
    }

    public static final int BASE_BUDGET = 2750; // one 20 s Mimi clip
    public static final int WORK_SIDE = 768;
    public static final int TRIAL_SPEED = 10;
    public static final int PAYLOAD_VERSION = 1;
    static final int[] SIDES = { 128, 160, 192, 224, 256, 288, 320, 352, 384,
            448, 512, 576, 640, 768 };

    public static final class Rgb {
        public final int w, h;
        public final byte[] px;

        Rgb(int w, int h, byte[] px) {
            this.w = w;
            this.h = h;
            this.px = px;
        }
    }

    public static final class Encoded {
        public byte[] payload;
        public int aspectCode;
        public Rgb preview;
    }

    /** detail 0 = standard (1 voice clip of airtime), 1 = more (2 clips). */
    public static int budget(int detail) {
        return BASE_BUDGET * (detail >= 1 ? 2 : 1);
    }

    public static int aspectCode(double aspect) {
        return (int) Math.max(20, Math.min(600, Math.round(aspect * 100)));
    }

    // ------------------------------------------------------------ pixels

    static Rgb fromBitmap(Bitmap b) {
        int w = b.getWidth(), h = b.getHeight();
        int[] argb = new int[w * h];
        b.getPixels(argb, 0, w, 0, 0, w, h);
        byte[] px = new byte[w * h * 3];
        for (int i = 0; i < argb.length; i++) {
            px[i * 3] = (byte) (argb[i] >> 16);
            px[i * 3 + 1] = (byte) (argb[i] >> 8);
            px[i * 3 + 2] = (byte) argb[i];
        }
        return new Rgb(w, h, px);
    }

    static Bitmap toBitmap(Rgb r) {
        int[] argb = new int[r.w * r.h];
        for (int i = 0; i < argb.length; i++)
            argb[i] = 0xFF000000 | ((r.px[i * 3] & 0xFF) << 16)
                    | ((r.px[i * 3 + 1] & 0xFF) << 8) | (r.px[i * 3 + 2] & 0xFF);
        return Bitmap.createBitmap(argb, r.w, r.h, Bitmap.Config.ARGB_8888);
    }

    static Rgb resize(Rgb src, int w, int h) {
        if (src.w == w && src.h == h)
            return src;
        Bitmap b = toBitmap(src);
        Bitmap s = Bitmap.createScaledBitmap(b, w, h, true);
        Rgb out = fromBitmap(s);
        if (s != b)
            s.recycle();
        b.recycle();
        return out;
    }

    static int[] fitSize(int w, int h, int side) {
        double s = Math.min(1.0, side / (double) Math.max(w, h));
        return new int[] { Math.max(8, (int) Math.round(w * s)),
                Math.max(8, (int) Math.round(h * s)) };
    }

    static double psnr(Rgb a, Rgb b) {
        double se = 0;
        int n = a.w * a.h;
        for (int i = 0, p = 0; i < n; i++, p += 3) {
            double la = 0.299 * (a.px[p] & 0xFF) + 0.587 * (a.px[p + 1] & 0xFF)
                    + 0.114 * (a.px[p + 2] & 0xFF);
            double lb = 0.299 * (b.px[p] & 0xFF) + 0.587 * (b.px[p + 1] & 0xFF)
                    + 0.114 * (b.px[p + 2] & 0xFF);
            se += (la - lb) * (la - lb);
        }
        double mse = se / Math.max(1, n);
        return mse <= 1e-9 ? 99 : 10 * Math.log10(255 * 255 / mse);
    }

    /** Decodes a JPEG/PNG and scales it to the reference size. */
    public static Rgb loadReference(byte[] image) {
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(image, 0, image.length, o);
        if (o.outWidth <= 0 || o.outHeight <= 0)
            return null;
        int sample = 1;
        while (Math.max(o.outWidth, o.outHeight) / (sample * 2) >= WORK_SIDE)
            sample *= 2;
        BitmapFactory.Options d = new BitmapFactory.Options();
        d.inSampleSize = sample;
        Bitmap b = BitmapFactory.decodeByteArray(image, 0, image.length, d);
        if (b == null)
            return null;
        int[] wh = fitSize(b.getWidth(), b.getHeight(), WORK_SIDE);
        Bitmap s = Bitmap.createScaledBitmap(b, wh[0], wh[1], true);
        Rgb r = fromBitmap(s);
        if (s != b)
            s.recycle();
        b.recycle();
        return r;
    }

    // ------------------------------------------------------------ codec

    private static byte[] encode(Rgb img, int q, int speed) {
        return NativeCodecs.av1Encode(img.px, img.w, img.h, q, speed, 2);
    }

    static Rgb decodeObus(byte[] obus) {
        byte[] r = NativeCodecs.av1Decode(obus);
        if (r == null || r.length < 4)
            return null;
        int w = ((r[0] & 0xFF) << 8) | (r[1] & 0xFF);
        int h = ((r[2] & 0xFF) << 8) | (r[3] & 0xFF);
        byte[] px = new byte[w * h * 3];
        System.arraycopy(r, 4, px, 0, px.length);
        return new Rgb(w, h, px);
    }

    /** Smallest quantizer (best quality) that fits, by bisection. */
    private static Object[] fitQ(Rgb img, int budget, int speed) {
        int lo = 0, hi = 63;
        Object[] best = null;
        while (lo <= hi) {
            int q = (lo + hi) >> 1;
            byte[] data = encode(img, q, speed);
            if (data != null && data.length <= budget) {
                best = new Object[] { q, data };
                hi = q - 1;
            } else {
                lo = q + 1;
            }
        }
        return best;
    }

    /** Encodes [image] (JPEG/PNG) to fit [detail]'s budget. */
    public static Encoded encodeImage(byte[] image, int detail) {
        if (!NativeCodecs.hasAv1())
            throw new IllegalStateException(
                    "This plugin build has no AV1 encoder (build libaom first)");
        Rgb ref = loadReference(image);
        if (ref == null)
            throw new IllegalArgumentException("Not a picture");
        int budget = budget(detail) - 1;
        int w = ref.w, h = ref.h, longSide = Math.max(w, h);
        int bestW = 0, bestH = 0;
        double bestScore = -1;
        int worse = 0;
        for (int side : SIDES) {
            if (side > longSide && bestScore >= 0)
                break;
            int[] wh = fitSize(w, h, side);
            Rgb scaled = resize(ref, wh[0], wh[1]);
            Object[] fit = fitQ(scaled, budget, TRIAL_SPEED);
            if (fit == null)
                continue;
            Rgb dec = decodeObus((byte[]) fit[1]);
            if (dec == null)
                continue;
            double s = psnr(ref, resize(dec, w, h));
            if (s > bestScore) {
                bestScore = s;
                bestW = wh[0];
                bestH = wh[1];
                worse = 0;
            } else if (++worse >= 2) {
                break;
            }
            if (side >= longSide)
                break;
        }
        if (bestScore < 0)
            throw new IllegalStateException("Photo does not fit the mesh budget");
        Rgb scaled = resize(ref, bestW, bestH);
        Object[] good = fitQ(scaled, budget, 6);
        byte[] data = null;
        if (good != null) {
            for (int q = (Integer) good[0]; q <= 63; q++) {
                byte[] d = encode(scaled, q, 4);
                if (d != null && d.length <= budget) {
                    data = d;
                    break;
                }
            }
            if (data == null)
                data = (byte[]) good[1];
        }
        if (data == null) {
            Object[] f = fitQ(scaled, budget, TRIAL_SPEED);
            data = f == null ? null : (byte[]) f[1];
        }
        if (data == null)
            throw new IllegalStateException("Photo does not fit the mesh budget");
        Encoded e = new Encoded();
        e.payload = new byte[data.length + 1];
        e.payload[0] = PAYLOAD_VERSION;
        System.arraycopy(data, 0, e.payload, 1, data.length);
        e.aspectCode = aspectCode(w / (double) h);
        e.preview = decodeObus(data);
        return e;
    }

    /** Decodes a received payload to JPEG, or null. */
    public static byte[] payloadToJpeg(byte[] payload) {
        if (payload.length < 2 || payload[0] != PAYLOAD_VERSION
                || !NativeCodecs.hasAv1())
            return null;
        byte[] obus = new byte[payload.length - 1];
        System.arraycopy(payload, 1, obus, 0, obus.length);
        Rgb r = decodeObus(obus);
        return r == null ? null : jpeg(r);
    }

    public static byte[] jpeg(Rgb r) {
        Bitmap b = toBitmap(r);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        b.compress(Bitmap.CompressFormat.JPEG, 92, out);
        b.recycle();
        return out.toByteArray();
    }
}
