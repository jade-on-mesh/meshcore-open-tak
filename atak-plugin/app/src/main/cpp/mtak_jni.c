// MeshCore ATAK plugin - JNI shim over Codec2 and the app's AV1 still-image
// coder (vox_av1.c). Used in direct-radio mode only.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "codec2.h"

#define JNI_FN(name) Java_com_jadeonmesh_meshcore_atak_media_NativeCodecs_##name

#ifdef MTAK_HAVE_AOM
int vox_av1_encode(const uint8_t *rgb, int w, int h, int q, int speed,
                   int threads, uint8_t *out, int out_cap);
int vox_av1_decode(const uint8_t *data, int len, uint8_t *rgb_out, int max_w,
                   int max_h, int *w_out, int *h_out);
#endif

JNIEXPORT jboolean JNICALL JNI_FN(av1Available)(JNIEnv *env, jclass cls) {
#ifdef MTAK_HAVE_AOM
  return JNI_TRUE;
#else
  return JNI_FALSE;
#endif
}

// 8 kHz PCM -> Codec2 bits (whole frames; the tail is zero-padded).
JNIEXPORT jbyteArray JNICALL JNI_FN(c2Encode)(JNIEnv *env, jclass cls,
                                              jint mode, jshortArray pcm) {
  struct CODEC2 *c2 = codec2_create(mode);
  if (!c2) return NULL;
  const int spf = codec2_samples_per_frame(c2);
  const int bpf = codec2_bytes_per_frame(c2);
  const jsize n = (*env)->GetArrayLength(env, pcm);
  const int frames = (n + spf - 1) / spf;
  jshort *in = (*env)->GetShortArrayElements(env, pcm, NULL);
  short *frame = (short *)calloc((size_t)spf, sizeof(short));
  unsigned char *out = (unsigned char *)malloc((size_t)frames * bpf + 1);
  if (!in || !frame || !out) {
    if (in) (*env)->ReleaseShortArrayElements(env, pcm, in, JNI_ABORT);
    free(frame);
    free(out);
    codec2_destroy(c2);
    return NULL;
  }
  for (int f = 0; f < frames; f++) {
    const int off = f * spf;
    const int len = (n - off) < spf ? (n - off) : spf;
    memset(frame, 0, sizeof(short) * (size_t)spf);
    memcpy(frame, in + off, sizeof(short) * (size_t)len);
    codec2_encode(c2, out + (size_t)f * bpf, frame);
  }
  (*env)->ReleaseShortArrayElements(env, pcm, in, JNI_ABORT);
  jbyteArray res = (*env)->NewByteArray(env, frames * bpf);
  if (res)
    (*env)->SetByteArrayRegion(env, res, 0, frames * bpf, (const jbyte *)out);
  free(frame);
  free(out);
  codec2_destroy(c2);
  return res;
}

// Codec2 bits -> 8 kHz PCM. A partial trailing frame is dropped.
JNIEXPORT jshortArray JNICALL JNI_FN(c2Decode)(JNIEnv *env, jclass cls,
                                               jint mode, jbyteArray bits) {
  struct CODEC2 *c2 = codec2_create(mode);
  if (!c2) return NULL;
  const int spf = codec2_samples_per_frame(c2);
  const int bpf = codec2_bytes_per_frame(c2);
  const jsize n = (*env)->GetArrayLength(env, bits);
  const int frames = n / bpf;
  jbyte *in = (*env)->GetByteArrayElements(env, bits, NULL);
  short *out = (short *)malloc(sizeof(short) * (size_t)(frames * spf + 1));
  if (!in || !out) {
    if (in) (*env)->ReleaseByteArrayElements(env, bits, in, JNI_ABORT);
    free(out);
    codec2_destroy(c2);
    return NULL;
  }
  for (int f = 0; f < frames; f++)
    codec2_decode(c2, out + (size_t)f * spf,
                  (const unsigned char *)in + (size_t)f * bpf);
  (*env)->ReleaseByteArrayElements(env, bits, in, JNI_ABORT);
  jshortArray res = (*env)->NewShortArray(env, frames * spf);
  if (res) (*env)->SetShortArrayRegion(env, res, 0, frames * spf, out);
  free(out);
  codec2_destroy(c2);
  return res;
}

// RGB888 -> AV1 OBUs (no temporal delimiter), or null.
JNIEXPORT jbyteArray JNICALL JNI_FN(av1Encode)(JNIEnv *env, jclass cls,
                                               jbyteArray rgb, jint w, jint h,
                                               jint q, jint speed,
                                               jint threads) {
#ifdef MTAK_HAVE_AOM
  jsize n = (*env)->GetArrayLength(env, rgb);
  if (n < w * h * 3) return NULL;
  jbyte *px = (*env)->GetByteArrayElements(env, rgb, NULL);
  int cap = 16384;
  uint8_t *out = NULL;
  int len = 0;
  for (int tries = 0; tries < 6; tries++) {
    out = (uint8_t *)malloc((size_t)cap);
    if (!out) break;
    len = vox_av1_encode((const uint8_t *)px, w, h, q, speed, threads, out, cap);
    if (len > 0) break;
    free(out);
    out = NULL;
    if (len < 0) {
      cap = -len > cap * 2 ? -len : cap * 2; // native side asks for more room
    } else {
      break; // hard failure
    }
  }
  (*env)->ReleaseByteArrayElements(env, rgb, px, JNI_ABORT);
  if (!out || len <= 0) {
    free(out);
    return NULL;
  }
  jbyteArray res = (*env)->NewByteArray(env, len);
  if (res) (*env)->SetByteArrayRegion(env, res, 0, len, (const jbyte *)out);
  free(out);
  return res;
#else
  return NULL;
#endif
}

// AV1 OBUs -> [w u16 BE][h u16 BE][RGB888], or null.
JNIEXPORT jbyteArray JNICALL JNI_FN(av1Decode)(JNIEnv *env, jclass cls,
                                               jbyteArray obus) {
#ifdef MTAK_HAVE_AOM
  const int maxW = 2048, maxH = 2048;
  jsize n = (*env)->GetArrayLength(env, obus);
  jbyte *in = (*env)->GetByteArrayElements(env, obus, NULL);
  uint8_t *rgb = (uint8_t *)malloc((size_t)maxW * maxH * 3);
  int w = 0, h = 0, ok = 0;
  if (in && rgb)
    ok = vox_av1_decode((const uint8_t *)in, n, rgb, maxW, maxH, &w, &h);
  if (in) (*env)->ReleaseByteArrayElements(env, obus, in, JNI_ABORT);
  if (!ok || w <= 0 || h <= 0) {
    free(rgb);
    return NULL;
  }
  const int len = 4 + w * h * 3;
  jbyteArray res = (*env)->NewByteArray(env, len);
  if (res) {
    jbyte hdr[4] = {(jbyte)(w >> 8), (jbyte)w, (jbyte)(h >> 8), (jbyte)h};
    (*env)->SetByteArrayRegion(env, res, 0, 4, hdr);
    (*env)->SetByteArrayRegion(env, res, 4, w * h * 3, (const jbyte *)rgb);
  }
  free(rgb);
  return res;
#else
  return NULL;
#endif
}
