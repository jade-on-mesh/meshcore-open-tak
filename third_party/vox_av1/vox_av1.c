// MeshCore Open TAK - AV1 still images for mesh image messages.
//
// Encodes RGB888 to a single AV1 key frame (reduced still-picture header,
// 4:2:0, full-range BT.601) and returns the raw OBUs with the temporal
// delimiter removed: no AVIF container, so every byte on air is picture
// data. Decoding takes those OBUs back to RGB888.
//
// Built on libaom (BSD-2-Clause). Exported with C linkage for dart:ffi.
// One source for every platform: Android (android/app/src/main/cpp), the
// macOS app (vox_av1.podspec) and the Windows/Linux builds (build.yml).

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "aom/aom_decoder.h"
#include "aom/aom_encoder.h"
#include "aom/aomcx.h"
#include "aom/aomdx.h"

#if defined(_WIN32)
#define VOX_EXPORT __declspec(dllexport)
#else
#define VOX_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

static inline uint8_t clamp8(int v) {
  return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

// Full-range BT.601, fixed point (x 2^16).
static void rgb_to_i420(const uint8_t *rgb, int w, int h, aom_image_t *img) {
  for (int y = 0; y < h; y++) {
    uint8_t *Y = img->planes[AOM_PLANE_Y] + y * img->stride[AOM_PLANE_Y];
    const uint8_t *p = rgb + (size_t)y * w * 3;
    for (int x = 0; x < w; x++, p += 3) {
      Y[x] = clamp8((19595 * p[0] + 38470 * p[1] + 7471 * p[2] + 32768) >> 16);
    }
  }
  const int cw = (w + 1) / 2, ch = (h + 1) / 2;
  for (int cy = 0; cy < ch; cy++) {
    uint8_t *U = img->planes[AOM_PLANE_U] + cy * img->stride[AOM_PLANE_U];
    uint8_t *V = img->planes[AOM_PLANE_V] + cy * img->stride[AOM_PLANE_V];
    for (int cx = 0; cx < cw; cx++) {
      int r = 0, g = 0, b = 0, n = 0;
      for (int dy = 0; dy < 2; dy++) {
        int yy = cy * 2 + dy;
        if (yy >= h) continue;
        for (int dx = 0; dx < 2; dx++) {
          int xx = cx * 2 + dx;
          if (xx >= w) continue;
          const uint8_t *q = rgb + ((size_t)yy * w + xx) * 3;
          r += q[0];
          g += q[1];
          b += q[2];
          n++;
        }
      }
      r /= n;
      g /= n;
      b /= n;
      U[cx] = clamp8(((-11059 * r - 21709 * g + 32768 * b) >> 16) + 128);
      V[cx] = clamp8(((32768 * r - 27439 * g - 5329 * b) >> 16) + 128);
    }
  }
}

// Chroma is upsampled bilinearly (centre-sited 4:2:0).
static void i420_to_rgb(const aom_image_t *img, uint8_t *rgb) {
  const int w = (int)img->d_w, h = (int)img->d_h;
  const int cw = (w + 1) / 2, ch = (h + 1) / 2;
  const int hbd = (img->fmt & AOM_IMG_FMT_HIGHBITDEPTH) != 0;
  const int shift = hbd ? (int)img->bit_depth - 8 : 0;
#define SAMPLE(plane, xx, yy)                                                  \
  (hbd ? (((const uint16_t *)(img->planes[plane] +                             \
                              (yy) * img->stride[plane]))[xx] >> shift)         \
       : img->planes[plane][(yy) * img->stride[plane] + (xx)])
  for (int y = 0; y < h; y++) {
    float fy = (y - 0.5f) * 0.5f;
    int y0 = (int)(fy < 0 ? -1 : fy);
    float wy = fy - y0;
    int ya = y0 < 0 ? 0 : y0, yb = y0 + 1 >= ch ? ch - 1 : y0 + 1;
    uint8_t *out = rgb + (size_t)y * w * 3;
    for (int x = 0; x < w; x++) {
      float fx = (x - 0.5f) * 0.5f;
      int x0 = (int)(fx < 0 ? -1 : fx);
      float wx = fx - x0;
      int xa = x0 < 0 ? 0 : x0, xb = x0 + 1 >= cw ? cw - 1 : x0 + 1;
      float u = (1 - wy) * ((1 - wx) * SAMPLE(1, xa, ya) + wx * SAMPLE(1, xb, ya)) +
                wy * ((1 - wx) * SAMPLE(1, xa, yb) + wx * SAMPLE(1, xb, yb)) - 128;
      float v = (1 - wy) * ((1 - wx) * SAMPLE(2, xa, ya) + wx * SAMPLE(2, xb, ya)) +
                wy * ((1 - wx) * SAMPLE(2, xa, yb) + wx * SAMPLE(2, xb, yb)) - 128;
      float Y = SAMPLE(0, x, y);
      out[x * 3 + 0] = clamp8((int)(Y + 1.402f * v + 0.5f));
      out[x * 3 + 1] = clamp8((int)(Y - 0.344136f * u - 0.714136f * v + 0.5f));
      out[x * 3 + 2] = clamp8((int)(Y + 1.772f * u + 0.5f));
    }
  }
#undef SAMPLE
}

// Encodes rgb (w*h*3 bytes) at quantizer q (0 best .. 63 smallest) and
// libaom speed (0 slowest/best .. 9). speed 10 selects libaom's all-intra
// mode at its fastest setting: about 10x quicker but less efficient, for
// trial encodes while searching sizes. Writes OBUs to out. Returns the number
// of bytes written, -(bytes needed) if out_cap is too small, or 0 on error.
VOX_EXPORT int vox_av1_encode(const uint8_t *rgb, int w, int h, int q, int speed,
                              int threads, uint8_t *out, int out_cap) {
  if (!rgb || w < 1 || h < 1 || q < 0 || q > 63) return 0;
  aom_codec_iface_t *iface = aom_codec_av1_cx();
  aom_codec_enc_cfg_t cfg;
  const int trial = speed >= 10;
  if (trial) speed = 9;
  if (aom_codec_enc_config_default(
          iface, &cfg, trial ? AOM_USAGE_ALL_INTRA : AOM_USAGE_GOOD_QUALITY)) {
    return 0;
  }
  cfg.g_w = (unsigned)w;
  cfg.g_h = (unsigned)h;
  cfg.g_bit_depth = AOM_BITS_8;
  cfg.g_input_bit_depth = 8;
  cfg.g_profile = 0;
  cfg.g_threads = (unsigned)(threads > 0 ? threads : 1);
  cfg.g_limit = 1;  // single frame => still_picture, reduced header
  cfg.g_lag_in_frames = 0;
  cfg.kf_max_dist = 0;
  cfg.rc_end_usage = AOM_Q;
  cfg.rc_min_quantizer = (unsigned)q;
  cfg.rc_max_quantizer = (unsigned)q;

  aom_codec_ctx_t ctx;
  if (aom_codec_enc_init(&ctx, iface, &cfg, 0)) return 0;
  // (all-intra needs no extra controls; it implies a single key frame)
  aom_codec_control(&ctx, AOME_SET_CPUUSED, speed);
  aom_codec_control(&ctx, AOME_SET_CQ_LEVEL, q);
  aom_codec_control(&ctx, AOME_SET_TUNING, AOM_TUNE_SSIM);
  aom_codec_control(&ctx, AV1E_SET_COLOR_RANGE, AOM_CR_FULL_RANGE);
  aom_codec_control(&ctx, AV1E_SET_MATRIX_COEFFICIENTS, AOM_CICP_MC_BT_601);
  aom_codec_control(&ctx, AV1E_SET_ROW_MT, 1);

  aom_image_t img;
  if (!aom_img_alloc(&img, AOM_IMG_FMT_I420, (unsigned)w, (unsigned)h, 16)) {
    aom_codec_destroy(&ctx);
    return 0;
  }
  img.range = AOM_CR_FULL_RANGE;
  img.mc = AOM_CICP_MC_BT_601;
  rgb_to_i420(rgb, w, h, &img);

  size_t cap = 4096, len = 0;
  uint8_t *buf = (uint8_t *)malloc(cap);
  int ok = buf != NULL;
  for (int pass = 0; ok && pass < 2; pass++) {
    // pass 0: the frame; pass 1: flush.
    if (aom_codec_encode(&ctx, pass == 0 ? &img : NULL, 0, 1, 0)) {
      ok = 0;
      break;
    }
    aom_codec_iter_t iter = NULL;
    const aom_codec_cx_pkt_t *pkt;
    while ((pkt = aom_codec_get_cx_data(&ctx, &iter)) != NULL) {
      if (pkt->kind != AOM_CODEC_CX_FRAME_PKT) continue;
      size_t n = pkt->data.frame.sz;
      if (len + n > cap) {
        while (len + n > cap) cap *= 2;
        uint8_t *nb = (uint8_t *)realloc(buf, cap);
        if (!nb) {
          ok = 0;
          break;
        }
        buf = nb;
      }
      memcpy(buf + len, pkt->data.frame.buf, n);
      len += n;
    }
  }
  aom_img_free(&img);
  aom_codec_destroy(&ctx);
  if (!ok || len == 0) {
    free(buf);
    return 0;
  }
  // Drop a leading temporal delimiter OBU (0x12 0x00); the decoder side adds
  // it back.
  size_t start = (len >= 2 && buf[0] == 0x12 && buf[1] == 0x00) ? 2 : 0;
  int outLen = (int)(len - start);
  if (!out || outLen > out_cap) {
    free(buf);
    return -outLen;
  }
  memcpy(out, buf + start, (size_t)outLen);
  free(buf);
  return outLen;
}

// Decodes OBUs (as produced by vox_av1_encode) to RGB888. On success returns
// 1 and stores the size; rgb_out must hold max_w*max_h*3 bytes. Returns
// -1 if the picture is larger than max_w x max_h (size still stored), 0 on
// error.
VOX_EXPORT int vox_av1_decode(const uint8_t *data, int len, uint8_t *rgb_out,
                              int max_w, int max_h, int *w_out, int *h_out) {
  if (!data || len < 1) return 0;
  uint8_t *tu = (uint8_t *)malloc((size_t)len + 2);
  if (!tu) return 0;
  tu[0] = 0x12;
  tu[1] = 0x00;
  memcpy(tu + 2, data, (size_t)len);

  aom_codec_ctx_t ctx;
  aom_codec_dec_cfg_t cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.threads = 2;
  cfg.allow_lowbitdepth = 1;
  int result = 0;
  if (aom_codec_dec_init(&ctx, aom_codec_av1_dx(), &cfg, 0) == AOM_CODEC_OK) {
    if (aom_codec_decode(&ctx, tu, (size_t)len + 2, NULL) == AOM_CODEC_OK) {
      aom_codec_iter_t iter = NULL;
      aom_image_t *img = aom_codec_get_frame(&ctx, &iter);
      if (img && (img->fmt & ~AOM_IMG_FMT_HIGHBITDEPTH) == AOM_IMG_FMT_I420) {
        if (w_out) *w_out = (int)img->d_w;
        if (h_out) *h_out = (int)img->d_h;
        if ((int)img->d_w > max_w || (int)img->d_h > max_h || !rgb_out) {
          result = -1;
        } else {
          i420_to_rgb(img, rgb_out);
          result = 1;
        }
      }
    }
    aom_codec_destroy(&ctx);
  }
  free(tu);
  return result;
}

// ---------------------------------------------------------------- clips
//
// Short video clips: the same 4:2:0 full-range BT.601 frames as the stills,
// coded as one AV1 sequence (a key frame, then inter frames). The stream is
// packed as one record per encoder packet: LEB128 length, then the OBUs of
// that temporal unit with its temporal delimiter removed (the decoder adds
// it back). A clip is only ever shown once all of it is here, so nothing in
// it needs to survive loss.

static size_t leb128_put(uint8_t *p, size_t v) {
  size_t n = 0;
  do {
    uint8_t b = (uint8_t)(v & 0x7f);
    v >>= 7;
    if (v) b |= 0x80;
    if (p) p[n] = b;
    n++;
  } while (v);
  return n;
}

static int leb128_get(const uint8_t *p, size_t len, size_t *pos, size_t *v) {
  size_t out = 0;
  for (int i = 0; i < 8; i++) {
    if (*pos >= len) return 0;
    uint8_t b = p[(*pos)++];
    out |= (size_t)(b & 0x7f) << (7 * i);
    if (!(b & 0x80)) {
      *v = out;
      return 1;
    }
  }
  return 0;
}

// Encodes `frames` RGB888 pictures (w*h*3 bytes each, back to back) shown at
// `fps`, at constant quantizer q (0 best .. 63 smallest) and libaom speed
// (0 slowest .. 9 fastest). Writes the packed stream to out. Returns the
// bytes written, -(bytes needed) if out_cap is too small, or 0 on error.
VOX_EXPORT int vox_av1_clip_encode(const uint8_t *rgb, int w, int h,
                                   int frames, int fps, int q, int speed,
                                   int threads, uint8_t *out, int out_cap) {
  if (!rgb || w < 2 || h < 2 || frames < 1 || fps < 1 || q < 0 || q > 63) {
    return 0;
  }
  if (speed < 0) speed = 0;
  if (speed > 9) speed = 9;
  aom_codec_iface_t *iface = aom_codec_av1_cx();
  aom_codec_enc_cfg_t cfg;
  if (aom_codec_enc_config_default(iface, &cfg, AOM_USAGE_GOOD_QUALITY)) {
    return 0;
  }
  cfg.g_w = (unsigned)w;
  cfg.g_h = (unsigned)h;
  cfg.g_bit_depth = AOM_BITS_8;
  cfg.g_input_bit_depth = 8;
  cfg.g_profile = 0;
  cfg.g_threads = (unsigned)(threads > 0 ? threads : 1);
  cfg.g_timebase.num = 1;
  cfg.g_timebase.den = fps;
  cfg.g_limit = (unsigned)frames;
  cfg.g_lag_in_frames = frames < 19 ? (unsigned)frames : 19;
  cfg.g_error_resilient = 0;
  cfg.rc_dropframe_thresh = 0;
  cfg.kf_mode = AOM_KF_AUTO;
  cfg.kf_min_dist = 0;
  cfg.kf_max_dist = (unsigned)frames + 1;  // one key frame, at the start
  cfg.rc_end_usage = AOM_Q;
  cfg.rc_min_quantizer = (unsigned)q;
  cfg.rc_max_quantizer = (unsigned)q;

  aom_codec_ctx_t ctx;
  if (aom_codec_enc_init(&ctx, iface, &cfg, 0)) return 0;
  aom_codec_control(&ctx, AOME_SET_CPUUSED, speed);
  aom_codec_control(&ctx, AOME_SET_CQ_LEVEL, q);
  aom_codec_control(&ctx, AOME_SET_TUNING, AOM_TUNE_SSIM);
  aom_codec_control(&ctx, AV1E_SET_COLOR_RANGE, AOM_CR_FULL_RANGE);
  aom_codec_control(&ctx, AV1E_SET_MATRIX_COEFFICIENTS, AOM_CICP_MC_BT_601);
  aom_codec_control(&ctx, AV1E_SET_ROW_MT, 1);

  aom_image_t img;
  if (!aom_img_alloc(&img, AOM_IMG_FMT_I420, (unsigned)w, (unsigned)h, 16)) {
    aom_codec_destroy(&ctx);
    return 0;
  }
  img.range = AOM_CR_FULL_RANGE;
  img.mc = AOM_CICP_MC_BT_601;

  size_t cap = 16384, len = 0;
  uint8_t *buf = (uint8_t *)malloc(cap);
  int ok = buf != NULL;
  const size_t frame_bytes = (size_t)w * h * 3;
  // frames inputs, then flushes until the encoder has nothing left.
  for (int i = 0; ok; i++) {
    const int flushing = i >= frames;
    if (!flushing) rgb_to_i420(rgb + frame_bytes * (size_t)i, w, h, &img);
    if (aom_codec_encode(&ctx, flushing ? NULL : &img, i, 1, 0)) {
      ok = 0;
      break;
    }
    int got = 0;
    aom_codec_iter_t iter = NULL;
    const aom_codec_cx_pkt_t *pkt;
    while ((pkt = aom_codec_get_cx_data(&ctx, &iter)) != NULL) {
      if (pkt->kind != AOM_CODEC_CX_FRAME_PKT) continue;
      got = 1;
      const uint8_t *d = (const uint8_t *)pkt->data.frame.buf;
      size_t n = pkt->data.frame.sz;
      if (n >= 2 && d[0] == 0x12 && d[1] == 0x00) {
        d += 2;
        n -= 2;
      }
      size_t need = len + leb128_put(NULL, n) + n;
      if (need > cap) {
        while (need > cap) cap *= 2;
        uint8_t *nb = (uint8_t *)realloc(buf, cap);
        if (!nb) {
          ok = 0;
          break;
        }
        buf = nb;
      }
      len += leb128_put(buf + len, n);
      memcpy(buf + len, d, n);
      len += n;
    }
    if (flushing && !got) break;
    if (i > frames + 64) break;  // a flush that never ends
  }
  aom_img_free(&img);
  aom_codec_destroy(&ctx);
  if (!ok || len == 0) {
    free(buf);
    return 0;
  }
  if (!out || (int)len > out_cap) {
    free(buf);
    return -(int)len;
  }
  memcpy(out, buf, len);
  free(buf);
  return (int)len;
}

// Decodes a stream from vox_av1_clip_encode into up to max_frames RGB888
// pictures of w*h (rgb_out holds max_frames*w*h*3 bytes). Returns the number
// of frames decoded, -1 if a frame isn't w*h, or 0 on error.
VOX_EXPORT int vox_av1_clip_decode(const uint8_t *data, int len,
                                   uint8_t *rgb_out, int max_frames, int w,
                                   int h) {
  if (!data || len < 1 || !rgb_out || max_frames < 1 || w < 1 || h < 1) {
    return 0;
  }
  aom_codec_ctx_t ctx;
  aom_codec_dec_cfg_t cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.threads = 2;
  cfg.allow_lowbitdepth = 1;
  if (aom_codec_dec_init(&ctx, aom_codec_av1_dx(), &cfg, 0) != AOM_CODEC_OK) {
    return 0;
  }
  uint8_t *tu = NULL;
  size_t tu_cap = 0, pos = 0;
  int frames = 0, result = 0;
  const size_t frame_bytes = (size_t)w * h * 3;
  while (pos < (size_t)len) {
    size_t n;
    if (!leb128_get(data, (size_t)len, &pos, &n) || n > (size_t)len - pos) {
      goto out;
    }
    if (n + 2 > tu_cap) {
      tu_cap = n + 2;
      uint8_t *nb = (uint8_t *)realloc(tu, tu_cap);
      if (!nb) goto out;
      tu = nb;
    }
    tu[0] = 0x12;
    tu[1] = 0x00;
    memcpy(tu + 2, data + pos, n);
    pos += n;
    if (aom_codec_decode(&ctx, tu, n + 2, NULL) != AOM_CODEC_OK) goto out;
    aom_codec_iter_t iter = NULL;
    aom_image_t *img;
    while ((img = aom_codec_get_frame(&ctx, &iter)) != NULL) {
      if ((img->fmt & ~AOM_IMG_FMT_HIGHBITDEPTH) != AOM_IMG_FMT_I420) {
        goto out;
      }
      if ((int)img->d_w != w || (int)img->d_h != h) {
        result = -1;
        goto out;
      }
      if (frames < max_frames) {
        i420_to_rgb(img, rgb_out + frame_bytes * (size_t)frames);
        frames++;
      }
    }
  }
  result = frames;
out:
  free(tu);
  aom_codec_destroy(&ctx);
  return result;
}
